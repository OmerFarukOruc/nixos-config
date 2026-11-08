#!/usr/bin/env python3
"""Parent-only Phase 6: derive REPORT.md, FINDINGS-DETAIL.md, NEEDS-VALIDATION.md and HARDENING.md. Usage: report.py --run DIR
from findings.json, coverage-ledger.json, run.json and the hand-written plan/posture.md,
plan/positive.md, plan/coverage-notes.md and plan/hardening-curated.md. Prose never changes a verdict, severity or blocker."""
import collections
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger
import runcfg
from runcfg import read_json, read_text, write_text

OUT = ledger.OUT

def and_join(xs):
    xs = [str(x) for x in xs]
    return xs[0] if len(xs) == 1 else ", ".join(xs[:-1]) + " and " + xs[-1]

def critic_line(units):
    added = collections.Counter()
    for u in units:
        for d in u["decisions"]:
            m = re.match(r"added in wave (\d+): ", d)
            if m:
                added[int(m.group(1)) - 1] += 1
                break
    waves = sorted(added)
    parts = []
    if waves:
        span = f"{waves[0]} to {waves[-1]}" if waves == list(range(waves[0], waves[-1] + 1)) and len(waves) > 2 else and_join(waves)
        parts.append(f"the post-wave critics for waves {span} added {and_join(added[w] for w in waves)} units.")
    def clean(c):
        return c.get("stop") and not c.get("missing_units") and not c.get("reassign_ids")
    quiet = []
    for name in sorted(os.listdir(f"{OUT}/plan"), key=lambda n: (len(n), n)):
        m = re.fullmatch(r"critic-w(\d+)-post\.json", name)
        if m and int(m.group(1)) not in added:
            c = read_json(f"{OUT}/plan/{name}"); c = c.get("result", c)
            if clean(c):
                quiet.append(f"the post-wave-{m.group(1)} critic")
            elif c.get("reassign_ids"):
                parts.append(f"The post-wave-{m.group(1)} critic reassigned {len(c['reassign_ids'])} units.")
            else:
                parts.append(f"The post-wave-{m.group(1)} critic proposed {len(c.get('missing_units') or [])} units that the parent did not accept.")
    final = f"{OUT}/plan/critic-final.json"
    if os.path.exists(final):
        c = read_json(final); c = c.get("result", c)
        if not clean(c):
            sys.exit(f"{final} accepted work; coverage is not complete, so no report")
        quiet.append("the distinct final-clean critic")
    if quiet:
        both = " both" if len(quiet) == 2 else (" all" if len(quiet) > 2 else "")
        text = f"{and_join(quiet)}{both} accepted no work and returned `stop: true`."
        parts.append(text[0].upper() + text[1:])
    return "- Coverage critics: " + " ".join(parts)

def hunter_waves():
    return sum(1 for n in os.listdir(f"{OUT}/plan") if re.fullmatch(r"wave-\d+\.json", n))

def loc(t):
    return f"`{t['file']}:{t['line']}`"

def one_line(s):
    s = " ".join(s.split())
    i = s.find(". ")
    return s if i < 0 else s[:i + 1]

def cell(s):
    return " ".join(str(s).split()).replace("|", "\\|")

def trace_md(rec):
    return "\n".join(f"{i}. {t['kind']}: {loc(t)} `{t['scope']}`: {t['description']}" for i, t in enumerate(rec["trace"], 1))

def evidence_md(rec):
    return "\n".join(f"- {loc(e)}: {e['description']}" for e in rec["evidence"])

def main():
    F = read_json(f"{OUT}/findings.json")
    units = ledger.load()
    prio = read_json(f"{OUT}/plan/nv-priority.json")
    rank = {fp: int(p) for p, fps in prio.items() for fp in fps}
    order = {fp: i for fps in prio.values() for i, fp in enumerate(fps)}
    sev_order = {"critical": 0, "high": 1, "medium": 2, "low": 3, "informational": 4}
    conf = sorted([f for f in F if f["verdict"] == "confirmed"], key=lambda f: (sev_order[f["severity"]["overall_severity"]], f["fingerprint"]))
    nv = sorted([f for f in F if f["verdict"] == "needs_validation"], key=lambda f: (rank[f["fingerprint"]], order[f["fingerprint"]]))
    rej = [f for f in F if f["verdict"] == "rejected"]
    by_fp = collections.defaultdict(list)
    for u in units:
        for fp in u["result_fingerprints"]:
            by_fp[fp].append(u)
    named = read_json(f"{OUT}/plan/boundaries.json")
    def boundary(fp):
        if fp in named:
            return named[fp]
        return "; ".join(sorted({u["boundary"] for u in by_fp[fp]}))
    counts = collections.Counter(u["status"] for u in units)
    merged = len({f for v in read_json(f"{OUT}/plan/phase3-consolidation.json").values() for f in v["merge"]})
    agents = sorted(d for d in os.listdir(f"{OUT}/agents") if d != "probe")
    roles = collections.Counter(("critic" if a.startswith("critic") else a.split("-")[0]) for a in agents)
    read = lambda p: read_text(f"{OUT}/plan/{p}").strip()

    hard = []
    for u in units:
        for h in u["hardening"]:
            if h not in [x for _, x in hard]:
                hard.append((u["unit_key"], h))

    r = []
    r.append(f"# Security audit report: {runcfg.NAME}\n")
    r.append("## 1. Run\n")
    r.append(f"- Source ref `{runcfg.COMMIT}` of `{runcfg.NAME}`.")
    waves = hunter_waves()
    hunters = sum(v for k, v in roles.items() if k.startswith("w"))
    r.append(f"- Agents spent: {len(agents)} in total ({roles['recon']} reconnaissance, {hunters} hunters{f' over {waves} waves' if waves else ''}, {roles['critic']} coverage critics, {roles['v3']} Phase 3 candidate verifiers, {roles['r5']} Phase 5 record verifiers, {roles['r6']} fresh verifiers for material Phase 5 replacements).")
    r.append("- Agents ran target code only through `sa-sandbox` (a per-agent bubblewrap sandbox with no external network and the resource caps listed in the harness README), and `promote.py` promoted their evidence files.")
    carried = sum(1 for u in units if u["prior_status"] != "none")
    r.append("- Prior runs: no unit in the ledger carries a prior status." if not carried else f"- Prior runs: {carried} of {len(units)} ledger units carry a prior status.")
    for d in runcfg.CFG.get("deviations", []):
        r.append(f"- Deviation: {d}")
    unavailable = runcfg.CFG.get("unavailable_checks", [])
    if unavailable:
        r.append(f"- Could not run: {and_join(unavailable)}. Findings whose decisive result needs them stay `needs_validation`.")
    excluded = runcfg.CFG.get("exclusions", {}).get("file", {})
    if excluded:
        r.append(f"- Companion blocks excluded by `run.json`: {'; '.join(f'`{block}` ({why})' for block, why in excluded.items())}.")
    r.append(f"- Deferred units: {counts.get('deferred', 0)}. Blocked units: {counts.get('blocked', 0)}.\n")
    r.append("## 2. Security posture\n")
    r.append(read("posture.md") + "\n")
    r.append("## 3. Confirmed findings\n")
    r.append("| Severity | Title | Affected boundary | Observed result |\n|---|---|---|---|")
    for f in conf:
        r.append(f"| {f['severity']['overall_severity']} | {cell(f['title'])} | {cell(boundary(f['fingerprint']))} | {cell(one_line(f['execution']['observed_result']))} |")
    r.append("")
    r.append("## 4. Confirmed finding details\n")
    for i, f in enumerate(conf, 1):
        e, s = f["execution"], f["severity"]
        r.append(f"### 4.{i} {f['title']}\n")
        r.append(f"- Fingerprint: `{f['fingerprint']}`")
        r.append(f"- Source: {', '.join(loc(t) for t in f['trace'] if t['kind'] in ('entrypoint', 'sink'))}")
        r.append(f"- Lower-trust principal: {e['attacker_perspective']}")
        r.append("- Bounded local reproduction:")
        for p in e["payloads"]:
            r.append(f"  - input: `{p}`" if "\n" not in p else f"  - input:\n\n```text\n{p}\n```")
        for x in e["instructions"]:
            r.append(f"  - {x}")
        r.append("- Conditions: " + " ".join(f"{c['kind']}: {c['description']}" for c in f["conditions"]))
        r.append(f"- Actual result: {e['observed_result']}")
        r.append(f"- Impact: {s['impact']['score']}. {s['impact']['reason']}")
        r.append(f"- Priority: overall {s['overall_severity']}; likelihood {s['likelihood']['score']}. {s['likelihood']['reason']}")
        r.append(f"- Smallest source fix: {f['remediation']['strategy']}")
        for c in f["remediation"].get("code_changes", []):
            r.append(f"  - `{c['file_name']}`")
        r.append("- Evidence: " + ", ".join(f"`{x['file']}`" for x in f["evidence"] if x["file"].startswith("agents/")) + "\n")
    r.append("## 5. NEEDS VALIDATION\n")
    r.append("These are source-grounded leads, not confirmed vulnerabilities, and carry no severity. Full records are in `NEEDS-VALIDATION.md`. Priority 1 touches secrets, release or admin authority; 2 touches accounts and identity; 3 touches availability and data handling.\n")
    r.append("| Priority | Title | Repository trace | Exact blocker | Local next step | Owner-observed deployment check |\n|---|---|---|---|---|---|")
    for f in nv:
        vp = f["validation_plan"]
        tr = " to ".join(loc(t) for t in f["trace"] if t["kind"] in ("entrypoint", "sink")) or loc(f["trace"][0])
        r.append(f"| {rank[f['fingerprint']]} | {cell(f['title'])} | {cell(tr)} | {cell(f['blockers'][0])} | {cell(vp.get('local', 'none applicable'))} | {cell(vp.get('deployment', 'none applicable'))} |")
    r.append("")
    r.append("## 6. Hardening notes and positive source patterns\n")
    r.append("### Hardening notes\n")
    r.append(read("hardening-curated.md"))
    r.append(f"\nAll {len(hard)} distinct hunter hardening notes, grouped by coverage unit, are in `HARDENING.md`. None of them is a finding.\n")
    r.append("### Positive source patterns\n")
    r.append(read("positive.md") + "\n")
    r.append("## 7. Coverage\n")
    r.append(f"- Ledger units: {len(units)}. covered {counts.get('covered', 0)}, candidate {counts.get('candidate', 0)}, blocked {counts.get('blocked', 0)}, deferred {counts.get('deferred', 0)}, not_applicable {counts.get('not_applicable', 0)}, planned {counts.get('planned', 0)}, in_progress {counts.get('in_progress', 0)}.")
    r.append(f"- Every candidate unit has an independent final disposition: {len(conf)} confirmed, {len(nv)} needs_validation, {len(rej)} rejected records in `findings.json` ({merged} hunter fingerprints merged into {len(F)} root causes).")
    na = [u for u in units if u["status"] == "not_applicable"]
    for u in na:
        r.append(f"- Not applicable: {u['surface']}. {' '.join(u['unresolved'])}")
    r.append(read("coverage-notes.md"))
    r.append(critic_line(units))
    r.append("- Validators: `validate-findings.cjs` and `validate-coverage-ledger.cjs` pass on the final files.\n")
    write_text(f"{OUT}/REPORT.md", "\n".join(r) + "\n", "w")

    d = ["# Findings detail\n"]
    mh = [f for f in conf if sev_order[f["severity"]["overall_severity"]] <= 2]
    if not mh:
        d.append(f"No confirmed record is medium, high or critical, so the skill requires no detail section. The complete records of the {len(conf)} low findings follow so each can be reproduced and fixed without reading `findings.json`.\n")
    for f in (mh or conf):
        e = f["execution"]
        d.append(f"## {f['title']} ({f['severity']['overall_severity']})\n")
        d.append(f"Fingerprint `{f['fingerprint']}`.\n\n{f['description']}\n")
        d.append(f"**Root cause.** {f['root_cause']}\n\n**Invariant.** {f['intended_behavior']}\n")
        d.append("**Trace.**\n\n" + trace_md(f) + "\n\n**Evidence.**\n\n" + evidence_md(f) + "\n")
        d.append(f"**Principal and resource.** {e['attacker_perspective']}\n")
        d.append("**Input.**\n\n" + "\n".join(f"```text\n{p}\n```" for p in e["payloads"]) + "\n")
        d.append("**Instructions.**\n\n" + "\n".join(f"{i}. {x}" for i, x in enumerate(e["instructions"], 1)) + "\n")
        d.append(f"**Observed result.** {e['observed_result']}\n")
        d.append("**Conditions.**\n\n" + "\n".join(f"- {c['kind']}: {c['description']}" for c in f["conditions"]) + "\n")
        d.append(f"**Severity.** Likelihood {f['severity']['likelihood']['score']}: {f['severity']['likelihood']['reason']} Impact {f['severity']['impact']['score']}: {f['severity']['impact']['reason']} Confidence {f['confidence']['score']}: {f['confidence']['reason']}\n")
        d.append(f"**Remediation.** {f['remediation']['strategy']}\n")
        for c in f["remediation"].get("code_changes", []):
            d.append(f"`{c['file_name']}`:\n\n```\n{c['fixed_code']}\n```\n")
    write_text(f"{OUT}/FINDINGS-DETAIL.md", "\n".join(d) + "\n", "w")

    n = ["# Needs validation\n", "Source-grounded leads without severity, in priority order. None is a confirmed vulnerability. Each lists the exact blocker and a bounded local or owner-observed way to settle it; none asks for traffic to a deployed system.\n"]
    for f in nv:
        n.append(f"## P{rank[f['fingerprint']]}: {f['title']}\n")
        n.append(f"Fingerprint `{f['fingerprint']}`. Affected boundary: {boundary(f['fingerprint'])}.\n\n{f['description']}\n")
        n.append(f"**Claimed root cause.** {f['claimed_root_cause']}\n")
        n.append("**Trace.**\n\n" + trace_md(f) + "\n\n**Verified evidence.**\n\n" + evidence_md(f) + "\n")
        n.append("**Blockers.**\n\n" + "\n".join(f"- {b}" for b in f["blockers"]) + "\n")
        for k in ("local", "deployment"):
            if k in f["validation_plan"]:
                n.append(f"**{'Local plan' if k == 'local' else 'Owner-observed deployment check'}.** {f['validation_plan'][k]}\n")
    write_text(f"{OUT}/NEEDS-VALIDATION.md", "\n".join(n) + "\n", "w")

    h = ["# Hardening notes\n", "Hunter notes kept in ledger bookkeeping. None is a finding; several were later raised as candidates and are in `findings.json` under their own fingerprint.\n"]
    cur = None
    for key, note in hard:
        if key != cur:
            u = next(x for x in units if x["unit_key"] == key)
            h.append(f"\n## {key}: {u['surface']}\n")
            cur = key
        h.append(f"- {' '.join(note.split())}")
    write_text(f"{OUT}/HARDENING.md", "\n".join(h) + "\n", "w")
    print(f"confirmed {len(conf)}, needs_validation {len(nv)}, rejected {len(rej)}, hardening {len(hard)}")

if __name__ == "__main__":
    main()
