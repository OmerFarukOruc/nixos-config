#!/usr/bin/env python3
"""Parent-only: write a coverage-critic prompt. Usage: critic.py --run DIR <critic-agent-id> <kind: post-wave|final-clean> <wave>
The prompt carries the files no unit has reviewed, from `ledger.py unreviewed`."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger
import runcfg
from runcfg import read_json, read_text, write_text

OUT = ledger.OUT
agent_id, kind, wave = sys.argv[1], sys.argv[2], int(sys.argv[3])
units = ledger.load()
unrev_path, unrev = ledger.unreviewed(["--wave", str(wave)])
kit = read_json(f"{OUT}/prompt-kit.json")
arch = read_text(f"{OUT}/architecture.md")
cands = read_json(f"{OUT}/plan/candidates.json") if os.path.exists(f"{OUT}/plan/candidates.json") else {}
unc = []
for w in range(1, wave + 1):
    p = f"{OUT}/plan/uncovered-wave-{w}.json"
    if os.path.exists(p):
        unc += read_json(p)
rows = []
for u in units:
    rows.append(f"| {u['unit_key']} | {u['status']} | {u['agent_id'] or '-'} | {u['wave']} | {len(u['reviewed_paths'])} | {len(u['local_checks'])} | {u['attack_class']} | {u['surface']} | {u['boundary']} | {', '.join(u['result_fingerprints']) or '-'} | {'; '.join(u['unresolved'])[:300] or '-'} |")
clist = "\n".join(f"- `{fp}`: {e['records'][-1]['record'].get('title','')} (proposed {e['records'][-1]['record'].get('proposed_verdict')}, units {', '.join(e['units'])}, hunters {', '.join(e['hunters'])})" for fp, e in sorted(cands.items())) or "- none"
ulist = "\n".join(f"- from {x['from']} (wave {x['wave']}): {x['attack_class']} on {x['surface']} / {x['boundary']} / {x['subsystem']}; paths {', '.join(x['starting_paths'])}; reason: {x['reason']}" for x in unc) or "- none"
classes = {}
for f in ["ATTACK-CLASSES.md", "WEB-PROTOCOL-AND-AUTH.md", "CLIENT-SIDE.md", "SUPPLY-CHAIN-AND-RELEASE.md", "CLOUD-AND-DEPLOYMENT.md", "PROTOCOLS-RPC-AND-MESSAGING.md", "RESOURCE-EXHAUSTION-AND-AVAILABILITY.md", "DATA-ISOLATION-AND-LIFECYCLE.md"]:
    classes[f] = ledger.ORDINARY if f == "ATTACK-CLASSES.md" else ledger.companion_classes(f)
cl = "\n".join(f"- {f}: " + "; ".join(v) for f, v in classes.items())
extra = ("This is the distinct FINAL-CLEAN critic pass. A previous post-wave critic accepted no work. Look again with fresh eyes; coverage is complete only if you also find nothing." if kind == "final-clean" else
         f"This is the post-wave coverage critic for wave {wave}.")
prompt = f"""# Coverage critic `{agent_id}`

You are a fresh `research` coverage critic for a defensive security audit of {runcfg.NAME} (`{runcfg.TARGET}`, commit {runcfg.COMMIT[:8]}). You are NOT the orchestrator and you did not hunt. {extra}
Read source (read-only). Do not write anything except a copy of your JSON result at `{OUT}/agents/{agent_id}/scratch/result.json` (Bash here-doc). Do not run target code. Do not contact any network service.

## Your contract (verbatim from HUNTING.md)

{kit['critic_contract']}

## architecture.md (verbatim)

{arch}

## Full coverage ledger

The complete ledger with every unit's block map, checks, reviewed paths and archived attempts is `{OUT}/coverage-ledger.json` (JSON array, about 500 KB; use `jq` to read slices, for example `jq '.[] | select(.unit_key=="u22")' {OUT}/coverage-ledger.json`). Hunter results are in `{OUT}/agents/<hunter-id>/scratch/result.json`. Summary:

| unit | status | owner | wave | paths | checks | attack class | surface | boundary | fingerprints | unresolved |
|---|---|---|---|---|---|---|---|---|---|---|
""" + "\n".join(rows) + f"""

## Current candidate fingerprints and states (all pending Phase 3 validation)

{clist}

## Hunter-reported `uncovered` entries (the parent has not yet turned these into units; judge each)

{ulist}

## Files no unit has reviewed

`ledger.py unreviewed` lists every file tracked at the reviewed commit that appears in no unit's `reviewed_paths`, minus the run's ignore globs. Counts by folder:

```text
{unrev}
```

Read the list at `{unrev_path}`. Each listed file that holds security-relevant behaviour needs a unit in `missing_units`. List the rest in `unreviewed_without_unit` as glob patterns, each with the reason its files hold no security-relevant behaviour; the parent adds the accepted patterns to run.json `unreviewed_ignore`.

## Prior-ledger gap summary

No prior run or compatible ledger exists.

## Available attack-class blocks (exact names for `selected_companion_blocks`, written `FILE.md#Name`)

{cl}

Companion selections must also list that file's `Core discipline`, `Universal moves` and `Validation rules`.

## What to check

Unmapped entry points, unchecked parallel paths, missing lifecycle modes, selected companion classes without a unit, unjustified exclusions, units closed without paths or checks, units whose checks do not actually support the invariant (read the cited source), and hunter `uncovered` entries that deserve a unit. Propose coverage, not findings. Each `missing_units` entry must be source-backed with repository-relative `starting_paths` and a reason citing file:line. Use `reassign_ids` only for existing `covered`, `candidate` or `blocked` units whose recorded evidence does not close the unit, giving the reason in `missing_units`-style prose inside the matching entry of `reassign_reasons`. Return exactly one JSON object through the structured output tool with the fields `missing_units`, `reassign_ids` (coverage IDs, exact strings), `reassign_reasons` (same order as `reassign_ids`, one source-backed sentence each), `resolved_prior_leads`, `unreviewed_without_unit`, `stop`.
"""
d = f"{OUT}/agents/{agent_id}"
os.makedirs(f"{d}/scratch"); os.makedirs(f"{d}/artifacts")
write_text(f"{d}/prompt.md", prompt, "x")
print(f"{d}/prompt.md", len(prompt))
