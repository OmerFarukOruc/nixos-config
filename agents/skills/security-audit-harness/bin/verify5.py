#!/usr/bin/env python3
"""Parent-only: build Phase 5 record-verifier prompts, one per confirmed and needs_validation record.
Usage: verify5.py --run DIR <prefix> [fingerprint ...]   (prefix r5 gives r5-NN; optional fingerprints limit the set)
Writes agents/<id>/prompt.md, creates loop-mounted scratch, writes plan/<prefix>-manifest.json."""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import blocks
import ledger
import runcfg
from runcfg import read_json, read_text, write_json, write_text

OUT = ledger.OUT
SKILL = ledger.SKILL
TARGET, COMMIT, NAME = runcfg.TARGET, runcfg.COMMIT, runcfg.NAME
SBX = f"{runcfg.BIN}/sa-sandbox --run {OUT}"
CPY = f"{runcfg.BIN}/sa-copy-src --run {OUT}"

def phase5_text():
    s = read_text(f"{SKILL}/VALIDATION-AND-REPORTING.md")
    return s[s.index("### Phase 5"):s.index("### Phase 6")].strip()

def main():
    prefix, rest = sys.argv[1], sys.argv[2:]
    replacements = {}
    if rest[:1] == ["--replacements"]:
        for item in read_json(rest[1]):
            replacements[item["record"]["fingerprint"]] = item
        rest = rest[2:]
    only = set(rest) | set(replacements)
    findings = [replacements[f["fingerprint"]]["record"] if f["fingerprint"] in replacements else f
                for f in read_json(f"{OUT}/findings.json")]
    units = ledger.load()
    kit = read_json(f"{OUT}/prompt-kit.json")
    arch = read_text(f"{OUT}/architecture.md")
    p5 = phase5_text()
    todo = [f for f in findings if f["verdict"] in ("confirmed", "needs_validation") and (not only or f["fingerprint"] in only)]
    manifest = []
    for i, rec in enumerate(todo, 1):
        vid = f"{prefix}-{i:02d}"
        fp = rec["fingerprint"]
        linked = [u for u in units if fp in u["result_fingerprints"]]
        files = []
        for u in linked:
            for r in u["selected_companion_blocks"]:
                f = r.split("#")[0]
                if f not in files:
                    files.append(f)
        vblocks = [(f"{f}#{sec}", blocks.extract(SKILL, f"{f}#{sec}")) for f in files for sec in ("Core discipline", "Validation rules")]
        prior_agents = sorted({c["agent_id"] for u in linked for c in u["local_checks"]} | {u["agent_id"] for u in linked if u["agent_id"]})
        repl = replacements.get(fp)
        if repl:
            prior_agents.append(repl["proposer"])
        repl_note = ("" if not repl else f"""
## Why you are checking this record

A Phase 5 record verifier (`{repl['proposer']}`) proposed the replacement record below for the record in findings.json. Its stated reason, verbatim:

```text
{repl['reason']}
```

The current findings.json record is in `{OUT}/findings.json` (fingerprint `{fp}`). Under the Phase 5 rules this replacement changes the root cause or observed result, so it is applied only after you, a new independent verifier, recheck the current source and independently reproduce any decisive local result. Return `verified` if the replacement record is correct as written, or `replace` with a corrected complete record.
""")
        base = f"{OUT}/agents/{vid}"
        if not os.path.ismount(f"{base}/scratch"):
            subprocess.run([f"{runcfg.BIN}/mkscratch", "--run", OUT, vid], check=True, stdout=subprocess.DEVNULL)
        ex = runcfg.CFG.get("execution_example")
        example_line = f"- {ex['label']}: `{SBX} {vid} -- {ex['command']}`. {ex['note']}" if ex else ""
        prompt = f"""# Record verifier `{vid}` (Phase 5)

You are a fresh `research` record verifier for a defensive security audit of {NAME} (`{TARGET}` at commit `{COMMIT}`), requested by the repository owner. You are NOT the orchestrator. You did not hunt this candidate and did not perform its Phase 3 validation; agents that worked on it before you: {', '.join(prior_agents)}. Check the structured record below against the current source, not any hunter write-up. Try to find what is wrong with it.

## Phase 5 instructions (verbatim from VALIDATION-AND-REPORTING.md)

```text
{p5}
```

## Source and local execution boundary for this run

- Read source in the target repository; never edit it. Your only writable path is `{base}/scratch/` (4 GiB ext4 mount); write files there with Bash here-docs (the Write tool refuses this path).
- Source copy for builds: `{CPY} {vid}` (trusted parent script, `git archive` of the reviewed commit into `scratch/src`).
- Run target-controlled code only as `{SBX} {vid} -- <cmd>`: cwd `scratch/src`, no external network (isolated loopback only), an empty allowlisted environment, read-only system folders plus the toolchain and dependency cache that run.json names, writes only in scratch, memory 5 GiB, swap 0, 512 tasks, 4 CPUs, 1180 s wall clock, 512 MiB per file, 4096 open files, 4 GiB disk. Two sandboxes run host-wide at once, so a call may wait.
{example_line}
- Never run target code or target scripts outside the sandbox, and never contact deployed endpoints or hosted services.
- Earlier promoted evidence cited by the record lives under `{OUT}/agents/<agent-id>/artifacts/` (read-only). For a `confirmed` record, reproduce the decisive local result yourself in your own sandbox before you return `verified`.
- If you return a replacement that needs new evidence, put it in `evidence/proof-1.txt` .. `evidence/proof-6.txt` in your scratch (at most 262144 bytes each, 1048576 total, regular single-link files), cite it as `agents/{vid}/artifacts/evidence/proof-N.txt`, and list it in `artifacts`. The parent promotes it with trusted code.
- Before returning, also write your JSON answer to `{base}/scratch/result.json`.

## architecture.md (facts to interpret the path)

{arch}

## Relevant companion blocks (verbatim)

""" + "\n\n".join(f"### `{r}`\n\n{t}" for r, t in vblocks) + f"""

{repl_note}
## The final record to verify

```json
{json.dumps(rec, indent=1, ensure_ascii=False)}
```

## Schema branches (verbatim from report-schema.json)

`confirmed`:
```json
{kit['schema_confirmed']}
```

`needs_validation`:
```json
{kit['schema_needs_validation']}
```

`rejected`:
```json
{kit['schema_rejected']}
```

## Return

Return exactly one JSON object through the structured output tool with these fields: `decision` (`verified` or `replace`), `fingerprint` (always `{fp}`), `reason` (empty string for `verified`; for `replace`, what is wrong and whether the change is material under the rules above), `record` (null for `verified`; for `replace`, the complete replacement record that exactly matches its schema branch, including `"verdict"`, no extra fields), and `artifacts` (scratch-relative evidence files to promote, empty if none).
"""
        if os.path.exists(f"{base}/prompt.md"):
            raise SystemExit(f"{base}/prompt.md exists")
        write_text(f"{base}/prompt.md", prompt, "x")
        manifest.append({"id": vid, "fingerprint": fp, "prompt_path": f"{base}/prompt.md", "units": [u["unit_key"] for u in linked]})
    write_json(f"{OUT}/plan/{prefix}-manifest.json", manifest, indent=1)
    args = f"{OUT}/plan/{prefix}-args.json"
    write_json(args, {"verifiers": [{"id": m["id"], "prompt_path": m["prompt_path"]} for m in manifest]})
    print(f"{len(manifest)} verifiers; workflow args in {args}")

if __name__ == "__main__":
    main()
