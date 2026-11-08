# Security-audit harness

The parent's bookkeeping for a full audit run: the ledger, prompt builders, the sandbox, artifact promotion, the
Workflow scripts and the report generator. SKILL.md and its companion files stay the source of every rule; these
scripts apply them so each run does not rebuild the tooling. The `security-audit` skill is the folder next to this one, and
the scripts read its files from there.

## Layout

- A run directory holds one audit run, for example `~/security-audit-skill/<repo>/run-1/`. It holds `run.json`,
  `architecture.md`, `coverage-ledger.json`, `findings.json`, `agents/<id>/`, `plan/` and the reports.
- `bin/` holds the parent scripts. Each takes `--run DIR` first and refuses to run without it; `wf-results` and
  `blocks.py` take no run. Every script that saves the ledger ends with a count line such as
  `ledger: 108 units; candidate 33, covered 74, not_applicable 1`. Quote counts from that line.
- `workflows/` holds the Workflow scripts. Run them as `Workflow({scriptPath: "<harness>/workflows/<name>.js", args})`.
  Each returns only ids and counts; `bin/wf-results <runId>` rebuilds the full per-agent results from the run's
  journal, in the shape the apply scripts read.
- The replay of a finished run through these scripts is unverified, because no public fixture run exists.

## run.json

```json
{
  "name": "<repo name used in prompts and the report title>",
  "target": "<absolute path of the target checkout>",
  "commit": "<full SHA under review>",
  "unreviewed_ignore": ["<glob of tracked files that hold no security-relevant behaviour>"],
  "exclusions": {"file": {"<FILE.md#Core discipline>": "<reason>"}, "never": {"<FILE.md#Class>": "<reason>"}},
  "execution_example": {"label": "<short name>", "command": "<command run inside sa-sandbox>", "note": "<what it shows>"},
  "sandbox": {
    "require": ["<executables that must exist, or sa-sandbox refuses>"],
    "ro_binds": ["<read-only toolchain and dependency-cache folders>"],
    "path": ["<PATH entries in front of the system PATH>"],
    "env": {"<NAME>": "<value>"},
    "files": {"<scratch-relative path>": "<content written before each run>"}
  }
}
```

Optional keys that `report.py` prints in section 1 of the report, each only when present:
`deviations` (strings) and `unavailable_checks` (strings, for example checks that need a service the sandbox cannot
start). `exclusions.file` also lists the companion blocks the report names as excluded. The report states the run's
commit, the wave count (one `plan/wave-N.json` per wave), the agent counts, and whether any ledger unit carries a prior
status, and nothing else about scope, branch or earlier runs.

Sandbox values may use `{run}` for the run directory and `{scratch}` for the agent's scratch mount.
Keep the `run.json` of each finished run in its run directory; the one from an earlier run of a similar project is the starting point.

## Sandbox scripts

- `mkscratch --run DIR <agent-id> [size, default 4G]` creates `agents/<id>/{scratch,artifacts}` under a run. The
  scratch is a sparse ext4 loop mount, which caps its disk use. It needs passwordless `sudo -n mount`, and takes
  `mkfs.ext4` from PATH or from nixpkgs through `nix shell`.
- `sa-copy-src --run DIR <agent-id>` copies the run's reviewed commit (`git archive`, no build outputs) into
  `<scratch>/src`. It runs outside the sandbox and does not execute target code.
- `sa-node <script> [ARG...]` runs node from PATH, otherwise node from nixpkgs through `nix shell`, capped by `heavy`
  where the host has it.
- `sa-sandbox --run DIR <agent-id> -- CMD [ARG...]` runs one target-controlled command, with cwd `<scratch>/src` if it
  exists, else `<scratch>`. It refuses to run when it cannot apply or verify a control:
  - a systemd user scope with MemoryMax 5G, no swap, TasksMax 512, CPUQuota 400% and RuntimeMaxSec 1200;
  - prlimit with fsize 512 MiB, nofile 4096 and core 0;
  - the 4 GiB ext4 loop mount as the only writable path;
  - bubblewrap with every namespace unshared, so the network is an isolated loopback only;
  - an `env -i` allowlist;
  - read-only system folders (on NixOS `/nix/store` and not `/nix/var`, so no nix-daemon socket), plus the toolchain
    and dependency cache that the `run.json` `sandbox` block names.

  At most two sandboxes run at once on a host, because each may take 4 CPUs and 5 GiB of memory. The files that
  `sandbox.files` writes land in a scratch that earlier target code could fill with symlinks, so the script writes them
  only at paths that resolve inside the scratch and replaces a symlink at the leaf instead of following it.

## Phases

| Phase | Parent steps |
|---|---|
| Setup | Write `run.json` and warm the toolchain and offline dependency cache it names. Run `kit.py --run DIR`. |
| 1 Recon | `recon.js` with `{target, commit, out, agents: [{id, task}]}`; `wf-results <runId> > plan/recon-output.json`. Write `architecture.md` and `plan/units.py`, then `ledger.py --run DIR seed`. |
| 2 Hunt | `wave.py --run DIR N <agent>=<unit>,<unit> ...`, then `hunt-wave.js` with `plan/wave-N-args.json`, then `wf-results <runId> > plan/wave-N-output.json` and `fold.py --run DIR N plan/wave-N-output.json`. |
| 2 Critic | `critic.py --run DIR critic-wN-post post-wave N`, then `coverage-critic.js` with `{id, prompt_path}` and `wf-results <runId> \| jq '.results[0]' > plan/critic-wN-post.json`. Write the accepted units as a specs file and run `ledger.py --run DIR add-units <specs>`; add accepted `unreviewed_without_unit` patterns to `run.json`. |
| 3 Verify | Write `plan/phase3-consolidation.json`, run `verify3.py --run DIR plan/phase3-consolidation.json`, `verify-candidates.js` with `plan/phase3-args.json`, `wf-results <runId> > plan/phase3-output.json`, then `apply3.py --run DIR plan/phase3-output.json`. |
| 4 Validate | `sa-node <skill>/validate-findings.cjs findings.json` and `sa-node <skill>/validate-coverage-ledger.cjs coverage-ledger.json`. |
| 5 Records | `verify5.py --run DIR r5`, `verify-records.js` with `plan/r5-args.json`, `wf-results <runId> > plan/phase5-output.json`, then `apply5.py --run DIR plan/r5-manifest.json plan/phase5-output.json --pending <material ids>`. Send each material replacement to a fresh verifier with `verify5.py --run DIR r6 --replacements <file>`. |
| 6 Report | Write `plan/posture.md`, `positive.md`, `coverage-notes.md`, `hardening-curated.md`, `nv-priority.json` and `boundaries.json`, then run `report.py --run DIR`. |

`ledger.py --run DIR add-units SPECS.json` reads `{"wave": N, "units": [{key, surface: [label, ref], boundary,
subsystem, attack_class: [file, class], ordinary, companions: [[file, class]], lifecycle, paths, origin}],
"reassign": [{unit_key, reason}]}`. `ledger.py --run DIR unreviewed --wave N` lists the files no unit reviewed, which the critic
prompt carries, because a file no hunter read is the cheapest coverage gap to find.

Hunting continues while a post-wave critic adds units. Coverage is complete when a post-wave critic and a distinct
final-clean critic (`critic.py --run DIR critic-final final-clean N`) both return `stop: true` with no units.

## Traps

- `mkscratch` mounts each agent's scratch as a loop device and needs passwordless `sudo -n mount`. On a host without
  it, the script refuses.
- Before deleting `.scratch-images/`, unmount every `agents/*/scratch` with `sudo -n umount`. Keep anything worth
  keeping in `agents/<id>/scratch-keep/` first, because the mount holds each agent's `result.json`.
- `fold.py` checks all candidate records of a hunter in one `validate-findings.cjs` call, then each record alone when that
  fails, because the validator stops at 100 errors and would leave later records unnamed.
- `wave.py` hands the Workflow only the JSON Schema keywords of the report schema and drops the others, such as
  `visibleContent`; `fold.py` still enforces the full schema with `validate-findings.cjs`. Whether the Workflow tool
  needs this is not verified.
- Pass `wave-N-args.json` as the Workflow `args` value itself, not as a path, because Workflow scripts cannot read
  files.
