"""What running agents hold: unfinished work in a folder, its owner, and the sessions that named a word."""

import datetime
import functools
import glob
import json
import os
import re
import time
from typing import NamedTuple

from config import HANDOFFS, RECENT, UNFINISHED_DEPTH
from holders import HOME, tilde
from rows import CommandError, run


@functools.cache
def unfinished(path: str) -> str | None:
    """Why a /tmp folder holds work an agent may still need, or None.

    An agent ticks the items in its TASKS.md as it finishes them, so an
    unticked one means the task is open. A git repo or worktree with changes,
    or with commits no remote has, holds the only copy of that work; a repo
    git cannot read counts too. A worktree's `.git` is a file. An agent names
    its scratch folder with its session ID or that ID's first 8 characters,
    so a folder whose name holds the ID of a running agent (owner_reason)
    belongs to that agent, and a handoff that names the folder passes it to
    the next one.
    --no-optional-locks keeps `git status` from rewriting the index, which
    would make the folder look changed today.
    """
    items, repos = 0, 0
    for top, dirs, files in os.walk(path):
        if ".git" in dirs or ".git" in files:
            repos += _git(top, "rev-list", "--count", "HEAD", "--not", "--remotes") != "0" or _git(
                top, "--no-optional-locks", "status", "--porcelain") != ""
        if "TASKS.md" in files:
            try:
                with open(os.path.join(top, "TASKS.md"), errors="replace") as f:
                    items += sum(1 for line in f if re.match(r"\s*- \[ \]", line))
            except OSError:
                pass
        depth = 0 if top == path else os.path.relpath(top, path).count(os.sep) + 1
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules")] if depth < UNFINISHED_DEPTH else []
    why = ([f"`TASKS.md` has {items} open item{'s' * (items > 1)}"] if items else []) + (
        [f"{repos} git repo{'s' * (repos > 1)} {'hold' if repos > 1 else 'holds'} changes or commits no remote has"]
        if repos else [])
    name = os.path.basename(path)
    if owner := owner_reason(name):
        why.append(owner)
    if handoff := named_in_handoff(path):
        why.append(f"`{tilde(handoff)}` names it")
    return "; ".join(why) or None


def named_in_handoff(path: str) -> str | None:
    """The first handoff file that names path or a path under it, or None.

    A period after the path ends a sentence; one before a word character
    names another path, such as `/tmp/x.bak`.
    """
    rx = re.compile(re.escape(path) + r"(?![\w-]|\.\w)")
    return next((f for f, text in handoff_texts().items() if rx.search(text)), None)


@functools.cache
def handoff_texts() -> dict[str, str]:
    texts = {}
    for f in sorted(glob.glob(f"{HANDOFFS}/**", recursive=True)):
        if not os.path.isfile(f):
            continue
        try:
            with open(f, errors="replace") as fh:
                texts[f] = fh.read()
        except OSError:
            continue
    return texts


def _git(top: str, *args: str) -> str | None:
    """git's output in top, or None when it fails or takes over 120 s."""
    try:
        return run(["git", "-C", top, *args]).strip()
    except CommandError:
        return None


def session_mentions(words: list[str]) -> dict[str, str]:
    """For each word a running agent wrote in the last RECENT seconds, which agent."""
    found: dict[str, str] = {}
    since = time.time() - RECENT
    cutoff = datetime.datetime.fromtimestamp(since, datetime.UTC).isoformat()
    transcripts = [(f"live session {s.label}", t) for s in live_sessions() if words
                   for t in glob.glob(f"{s.config_home}/projects/*/{s.sid}.jsonl")]
    transcripts += [(codex_label(t), rollout) for t, rollout in recent_codex_threads() if words]
    for label, transcript in transcripts:
        try:
            if os.stat(transcript).st_mtime < since:
                continue
            with open(transcript, errors="replace") as f:
                for line in f:
                    hits = [w for w in words if w not in found and w in line]
                    if hits and json.loads(line).get("timestamp", "") >= cutoff:
                        found |= dict.fromkeys(hits, f"{label} named it")
        except (OSError, ValueError):
            continue
    return found


UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")


@functools.cache
def recent_codex_threads() -> tuple[tuple[str, str], ...]:
    """Each Codex thread whose rollout file changed in the last RECENT seconds, as (ID, rollout path).

    Codex keeps no file per running process, so a recent write stands in for
    a live thread; the ID is the CODEX_THREAD_ID its commands see.
    """
    since = time.time() - RECENT
    out = []
    for f in glob.glob(f"{HOME}/.codex/sessions/*/*/*/rollout-*.jsonl"):
        ids = UUID.findall(os.path.basename(f))
        try:
            if ids and os.stat(f).st_mtime >= since:
                out.append((ids[-1], f))
        except OSError:
            continue
    return tuple(out)


def codex_label(thread: str) -> str:
    return f"Codex thread `{thread[:8]}` (written in the last 24 h)"


def owner_reason(name: str) -> str | None:
    """Why a folder name ties the folder to a running agent, or None.

    A full ID in the name names one agent. Only its first 8 characters may
    name several: a Codex thread ID is a UUIDv7, whose first 8 characters are
    a timestamp that changes about once a minute.
    """
    owners = [(f"live session {s.label}", s.sid) for s in live_sessions()]
    owners += [(codex_label(t), t) for t, _ in recent_codex_threads()]
    full = set(UUID.findall(name))
    return (next((f"its name holds the ID of {label}" for label, sid in owners if sid in full), None)
            or next((f"its name holds the first 8 characters of the ID of {label}"
                     for label, sid in owners if sid[:8] in name), None))


class Session(NamedTuple):
    label: str
    sid: str
    config_home: str


@functools.cache
def live_sessions() -> tuple[Session, ...]:
    """Each Claude Code session whose process still runs.

    Each config home, such as ~/.claude or ~/.claude-work1, keeps
    sessions/<pid>.json; a procStart that differs from /proc/<pid>/stat means
    the pid was reused.
    """
    out = []
    for f in glob.glob(f"{HOME}/.claude*/sessions/*.json"):
        try:
            with open(f) as fh:
                s = json.load(fh)
            with open(f"/proc/{s['pid']}/stat") as fh:
                start = fh.read().rpartition(")")[2].split()[19]
        except (OSError, ValueError, KeyError):
            continue
        if start != str(s.get("procStart")):
            continue
        label = f"`{s.get('name') or s['sessionId'][:8]}` (pid {s['pid']})"
        out.append(Session(label, s["sessionId"], os.path.dirname(os.path.dirname(f))))
    return tuple(out)
