#!/usr/bin/env python3
"""Run configuration. Every harness script takes `--run DIR` as its first two arguments; importing this module
removes them from sys.argv, so each script reads its own arguments from sys.argv[1] on. DIR/run.json holds the facts
of that run: name, target, commit, exclusions, unreviewed_ignore, execution_example and sandbox.
`runcfg.py --run DIR sandbox-spec SCRATCH` prints the sandbox block as JSON with {run} and {scratch} filled in."""
import json
import os
import sys

BIN = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.dirname(BIN)
SKILL = os.path.join(os.path.dirname(HARNESS), "security-audit")


if not os.path.isfile(os.path.join(SKILL, "SKILL.md")):
    sys.exit(
        f"{SKILL}/SKILL.md does not exist. Run the scripts through the installed skill folder "
        "(for example ~/.claude/skills/security-audit-harness/bin/...), where security-audit is the next folder."
    )


def _take_run():
    if len(sys.argv) < 3 or sys.argv[1] != "--run":
        sys.exit(f"usage: {os.path.basename(sys.argv[0])} --run DIR ...")
    d = os.path.realpath(sys.argv[2])
    if not os.path.isfile(os.path.join(d, "run.json")):
        sys.exit(f"{d}/run.json does not exist")
    del sys.argv[1:3]
    return d


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write_text(path, text, mode="w"):
    with open(path, mode, encoding="utf-8") as f:
        return f.write(text)


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def write_json(path, obj, **kw):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, **kw)


def fill(value, scratch):
    if isinstance(value, str):
        return value.replace("{run}", OUT).replace("{scratch}", scratch)
    if isinstance(value, list):
        return [fill(v, scratch) for v in value]
    if isinstance(value, dict):
        return {k: fill(v, scratch) for k, v in value.items()}
    return value


OUT = _take_run()
CFG = read_json(os.path.join(OUT, "run.json"))
NAME, TARGET, COMMIT = CFG["name"], CFG["target"], CFG["commit"]


if __name__ == "__main__":
    if sys.argv[1:2] != ["sandbox-spec"] or len(sys.argv) != 3:
        sys.exit("usage: runcfg.py --run DIR sandbox-spec SCRATCH")
    spec = {"ro_binds": [], "path": [], "env": {}, "files": {}, "require": []}
    spec.update(CFG.get("sandbox", {}))
    print(json.dumps(fill(spec, sys.argv[2])))
