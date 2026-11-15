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
PROBE_FIRST_WAIT_MS = 3000
PROBE_LONGEST_WAIT_MS = 30000
FREED_WAIT_S = 30
PROMPT_WAIT_S = 60
SUBMIT_WAIT_MS = 5000
SUBMIT_UNTIL = ("--until", "working", "--until", "blocked")
COMPOSER_RULE = "─"
TRUST_QUESTION = "Yes, I trust this folder"
EXIT_DIALOG = "❯ 1. Exit and stop tasks"


def environ(p: Path) -> dict[str, str]:
    return dict(x.split("=", 1) for x in (p / "environ").read_bytes().decode().split("\0") if "=" in x)


def processes(comms: tuple[str, ...]) -> Iterator[tuple[Path, dict[str, str]]]:
    for p in Path("/proc").iterdir():
        try:
            if not p.name.isdigit() or (p / "comm").read_text().strip() not in comms:
                continue
            env = environ(p)
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

    def in_pane(self, comms: tuple[str, ...], pane: str) -> Iterator[Path]:
        info = self.herdr("pane", "process-info", "--pane", pane)["result"]["process_info"]
        for proc in info.get("foreground_processes") or []:
            if proc.get("name") in comms:
                yield Path(f"/proc/{proc['pid']}")

    def claude_pid(self, pane: str) -> int:
        for p in self.in_pane(CLAUDE, pane):
            return int(p.name)
        raise NoProcess(f"no claude process in pane {pane}")

    def claude_process(self, pane: str) -> tuple[int, list[str], str]:
        for p in self.in_pane(CLAUDE, pane):
            try:
                env = environ(p)
                argv = (p / "cmdline").read_bytes().decode().split("\0")[:-1]
            except OSError:
                continue
            return int(p.name), argv, env.get("CLAUDE_CONFIG_DIR", "")
        raise NoProcess(f"no claude process in pane {pane}")

    def codex_process(self, pane: str) -> int:
        for p in self.in_pane(CODEX, pane):
            return int(p.name)
        raise NoProcess(f"no claude or codex process in pane {pane}")

    def exit_claude(self, name: str, pid: int) -> None:
        h = self.herdr
        h("agent", "send-keys", name, "esc", check=False)
        time.sleep(1)
        h("agent", "send-keys", name, "ctrl+c", check=False)
        time.sleep(0.5)
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
            self.claude_pid(data["result"]["agent"]["pane_id"])
        except Failed:
            self.wait_freed(name)
            return False
        return True

    def wait_shell_ready(self, pane: str) -> None:
        seed = int.from_bytes(os.urandom(4), "big")
        answer = f"shell-ready-{seed + 1}"
        probe = f"echo shell-ready-$(({seed}+1))"
        deadline = time.time() + READY_WAIT_S
        wait_ms = PROBE_FIRST_WAIT_MS
        while (left_ms := int((deadline - time.time()) * 1000)) > 0:
            if next(self.in_pane(CLAUDE, pane), None):
                raise Failed(f"a claude already runs in pane {pane}")
            self.herdr("pane", "run", pane, probe)
            try:
                self.herdr("pane", "wait-output", pane, "--match", answer, "--timeout", str(min(wait_ms, left_ms)))
                return
            except HerdrError as e:
                if e.code != "timeout":
                    raise
            wait_ms = min(wait_ms * 2, PROBE_LONGEST_WAIT_MS)
        raise Failed(f"the shell in pane {pane} ran no typed command in {READY_WAIT_S} s")

    def answer_trust(self, name: str, screen: str) -> bool:
        if TRUST_QUESTION not in screen:
            return False
        self.herdr("agent", "send-keys", name, "down", "enter")
        return True

    def blocked_at_startup(self, name: str, screen: str) -> Failed:
        return Failed(f"{name} is blocked at startup by something other than the folder trust question; "
                      f"its screen ended: {screen[-400:]}")

    def composer_text(self, name: str) -> str:
        screen = self.herdr.screen(name)
        rules = [i for i, line in enumerate(screen.splitlines()) if line.startswith(COMPOSER_RULE)]
        if len(rules) < 2:
            raise Failed(f"could not find the input box of {name} on its screen: {screen[-400:]}")
        return "".join(screen.splitlines()[rules[-2] + 1:rules[-1]])

    def press_enter_until_taken(self, name: str, text: str) -> None:
        wanted = "".join(text.split())
        deadline = time.time() + PROMPT_WAIT_S
        while time.time() < deadline:
            status = self.herdr("agent", "get", name)["result"]["agent"]["agent_status"]
            if status not in ("idle", "done") or wanted not in "".join(self.composer_text(name).split()):
                return
            self.herdr("agent", "send-keys", name, "enter")
            self.log(f"pressed Enter again for {name}, whose input box kept the prompt")
            try:
                self.herdr("agent", "wait", name, *SUBMIT_UNTIL, "--timeout", str(SUBMIT_WAIT_MS))
                return
            except HerdrError as e:
                if e.code != "timeout":
                    raise
        raise Failed(f"{name} kept the prompt in its input box for {PROMPT_WAIT_S} s")

    def prompt_when_ready(self, name: str, text: str) -> None:
        deadline = time.time() + PROMPT_WAIT_S
        while True:
            try:
                self.herdr("agent", "prompt", name, text, "--wait", *SUBMIT_UNTIL, "--timeout", str(SUBMIT_WAIT_MS))
                return
            except HerdrError as e:
                if e.code == "timeout":
                    break
                if e.code not in ("agent_not_ready", "agent_blocked"):
                    raise
                code = e.code
            screen = self.herdr.screen(name)
            if time.time() >= deadline:
                raise Failed(f"{name} stayed blocked at startup for {PROMPT_WAIT_S} s; "
                             f"its screen ended: {screen[-400:]}")
            answered = self.answer_trust(name, screen)
            if code == "agent_blocked" and not answered:
                raise self.blocked_at_startup(name, screen)
            time.sleep(1)
        self.press_enter_until_taken(name, text)

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
            screen = h.screen(name)
            if not self.answer_trust(name, screen):
                raise self.blocked_at_startup(name, screen)
            h("agent", "wait", name, "--until", "idle", "--timeout", "60000")
            return
