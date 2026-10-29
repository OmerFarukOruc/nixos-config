from __future__ import annotations

import json
import os
import tempfile
from datetime import datetime
from pathlib import Path

EVENTS_MAX = 1 << 20


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=1)
        f.write("\n")
    os.replace(tmp, path)


def append_event(path: Path, msg: str) -> str:
    line = f"{datetime.now().astimezone().isoformat(timespec='seconds')} {msg}"
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.stat().st_size >= EVENTS_MAX:
        path.replace(path.with_name(path.name + ".1"))
    with path.open("a") as f:
        f.write(line + "\n")
    return line
