from __future__ import annotations

import json
import os
import shlex
import subprocess
import tempfile
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
OPENCODE = ("opencode", ".opencode2-wrap")
KINDS = {"claude": CLAUDE, "codex": CODEX, "opencode": OPENCODE}
OPENCODE_AGENT_FIELDS = ("mode", "model", "permissions", "system")
OPENCODE_CONFIG_VARS = (
    "OPENCODE_CONFIG", "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG_CONTENT", "OPENCODE_CONFIG_PROJECT_DISABLE",
)
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


def opencode_env(agent: str) -> dict[str, str]:
    env = {k: os.environ[k] for k in OPENCODE_CONFIG_VARS if k in os.environ}
    env["OPENCODE_CONFIG_CONTENT"] = json.dumps({"default_agent": agent})
    return env


def opencode(folder: Path, agent: str, *args: str) -> str:
    env = {k: v for k, v in os.environ.items() if k not in OPENCODE_CONFIG_VARS} | opencode_env(agent)
    try:
        run = subprocess.run(["opencode", *args, "--standalone"], cwd=folder, env=env, capture_output=True, text=True,
                             timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Failed(f"opencode {' '.join(args)} could not run in {folder}: {e}") from e
    if run.returncode != 0:
        raise Failed(f"opencode {' '.join(args)} exited {run.returncode} in {folder}: {run.stderr[-400:]}")
    return run.stdout


def opencode_agents(folder: Path, agent: str) -> dict[str, dict]:
    out = opencode(folder, agent, "debug", "agents")
    try:
        return {a["id"]: a for a in json.loads(out)}
    except (ValueError, KeyError, TypeError) as e:
        raise Failed(f"opencode debug agents printed no agent list in {folder}: {out[:200]}") from e


def check_opencode_agent(cwd: Path, agent: str) -> None:
    with tempfile.TemporaryDirectory() as empty:
        defined = opencode_agents(Path(empty), agent).get(agent)
    if defined is None:
        raise Failed(f"opencode has no global agent {agent}; `opencode debug agents` lists the agents")
    effective = opencode_agents(cwd, agent).get(agent) or {}
    changed = [f for f in OPENCODE_AGENT_FIELDS if effective.get(f) != defined.get(f)]
    if changed:
        raise Failed(f"the opencode config of {cwd} changes the {', '.join(changed)} of agent {agent}, "
                     "so it would not run as its global file defines it")
    model = defined.get("model")
    if not model:
        raise Failed(f"the opencode agent {agent} sets no model, so it would run on whichever model opencode picks")
    name = f"{model.get('providerID')}/{model.get('id')}"
    if name not in opencode(cwd, agent, "models").splitlines():
        raise Failed(f"`opencode models` in {cwd} does not list {name}, the model of agent {agent}, "
                     "and opencode would run the agent on another model")


def event_log(settings: Settings) -> Callable[[str], None]:
    events = settings.state / "limit-switch" / "events.log"

    def log(msg: str) -> None:
        print(append_event(events, msg), flush=True)

    return log


class Agents:
    def __init__(self, settings: Settings):
        self.herdr = Herdr(settings)
        self.log = event_log(settings)

    def foreground(self, pane: str) -> list[dict]:
        info = self.herdr("pane", "process-info", "--pane", pane)["result"]["process_info"]
        return info.get("foreground_processes") or []

    def in_pane(self, comms: tuple[str, ...], pane: str) -> Iterator[Path]:
        for proc in self.foreground(pane):
            if proc.get("name") in comms:
                yield Path(f"/proc/{proc['pid']}")

    def process(self, kind: str, pane: str) -> tuple[int, list[str], dict[str, str]]:
        for p in self.in_pane(KINDS[kind], pane):
            try:
                env = environ(p)
                argv = (p / "cmdline").read_bytes().decode().split("\0")[:-1]
            except OSError:
                continue
            return int(p.name), argv, env
        raise NoProcess(f"no {kind} process in pane {pane}")

    def claude_process(self, pane: str) -> tuple[int, list[str], str]:
        pid, argv, env = self.process("claude", pane)
        return pid, argv, env.get("CLAUDE_CONFIG_DIR", "")

    def agent_process(self, pane: str) -> tuple[str, int]:
        procs = self.foreground(pane)
        for kind, comms in KINDS.items():
            for proc in procs:
                if proc.get("name") in comms:
                    return kind, int(proc["pid"])
        raise NoProcess(f"no {', '.join(KINDS)} process in pane {pane}")

    def end(self, name: str, pane: str) -> None:
        kind, pid = self.agent_process(pane)
        if kind == "claude":
            self.exit_claude(name, pid)
        else:
            self.exit_by_ctrl_c(name, kind, pid)

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

    def exit_by_ctrl_c(self, name: str, kind: str, pid: int) -> None:
        for _ in range(3):
            self.herdr("agent", "send-keys", name, "ctrl+c", check=False)
            if gone(pid, 3):
                self.wait_freed(name)
                return
        raise Failed(f"{kind} pid {pid} of {name} did not exit")

    def wait_freed(self, name: str) -> None:
        deadline = time.time() + FREED_WAIT_S
        while time.time() < deadline:
            if self.herdr("agent", "get", name, check=False).get("error", {}).get("code") == "agent_not_found":
                return
            time.sleep(0.5)
        raise Failed(f"herdr still lists {name} {FREED_WAIT_S} s after its process exited")

    def running(self, name: str) -> bool:
        data = self.herdr("agent", "get", name, check=False)
        if "result" not in data:
            return False
        try:
            self.agent_process(data["result"]["agent"]["pane_id"])
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
            if next(self.in_pane(CLAUDE + CODEX + OPENCODE, pane), None):
                raise Failed(f"an agent already runs in pane {pane}")
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
        return Failed(f"{name} is blocked at startup by something other than Claude's folder trust question; "
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

    def prompt_until_turn(self, name: str, text: str) -> None:
        deadline = time.time() + PROMPT_WAIT_S
        try:
            self.herdr("agent", "prompt", name, text, "--wait", *SUBMIT_UNTIL, "--timeout", str(PROMPT_WAIT_S * 1000))
            return
        except HerdrError as e:
            if e.code != "agent_prompt_stalled":
                raise self.no_turn(name, e) from e
        try:
            left_ms = max(1, int((deadline - time.time()) * 1000))
            self.herdr("agent", "wait", name, *SUBMIT_UNTIL, "--timeout", str(left_ms))
        except HerdrError as e:
            raise self.no_turn(name, e) from e

    def no_turn(self, name: str, e: HerdrError) -> Failed:
        return Failed(f"{name} did not start a turn on its brief within {PROMPT_WAIT_S} s ({e.code}); "
                      f"its screen ended: {self.herdr.screen(name)[-400:]}")

    def start_claude(self, pane: str, name: str, config_dir: str, args: list[str]) -> None:
        env = "export CLAUDE_TOOLS_PLAIN=1; " + (
            f"export CLAUDE_CONFIG_DIR={shlex.quote(config_dir)}" if config_dir else "unset CLAUDE_CONFIG_DIR"
        )
        self.start_in_pane(pane, name, "claude", env, args)

    def start_rotated(self, pane: str, name: str, account: str, args: list[str]) -> None:
        env = f"unset CLAUDE_CONFIG_DIR CLAUDE_TOOLS_PLAIN; export CLAUDE_TOOLS_START_ACCOUNT={shlex.quote(account)}"
        self.start_in_pane(pane, name, "claude", env, args)

    def start_opencode(self, pane: str, name: str, agent: str, args: tuple[str, ...] = ()) -> None:
        env = " ".join(["unset", *OPENCODE_CONFIG_VARS, ";", "export",
                        *(f"{k}={shlex.quote(v)}" for k, v in opencode_env(agent).items())])
        self.start_in_pane(pane, name, "opencode", env, ["--standalone", *args])

    def start_codex(self, pane: str, name: str, args: list[str]) -> None:
        self.start_in_pane(pane, name, "codex", ":", args)

    def start_in_pane(self, pane: str, name: str, kind: str, env: str, args: list[str]) -> None:
        h = self.herdr
        self.wait_shell_ready(pane)
        h("pane", "run", pane, env)
        deadline = time.time() + 60
        while True:
            try:
                h("agent", "start", name, "--kind", kind, "--pane", pane, "--timeout", "120000", "--", *args)
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
