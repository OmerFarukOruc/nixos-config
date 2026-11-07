#!/usr/bin/env python3
"""PreToolUse hook: deny a file edit in a repository's main checkout, unless that repository sets the git config key
`agents.mainCheckoutEdits` to true, or the file lies under a folder that a value of `agents.mainCheckoutEditPaths`
names relative to the checkout, such as `agents/` in nixos-config.

Claude Code sends Edit, Write, and NotebookEdit with `file_path` or `notebook_path`. A shell command that writes a
file, such as `sed -i` or `cat >`, passes, because this hook sees only these tools. Input it cannot read is let
through.
"""
import json
import os
import sys

from checkouts import git, is_shared_checkout


def named_paths(tool_input):
    for key in ("file_path", "notebook_path"):
        if isinstance(tool_input.get(key), str):
            yield tool_input[key]


def nearest_directory(path):
    directory = os.path.dirname(path)
    while not os.path.isdir(directory) and directory != os.path.dirname(directory):
        directory = os.path.dirname(directory)
    return directory


def refusing_checkout(path):
    directory = nearest_directory(path)
    if git(directory, "rev-parse", "--is-inside-work-tree") != "true" or not is_shared_checkout(directory):
        return None
    if git(directory, "config", "--bool", "agents.mainCheckoutEdits") == "true":
        return None
    checkout = git(directory, "rev-parse", "--show-toplevel")
    if checkout and in_edit_paths(directory, os.path.relpath(path, os.path.realpath(checkout))):
        return None
    return checkout


def in_edit_paths(directory, relative):
    prefixes = (git(directory, "config", "--get-all", "agents.mainCheckoutEditPaths") or "").splitlines()
    return any(relative.startswith(prefix.rstrip("/") + "/") for prefix in prefixes if prefix.strip("/"))


def main():
    try:
        data = json.load(sys.stdin)
        tool_input, cwd = data["tool_input"], data.get("cwd")
        if not isinstance(cwd, str) or not cwd:
            cwd = os.getcwd()
        paths = [os.path.realpath(os.path.join(cwd, os.path.expanduser(path))) for path in named_paths(tool_input)]
    except (ValueError, KeyError, TypeError, AttributeError):
        return 0
    for path in paths:
        checkout = refusing_checkout(path)
        if checkout:
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": (
                    f"{checkout} is a repository's main checkout, which sessions share for reading and landing. "
                    "Load the worktrees skill, run `wt switch --create <type>/<slug> --no-cd` from that checkout, "
                    "and make this change under the worktree path it prints. Omer can still edit here himself."
                ),
            }}))
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
