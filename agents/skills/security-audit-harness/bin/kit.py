#!/usr/bin/env python3
"""Build DIR/prompt-kit.json: verbatim skill text pieces used by hunter and verifier prompts. Usage: kit.py --run DIR"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import runcfg
from runcfg import read_json, read_text, write_json

skill, out = runcfg.SKILL, os.path.join(runcfg.OUT, "prompt-kit.json")
H = read_text(f"{skill}/HUNTING.md")
V = read_text(f"{skill}/VALIDATION-AND-REPORTING.md")
S = read_json(f"{skill}/report-schema.json")

def fenced_after(text, marker):
    i = text.index(marker)
    j = text.index("```", i)
    j = text.index("\n", j) + 1
    k = text.index("\n```", j)
    return text[j:k]

def section(text, start, end):
    i = text.index(start)
    k = text.index(end, i + len(start))
    return text[i:k].rstrip()

branches = {b["properties"]["verdict"]["const"]: b for b in S["items"]["oneOf"]}
kit = {
    "method": fenced_after(H, "#### Core hunting method"),
    "promotion": fenced_after(H, "#### Promotion procedure"),
    "validation": fenced_after(H, "#### Core validation rules"),
    "result_contract": section(H, "Return exactly one JSON object, with no surrounding prose:", "## Parent consolidation"),
    "critic_contract": section(H, "Immediately after each hunter wave", "The parent rejects proposed units"),
    "verifier_prompt": fenced_after(V, "#### Candidate-verifier prompt"),
    "verifier_promotion": fenced_after(V, "Copy this promotion procedure verbatim"),
    "phase5_confirmed": section(V, "For `confirmed`, require it to check:", "For `needs_validation`, require it to check:"),
    "phase5_nv": section(V, "For `needs_validation`, require it to check:", "Each verifier returns exactly one JSON object"),
    "phase5_return": section(V, "Each verifier returns exactly one JSON object", "Do not apply a Phase 5 replacement"),
    "schema_confirmed": json.dumps(branches["confirmed"], indent=2),
    "schema_needs_validation": json.dumps(branches["needs_validation"], indent=2),
    "schema_rejected": json.dumps(branches["rejected"], indent=2),
}
assert kit["promotion"] == kit["verifier_promotion"], "promotion blocks differ"
write_json(out, kit, indent=1, ensure_ascii=False)
for k, v in kit.items():
    print(k, len(v), repr(v[:50]))
