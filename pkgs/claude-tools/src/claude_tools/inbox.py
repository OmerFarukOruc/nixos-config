from __future__ import annotations

import fcntl
import os
import re
from collections.abc import Callable
from datetime import datetime
from pathlib import Path

KINDS = ("NEED", "DONE", "INFO")
TEXT_MAX = 500
HEAD_MAX = 430
NOTE_COPIES = 100


def keep_full(notes: Path, text: str, kind: str, agent: str, now: datetime) -> Path:
    notes.mkdir(parents=True, exist_ok=True)
    stem = f"{now.strftime('%Y%m%dT%H%M%SZ')}-{re.sub(r'[^A-Za-z0-9_.-]', '_', agent)[:64]}-{kind}"
    for n in range(NOTE_COPIES):
        path = notes / f"{stem}{f'-{n}' if n else ''}.txt"
        try:
            with path.open("x") as f:
                f.write(text.rstrip("\n") + "\n")
            return path
        except FileExistsError:
            continue
    raise FileExistsError(f"{notes / stem}.txt and {NOTE_COPIES - 1} numbered copies exist")


def record(inbox: Path, kind: str, text: str, agent: str, now: datetime) -> str:
    folded = re.sub(r"\s+", " ", text).strip()
    if len(folded) > HEAD_MAX:
        try:
            folded = f"full text: {keep_full(inbox.parent / 'notes', text, kind, agent, now)} | {folded}"
        except OSError as e:
            folded = f"(full text not saved: {type(e).__name__}: {e}) {folded}"
    return "\t".join([now.strftime("%Y-%m-%dT%H:%M:%SZ"), agent, kind, folded[:TEXT_MAX]])


def append(path: Path, line: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(line + "\n")
        f.flush()


def format_record(line: str) -> str:
    fields = line.split("\t")
    if len(fields) != 4:
        return f"--:--:-- ? INFO | {line}"
    when, agent, kind, text = fields
    stamp = when[11:19] if re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", when) else "--:--:--"
    return f"{stamp} {agent} {kind}{' (reply required)' if kind == 'NEED' else ''} | {text}"


class Inbox:
    def __init__(self, path: Path):
        self.path = path
        self.offset_file = path.with_name(path.name + ".offset")
        self.offset: int | None = None
        self.saved = 0

    def load(self) -> int:
        try:
            return int(self.offset_file.read_text())
        except (OSError, ValueError):
            return 0

    def save(self) -> None:
        if self.offset == self.saved:
            return
        tmp = self.offset_file.with_name(self.offset_file.name + ".tmp")
        tmp.write_text(str(self.offset))
        os.replace(tmp, self.offset_file)
        self.saved = self.offset

    def poll(self, emit: Callable[[str], None]) -> None:
        if self.offset is None:
            self.offset = self.saved = self.load()
        try:
            size = self.path.stat().st_size
        except FileNotFoundError:
            return
        self.offset = 0 if size < self.offset else self.offset
        with self.path.open("rb") as f:
            f.seek(self.offset)
            data = f.read()
        for raw in data[: data.rfind(b"\n") + 1].splitlines(keepends=True):
            emit(raw.decode(errors="replace").rstrip("\n"))
            self.offset += len(raw)
            self.save()
        self.save()
