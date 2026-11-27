#!/usr/bin/env python3
"""Stop hook: name each subagent that ended its turn while a command of its own still runs.

Claude Code sends the session the notice `Agent "<description>" is waiting on its own background work` for such a
subagent. The hook prints `hookSpecificOutput.additionalContext` that names the subagent, once per notice, when no
`TaskStop` or `SendMessage` to it followed the notice and `background_tasks` in the hook input still lists a `shell`
task that the subagent's own transcript shows it started. It prints nothing inside a subagent, while
`stop_hook_active` is true, when the input has no `background_tasks`, and on any error.
"""

import contextlib
import json
import os
import re
import sys
from pathlib import Path

NOTICE = re.compile(
    r"<task-notification>\s*<task-id>(?P<id>[^<]+)</task-id>.*?<summary>(?P<summary>[^<]*)</summary>",
    re.DOTALL,
)
WAITING = re.compile(r'^Agent "(?P<label>.*)" is waiting on its own background work$')
MARKERS = ("<task-notification>", '"TaskStop"', '"SendMessage"')
OWN_COMMAND = re.compile(
    r"(?:moved to the background \(ID: |running in background with ID: )([A-Za-z0-9_-]+)"
)


def records(path):
    with open(path, encoding="utf-8", errors="replace") as transcript:
        for number, line in enumerate(transcript, 1):
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict):
                yield number, line, entry


def arrived_notice(entry):
    if entry.get("type") != "queue-operation" or entry.get("operation") != "enqueue":
        return None
    content = entry.get("content")
    return NOTICE.match(content) if isinstance(content, str) else None


def tool_calls(entry):
    if entry.get("type") != "assistant":
        return []
    message = entry.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, list):
        return []
    return [
        block
        for block in content
        if isinstance(block, dict) and block.get("type") == "tool_use"
    ]


def settled_ids(entry):
    ids = []
    for call in tool_calls(entry):
        raw_input = call.get("input")
        tool_input = raw_input if isinstance(raw_input, dict) else {}
        if call.get("name") == "TaskStop":
            ids.append(tool_input.get("task_id") or tool_input.get("shell_id"))
        elif call.get("name") == "SendMessage":
            ids.append(str(tool_input.get("to", "")).split(" [")[0])
    return [agent_id for agent_id in ids if agent_id]


def waiting_agents(transcript_path):
    waiting = {}
    for number, line, entry in records(transcript_path):
        if not any(marker in line for marker in MARKERS):
            continue
        notice = arrived_notice(entry)
        if notice:
            state = WAITING.match(notice["summary"].strip())
            if state:
                waiting[notice["id"]] = (state["label"], number)
            else:
                waiting.pop(notice["id"], None)
        for agent_id in settled_ids(entry):
            waiting.pop(agent_id, None)
    return waiting


def tool_result_texts(entry):
    if entry.get("type") != "user":
        return
    message = entry.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, list):
        return
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "tool_result":
            continue
        result = block.get("content")
        if isinstance(result, str):
            yield result
        elif isinstance(result, list):
            for part in result:
                if isinstance(part, dict) and isinstance(part.get("text"), str):
                    yield part["text"]


def own_command_ids(transcript_path, agent_id):
    agent_transcript = (
        Path(transcript_path).with_suffix("") / "subagents" / f"agent-{agent_id}.jsonl"
    )
    ids = set()
    try:
        for _, line, entry in records(agent_transcript):
            if "background" in line:
                for text in tool_result_texts(entry):
                    ids.update(OWN_COMMAND.findall(text))
    except OSError:
        return set()
    return ids


def running_command_ids(hook_input):
    tasks = hook_input.get("background_tasks")
    if not isinstance(tasks, list):
        return set()
    return {
        str(task.get("id"))
        for task in tasks
        if isinstance(task, dict) and task.get("type") == "shell"
    }


def left_open(hook_input):
    if hook_input.get("stop_hook_active") or hook_input.get("agent_id"):
        return {}
    running = running_command_ids(hook_input)
    if not running:
        return {}
    transcript_path = str(hook_input.get("transcript_path") or "")
    return {
        agent_id: notice
        for agent_id, notice in waiting_agents(transcript_path).items()
        if own_command_ids(transcript_path, agent_id) & running
    }


def first_naming(hook_input, agent_id, notice_line):
    root = Path(
        os.environ.get("XDG_RUNTIME_DIR")
        or os.environ.get("XDG_STATE_HOME")
        or Path.home() / ".local/state"
    )
    session = re.sub(
        r"[^A-Za-z0-9-]", "_", str(hook_input.get("session_id") or "unknown")
    )
    marker = (
        root / "claude-hooks/agent-left-open" / session / f"{agent_id}-{notice_line}"
    )
    try:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.open("x").close()
    except OSError:
        return False
    return True


def feedback(agents):
    lines = [f'- {agent_id} "{label}"' for agent_id, label in agents.items()]
    return (
        "These subagents ended their turn while a command of theirs still ran in the background. "
        "Each one stays alive, with its context and any worktree it made, until that command ends:\n"
        + "\n".join(lines)
        + "\nFor each one whose report you have accepted, or whose result you no longer need, "
        "call TaskStop with its id as task_id now. "
        "Leave one whose report is still missing; it resumes when its command ends and notifies you again. "
        "This reminder comes once for each such notice."
    )


def main():
    hook_input = json.load(sys.stdin)
    if not isinstance(hook_input, dict):
        return
    agents = {
        agent_id: label
        for agent_id, (label, notice_line) in left_open(hook_input).items()
        if re.fullmatch(r"[A-Za-z0-9_-]+", agent_id)
        and first_naming(hook_input, agent_id, notice_line)
    }
    if agents:
        json.dump(
            {
                "hookSpecificOutput": {
                    "hookEventName": "Stop",
                    "additionalContext": feedback(agents),
                }
            },
            sys.stdout,
        )


if __name__ == "__main__":
    with contextlib.suppress(OSError, ValueError, TypeError, AttributeError, KeyError):
        main()
    sys.exit(0)
