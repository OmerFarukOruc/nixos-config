#!/usr/bin/env python3
"""Parent-only: apply Phase 3 verifier results.
Usage: apply3.py --run DIR plan/phase3-output.json
Promotes each verifier's declared artifacts, adds one verifier check to every linked unit, replaces merged
hunter fingerprints with the final fingerprint, records the decision, and writes findings.json sorted by fingerprint."""
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger
import runcfg
from runcfg import read_json

OUT = ledger.OUT
TARGET = runcfg.TARGET

def repo_paths(rec):
    paths = []
    for e in rec.get("trace", []) + rec.get("evidence", []):
        f = e.get("file")
        if f and not f.startswith("agents/") and os.path.isfile(os.path.join(TARGET, f)) and f not in paths:
            paths.append(f)
    return paths

def main():
    data = read_json(sys.argv[1])
    data = data.get("result", data)
    manifest = {m["id"]: m for m in read_json(f"{OUT}/plan/phase3-manifest.json")}
    assert not data["missing"], data["missing"]
    units = ledger.load()
    findings, problems = [], []
    for r in sorted(data["results"], key=lambda x: x["id"]):
        vid, m, rec = r["id"], manifest[r["id"]], r["record"]
        if r["decision"] != rec.get("verdict"):
            problems.append(f"{vid}: decision {r['decision']} != record verdict {rec.get('verdict')}")
            continue
        if rec.get("fingerprint") != m["fingerprint"]:
            problems.append(f"{vid}: fingerprint changed to {rec.get('fingerprint')}")
            continue
        unsafe = [a for a in r["artifacts"] if not re.fullmatch(r"evidence/proof-[1-6]\.txt", a)]
        if unsafe:
            problems.append(f"{vid}: artifacts outside the promotion allowlist: {unsafe}")
            continue
        pending = [a for a in r["artifacts"] if not ledger.already_promoted(vid, a)]
        if pending:
            p = subprocess.run([sys.executable, "-I", f"{runcfg.BIN}/promote.py", "--run", OUT, vid, *pending], capture_output=True, text=True, check=False)
            if p.returncode != 0:
                problems.append(f"{vid}: promotion failed: {p.stdout.strip()} {p.stderr.strip()}"[:400])
        promoted = [f"agents/{vid}/artifacts/{a}" for a in r["artifacts"] if ledger.already_promoted(vid, a)]
        if rec["verdict"] == "confirmed" and not promoted:
            problems.append(f"{vid}: confirmed without a promoted artifact")
            continue
        paths = repo_paths(rec)
        check = {"agent_id": vid, "reviewed_paths": paths, "invariant": rec.get("intended_behavior") or rec["title"],
                 "method": "local" if promoted else "source",
                 "result": f"Phase 3 independent verifier decision: {rec['verdict']}. {rec['title']}",
                 "artifact": promoted[0] if promoted else None}
        for u in units:
            if u["unit_key"] not in m["units"]:
                continue
            assert u["status"] == "candidate", (u["unit_key"], u["status"])
            u["local_checks"].append(check)
            for pth in paths:
                if pth not in u["reviewed_paths"]:
                    u["reviewed_paths"].append(pth)
            fps = [f for f in u["result_fingerprints"] if f not in m["merge"]]
            if m["fingerprint"] not in fps:
                fps.append(m["fingerprint"])
            u["result_fingerprints"] = fps
            merged = [f for f in m["merge"] if f != m["fingerprint"]]
            note = f" (merged hunter fingerprints: {', '.join(merged)})" if merged else ""
            u["decisions"].append(f"phase 3: verifier {vid} returned {rec['verdict']} for {m['fingerprint']}{note}")
        findings.append(rec)
    if problems:
        print("\n".join(problems))
        sys.exit(2)
    findings.sort(key=lambda f: f["fingerprint"])
    ledger.save(units)
    with open(f"{OUT}/findings.json", "w") as f:
        json.dump(findings, f, indent=1, ensure_ascii=False)
    print(f"{len(findings)} records written")
    print(ledger.count_line(units))

if __name__ == "__main__":
    main()
