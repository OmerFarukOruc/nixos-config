#!/usr/bin/env python3
"""PreToolUse hook: deny a file edit in a repository's main checkout, unless that repository sets the git config key
`agents.mainCheckoutEdits` to true, or the file lies under a folder that a value of `agents.mainCheckoutEditPaths`
names relative to the checkout, such as `agents/` in nixos-config.

Claude Code sends Edit, Write, and NotebookEdit with `file_path` or `notebook_path`. Codex sends `apply_patch` with
the patch text as `command`, whose `*** Add File:`, `*** Update File:`, `*** Delete File:` and `*** Move to:` lines
name the paths, relative to `cwd`. Codex joins those paths to `cwd` without expanding `~` and resolves `..` before any
symlink, and it accepts an indented header as the first line of the patch and after an Add or Delete hunk, where an
Update hunk would read it as a context line; the hook reads them the same way. A shell command that writes a file,
such as `sed -i` or `cat >`, passes, because this hook sees only these tools. Input it cannot read is let through.
"""
import json
import os
import re
import sys

from checkouts import git, is_shared_checkout

PATCH_HEADER = re.compile(r"\*\*\* (Add File|Update File|Delete File|Move to): (.+?)\s*$")


def patch_headers(patch):
    """The (kind, path) pairs of the file headers of the apply_patch text patch."""
    hunk = None
    for line in patch.splitlines():
        if line.strip() == "*** Begin Patch":
            hunk = None
            continue
        match = PATCH_HEADER.match(line) or (hunk != "Update File" and PATCH_HEADER.match(line.strip()))
        if match:
            kind, path = match.groups()
            hunk = hunk if kind == "Move to" else kind
            yield kind, path


def patch_paths(patch, cwd):
    """The paths the patch writes, with symlinks resolved, and for a deleted or moved file the directory entry itself."""
    headers = list(patch_headers(patch))
    for k, (kind, path) in enumerate(headers):
        lexical = os.path.normpath(os.path.join(cwd, path))
        moved = kind == "Update File" and k + 1 < len(headers) and headers[k + 1][0] == "Move to"
        if kind == "Delete File" or moved:
            yield os.path.join(os.path.realpath(os.path.dirname(lexical)), os.path.basename(lexical))
        if kind != "Delete File":
            yield os.path.realpath(lexical)


def edited_paths(tool_name, tool_input, cwd):
    for key in ("file_path", "notebook_path"):
        if isinstance(tool_input.get(key), str):
            yield os.path.realpath(os.path.join(cwd, os.path.expanduser(tool_input[key])))
    if tool_name == "apply_patch" and isinstance(tool_input.get("command"), str):
        yield from patch_paths(tool_input["command"], cwd)


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
        paths = list(edited_paths(data.get("tool_name"), tool_input, cwd))
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
