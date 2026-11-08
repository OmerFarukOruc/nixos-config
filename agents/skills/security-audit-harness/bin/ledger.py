#!/usr/bin/env python3
"""Parent-only ledger helpers.
  ledger.py --run DIR seed                 write coverage-ledger.json from plan/units.py
  ledger.py --run DIR unreviewed --wave N [--ledger FILE]
                                           list tracked files at the run's commit that no unit reviewed, minus the
                                           run.json unreviewed_ignore globs, into plan/unreviewed-wave-N.txt
  ledger.py --run DIR add-units SPECS.json add the units and reassignments a coverage critic justified
Every command that saves the ledger ends with its count line."""
import collections
import fnmatch
import json
import os
import re
import runpy
import subprocess
import sys
import unicodedata
from urllib.parse import quote

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import runcfg
from runcfg import read_json, read_text

OUT, SKILL = runcfg.OUT, runcfg.SKILL
LEDGER = os.path.join(OUT, "coverage-ledger.json")
ORDINARY = ["Injection", "Access control", "Resource and file handling", "Cryptography and secrets", "Business logic",
            "Feature abuse and data leakage", "Chained vulnerabilities and trust boundaries", "Wildcard", "Obvious things"]
SECTIONS = ["Core discipline", "Universal moves", "Validation rules"]
FILE_EXCLUSIONS = runcfg.CFG.get("exclusions", {}).get("file", {})
NEVER = runcfg.CFG.get("exclusions", {}).get("never", {})

def enc(ref):
    if unicodedata.normalize("NFC", ref) != ref or ref != ref.strip() or not ref:
        raise ValueError(f"bad ref {ref!r}")
    return quote(ref, safe="")

def companion_classes(fname):
    lines = read_text(f"{SKILL}/{fname}").split("\n")
    return [l[2:-2] for l in lines if re.fullmatch(r"\*\*[^*]+\*\*", l)]

def seed():
    plan = runpy.run_path(os.path.join(OUT, "plan/units.py"))
    units = plan["UNITS"]
    owners = {}
    for u in units:
        owners.setdefault(f"ATTACK-CLASSES.md#{u[6]}" if u[6] else None, []).append(u[0])
        owners.setdefault(f"{u[5][0]}#{u[5][1]}", []).append(u[0])
        for f, c in u[7]:
            owners.setdefault(f"{f}#{c}", []).append(u[0])
    out = []
    def mk(key, surface, boundary, subsystem, cls, ordinary, comps, lifecycle, paths, group, status="planned", reason=None):
        attack_ref = f"{cls[0]}#{cls[1]}"
        refs = {"surface": surface[1], "boundary": boundary[1], "subsystem": subsystem[1], "attack_class": attack_ref}
        parts = [enc(refs[k]) for k in ("surface", "boundary", "subsystem", "attack_class")]
        if lifecycle:
            refs["lifecycle"] = f"lifecycle/{lifecycle}"
            parts.append(enc(refs["lifecycle"]))
        files = []
        for f, _ in comps:
            if f not in files:
                files.append(f)
        selected = []
        for f in files:
            selected.append(f"{f}#Core discipline")
            selected += [f"{ff}#{c}" for ff, c in comps if ff == f]
            selected += [f"{f}#Universal moves", f"{f}#Validation rules"]
        excluded = []
        ord_ref = f"ATTACK-CLASSES.md#{ordinary}" if ordinary else None
        for c in ORDINARY:
            r = f"ATTACK-CLASSES.md#{c}"
            if r != ord_ref:
                others = [o for o in owners.get(r, []) if o != key]
                excluded.append({"block": r, "reason": f"Owned by unit(s) {', '.join(others)} for their own boundary." if others else "Not applicable to this boundary."})
        for f in files:
            for c in companion_classes(f):
                r = f"{f}#{c}"
                if r in selected:
                    continue
                if r in NEVER:
                    excluded.append({"block": r, "reason": NEVER[r]})
                else:
                    others = [o for o in owners.get(r, []) if o != key]
                    excluded.append({"block": r, "reason": f"Owned by unit(s) {', '.join(others)} for their own boundary." if others else "Not applicable to this boundary."})
        for r, why in FILE_EXCLUSIONS.items():
            excluded.append({"block": r, "reason": why})
        unit = {
            "coverage_id": "::".join(parts), "canonical_refs": refs,
            "surface": surface[0], "boundary": boundary[0], "subsystem": subsystem[0], "attack_class": f"{cls[1]} ({cls[0]})",
            "starting_paths": paths, "ordinary_attack_class_block": ord_ref,
            "selected_companion_blocks": selected, "excluded_blocks": excluded,
            "prior_status": "none", "attempts": [], "wave": 1, "status": status, "agent_id": None,
            "reviewed_paths": [], "local_checks": [], "result_fingerprints": [], "unresolved": [reason] if reason else [],
            "unit_key": key, "hunter_group": group, "hardening": [], "decisions": [],
        }
        if lifecycle:
            unit["lifecycle"] = lifecycle
        return unit
    for u in units:
        key, group, surface, boundary, subsystem, cls, ordinary, comps, lifecycle, paths = u
        out.append(mk(key, surface, boundary, subsystem, cls, ordinary, comps, lifecycle, paths, group))
    for na in plan["NOT_APPLICABLE"]:
        key, surface, boundary, subsystem, cls, ordinary, comps, lifecycle, paths, reason = na
        out.append(mk(key, surface, boundary, subsystem, cls, ordinary, comps, lifecycle, paths, None, "not_applicable", reason))
    out.sort(key=lambda x: x["coverage_id"])
    ids = [x["coverage_id"] for x in out]
    assert len(ids) == len(set(ids)), "duplicate coverage ids"
    save(out)
    print(f"seeded {len(out)} units")
    print(count_line(out))

def already_promoted(agent, rel):
    return os.path.isfile(os.path.join(OUT, f"agents/{agent}/artifacts/{rel}"))

def load():
    return read_json(LEDGER)

def count_line(units):
    c = collections.Counter(u["status"] for u in units)
    return f"ledger: {len(units)} units; " + ", ".join(f"{s} {c[s]}" for s in sorted(c))

def save(units):
    units.sort(key=lambda x: x["coverage_id"])
    tmp = LEDGER + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(units, f, indent=1, ensure_ascii=False)
    os.replace(tmp, LEDGER)

def owners_from(units):
    owners = {}
    for u in units:
        refs = [u["ordinary_attack_class_block"], u["canonical_refs"]["attack_class"]] + u["selected_companion_blocks"]
        for r in refs:
            if r:
                owners.setdefault(r, set()).add(u["unit_key"])
    return owners

def make_unit(units, key, surface, boundary, subsystem, cls, ordinary, comps, lifecycle, paths, wave, origin):
    owners = owners_from(units)
    attack_ref = f"{cls[0]}#{cls[1]}"
    refs = {"surface": surface[1], "boundary": boundary[1], "subsystem": subsystem[1], "attack_class": attack_ref}
    parts = [enc(refs[k]) for k in ("surface", "boundary", "subsystem", "attack_class")]
    if lifecycle:
        refs["lifecycle"] = f"lifecycle/{lifecycle}"
        parts.append(enc(refs["lifecycle"]))
    files = []
    for f, _ in comps:
        if f not in files:
            files.append(f)
    selected = []
    for f in files:
        selected.append(f"{f}#Core discipline")
        selected += [f"{ff}#{c}" for ff, c in comps if ff == f]
        selected += [f"{f}#Universal moves", f"{f}#Validation rules"]
    ord_ref = f"ATTACK-CLASSES.md#{ordinary}" if ordinary else None
    def why(r):
        if r in NEVER:
            return NEVER[r]
        o = sorted(owners.get(r, set()) - {key})
        return f"Owned by unit(s) {', '.join(o)} for their own boundary." if o else "Not applicable to this boundary."
    excluded = [{"block": f"ATTACK-CLASSES.md#{c}", "reason": why(f"ATTACK-CLASSES.md#{c}")} for c in ORDINARY if f"ATTACK-CLASSES.md#{c}" != ord_ref]
    for f in files:
        for c in companion_classes(f):
            r = f"{f}#{c}"
            if r not in selected:
                excluded.append({"block": r, "reason": why(r)})
    excluded += [{"block": r, "reason": w} for r, w in FILE_EXCLUSIONS.items()]
    unit = {"coverage_id": "::".join(parts), "canonical_refs": refs, "surface": surface[0], "boundary": boundary[0],
            "subsystem": subsystem[0], "attack_class": f"{cls[1]} ({cls[0]})", "starting_paths": paths,
            "ordinary_attack_class_block": ord_ref, "selected_companion_blocks": selected, "excluded_blocks": excluded,
            "prior_status": "none", "attempts": [], "wave": wave, "status": "planned", "agent_id": None,
            "reviewed_paths": [], "local_checks": [], "result_fingerprints": [], "unresolved": [],
            "unit_key": key, "hunter_group": None, "hardening": [], "decisions": [f"added in wave {wave}: {origin}"]}
    if lifecycle:
        unit["lifecycle"] = lifecycle
    if any(x["coverage_id"] == unit["coverage_id"] for x in units):
        raise ValueError(f"canonical identity collision for {key}")
    return unit

def reassign(units, unit_key, reason, wave):
    u = next(x for x in units if x["unit_key"] == unit_key)
    assert u["status"] in ("covered", "candidate", "blocked"), (unit_key, u["status"])
    u["attempts"].append({k: u[k] for k in ("wave", "status", "agent_id", "reviewed_paths", "local_checks", "result_fingerprints", "unresolved")} | {"reassignment_reason": reason})
    u.update({"wave": wave, "status": "planned", "agent_id": None, "reviewed_paths": [], "local_checks": [], "result_fingerprints": [], "unresolved": []})
    u["decisions"].append(f"wave {wave}: reassigned by critic: {reason}")


def tracked_files():
    r = subprocess.run(["git", "-C", runcfg.TARGET, "ls-tree", "-r", "--name-only", "-z", runcfg.COMMIT],
                       capture_output=True, check=True)
    return [p for p in r.stdout.decode().split("\0") if p]

def unreviewed(args):
    wave = int(args[args.index("--wave") + 1])
    src = args[args.index("--ledger") + 1] if "--ledger" in args else LEDGER
    units = read_json(src)
    reviewed = {p for u in units for p in u["reviewed_paths"]}
    ignore = runcfg.CFG.get("unreviewed_ignore", [])
    files = [p for p in tracked_files() if p not in reviewed and not any(fnmatch.fnmatch(p, g) for g in ignore)]
    path = os.path.join(OUT, "plan", f"unreviewed-wave-{wave}.txt")
    with open(path, "w", encoding="utf-8") as f:
        f.write("".join(p + "\n" for p in files))
    groups = collections.Counter(os.path.dirname(p) or "." for p in files)
    lines = [f"unreviewed: {len(files)} files, listed in {path}"]
    lines += [f"  {n:4d}  {d}/" for d, n in sorted(groups.items(), key=lambda x: (-x[1], x[0]))]
    return path, "\n".join(lines)

def add_units(specs_path):
    spec = read_json(specs_path)
    wave, units = spec["wave"], load()
    tracked = set(tracked_files())
    for s in spec.get("units", []):
        missing = [p for p in s["paths"] if p not in tracked]
        if missing:
            sys.exit(f"{s['key']}: paths not tracked at {runcfg.COMMIT[:8]}: {missing}")
        units.append(make_unit(units, s["key"], tuple(s["surface"]), tuple(s["boundary"]), tuple(s["subsystem"]),
                               tuple(s["attack_class"]), s.get("ordinary"), [tuple(c) for c in s.get("companions", [])],
                               s.get("lifecycle"), s["paths"], wave, s["origin"]))
    for r in spec.get("reassign", []):
        reassign(units, r["unit_key"], r["reason"], wave)
    save(units)
    print(f"added {len(spec.get('units', []))} units, reassigned {len(spec.get('reassign', []))}")
    print(count_line(units))

if __name__ == "__main__":
    cmd, rest = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else ("", [])
    if cmd == "seed":
        seed()
    elif cmd == "unreviewed" and "--wave" in rest:
        print(unreviewed(rest)[1])
    elif cmd == "add-units" and len(rest) == 1:
        add_units(rest[0])
    else:
        sys.exit(__doc__)
