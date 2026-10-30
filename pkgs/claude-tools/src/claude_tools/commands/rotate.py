from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from claude_tools.accounts import Accounts, account_of, env_for, read_accounts
from claude_tools.agents import sessions
from claude_tools.errors import Failed
from claude_tools.limits import NO_RESET_WAIT
from claude_tools.picker import CANCELLED, PICKED, Picker
from claude_tools.selection import best, free_at, held_names, hold_limit, next_account
from claude_tools.settings import Settings
from claude_tools.store import append_event, now, read_json
from claude_tools.usage import by_name, load_cache, locked_refresh

CACHE_MAX_AGE = 900
MIN_WAIT = 60
STOP_WAIT_S = 15
NON_INTERACTIVE = {"-p", "--print", "-v", "--version", "-h", "--help"}
SESSION_FLAGS = {"-r", "--resume", "-c", "--continue", "--session-id", "--fork-session", "--from-pr"}
OPTION_LINE = re.compile(r"^  ((?:--?[\w-]+, )*--?[\w-]+)(?: ([<\[])[^>\]]*?(\.\.\.)?[>\]])?")
COMMAND_LINE = re.compile(r"^  ([a-z][\w|-]*)")


class Rotation:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.state = settings.state / "rotate"
        self.accounts = Accounts({}, None)
        self.dirs: dict[str, str] = {}

    @property
    def names(self) -> list[str]:
        return list(self.dirs)

    def log(self, msg: str) -> None:
        append_event(self.state / "events.log", msg)

    def say(self, msg: str) -> None:
        print(f"claude-tools rotate: {msg}", file=sys.stderr, flush=True)
        self.log(msg)

    def choose(self, recommend: str | None) -> str | None:
        cursor = recommend
        while True:
            by_dir = sessions(self.settings.home)
            live = {n: by_dir.get(d, 0) for n, d in self.dirs.items()}
            try:
                picker = Picker(self.accounts.names, self.dirs, load_cache(self.settings), live,
                                held_names(self.settings), cursor, self.settings.color)
                outcome, name = picker.run()
            except Exception as e:
                self.say(f"the account picker failed ({e!r})")
                return None
            if outcome == PICKED:
                return name
            if outcome == CANCELLED:
                return ""
            cursor = name or cursor
            print("claude-tools rotate: checking every account's usage…", file=sys.stderr, flush=True)
            try:
                locked_refresh(self.settings, self.names, None)
            except (OSError, ValueError, Failed) as e:
                self.say(f"could not check the accounts' usage ({e})")

    def after_limit(self, current: str, hook: dict) -> str | None:
        held = hold_limit(self.settings, current, hook.get("last_assistant_message") or "")
        nxt = next_account(self.settings, None)
        what = f"a {held[1]} until {when(held[0])}" if held else "a limit that has already reset"
        self.log(f"{current} hit {what}; next account: {nxt or 'none'}")
        return nxt

    def wake_time(self, session: str) -> float:
        at = time.time()
        try:
            free = free_at(self.settings, self.names, int(at))
        except Exception as e:
            self.log(f"session {session}: reading when an account is free failed: {e!r}")
            free = None
        until = max(free or at + NO_RESET_WAIT, at + MIN_WAIT)
        self.log(f"session {session}: no account is free; picking again at {when(until)}")
        return until


@dataclass
class Stop:
    session: str
    transcript: Path | None
    seen: int

    @classmethod
    def at_limit(cls, hook: dict) -> Stop:
        transcript = Path(hook["transcript_path"]) if hook.get("transcript_path") else None
        try:
            seen = transcript.stat().st_size if transcript else 0
        except OSError:
            seen = 0
        return cls(hook["session_id"], transcript, seen)

    def continued(self) -> bool:
        if not self.transcript:
            return False
        try:
            with self.transcript.open("rb") as f:
                f.seek(self.seen)
                lines = f.read().splitlines()
        except OSError:
            return False
        for line in lines:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict) and entry.get("type") == "user" and not entry.get("isMeta"):
                return True
        return False


def when(t: float) -> str:
    return datetime.fromtimestamp(t).astimezone().isoformat(timespec="seconds")


def claude_help(cache: Path) -> str:
    real = Path(shutil.which("claude") or "claude").resolve()
    key = re.sub(r"[^\w.-]", "_", f"{real}-{int(real.stat().st_mtime)}")
    f = cache / f"help-{key}.txt"
    if not f.exists():
        cache.mkdir(parents=True, exist_ok=True)
        tmp = f.with_suffix(f".{os.getpid()}")
        with tmp.open("w") as out:
            subprocess.run(["claude", "--help"], stdout=out, stderr=subprocess.DEVNULL, check=False)
        if "Commands:" not in tmp.read_text():
            tmp.unlink(missing_ok=True)
            raise OSError("claude --help printed no command list")
        for old in cache.glob("help-*.txt"):
            old.unlink(missing_ok=True)
        tmp.replace(f)
    return f.read_text()


def parse_help(text: str) -> tuple[dict[str, str], set[str]]:
    opts, cmds, section = {}, set(), None
    for line in text.splitlines():
        if re.match(r"^\S", line):
            section = line.strip().rstrip(":").lower()
            continue
        if section == "options" and (m := OPTION_LINE.match(line)):
            kind = "" if not m[2] else "variadic" if m[3] else "required" if m[2] == "<" else "optional"
            for o in m[1].split(", "):
                opts[o] = kind
        elif section == "commands" and (m := COMMAND_LINE.match(line)):
            cmds.update(m[1].split("|"))
    return opts, cmds


def interactive(args: list[str], cmds: set[str]) -> bool:
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        return False
    if any(a in NON_INTERACTIVE for a in args):
        return False
    return not (args and args[0] in cmds)


def option_values(args: list[str], i: int, kind: str) -> list[str]:
    if kind == "required":
        return args[i:i + 1]
    taken = []
    if kind in ("optional", "variadic"):
        while i + len(taken) < len(args) and not args[i + len(taken)].startswith("-"):
            taken.append(args[i + len(taken)])
            if kind == "optional":
                break
    return taken


def carried_args(args: list[str], opts: dict[str, str]) -> list[str]:
    out, i = [], 0
    while i < len(args):
        a = args[i]
        i += 1
        if a == "--":
            break
        if not a.startswith("-"):
            continue
        name = a.split("=", 1)[0]
        taken = option_values(args, i, "" if "=" in a else opts.get(name, ""))
        i += len(taken)
        if name not in SESSION_FLAGS:
            out += [a, *taken]
    return out


def exit_code(code: int) -> int:
    return code if code >= 0 else 128 - code


class Runner:
    def __init__(self) -> None:
        self.child: subprocess.Popen | None = None
        self.quit = False
        for s in (signal.SIGINT, signal.SIGQUIT):
            signal.signal(s, signal.SIG_IGN)
        for s in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(s, self.forward)

    def forward(self, sig: int, _frame: object) -> None:
        self.quit = True
        if self.child and self.child.poll() is None:
            self.child.send_signal(sig)

    def start(self, argv: list[str], env: dict) -> None:
        def restore() -> None:
            signal.signal(signal.SIGINT, signal.SIG_DFL)
            signal.signal(signal.SIGQUIT, signal.SIG_DFL)

        self.child = subprocess.Popen(argv, env=env, preexec_fn=restore)

    def limit_hit(self, flag: Path) -> dict | None:
        if self.quit or not flag.exists():
            return None
        data = read_json(flag)
        flag.unlink(missing_ok=True)
        return data if data.get("session_id") else None

    def wait(self, flag: Path, until: float | None = None) -> int | dict | None:
        pid = self.child.pid
        while True:
            try:
                got, status = os.waitpid(pid, os.WNOHANG | os.WUNTRACED)
            except ChildProcessError:
                return exit_code(self.child.returncode or 0)
            if got == pid:
                if os.WIFSTOPPED(status):
                    os.kill(os.getpid(), signal.SIGSTOP)
                    continue
                self.child.returncode = os.waitstatus_to_exitcode(status)
                return exit_code(self.child.returncode)
            if hit := self.limit_hit(flag):
                return hit
            if until is not None and time.time() >= until:
                return None
            time.sleep(0.5)

    def stop(self) -> None:
        self.child.send_signal(signal.SIGTERM)
        try:
            self.child.wait(STOP_WAIT_S)
        except subprocess.TimeoutExpired:
            self.child.kill()
            self.child.wait()
        subprocess.run(["stty", "sane"], check=False, stderr=subprocess.DEVNULL)


def plain(args: list[str]) -> None:
    os.execvp("claude", ["claude", *args])


def first_account(r: Rotation, args: list[str]) -> str | None:
    try:
        r.accounts = read_accounts(r.settings.accounts_file)
        r.dirs = r.accounts.usable
        if now() - load_cache(r.settings).get("updated", 0) > CACHE_MAX_AGE:
            print("claude-tools rotate: reading account usage…", file=sys.stderr, flush=True)
        data = locked_refresh(r.settings, [], CACHE_MAX_AGE)
        current = best(r.settings, by_name(data), r.names)
    except (OSError, ValueError, KeyError, TypeError, Failed) as e:
        r.say(f"could not pick an account ({e}); running plain claude")
        plain(args)
    if r.settings.pick:
        chosen = r.choose(current)
        if chosen == "":
            raise SystemExit(0)
        current = chosen or current
    if current is None:
        try:
            current = account_of(r.settings.config_dir, r.dirs, r.settings.home)
        except Failed:
            current = r.names[0] if r.names else ""
        r.say(f"every account is limited or unreadable; starting on {current}")
        time.sleep(1)
    return current


def supervise(r: Rotation, runner: Runner, current: str, flag: Path) -> tuple[str, str] | int:
    stop: Stop | None = None
    wake: float | None = None
    while True:
        got = runner.wait(flag, wake)
        if isinstance(got, int):
            return got
        if got is not None:
            stop = Stop.at_limit(got)
        try:
            nxt = r.after_limit(current, got) if got else next_account(r.settings, None)
        except Exception as e:
            r.log(f"session {stop.session}: no move, picking the next account failed: {e!r}")
            nxt = None
        if runner.child.poll() is not None:
            continue
        if stop.continued():
            r.log(f"session {stop.session}: a prompt went in after the limit; no move")
            stop = wake = None
            continue
        if nxt and not runner.quit:
            return stop.session, nxt
        wake = r.wake_time(stop.session)


def run(settings: Settings, args: list[str]) -> int:
    r = Rotation(settings)
    try:
        opts, cmds = parse_help(claude_help(settings.cache / "rotate"))
    except (OSError, subprocess.SubprocessError) as e:
        r.say(f"could not read claude --help ({e}); running plain claude, without account moves")
        plain(args)
    if not interactive(args, cmds):
        plain(args)
    current = first_account(r, args)
    rotate_id = str(os.getpid())
    base = {**os.environ, "CLAUDE_TOOLS_ROTATE_ID": rotate_id}
    settings.runtime.joinpath("rotate").mkdir(parents=True, exist_ok=True)
    runner = Runner()
    argv = ["claude", *args]
    while True:
        runner.start(argv, env_for(base, r.dirs.get(current, "")))
        moved = supervise(r, runner, current, settings.runtime / "rotate" / f"{rotate_id}-{runner.child.pid}.json")
        if isinstance(moved, int):
            return moved
        session, nxt = moved
        if nxt == current:
            r.say(f"the usage limit of {current} has reset; resuming session {session} on it")
            message = (f"The usage limit of your Claude account {current} has reset, so claude-tools rotate resumed "
                       "this session on it. Continue where you stopped.")
        else:
            r.say(f"{current} hit its usage limit; resuming session {session} on {nxt}")
            message = (f"Your Claude account {current} hit its usage limit, so claude-tools rotate resumed this "
                       f"session on the {nxt} account. Continue where you stopped.")
        runner.stop()
        args = carried_args(args, opts)
        argv = ["claude", *args, "--resume", session, message]
        current = nxt


def add_parser(sub: argparse._SubParsersAction) -> None:
    sub.add_parser("rotate", add_help=False,
                   help="run claude with the account picker; move a session to another account at a usage limit")
