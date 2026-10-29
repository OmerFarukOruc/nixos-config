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
from datetime import datetime
from pathlib import Path

from claude_tools.accounts import accounts
from claude_tools.agents import sessions
from claude_tools.limits import active, limited_until
from claude_tools.picker import CANCELLED, PICKED, Picker
from claude_tools.selection import startable
from claude_tools.settings import Settings
from claude_tools.store import append_event, read_json, write_json
from claude_tools.usage import entries, load_cache, run_refresh

CACHE_MAX_AGE = 900
REFRESH_TIMEOUT = 120
STOP_WAIT_S = 15
NON_INTERACTIVE = {"-p", "--print", "-v", "--version", "-h", "--help"}
SESSION_FLAGS = {"-r", "--resume", "-c", "--continue", "--session-id", "--fork-session", "--from-pr"}
OPTION_LINE = re.compile(r"^  ((?:--?[\w-]+, )*--?[\w-]+)(?: ([<\[])[^>\]]*?(\.\.\.)?[>\]])?")
COMMAND_LINE = re.compile(r"^  ([a-z][\w|-]*)")


class Rotation:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.state = settings.state / "rotate"
        self.dirs: dict[str, str] = {}

    @property
    def names(self) -> list[str]:
        return list(self.dirs)

    def log(self, msg: str) -> None:
        append_event(self.state / "events.log", msg)

    def say(self, msg: str) -> None:
        print(f"claude-tools rotate: {msg}", file=sys.stderr, flush=True)
        self.log(msg)

    def limits(self, now: float | None = None) -> dict:
        limits = read_json(self.state / "limits.json")
        return limits if now is None else active(limits, now)

    def usage(self, refresh: list[str] | None = None) -> dict[str, dict]:
        if not refresh and time.time() - load_cache(self.settings).get("updated", 0) > CACHE_MAX_AGE:
            print("claude-tools rotate: reading account usage…", file=sys.stderr, flush=True)
        try:
            run_refresh(refresh or [], None if refresh else CACHE_MAX_AGE, REFRESH_TIMEOUT)
        except subprocess.TimeoutExpired:
            self.log(f"the usage refresh took longer than {REFRESH_TIMEOUT} s; using the cache as it is")
        return entries(self.settings)

    def pick(self, skip: str | None, limits: dict, now: float) -> str | None:
        found = startable(self.settings, set(active(limits, now)), {skip} if skip else set())
        return found[0] if found else None

    def choose(self, recommend: str | None, limits: dict) -> str | None:
        cursor = recommend
        while True:
            by_dir = sessions(self.settings.home)
            live = {n: by_dir.get(d, 0) for n, d in self.dirs.items()}
            try:
                picker = Picker(self.dirs, load_cache(self.settings), live, set(active(limits, time.time())), cursor,
                                self.settings.color)
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
            self.usage(self.names)

    def next_account(self, current: str) -> str | None:
        now = time.time()
        until, reason = limited_until(self.usage([current]).get(current), now)
        limits = self.limits(now)
        limits[current] = {"until": until, "reason": reason}
        write_json(self.state / "limits.json", limits)
        self.usage()
        nxt = self.pick(current, limits, now)
        self.log(f"{current} hit a {reason}; next account: {nxt or 'none'}")
        return nxt

    def next_free(self, current: str, session: str) -> str | None:
        now = time.time()
        limits = self.limits(now)
        self.usage(self.names)
        nxt = self.pick(current, limits, now)
        self.log(f"session {session}: an account's limit ended; next account: {nxt or 'none'}")
        return nxt

    def next_reset(self, current: str, now: float) -> float | None:
        limits = self.limits()
        own = limits.get(current, {}).get("until", 0)
        ends = [v["until"] for n, v in limits.items() if n != current and n in self.dirs and now < v.get("until", 0) < own]
        return min(ends) if ends else None


def claude_help(cache: Path) -> str:
    real = Path(shutil.which("claude") or "claude").resolve()
    key = re.sub(r"[^\w.-]", "_", f"{real}-{int(real.stat().st_mtime)}")
    f = cache / f"help-{key}.txt"
    if not f.exists():
        text = subprocess.run(["claude", "--help"], capture_output=True, text=True, check=False).stdout
        if "Commands:" not in text:
            raise OSError("claude --help printed no command list")
        cache.mkdir(parents=True, exist_ok=True)
        for old in cache.glob("help-*.txt"):
            old.unlink(missing_ok=True)
        tmp = f.with_suffix(f".{os.getpid()}")
        tmp.write_text(text)
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


def resume_args(args: list[str], opts: dict[str, str], session: str, message: str) -> list[str]:
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
    return [*out, "--resume", session, message]


def env_for(base: dict, config_dir: str) -> dict:
    env = dict(base)
    env.pop("CLAUDE_CONFIG_DIR", None)
    if config_dir:
        env["CLAUDE_CONFIG_DIR"] = config_dir
    return env


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
        try:
            data = json.loads(flag.read_text())
        except (OSError, json.JSONDecodeError):
            data = {}
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
        r.dirs = accounts()
        limits = r.limits()
        r.usage()
        current = r.pick(None, limits, time.time())
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as e:
        r.say(f"could not pick an account ({e}); running plain claude")
        plain(args)
    if r.settings.pick:
        chosen = r.choose(current, limits)
        if chosen == "":
            raise SystemExit(0)
        current = chosen or current
    if current is None:
        current = next((n for n, d in r.dirs.items() if d == r.settings.config_dir), r.names[0] if r.names else "")
        r.say(f"every account is limited or unreadable; starting on {current}")
        time.sleep(1)
    return current


def supervise(r: Rotation, runner: Runner, current: str, flag: Path) -> tuple[str, str] | int:
    waiting: tuple[str, float] | None = None
    while True:
        got = runner.wait(flag, waiting[1] if waiting else None)
        if isinstance(got, int):
            return got
        session = waiting[0] if got is None else got["session_id"]
        try:
            nxt = r.next_free(current, session) if got is None else r.next_account(current)
        except Exception as e:
            r.log(f"session {session}: no move, picking the next account failed: {e!r}")
            nxt = None
        if nxt and not runner.quit:
            return session, nxt
        try:
            wake = r.next_reset(current, time.time())
        except Exception as e:
            r.log(f"session {session}: no wait for another account, reading limits.json failed: {e!r}")
            wake = None
        waiting = (session, wake) if wake else None
        if wake:
            r.log(f"session {session}: no account is free; picking again at "
                  f"{datetime.fromtimestamp(wake).astimezone().isoformat(timespec='seconds')}")


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
        r.say(f"{current} hit its usage limit; resuming session {session} on {nxt}")
        runner.stop()
        message = (f"Your Claude account {current} hit its usage limit, so claude-tools rotate resumed this session "
                   f"on the {nxt} account. Continue where you stopped.")
        argv = ["claude", *resume_args(args, opts, session, message)]
        args = argv[1:-3]
        current = nxt


def add_parser(sub: argparse._SubParsersAction) -> None:
    sub.add_parser("rotate", add_help=False,
                   help="run claude with the account picker; move a session to another account at a usage limit")
