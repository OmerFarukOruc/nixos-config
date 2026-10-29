from __future__ import annotations

import os
import shlex
import time
from collections.abc import Callable, Iterator
from pathlib import Path

from claude_tools.accounts import normalize
from claude_tools.errors import Failed, HerdrError, NoProcess
from claude_tools.herdr import Herdr
from claude_tools.settings import Settings
from claude_tools.store import append_event

CLAUDE = ("claude", ".claude-wrapped")
CODEX = ("codex", ".codex-wrapped")
SKIP_PERMISSIONS = "--dangerously-skip-permissions"
READY_WAIT_S = 180
FREED_WAIT_S = 30
EXIT_DIALOG = "❯ 1. Exit and stop tasks"


def processes(comms: tuple[str, ...]) -> Iterator[tuple[Path, dict[str, str]]]:
    for p in Path("/proc").iterdir():
        try:
            if not p.name.isdigit() or (p / "comm").read_text().strip() not in comms:
                continue
            env = dict(x.split("=", 1) for x in (p / "environ").read_bytes().decode().split("\0") if "=" in x)
        except OSError:
            continue
        yield p, env


def sessions(home: Path) -> dict[str, int]:
    count: dict[str, int] = {}
    for p, env in processes(CLAUDE):
        try:
            if not os.readlink(p / "fd/0").startswith("/dev/pts/"):
                continue
        except OSError:
            continue
        d = normalize(env.get("CLAUDE_CONFIG_DIR", ""), home)
        count[d] = count.get(d, 0) + 1
    return count


def gone(pid: int, seconds: float) -> bool:
    deadline = time.time() + seconds
    while time.time() < deadline:
        if not Path(f"/proc/{pid}").exists():
            return True
        time.sleep(0.5)
    return False


def event_log(settings: Settings) -> Callable[[str], None]:
    events = settings.state / "limit-switch" / "events.log"

    def log(msg: str) -> None:
        print(append_event(events, msg), flush=True)

    return log


class Agents:
    def __init__(self, settings: Settings):
        self.herdr = Herdr(settings)
        self.log = event_log(settings)

    def in_pane(self, comms: tuple[str, ...], pane: str) -> Iterator[tuple[Path, dict[str, str]]]:
        for p, env in processes(comms):
            if env.get("HERDR_PANE_ID") == pane and env.get("HERDR_SOCKET_PATH") == self.herdr.socket:
                yield p, env

    def claude_process(self, pane: str) -> tuple[int, list[str], str]:
        for p, env in self.in_pane(CLAUDE, pane):
            try:
                argv = (p / "cmdline").read_bytes().decode().split("\0")[:-1]
            except OSError:
                continue
            return int(p.name), argv, env.get("CLAUDE_CONFIG_DIR", "")
        raise NoProcess(f"no claude process in pane {pane}")

    def codex_process(self, pane: str) -> int:
        for p, _ in self.in_pane(CODEX, pane):
            return int(p.name)
        raise NoProcess(f"no claude or codex process in pane {pane}")

    def exit_claude(self, name: str, pid: int) -> None:
        h = self.herdr
        h("agent", "send-keys", name, "esc", check=False)
        time.sleep(1)
        h("agent", "prompt", name, "/exit", check=False)
        deadline = time.time() + 10
        while not gone(pid, 1) and time.time() < deadline:
            if EXIT_DIALOG in h.screen(name):
                h("agent", "send-keys", name, "enter", check=False)
                self.log(f"answered the background-work dialog of {name} with Exit and stop tasks")
                break
        if not gone(pid, 30):
            h("agent", "send-keys", name, "ctrl+c", check=False)
            time.sleep(0.5)
            h("agent", "send-keys", name, "ctrl+c", check=False)
            if not gone(pid, 15):
                raise Failed(f"claude pid {pid} of {name} did not exit")
        self.wait_freed(name)

    def exit_codex(self, name: str, pid: int) -> None:
        for _ in range(3):
            self.herdr("agent", "send-keys", name, "ctrl+c", check=False)
            if gone(pid, 3):
                self.wait_freed(name)
                return
        raise Failed(f"codex pid {pid} of {name} did not exit")

    def wait_freed(self, name: str) -> None:
        deadline = time.time() + FREED_WAIT_S
        while time.time() < deadline:
            if self.herdr("agent", "get", name, check=False).get("error", {}).get("code") == "agent_not_found":
                return
            time.sleep(0.5)
        raise Failed(f"herdr still lists {name} {FREED_WAIT_S} s after its claude exited")

    def running(self, name: str) -> bool:
        data = self.herdr("agent", "get", name, check=False)
        if "result" not in data:
            return False
        try:
            self.claude_process(data["result"]["agent"]["pane_id"])
        except Failed:
            self.wait_freed(name)
            return False
        return True

    def wait_shell_ready(self, pane: str) -> None:
        deadline = time.time() + READY_WAIT_S
        while time.time() < deadline:
            if next(self.in_pane(CLAUDE, pane), None):
                raise Failed(f"a claude already runs in pane {pane}")
            n = int.from_bytes(os.urandom(4), "big")
            self.herdr("pane", "run", pane, f"echo shell-ready-$(({n}+1))")
            if "result" in self.herdr("pane", "wait-output", pane, "--match", f"shell-ready-{n + 1}",
                                      "--timeout", "3000", check=False):
                return
        raise Failed(f"the shell in pane {pane} ran no typed command in {READY_WAIT_S} s")

    def start_claude(self, pane: str, name: str, config_dir: str, args: list[str]) -> None:
        h = self.herdr
        self.wait_shell_ready(pane)
        env = "export CLAUDE_TOOLS_PLAIN=1; " + (
            f"export CLAUDE_CONFIG_DIR={shlex.quote(config_dir)}" if config_dir else "unset CLAUDE_CONFIG_DIR"
        )
        h("pane", "run", pane, env)
        deadline = time.time() + 60
        while True:
            try:
                h("agent", "start", name, "--kind", "claude", "--pane", pane, "--timeout", "120000", "--", *args)
                return
            except HerdrError as e:
                if e.code == "agent_pane_busy" and time.time() < deadline:
                    time.sleep(1)
                    continue
                if e.code != "agent_not_ready":
                    raise
            if "Yes, I trust this folder" not in h.screen(name):
                raise Failed(f"{name} is blocked at startup by something other than the folder trust question")
            h("agent", "send-keys", name, "down")
            h("agent", "send-keys", name, "enter")
            h("agent", "wait", name, "--until", "idle", "--timeout", "60000")
            return
