#!/usr/bin/env python3
"""Parent-only: build Phase 3 candidate-verifier prompts.
Usage: verify3.py --run DIR <consolidation.json>   where the file maps final fingerprint -> {"merge": [hunter fingerprints...]}.
Writes agents/<vid>/prompt.md (vid = v3-NN), creates loop-mounted scratch, prints a manifest."""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import blocks
import ledger
import runcfg
from runcfg import read_json, read_text, write_json, write_text

OUT, SKILL = ledger.OUT, ledger.SKILL
TARGET, COMMIT, NAME = runcfg.TARGET, runcfg.COMMIT, runcfg.NAME
SBX = f"{runcfg.BIN}/sa-sandbox --run {OUT}"
CPY = f"{runcfg.BIN}/sa-copy-src --run {OUT}"

def main():
    cons = read_json(sys.argv[1])
    cands = read_json(f"{OUT}/plan/candidates.json")
    units = ledger.load()
    kit = read_json(f"{OUT}/prompt-kit.json")
    arch = read_text(f"{OUT}/architecture.md")
    manifest = []
    for i, (fp, spec) in enumerate(sorted(cons.items()), 1):
        vid = f"v3-{i:02d}"
        recs, hunters = [], set()
        for src in spec["merge"]:
            for r in cands[src]["records"]:
                recs.append(r["record"]); hunters.add(r["hunter"])
        linked = [u for u in units if set(u["result_fingerprints"]) & set(spec["merge"])]
        files = []
        for u in linked:
            for r in u["selected_companion_blocks"]:
                f = r.split("#")[0]
                if f not in files:
                    files.append(f)
        vblocks = []
        for f in files:
            for sec in ("Core discipline", "Validation rules"):
                vblocks.append((f"{f}#{sec}", blocks.extract(SKILL, f"{f}#{sec}")))
        unit_ev = [{"unit_key": u["unit_key"], "coverage_id": u["coverage_id"], "surface": u["surface"], "boundary": u["boundary"],
                    "attack_class": u["attack_class"], "owner": u["agent_id"], "local_checks": u["local_checks"]} for u in linked]
        base = f"{OUT}/agents/{vid}"
        if not os.path.ismount(f"{base}/scratch"):
            subprocess.run([f"{runcfg.BIN}/mkscratch", "--run", OUT, vid], check=True, stdout=subprocess.DEVNULL)
        merged_note = ""
        if len(spec["merge"]) > 1:
            merged_note = (f"\nThe parent consolidated {len(spec['merge'])} hunter fingerprints that share one root cause: "
                           + ", ".join(f"`{m}`" for m in spec["merge"]) + f". Use the final fingerprint `{fp}` unless you establish that they are genuinely different root causes; then say so in the record description and keep `{fp}` for the strongest one.\n")
        ex = runcfg.CFG.get("execution_example")
        example_line = f"- {ex['label']}: `{SBX} {vid} -- {ex['command']}`. {ex['note']}" if ex else ""
        prompt = f"""# Candidate verifier `{vid}` (Phase 3)

You are a fresh `general` verifier for a defensive security audit of {NAME} (`{TARGET}` at commit `{COMMIT}`), requested by the repository owner. You are NOT the orchestrator, you did not hunt this candidate, and you receive no other verifier's conclusion. Hunters that proposed it: {', '.join(sorted(hunters))}.

## Verifier instructions (verbatim from VALIDATION-AND-REPORTING.md)

```text
{kit['verifier_prompt']}
```

## Promotion procedure (verbatim)

```text
{kit['verifier_promotion']}
```

## Source and local execution boundary for this run

- Read source in the target repository; never edit it. Your only writable path is `{base}/scratch/` (4 GiB ext4 mount); write files there with Bash here-docs (the Write tool refuses this path).
- Source copy for builds: `{CPY} {vid}` (trusted parent script, `git archive` of the reviewed commit into `scratch/src`). You may add a minimal test or harness inside `scratch/src`.
- Run target-controlled code only as `{SBX} {vid} -- <cmd>`: cwd `scratch/src`, no external network (isolated loopback only), an empty allowlisted environment, read-only system folders plus the toolchain and dependency cache that run.json names, writes only in scratch, memory 5 GiB, swap 0, 512 tasks, 4 CPUs, 1180 s wall clock, 512 MiB per file, 4096 open files, 4 GiB disk. It refuses to run if a control fails. Two sandboxes run host-wide at once, so a call may wait.
{example_line}
- Never run target code or target scripts outside the sandbox, and never contact deployed endpoints or hosted services.
- Evidence promotion allowlist: `evidence/proof-1.txt` .. `evidence/proof-6.txt` in your scratch, at most 262144 bytes each and 1048576 total, regular single-link files. Record the exact command, input, limits and decisive output lines. Refer to promoted evidence in the record as `agents/{vid}/artifacts/evidence/proof-N.txt`; the parent promotes after you finish. Record environment variable names only.
- Before returning, also write your JSON answer to `{base}/scratch/result.json`.

## architecture.md (facts to interpret the path)

{arch}

## Relevant companion blocks (verbatim)

""" + "\n\n".join(f"### `{r}`\n\n{t}" for r, t in vblocks) + f"""

## The candidate
{merged_note}
Hunter record(s), verbatim (they use `proposed_verdict` in place of `verdict`):

```json
{json.dumps(recs, indent=1, ensure_ascii=False)}
```

## Linked coverage units and their checks

```json
{json.dumps(unit_ev, indent=1, ensure_ascii=False)}
```

Hunter artifacts named there live under `{OUT}/agents/<hunter-id>/artifacts/` (read-only for you; they are hunter evidence, not yours). Hunter scratch directories hold their harness sources if you want to re-use an input, but reproduce any decisive result yourself.

Prior records with the same fingerprint: none (no prior run).

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

Return exactly one JSON object through the structured output tool: `{{"decision": "confirmed|needs_validation|rejected", "record": {{...}}, "artifacts": ["evidence/proof-N.txt", ...]}}`. `record` must exactly match the decision's schema branch (including `"verdict"`, no extra fields; repository-relative paths; positive lines; a multi-entry trace starts with `entrypoint` and ends with `sink`). `artifacts` lists the scratch-relative evidence files you want promoted (empty if none). Severity only for `confirmed`, and overall severity must not exceed demonstrated impact.
"""
        if os.path.exists(f"{base}/prompt.md"):
            raise SystemExit(f"{base}/prompt.md exists")
        write_text(f"{base}/prompt.md", prompt, "x")
        manifest.append({"id": vid, "fingerprint": fp, "merge": spec["merge"], "prompt_path": f"{base}/prompt.md", "units": [u["unit_key"] for u in linked]})
    write_json(f"{OUT}/plan/phase3-manifest.json", manifest, indent=1)
    args = f"{OUT}/plan/phase3-args.json"
    write_json(args, {"verifiers": [{"id": m["id"], "prompt_path": m["prompt_path"]} for m in manifest]})
    print(f"{len(manifest)} verifiers; workflow args in {args}")

if __name__ == "__main__":
    main()
