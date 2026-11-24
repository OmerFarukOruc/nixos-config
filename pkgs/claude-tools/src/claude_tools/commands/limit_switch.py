from __future__ import annotations

import argparse
import re
import socket
import subprocess
import time
from dataclasses import asdict, dataclass, field, fields, replace
from datetime import datetime
from pathlib import Path

from claude_tools.accounts import ROTATE_ID, account_of, read_accounts
from claude_tools.agents import KINDS, SKIP_PERMISSIONS, UNNAMED, Agents, opencode_agent_of, opencode_config
from claude_tools.commands.rotate import carried_args, claude_help, help_text, parse_help, parsed_flags
from claude_tools.errors import Failed
from claude_tools.herdr import session_of
from claude_tools.limits import last_model, recorded_limit
from claude_tools.selection import hold_limit, next_account
from claude_tools.settings import Settings
from claude_tools.store import locked, read_json, write_json

COOLDOWN = 300
ENDED_KEEP = 30 * 86400
BOOT_ID = Path("/proc/sys/kernel/random/boot_id")
CODEX_OPTION_LINE = re.compile(r"^\s+((?:-\w, )?--[\w-]+)(?: ([<\[])[^>\]]*?(\.\.\.)?[>\]])?")
CODEX_SELECTORS = {"--last", "--all"}
OPENCODE_SELECTORS = ("--session", "-s", "--prompt")
OPENCODE_CONTINUE = ("--continue", "-c")


OWN_PERMISSIONS = {"--settings", "--permission-mode"}
ALLOWS_BYPASS = "--allow-dangerously-skip-permissions"


@dataclass(frozen=True)
class Record:
    pane: str
    workspace: str | None
    cwd: str
    session: str
    args: list[str]
    kind: str = "claude"
    named: bool = True
    config_dir: str = ""
    rotate: bool = False
    model: str | None = None
    opencode_config: dict[str, str] = field(default_factory=dict)
    codex_home: str = ""
    ended_at: float | None = None

    @classmethod
    def parse(cls, name: str, data: dict) -> Record:
        known = {f.name for f in fields(cls)}
        try:
            return cls(**{k: v for k, v in data.items() if k in known})
        except TypeError as e:
            raise Failed(f"the record of {name} in agents.json is incomplete: {e}") from e

    def json(self) -> dict:
        return {k: v for k, v in asdict(self).items() if not (k == "ended_at" and v is None)}


@dataclass(frozen=True)
class State:
    server: str | None = None
    boot: str = ""
    agents: dict[str, Record] = field(default_factory=dict)
    ended: dict[str, Record] = field(default_factory=dict)

    @classmethod
    def parse(cls, data: dict) -> State:
        return cls(data.get("server"), data.get("boot", ""),
                   {n: Record.parse(n, r) for n, r in data.get("agents", {}).items()},
                   {n: Record.parse(n, r) for n, r in data.get("ended", {}).items()})

    def json(self) -> dict:
        return {"server": self.server, "boot": self.boot, "agents": {n: r.json() for n, r in self.agents.items()},
                "ended": {n: r.json() for n, r in self.ended.items()}}


@dataclass(frozen=True)
class Try:
    at: float
    started: bool


class PromptFailed(Failed):
    pass


def own_permissions(argv: list[str], opts: dict[str, str]) -> bool:
    names = {name for name, _ in parsed_flags(argv, opts)}
    return bool(names & OWN_PERMISSIONS) and ALLOWS_BYPASS not in names


def drop_flags(argv: list[str], valued: tuple[str, ...], bare: tuple[str, ...]) -> list[str]:
    out, skip = [], False
    for a in argv:
        if skip:
            skip = False
        elif a in valued:
            skip = True
        elif a not in bare and a.split("=", 1)[0] not in valued:
            out.append(a)
    return out


def with_model(argv: list[str], model: str | None, opts: dict[str, str]) -> list[str]:
    given = [tokens[1] if len(tokens) > 1 else tokens[0].split("=", 1)[-1]
             for name, tokens in parsed_flags(argv, opts) if name == "--model"]
    if not model or (given and given[-1].split("[", 1)[0] in model):
        return argv
    kept = [t for name, tokens in parsed_flags(argv, opts) if name != "--model" for t in tokens]
    return [*kept, "--model", model]


def resume_args(argv: list[str], session: str, opts: dict[str, str], model: str | None = None,
                bypass: bool = True) -> list[str]:
    out = carried_args(argv, opts) if opts else drop_flags(argv, ("--resume", "-r"), ("--continue", "-c"))
    out = with_model(out, model, opts) if opts else out
    add = bypass and SKIP_PERMISSIONS not in out and not own_permissions(out, opts)
    return [*([SKIP_PERMISSIONS] if add else []), *out, "--resume", session]


def codex_args(argv: list[str], session: str, opts: dict[str, str]) -> list[str]:
    kept = [t for name, tokens in parsed_flags(argv, opts) if name not in CODEX_SELECTORS for t in tokens]
    return ["resume", session, *kept]


def opencode_args(argv: list[str], session: str) -> list[str]:
    return [*drop_flags(argv, OPENCODE_SELECTORS, OPENCODE_CONTINUE), "--session", session]


def key_of(agent: dict) -> str | None:
    pane = agent.get("pane_id")
    return agent.get("name") or (UNNAMED + pane.replace(":", "-").lower() if pane else None)


def running_as(name: str, r: Record, live: list[dict]) -> dict | None:
    return next((a for a in live if session_of(a) == r.session or (r.named and a.get("name") == name)), None)


def free_name(name: str, live: list[dict]) -> str:
    taken = {a.get("name") for a in live}
    while name in taken:
        name += "-r"
    return name


def boot_id() -> str:
    try:
        return BOOT_ID.read_text().strip()
    except OSError:
        return ""


def restart_reason(state: State) -> str:
    booted = state.boot and state.boot != boot_id()
    return f"{socket.gethostname()} rebooted" if booted else "The herdr server restarted"


def resume_message(r: Record, why: str, moved: bool) -> str:
    claude = r.kind == "claude"
    lost = "background shell tasks, Monitors, subagents and self-paced loops" if claude else \
        "background shell commands"
    where = "in a new workspace, because its pane was gone or held another agent" if moved else "in the same pane"
    how = "on the same account with the same flags and model" if claude else "with the same flags"
    loops = "A fixed-interval /loop comes back, so run CronList before you start one again. " if claude else ""
    return (f"{why}, so every process this session started has ended: {lost}. This session was resumed {where} "
            f"{how}. {loops}Before you run a command again that was running when the session stopped, check what "
            "it already did, such as whether a `git worktree add` already made its folder. If your last turn had "
            "finished and you were waiting for Omer, stay idle. Otherwise continue where you stopped, and start "
            "again the background work you still need.")


def next_state(state: State, agents: dict[str, Record], server: str, failed: list[str], now: float) -> State:
    for n in failed:
        agents.setdefault(n, state.agents[n])
    ended = {n: r if r.ended_at else replace(r, ended_at=now) for n, r in state.ended.items()
             if n not in agents and (r.ended_at or now) > now - ENDED_KEEP}
    ended.update({n: replace(r, ended_at=now) for n, r in state.agents.items() if n not in agents})
    pending = bool(failed)
    return State(state.server if pending else server, state.boot if pending else boot_id(), agents, ended)


def recorded(state: State, name: str) -> Record:
    found = state.agents.get(name) or state.ended.get(name)
    if found is None:
        known = sorted({*state.agents, *state.ended})
        raise Failed(f"no record of {name}; recorded: {', '.join(known) or 'none'}")
    return found


def at(t: float | None) -> str:
    return datetime.fromtimestamp(t).astimezone().strftime("%a %H:%M") if t else "unknown"


class Switcher:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.state = settings.state / "limit-switch"
        self.agents = Agents(settings)
        self.herdr = self.agents.herdr
        self.log = self.agents.log

    def load(self, name: str) -> dict:
        return read_json(self.state / name)

    def save(self, name: str, data: dict) -> None:
        if data != self.load(name):
            write_json(self.state / name, data)

    def load_state(self) -> State:
        return State.parse(self.load("agents.json"))

    def load_tries(self) -> dict[str, Try]:
        return {n: Try(**t) for n, t in self.load("restore-failed.json").items() if isinstance(t, dict)}

    def save_tries(self, tries: dict[str, Try]) -> None:
        self.save("restore-failed.json", {n: asdict(t) for n, t in tries.items()})

    def resume_message(self, name: str, default: str) -> str:
        msg_file = self.settings.config / "resume" / name
        return msg_file.read_text().strip() if msg_file.is_file() else default

    def resume_args(self, argv: list[str], session: str, model: str | None = None, bypass: bool = True) -> list[str]:
        try:
            opts, _ = parse_help(claude_help(self.settings.cache / "rotate"))
        except OSError:
            opts = {}
        return resume_args(argv, session, opts, model, bypass)

    def codex_args(self, argv: list[str], session: str) -> list[str]:
        try:
            text = help_text(self.settings.cache / "rotate", ["codex", "resume", "--help"], "Options:")
        except OSError as e:
            raise Failed(f"could not read codex resume --help, so the recorded codex options cannot be parsed: {e}") \
                from e
        return codex_args(argv, session, parse_help(text, CODEX_OPTION_LINE)[0])

    def switch(self, name: str, to: str | None, after_limit: bool = False) -> bool:
        agent = self.herdr("agent", "get", name)["result"]["agent"]
        if agent.get("agent") != "claude" or agent.get("agent_status") == "working":
            what = f"{agent['agent']} and {agent.get('agent_status')}" if agent.get("agent") else "no running agent"
            raise Failed(f"{name} is {what}; only an idle Claude agent can move")
        session = session_of(agent)
        if not session:
            raise Failed(f"herdr knows no session id for {name}; is the claude integration installed?")
        pane = agent["pane_id"]
        pid, argv, config_dir = self.agents.claude_process(pane)
        found = read_accounts(self.settings.accounts_file)
        dirs = found.usable
        current = account_of(config_dir, found.local, self.settings.home)
        if to is None:
            try:
                to = next_account(self.settings, None if after_limit else current)
            except (OSError, subprocess.SubprocessError, ValueError) as e:
                raise Failed(f"could not pick the next account: {e!r}") from e
            if to is None:
                self.log(f"{name}: every other account is limited or unreadable; {name} stays on {current}")
                return False
            if to == current:
                self.herdr("agent", "prompt", name, self.resume_message(name, (
                    f"The usage limit of your Claude account {current} has reset. Continue where you stopped.")))
                self.log(f"{name}: the limit of {current} has reset; told it to continue, session {session}")
                return True
        elif to not in dirs:
            raise Failed(f"unknown account {to}")
        self.agents.exit_claude(name, pid)
        try:
            self.agents.start_claude(pane, name, dirs[to], self.resume_args(argv[1:], session))
        except Failed as e:
            self.log(f"{name}: start on {to} failed ({e}); starting it on {current} again")
            self.agents.start_claude(pane, name, found.local[current], self.resume_args(argv[1:], session))
            raise
        self.agents.prompt_when_ready(name, self.resume_message(name, (
            f"Your Claude account {current} hit its usage limit, so this session now runs on the {to} account. "
            "Continue where you stopped.")))
        self.log(f"{name}: moved from {current} to {to}, session {session}")
        return True

    def start_kind(self, pane: str, name: str, r: Record) -> None:
        if r.kind == "codex":
            self.agents.start_codex(pane, name, r.codex_home, self.codex_args(r.args, r.session))
        elif r.kind == "opencode":
            self.agents.start_opencode(pane, name, opencode_agent_of(r.opencode_config),
                                       opencode_args(r.args, r.session), r.opencode_config)
        elif r.rotate:
            found = read_accounts(self.settings.accounts_file)
            account = account_of(r.config_dir, found.local, self.settings.home)
            self.agents.start_rotated(pane, name, account, self.resume_args(r.args, r.session, r.model, r.named))
        else:
            self.agents.start_claude(pane, name, r.config_dir, self.resume_args(r.args, r.session, r.model, r.named))

    def finish_restore(self, name: str, r: Record, pane: str, temporary: str | None, why: str, moved: bool) -> None:
        text = self.resume_message(name, resume_message(r, why, moved))
        try:
            if temporary:
                self.herdr("agent", "rename", temporary, "--clear")
            if r.kind == "claude":
                self.agents.prompt_when_ready(pane, text)
            else:
                self.agents.prompt_until_turn(pane, text)
        except Failed as e:
            raise PromptFailed(f"started, but the resume message did not arrive: {e}") from e

    def start_recorded(self, name: str, r: Record, why: str, live: list[dict]) -> str:
        panes = {x["pane_id"]: x for x in self.herdr("pane", "list")["result"]["panes"]}
        pane, workspace = r.pane, None
        if pane not in panes or panes[pane].get("agent"):
            ws = self.herdr("workspace", "create", "--cwd", r.cwd, "--label", r.workspace or name, "--no-focus")
            pane, workspace = ws["result"]["root_pane"]["pane_id"], ws["result"]["workspace"]["workspace_id"]
        start_as = name if r.named else free_name(name, live)
        try:
            self.start_kind(pane, start_as, r)
        except Failed:
            if "result" in self.herdr("agent", "get", start_as, check=False):
                try:
                    self.agents.end(start_as, pane)
                except Failed as e:
                    self.log(f"{name}: could not stop {start_as} after the failed start: {e}")
            if workspace:
                try:
                    self.herdr("workspace", "close", workspace)
                except Failed as e:
                    self.log(f"{name}: could not close workspace {workspace} after the failed start: {e}")
            raise
        self.finish_restore(name, r, pane, None if r.named else start_as, why, workspace is not None)
        return pane

    def restore(self, state: State, server: str, wait: bool = True) -> list[str]:
        if not server or not state.agents or state.server == server:
            return []
        failed, tries, live = [], self.load_tries(), self.herdr.agents()
        why = restart_reason(state)
        for n, r in state.agents.items():
            agent, last = running_as(n, r, live), tries.get(n)
            if agent and not (last and last.started):
                tries.pop(n, None)
                continue
            if wait and last and last.at > time.time() - COOLDOWN:
                failed.append(n)
                continue
            try:
                if agent:
                    temporary = None if r.named else agent.get("name")
                    self.finish_restore(n, r, agent["pane_id"], temporary, why, agent["pane_id"] != r.pane)
                    self.log(f"{n}: sent the resume message again in pane {agent['pane_id']}, session {r.session}")
                else:
                    pane = self.start_recorded(n, r, why, live)
                    self.log(f"{n}: restored in pane {pane} after a herdr server restart, session {r.session}")
                tries.pop(n, None)
            except Failed as e:
                failed.append(n)
                tries[n] = Try(time.time(), isinstance(e, PromptFailed))
                self.log(f"{n}: restore failed, next try in {COOLDOWN // 60} min: {e}")
        self.save_tries(tries)
        return failed

    def resume(self, state: State, name: str) -> None:
        r, live = state.agents.get(name) or state.ended.get(name), self.herdr.agents()
        agent = running_as(name, r, live) if r else next((a for a in live if a.get("name") == name), None)
        if agent and self.agents.running(agent.get("name") or agent["pane_id"]):
            self.log(f"{name} is running already in pane {agent['pane_id']}")
            return
        r = recorded(state, name)
        pane = self.start_recorded(name, r, "This agent had exited", live)
        self.log(f"{name}: resumed in pane {pane} by hand, session {r.session}")

    def recorded_agent(self, a: dict, labels: dict) -> Record | None:
        kind, sid = a.get("agent") or "claude", session_of(a)
        if kind not in KINDS or not sid:
            return None
        _, argv, env = self.agents.process(kind, a["pane_id"])
        r = Record(kind=kind, named=a.get("name") is not None, pane=a["pane_id"],
                   workspace=labels.get(a["workspace_id"]), cwd=a["cwd"], session=sid, args=argv[1:])
        if kind == "claude":
            return replace(r, config_dir=env.get("CLAUDE_CONFIG_DIR", ""), rotate=ROTATE_ID in env,
                           model=last_model(self.settings.home / ".claude/projects", sid))
        if kind == "opencode":
            return replace(r, opencode_config=opencode_config(env))
        return replace(r, codex_home=env.get("CODEX_HOME", ""))

    def snapshot(self, server: str, state: State, failed: list[str]) -> None:
        labels = {w["workspace_id"]: w.get("label") for w in self.herdr("workspace", "list")["result"]["workspaces"]}
        agents: dict[str, Record] = {}
        for a in self.herdr.agents():
            key = key_of(a)
            if not key:
                continue
            if (a.get("name") or "").startswith(UNNAMED):
                self.log(f"{key}: not recorded, because names that start with {UNNAMED} are kept for agents "
                         "without a name")
                continue
            old = state.agents.get(key)
            try:
                r = self.recorded_agent(a, labels)
            except Failed as e:
                if old and old.session == session_of(a):
                    agents[key] = old
                    self.log(f"{key}: kept its last record, because its process could not be read: {e}")
                continue
            if r and old and old.session == r.session and r.model is None:
                r = replace(r, model=old.model)
            if r:
                agents[key] = r
        self.save("agents.json", next_state(state, agents, server, failed, time.time()).json())

    def move_limited(self, a: dict, hit: tuple[str, int], local: dict[str, str]) -> None:
        name, (text, said) = a["name"], hit
        current = account_of(self.agents.claude_process(a["pane_id"])[2], local, self.settings.home)
        try:
            held = hold_limit(self.settings, current, text, said)
        except (OSError, subprocess.SubprocessError, ValueError) as e:
            raise Failed(f"could not hold {current}: {e!r}") from e
        what = f"held until {at(held[0])} after a {held[1]}" if held else "not held, its limit has reset"
        self.log(f"{name}: {current} recorded {text!r} at {at(said)}; {what}")
        self.switch(name, None, after_limit=True)

    def scan(self) -> int:
        server = self.herdr.ensure_server(self.log)
        state = self.load_state()
        lost = self.restore(state, server)
        switched = self.load("switched.json")
        local, failed = None, len(lost)
        for a in self.herdr.agents():
            name = a.get("name")
            if a.get("agent") != "claude" or a.get("agent_status") == "working" or name is None:
                continue
            if switched.get(name, 0) > time.time() - COOLDOWN:
                continue
            session = session_of(a)
            hit = recorded_limit(self.settings.home / ".claude/projects", session) if session else None
            if not hit:
                continue
            try:
                local = local or read_accounts(self.settings.accounts_file).local
                self.move_limited(a, hit, local)
            except Failed as e:
                failed += 1
                self.log(f"{name}: switch failed: {e}")
            switched[name] = time.time()
            self.save("switched.json", switched)
        self.snapshot(server, state, lost)
        return 1 if failed else 0

    def restore_or_resume(self, name: str | None) -> int:
        server = self.herdr.ensure_server(self.log)
        state = self.load_state()
        lost = self.restore(state, server, wait=False)
        try:
            if name is not None and name not in lost:
                self.resume(state, name)
        finally:
            self.snapshot(server, state, lost)
        return 1 if lost else 0

    def switch_now(self, name: str, to: str | None) -> int:
        ok = self.switch(name, to)
        if ok:
            switched = self.load("switched.json")
            switched[name] = time.time()
            self.save("switched.json", switched)
        return 0 if ok else 1


def run(settings: Settings, a: argparse.Namespace) -> int:
    s = Switcher(settings)
    with locked(s.state / "lock"):
        try:
            if a.cmd == "scan":
                return s.scan()
            if a.cmd == "restore":
                return s.restore_or_resume(None)
            if a.cmd == "resume":
                return s.restore_or_resume(a.name)
            return s.switch_now(a.name, a.to)
        except Failed as e:
            s.log(f"{a.cmd} failed: {e}")
            return 1


def add_parser(sub: argparse._SubParsersAction) -> None:
    ap = sub.add_parser("limit-switch", help="keep herdr agents running across usage limits and server restarts",
                        description="Move named herdr Claude agents off accounts that hit a usage limit, and start "
                                    "every recorded Claude, Codex and opencode agent again after the herdr server "
                                    "restarted.")
    cmds = ap.add_subparsers(dest="cmd", required=True)
    cmds.add_parser("scan", help="restore, then switch each named idle Claude agent whose transcript ends in a usage limit error")
    cmds.add_parser("restore", help="only the restore step of scan")
    sw = cmds.add_parser("switch", help="switch one agent now")
    sw.add_argument("name")
    sw.add_argument("--to", metavar="ACCOUNT")
    cmds.add_parser("resume", help="start a recorded agent that is not running").add_argument("name")
    ap.set_defaults(run=run)
