from __future__ import annotations

import json
import re
from pathlib import Path

TAIL_BYTES = 4 << 20
STATUS = re.compile(r"^\s*(?:● )?((?:STATUS|NEED):.*)$")


def mtime(path: Path) -> float:
    try:
        return path.stat().st_mtime
    except OSError:
        return -1.0


def transcript_path(session: str, home: Path) -> Path | None:
    return max(home.glob(f".claude*/projects/*/{session}.jsonl"), key=mtime, default=None)


def last_text(path: Path) -> str | None:
    with path.open("rb") as f:
        f.seek(max(0, f.seek(0, 2) - TAIL_BYTES))
        lines = f.read().split(b"\n")
    for raw in reversed(lines):
        try:
            entry = json.loads(raw)
            if entry.get("type") != "assistant":
                continue
            parts = [c["text"] for c in entry["message"]["content"] if isinstance(c, dict) and c.get("text")]
        except (ValueError, KeyError, TypeError, AttributeError):
            continue
        if parts:
            return "\n".join(parts)
    return None


def status_line(text: str) -> str | None:
    found = [m[1] for line in text.splitlines() if (m := STATUS.match(line))]
    return found[-1] if found else None


def session_of(agent: dict) -> str | None:
    return (agent.get("agent_session") or {}).get("value")


def answer_of(agent: dict, home: Path) -> str | None:
    session = session_of(agent)
    path = transcript_path(session, home) if session else None
    try:
        return last_text(path) if path else None
    except OSError:
        return None
