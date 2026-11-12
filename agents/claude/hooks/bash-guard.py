#!/usr/bin/env python3
"""PreToolUse hook for Bash: deny a call that one of the guard checks refuses, with every reason in one answer.

Each check reads the call through `bash_call.parse`, so a commit message, a script, or a doc that mentions a command is
not read as that command. Three checks also look at the raw command text: the placeholder check searches it for a
`gh` post and a placeholder word, so a commit message that holds both is denied, and the worktree and build checks skip
a call whose text lacks their command's name. Every check runs on its own: one that raises is logged to stderr and named
in a `systemMessage` of the answer, and the other checks still answer. All checks keep to one deadline, so the answer
comes before Claude Code stops the hook at its timeout. Input that is not a Bash call with a command string is let
through.
"""
import json
import sys
import time

import git_checks
import process_checks
import secret_checks
import shell_checks
from bash_call import parse

CHECKS = git_checks.CHECKS + process_checks.CHECKS + secret_checks.CHECKS + shell_checks.CHECKS
DEADLINE_SECONDS = 8.0


def main():
    start = time.monotonic()
    try:
        data = json.load(sys.stdin)
        command = data["tool_input"]["command"]
    except (ValueError, KeyError, TypeError, AttributeError):
        return 0
    if not isinstance(command, str):
        return 0
    call, reasons, failed = parse(command, data, start + DEADLINE_SECONDS), [], []
    for check in CHECKS:
        try:
            reason = check(call)
        except Exception:
            import logging
            logging.getLogger("bash-guard").exception("%s failed", check.__name__)
            failed.append(check.__name__)
        else:
            if reason:
                reasons.append(reason)
    if reasons:
        answer = {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "\n\n".join(reasons),
        }}
        if failed:
            answer["systemMessage"] = f"bash-guard: {', '.join(failed)} failed and did not check this call; see stderr."
        print(json.dumps(answer))
    return int(bool(failed) and not reasons)


if __name__ == "__main__":
    sys.exit(main())
