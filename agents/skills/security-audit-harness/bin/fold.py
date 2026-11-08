#!/usr/bin/env python3
"""Parent-only: fold one hunter wave's structured results into the ledger.
Usage: fold.py --run DIR <wave-number> <workflow-output.json>
Promotes declared artifacts, validates each unit result, updates only assigned units, stores candidates,
hardening and uncovered entries under plan/, and prints a summary that ends with the ledger count line.
Units with an invalid result go back to planned. A candidate record must pass the skill's validate-findings.cjs
with its proposed_verdict as verdict; a unit that names a refused or missing record goes back to planned, so no
verifier starts from a title alone."""
import json
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger
import runcfg
from runcfg import read_json, write_json

OUT = ledger.OUT
ART_RE = re.compile(r"^agents/([a-z0-9][a-z0-9_-]{0,63})/artifacts/(evidence/proof-[1-6]\.txt)$")

def safe_rel(p):
    return isinstance(p, str) and p and not p.startswith("/") and ".." not in p.split("/") and "\\" not in p

def promote(agent, rel):
    if ledger.already_promoted(agent, rel):
        return True, "already promoted"
    r = subprocess.run(["python3", "-I", f"{runcfg.BIN}/promote.py", "--run", OUT, agent, rel], capture_output=True, text=True, check=False)
    line = (r.stdout.strip().splitlines() or [""])[-1]
    return r.returncode == 0, line

def validator_errors(recs):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
        json.dump(recs, f, ensure_ascii=False)
    try:
        r = subprocess.run([f"{runcfg.BIN}/sa-node", f"{runcfg.SKILL}/validate-findings.cjs", f.name],
                           capture_output=True, text=True, check=False)
    finally:
        os.unlink(f.name)
    if r.returncode == 0:
        return []
    lines = (r.stdout + r.stderr).splitlines()
    return [x[len("ERROR: "):] for x in lines if x.startswith("ERROR: ")] or lines[-1:] or [f"validator exit {r.returncode}"]

def first_validator_error_by_fingerprint(cands):
    recs = [{**{k: v for k, v in c.items() if k != "proposed_verdict"}, "verdict": c.get("proposed_verdict")} for c in cands]
    bad = {}
    seen = set()
    for r in recs:
        fp = str(r.get("fingerprint", ""))
        if fp in seen:
            bad[fp] = "duplicate fingerprint in this hunter's candidates"
        seen.add(fp)
    if not recs or not validator_errors(sorted(recs, key=lambda r: str(r.get("fingerprint", "")))):
        return bad
    for r in recs:
        errors = validator_errors([r])
        if errors:
            bad.setdefault(str(r.get("fingerprint", "")), errors[0])
    return bad

def main():
    wave = int(sys.argv[1])
    data = read_json(sys.argv[2])
    data = data.get("result", data)
    plan = read_json(f"{OUT}/plan/wave-{wave}.json")
    by_agent = {h["id"]: h for h in plan["hunters"]}
    units = ledger.load()
    by_id = {u["coverage_id"]: u for u in units}
    cand_path = f"{OUT}/plan/candidates.json"
    cands = read_json(cand_path) if os.path.exists(cand_path) else {}
    uncovered, report = [], []
    got = {r["id"]: r for r in data["results"]}
    for agent, h in by_agent.items():
        r = got.get(agent)
        if r is None:
            for cid in h["coverage_ids"]:
                u = by_id[cid]; u["status"] = "planned"; u["agent_id"] = None
                u["decisions"].append(f"wave {wave}: hunter {agent} returned no result; unit returned to planned")
            report.append(f"{agent}: NO RESULT, units back to planned")
            continue
        notes = []
        refused = first_validator_error_by_fingerprint(r.get("candidates") or [])
        recorded = {str(c.get("fingerprint", "")) for c in r.get("candidates") or []}
        if r.get("receipt") != h["receipt"]:
            notes.append("receipt mismatch")
        seen = set()
        for ur in r["units"]:
            cid = ur["coverage_id"]
            if cid not in h["coverage_ids"] or cid in seen:
                notes.append(f"unassigned or duplicate unit {cid[:60]}"); continue
            seen.add(cid)
            u = by_id[cid]
            checks, bad = [], []
            for c in ur["checks"]:
                if c.get("agent_id") != agent or not c.get("reviewed_paths") or not all(safe_rel(p) for p in c["reviewed_paths"]):
                    bad.append("check owner or paths invalid"); continue
                if c["method"] == "source":
                    if c.get("artifact") is not None:
                        bad.append("source check with artifact"); continue
                else:
                    m = ART_RE.match(c.get("artifact") or "")
                    if not m or m.group(1) != agent:
                        bad.append(f"local artifact path invalid: {c.get('artifact')}"); continue
                    ok, line = promote(agent, m.group(2))
                    if not ok:
                        bad.append(f"promotion refused: {line}"); continue
                checks.append({k: c[k] for k in ("agent_id", "reviewed_paths", "invariant", "method", "result", "artifact")})
            disp = ur["disposition"]
            fps = ur.get("candidate_fingerprints") or []
            unresolved = ur.get("unresolved") or []
            valid = bool(checks)
            if disp == "covered" and (fps or unresolved): valid = False; bad.append("covered unit with fingerprints or unresolved")
            if disp == "candidate" and not fps: valid = False; bad.append("candidate unit without fingerprints")
            for fp in fps:
                if fp in refused: valid = False; bad.append(f"candidate {fp} refused: {refused[fp]}")
                elif fp not in recorded: valid = False; bad.append(f"candidate {fp} has no record")
            if disp == "blocked" and (fps or not unresolved): valid = False; bad.append("blocked unit shape invalid")
            if not valid:
                u["status"] = "planned"; u["agent_id"] = None
                u["decisions"].append(f"wave {wave}: result from {agent} rejected ({'; '.join(bad) or 'no valid checks'}); unit returned to planned")
                notes.append(f"{u['unit_key']} rejected: {'; '.join(bad) or 'no valid checks'}")
                continue
            if bad:
                u["decisions"].append(f"wave {wave}: dropped invalid checks from {agent}: {'; '.join(bad)}")
                notes.append(f"{u['unit_key']} dropped checks: {'; '.join(bad)}")
            paths = sorted({p for c in checks for p in c["reviewed_paths"]})
            u.update({"status": disp, "reviewed_paths": paths, "local_checks": checks,
                      "result_fingerprints": sorted(set(fps)) if disp == "candidate" else [],
                      "unresolved": unresolved if disp in ("candidate", "blocked") else []})
        for cid in h["coverage_ids"]:
            if cid not in seen and by_id[cid]["status"] == "in_progress":
                u = by_id[cid]; u["status"] = "planned"; u["agent_id"] = None
                u["decisions"].append(f"wave {wave}: hunter {agent} omitted this unit; returned to planned")
                notes.append(f"{u['unit_key']} omitted")
        for cid in h["coverage_ids"]:
            by_id[cid]["hardening"] = sorted(set(by_id[cid]["hardening"]) | set(r.get("hardening") or []))
        for c in r.get("candidates") or []:
            fp = c.get("fingerprint", "")
            if fp in refused:
                continue
            entry = cands.setdefault(fp, {"records": [], "units": [], "hunters": []})
            entry["records"].append({"hunter": agent, "wave": wave, "record": c})
            entry["hunters"] = sorted(set(entry["hunters"]) | {agent})
            entry["units"] = sorted(set(entry["units"]) | {by_id[x]["unit_key"] for x in h["coverage_ids"] if fp in by_id[x]["result_fingerprints"]})
        for x in r.get("uncovered") or []:
            uncovered.append({"from": agent, "wave": wave, **x})
        report.append(f"{agent}: {len(seen)} units, {len(r.get('candidates') or [])} candidates, {len(r.get('uncovered') or [])} uncovered" + (f"; NOTES: {' | '.join(notes)}" if notes else ""))
    ledger.save(units)
    write_json(cand_path, cands, indent=1, ensure_ascii=False)
    write_json(f"{OUT}/plan/uncovered-wave-{wave}.json", uncovered, indent=1, ensure_ascii=False)
    print("\n".join(report))
    print(ledger.count_line(units))

if __name__ == "__main__":
    main()
