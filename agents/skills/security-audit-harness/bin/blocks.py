#!/usr/bin/env python3
"""Extract skill attack-class blocks verbatim. Usage: blocks.py <skill-dir> <FILE.md#Name>... (prints JSON {ref: text})."""
import json
import re
import sys


def extract(skill, ref):
    fname, name = ref.split("#", 1)
    with open(f"{skill}/{fname}", encoding="utf-8") as f:
        lines = f.read().split("\n")
    if fname == "ATTACK-CLASSES.md":
        hdr = re.compile(r"^\*\*([^*]+)\*\* \(subagent_type")
        starts = [i for i, l in enumerate(lines) if hdr.match(l)]
        for k, i in enumerate(starts):
            if hdr.match(lines[i]).group(1) == name:
                end = starts[k + 1] if k + 1 < len(starts) else len(lines)
                return "\n".join(lines[i:end]).strip()
        raise KeyError(ref)
    for i, l in enumerate(lines):
        m = re.match(r"^## (.+?)(?: \(.*\))?$", l)
        if m and m.group(1) == name:
            j = i + 1
            while j < len(lines) and not lines[j].startswith("## "):
                j += 1
            return "\n".join(lines[i:j]).strip()
        if l == f"**{name}**":
            j = i + 1
            while j < len(lines) and not (lines[j].startswith("**") or lines[j].startswith("#")):
                j += 1
            return "\n".join(lines[i:j]).strip()
    raise KeyError(ref)

if __name__ == "__main__":
    skill = sys.argv[1]
    print(json.dumps({r: extract(skill, r) for r in sys.argv[2:]}, ensure_ascii=False))
