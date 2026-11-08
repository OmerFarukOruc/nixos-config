#!/usr/bin/env python3
"""Parent-only: build hunter prompts for one wave.
Usage: wave.py --run DIR <wave-number> <agent-id>=<coverage-id-file-or-unit-keys,comma> ...
Each assignment is agent-id=unitkey1,unitkey2 (unit_key bookkeeping field). Writes agents/<id>/prompt.md,
creates the loop-mounted scratch, marks units in_progress, and writes plan/wave-N.json and the workflow args
plan/wave-N-args.json, whose candidate_schema comes from report-schema.json."""
import hashlib
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import blocks
import ledger
import runcfg
from runcfg import read_json, read_text, write_json

OUT = ledger.OUT
SKILL = ledger.SKILL
TARGET, COMMIT, NAME = runcfg.TARGET, runcfg.COMMIT, runcfg.NAME
SBX = f"{runcfg.BIN}/sa-sandbox --run {OUT}"
CPY = f"{runcfg.BIN}/sa-copy-src --run {OUT}"

JSON_SCHEMA_KEYWORDS = {"type", "properties", "required", "items", "enum", "const", "pattern", "minLength", "maxLength",
                        "minimum", "maximum", "minItems", "maxItems", "uniqueItems", "additionalProperties", "description",
                        "oneOf", "anyOf", "allOf", "format"}

def without_extension_keywords(node):
    out = {}
    for k, v in node.items():
        if k not in JSON_SCHEMA_KEYWORDS:
            continue
        if k == "properties":
            v = {name: without_extension_keywords(sub) for name, sub in v.items()}
        elif k == "items" or (k == "additionalProperties" and isinstance(v, dict)):
            v = without_extension_keywords(v)
        elif k in ("oneOf", "anyOf", "allOf"):
            v = [without_extension_keywords(sub) for sub in v]
        out[k] = v
    return out

def candidate_schema():
    schema = without_extension_keywords(read_json(f"{SKILL}/report-schema.json"))
    branches = []
    for b in schema["items"]["oneOf"]:
        if b["properties"]["verdict"]["const"] not in ("confirmed", "needs_validation"):
            continue
        name = lambda k: "proposed_verdict" if k == "verdict" else k
        branches.append({**b, "properties": {name(k): v for k, v in b["properties"].items()},
                         "required": [name(k) for k in b["required"]]})
    return {"oneOf": branches}

def unit_map(u):
    keys = ["coverage_id", "canonical_refs", "surface", "boundary", "subsystem", "attack_class", "starting_paths",
            "ordinary_attack_class_block", "selected_companion_blocks", "excluded_blocks", "prior_status", "wave"]
    if "lifecycle" in u:
        keys.insert(6, "lifecycle")
    return {k: u[k] for k in keys}

def build(wave, agent_id, unit_keys, units, kit, arch, exclusions_note):
    mine = [u for u in units if u["unit_key"] in unit_keys]
    assert len(mine) == len(unit_keys), (agent_id, unit_keys)
    peers = [u for u in units if u["unit_key"] not in unit_keys and u["status"] in ("planned", "in_progress", "covered", "candidate", "blocked")]
    refs = []
    for u in mine:
        if u["ordinary_attack_class_block"] and u["ordinary_attack_class_block"] not in refs:
            refs.append(u["ordinary_attack_class_block"])
    for u in mine:
        for r in u["selected_companion_blocks"]:
            if r not in refs:
                refs.append(r)
    texts = {r: blocks.extract(SKILL, r) for r in refs}
    excluded = {}
    for u in mine:
        for e in u["excluded_blocks"]:
            if e["block"] not in refs:
                excluded.setdefault(e["block"], e["reason"])
    receipt = hashlib.sha256(f"{agent_id}:{wave}:{','.join(unit_keys)}".encode()).hexdigest()[:16]
    base = f"{OUT}/agents/{agent_id}"
    p = []
    p.append(f"# Part 1. Role\n\nYour goal is to find source-grounded security invariant failures in the coverage units assigned below for {NAME}, a defensive audit the repository owner requested. You must return exactly one JSON object matching the structured-result contract at the end of this prompt.\n\nYou are NOT the orchestrator. You are hunter `{agent_id}` in wave {wave}. Do only this assignment.")
    p.append("# Part 2. architecture.md (verbatim)\n\n" + arch)
    unit_json = json.dumps([unit_map(u) for u in mine], indent=1, ensure_ascii=False)
    p.append(f"# Part 3. Assigned coverage units (block maps from coverage-ledger.json)\n\nTarget repository (read-only): `{TARGET}` at commit `{COMMIT}`. Every path is repository-relative.\n\n```json\n{unit_json}\n```")
    p.append("# Part 4. Selected attack-class blocks (verbatim)\n\n" + "\n\n".join(f"## Block `{r}`\n\n{texts[r]}" for r in refs))
    p.append("# Part 5. Excluded blocks and reasons\n\n" + "\n".join(f"- `{b}`: {why}" for b, why in excluded.items()))
    p.append("# Part 6. Core hunting method (verbatim)\n\n```text\n" + kit["method"] + "\n```\n\n## Promotion procedure (verbatim)\n\n```text\n" + kit["promotion"] + "\n```")
    p.append("# Part 7. Core validation rules (verbatim)\n\n```text\n" + kit["validation"] + "\n```")
    p.append("# Part 8. Exclusions and peer-owned units\n\nCarried same-source prior confirmed exclusions: none (no prior run exists).\n" + exclusions_note +
             "\nPeer-owned current coverage IDs (do not duplicate their work; if your trace crosses into one, stop at the boundary and note it in `hardening` or `uncovered`):\n\n" +
             "\n".join(f"- `{u['unit_key']}` {u['attack_class']} on {u['surface']}: `{u['coverage_id']}`" for u in peers))
    ex = runcfg.CFG.get("execution_example")
    example_line = f"- {ex['label']}: `{SBX} {agent_id} -- {ex['command']}`. {ex['note']}" if ex else ""
    sandbox = f"""# Part 9. Your paths, sandbox, promotion allowlist and result contract

- Agent ID: `{agent_id}`. Scratch (your only writable path): `{base}/scratch/` (a 4 GiB ext4 mount). Retained artifacts root (parent-owned, never write it): `{base}/artifacts/`.
- Do not edit the target repository, other agents' directories, or any shared run file. The Write tool refuses your scratch path; write files there with Bash here-docs.
- Source copy for builds: run `{CPY} {agent_id}` once (trusted parent script; it writes `git archive {COMMIT[:8]}` into `scratch/src`). You may add a minimal test or harness file inside `scratch/src` only.
- Target-controlled execution only through the parent sandbox: `{SBX} {agent_id} -- <cmd>`. It runs with cwd `scratch/src`, no external network (isolated loopback only), an empty allowlisted environment, read-only system folders plus the toolchain and dependency cache that run.json names, writes only in scratch, and limits: memory 5 GiB, swap 0, 512 tasks, 4 CPUs, 1180 s wall clock, 512 MiB per file, 4096 open files, 4 GiB disk. It refuses to run if a control fails. Two sandboxes run host-wide at once, so a call may wait. Never run gradle, the target's Python or shell scripts, or any target code outside it.
{example_line}
- Evidence promotion allowlist (predeclared): `evidence/proof-1.txt` through `evidence/proof-6.txt` under your scratch, at most 262144 bytes each and 1048576 bytes in total, regular files with one link. Put the exact command, input, limits and the decisive output lines in them. For a `local` check set `artifact` to `agents/{agent_id}/artifacts/evidence/proof-N.txt`. The parent promotes these files after you finish; a file that fails promotion invalidates its check. Record environment variable names only, never values from the host.
- Before returning, write your final JSON result to `{base}/scratch/result.json` with a Bash here-doc as well.
- Read receipt: set the top-level field `receipt` in your result to `{receipt}` to show you read this prompt to the end.

## Structured hunter result (verbatim from HUNTING.md)

{kit['result_contract']}

## `confirmed` branch of report-schema.json (verbatim)

```json
{kit['schema_confirmed']}
```

## `needs_validation` branch of report-schema.json (verbatim)

```json
{kit['schema_needs_validation']}
```
"""
    p.append(sandbox)
    if not os.path.ismount(f"{base}/scratch"):
        subprocess.run([f"{runcfg.BIN}/mkscratch", "--run", OUT, agent_id], check=True, stdout=subprocess.DEVNULL)
    path = f"{base}/prompt.md"
    with open(path, "x", encoding="utf-8") as f:
        f.write("\n\n".join(p) + "\n")
    for u in mine:
        assert u["status"] == "planned", u["unit_key"]
        u["status"] = "in_progress"
        u["agent_id"] = agent_id
        u["wave"] = wave
    return {"id": agent_id, "prompt_path": path, "receipt": receipt, "coverage_ids": [u["coverage_id"] for u in mine], "unit_keys": unit_keys}

def main():
    wave = int(sys.argv[1])
    units = ledger.load()
    kit = read_json(f"{OUT}/prompt-kit.json")
    arch = read_text(f"{OUT}/architecture.md")
    note = "\nParent reminder from wave 1: a `covered` unit must have an empty `unresolved` list. Put non-decisive caveats in `hardening`; if a decisive fact stays open, use `blocked` (no fingerprint) or a `needs_validation` candidate.\n"
    out = []
    for a in sys.argv[2:]:
        agent_id, keys = a.split("=", 1)
        out.append(build(wave, agent_id, keys.split(","), units, kit, arch, note))
    ledger.save(units)
    write_json(f"{OUT}/plan/wave-{wave}.json", {"wave": wave, "out": OUT, "hunters": out}, indent=1)
    args = f"{OUT}/plan/wave-{wave}-args.json"
    write_json(args, {"wave": wave, "hunters": out, "candidate_schema": candidate_schema()}, indent=1)
    print(f"wave {wave}: {len(out)} hunters; workflow args in {args}")
    print(ledger.count_line(units))

if __name__ == "__main__":
    main()
