#!/usr/bin/env python3
"""Parent-only: apply Phase 5 record-verifier results.
Usage: apply5.py --run DIR <manifest.json> <output.json> [--pending id,id]
Applies 'replace' records for ids not listed as pending (non-material or already freshly verified),
records every outcome in the linked ledger units' decisions, and rewrites findings.json sorted by fingerprint."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger
from runcfg import read_json

OUT = ledger.OUT

def main():
    manifest = {m["id"]: m for m in read_json(sys.argv[1])}
    data = read_json(sys.argv[2]); data = data.get("result", data)
    pending = set(sys.argv[4].split(",")) if len(sys.argv) > 4 and sys.argv[3] == "--pending" else set()
    assert not data["missing"], data["missing"]
    findings = {f["fingerprint"]: f for f in read_json(f"{OUT}/findings.json")}
    units = ledger.load()
    for r in sorted(data["results"], key=lambda x: x["id"]):
        vid, fp = r["id"], manifest[r["id"]]["fingerprint"]
        assert r["fingerprint"] == fp, (vid, r["fingerprint"])
        if r["decision"] == "verified":
            note = f"phase 5: record verifier {vid} verified {fp}"
        elif vid in pending:
            note = f"phase 5: record verifier {vid} proposed a material replacement for {fp}; sent to a fresh verifier"
        else:
            rec = r["record"]
            assert rec["fingerprint"] == fp, vid
            findings[fp] = rec
            note = f"phase 5: record verifier {vid} replacement applied for {fp}: {r['reason'][:300]}"
        for u in units:
            if fp in u["result_fingerprints"]:
                u["decisions"].append(note)
    ledger.save(units)
    with open(f"{OUT}/findings.json", "w") as f:
        json.dump(sorted(findings.values(), key=lambda x: x["fingerprint"]), f, indent=1, ensure_ascii=False)
    print(f"{len(findings)} records")
    print(ledger.count_line(units))

if __name__ == "__main__":
    main()
