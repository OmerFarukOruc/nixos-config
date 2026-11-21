from __future__ import annotations

import argparse
import re
import shlex
import sys
import time
from collections.abc import Callable
from pathlib import Path

from claude_tools.accounts import accounts, config_dir_of
from claude_tools.agents import SKIP_PERMISSIONS, UNNAMED, Agents, check_codex_choice, check_opencode_agent
from claude_tools.errors import Failed, NoProcess
from claude_tools.herdr import Herdr
from claude_tools.settings import Settings
from claude_tools.watch import watch

EFFORTS = ("low", "medium", "high", "xhigh", "max")
Starter = Callable[[Agents, str, str | None], None]
CODEX_FLAGS = ("-s", "workspace-write", "-c", "sandbox_workspace_write.network_access=true", "-a", "never")
MODE_FOOTERS = {"acceptEdits": "accept edits on", "auto": "auto mode on", "bypassPermissions": "bypass permissions on",
                "manual": "manual mode on", "dontAsk": "", "plan": "plan mode on"}
MODE_WAIT_S = 15
NAME = re.compile(r"[a-z][a-z0-9_-]{0,31}")
BUSY = ("working", "blocked")


def agent_name(text: str) -> str:
    if not NAME.fullmatch(text):
        raise argparse.ArgumentTypeError(f"NAME {text!r} must match {NAME.pattern}")
    if text.startswith(UNNAMED):
        raise argparse.ArgumentTypeError(f"NAME {text!r} starts with {UNNAMED}, which limit-switch keeps for "
                                         "agents without a name")
    return text


def nonempty(text: str) -> str:
    if not text:
        raise argparse.ArgumentTypeError("the value is empty")
    return text


def folder(text: str) -> Path:
    if not Path(text).is_dir():
        raise argparse.ArgumentTypeError(f"{text} is not a folder")
    return Path(text).resolve()


def brief_file(text: str) -> Path:
    if not Path(text).is_file():
        raise argparse.ArgumentTypeError(f"{text} is not a file")
    return Path(text)


def permission_flags(mode: str | None) -> list[str]:
    if mode is None:
        return [SKIP_PERMISSIONS]
    return ["--permission-mode", mode, "--allow-dangerously-skip-permissions"]


def wait_for_mode(ag: Agents, name: str, mode: str) -> None:
    footer = MODE_FOOTERS[mode]
    if not footer:
        return
    deadline = time.time() + MODE_WAIT_S
    while True:
        screen = ag.herdr.screen(name)
        if footer in screen:
            return
        if time.time() >= deadline:
            raise Failed(f"{name} started, but its footer never showed {footer!r}")
        ag.answer_trust("claude", name, screen)
        time.sleep(1)


def caller_workspace(settings: Settings, ag: Agents) -> list[str]:
    if not settings.herdr_pane or settings.herdr_session:
        return []
    data = ag.herdr("pane", "get", settings.herdr_pane, check=False)
    workspace = data.get("result", {}).get("pane", {}).get("workspace_id")
    if not workspace:
        code = (data.get("error") or {}).get("code", "no answer")
        raise Failed(f"herdr pane get {settings.herdr_pane}: {code}, so the tab cannot open in the caller's "
                     "workspace and would open in the one someone has focused")
    return ["--workspace", workspace]


def clean_up(ag: Agents, name: str, pane: str, tab: str) -> None:
    try:
        if "result" in ag.herdr("agent", "get", name, check=False):
            ag.end(name, pane)
    except Failed as e:
        print(f"claude-tools agent start: could not stop {name} after the failed start: {e}", file=sys.stderr)
    try:
        ag.herdr("tab", "close", tab, check=False)
    except Failed as e:
        print(f"claude-tools agent start: could not close tab {tab} after the failed start: {e}", file=sys.stderr)


def refuse(*flags: tuple[str, str | None, str]) -> None:
    for flag, value, reason in flags:
        if value:
            raise Failed(f"{flag}: {reason}")


def refuse_agent(a: argparse.Namespace) -> None:
    if a.agent:
        raise Failed("--agent names an opencode agent; it needs --kind opencode")


def prepare_claude(settings: Settings, a: argparse.Namespace) -> Starter:
    refuse_agent(a)
    if a.effort and a.effort not in EFFORTS:
        raise Failed(f"--effort {a.effort} is not one of {', '.join(EFFORTS)}")
    config_dir = config_dir_of(a.account, accounts(settings.accounts_file)) if a.account else settings.config_dir
    flags = [*permission_flags(a.permission_mode), *(["--model", a.model] if a.model else []),
             *(["--effort", a.effort] if a.effort else [])]

    def start_claude(ag: Agents, pane: str, brief: str | None) -> None:
        ag.start_claude(pane, a.name, config_dir, flags)
        if a.permission_mode:
            wait_for_mode(ag, a.name, a.permission_mode)
        if brief:
            ag.prompt_when_ready(a.name, brief)

    return start_claude


def prepare_codex(settings: Settings, a: argparse.Namespace) -> Starter:
    refuse_agent(a)
    refuse(("--account", a.account, "it picks a Claude account; Codex uses the login in its CODEX_HOME"),
           ("--permission-mode", a.permission_mode,
            "it is a Claude mode; Codex starts in the workspace-write sandbox with no approval prompts"))
    check_codex_choice(settings.codex_models, a.model, a.effort)
    flags = [*(["-m", a.model] if a.model else []),
             *(["-c", f"model_reasoning_effort={a.effort}"] if a.effort else []), *CODEX_FLAGS]

    def start_codex(ag: Agents, pane: str, brief: str | None) -> None:
        ag.start_codex(pane, a.name, settings.codex_home, flags)
        if brief:
            ag.prompt_until_turn(a.name, brief)

    return start_codex


def prepare_opencode(settings: Settings, a: argparse.Namespace) -> Starter:
    if not a.agent:
        raise Failed("--kind opencode needs --agent, the opencode agent that sets the model and the permissions")
    own = f"the opencode agent {a.agent} sets its own model and permissions"
    refuse(("--account", a.account, f"Claude only; {own}"), ("--model", a.model, f"Claude only; {own}"),
           ("--effort", a.effort, f"Claude only; {own}"),
           ("--permission-mode", a.permission_mode, f"Claude only; {own}"))
    check_opencode_agent(a.cwd, a.agent)

    def start_opencode(ag: Agents, pane: str, brief: str | None) -> None:
        ag.start_opencode(pane, a.name, a.agent, [])
        if brief:
            ag.prompt_until_turn(a.name, brief)

    return start_opencode


PREPARE = {"claude": prepare_claude, "codex": prepare_codex, "opencode": prepare_opencode}


def start(settings: Settings, a: argparse.Namespace) -> None:
    ag = Agents(settings)
    if ag.running(a.name):
        raise Failed(f"{a.name} is already running; `claude-tools agent stop {a.name}` ends it once it is idle")
    begin = PREPARE[a.kind](settings, a)
    brief = f"Your brief is in {a.brief.resolve()}. Read it and carry it out." if a.brief else None
    created = ag.herdr("tab", "create", "--label", a.name, "--cwd", str(a.cwd), "--no-focus",
                       *caller_workspace(settings, ag))["result"]
    tab, pane = created["tab"]["tab_id"], created["root_pane"]["pane_id"]
    try:
        begin(ag, pane, brief)
    except BaseException:
        clean_up(ag, a.name, pane, tab)
        raise


def is_own_tab(name: str, tab: dict) -> bool:
    return tab.get("label") == name and tab.get("pane_count") == 1


def close_unlisted(ag: Agents, name: str, data: dict) -> None:
    code = (data.get("error") or {}).get("code", "no answer")
    tabs = ag.herdr("tab", "list", check=False).get("result", {}).get("tabs", []) if code == "agent_not_found" else []
    own = [t["tab_id"] for t in tabs if is_own_tab(name, t)]
    if not own:
        raise Failed(f"herdr agent get: {code}")
    for tab_id in own:
        ag.herdr("tab", "close", tab_id)
    print(f"claude-tools agent stop: herdr no longer lists {name}; closed its tab {', '.join(own)}")


def stop(settings: Settings, a: argparse.Namespace) -> None:
    ag = Agents(settings)
    data = ag.herdr("agent", "get", a.name, check=False)
    if "result" not in data:
        close_unlisted(ag, a.name, data)
        return
    agent = data["result"]["agent"]
    status = agent.get("agent_status")
    if status in BUSY and not a.force:
        herdr = shlex.join(ag.herdr.cmd)
        raise Failed(f"{a.name} is {status}. Read its pane with `{herdr} agent read {a.name} --source recent-unwrapped`, "
                     f"then wait with `{herdr} agent wait {a.name} --until idle --until done` or answer its question. "
                     "Pass --force only to cut it off on purpose.")
    try:
        ag.end(a.name, agent["pane_id"])
    except NoProcess as e:
        raise Failed(f"{e}, but herdr still lists {a.name}; the tab stays") from e
    tab = ag.herdr("tab", "get", agent["tab_id"], check=False).get("result", {}).get("tab", {})
    if is_own_tab(a.name, tab):
        ag.herdr("tab", "close", agent["tab_id"])


def follow(settings: Settings, a: argparse.Namespace) -> None:
    watch(Herdr(settings), a.names, a.host)


def run(settings: Settings, a: argparse.Namespace) -> int:
    try:
        a.action(settings, a)
    except Failed as e:
        print(f"claude-tools agent {a.cmd}: {e}", file=sys.stderr)
        return 1
    return 0


def add_parser(sub: argparse._SubParsersAction) -> None:
    ap = sub.add_parser("agent", help="start, stop or watch named Claude, Codex or opencode agents in herdr")
    cmds = ap.add_subparsers(dest="cmd", required=True)
    st = cmds.add_parser("start", help="start a named Claude, Codex or opencode agent in its own herdr tab",
                         description="Start a named agent in its own herdr tab, in the caller's workspace, "
                                     "without moving anyone's focus, and send it one prompt that names the brief "
                                     "file. Claude runs with --dangerously-skip-permissions. Codex runs with "
                                     "-s workspace-write, network access and -a never, on --model and --effort "
                                     "when given, else on its configured defaults. opencode runs its TUI "
                                     "with --standalone and starts in the agent that --agent names, which sets its "
                                     "model and permissions. On a failure after the tab exists, the agent stops and "
                                     "the tab closes, so the command can run again.")
    st.add_argument("name", type=agent_name)
    st.add_argument("--cwd", required=True, type=folder)
    st.add_argument("--kind", choices=tuple(PREPARE), default="claude")
    st.add_argument("--agent", type=nonempty, help="with --kind opencode: the opencode agent the session starts in, such as "
                                    "opencode-review; it must exist, set a model that `opencode models` lists in the "
                                    "folder, and the folder's project config must leave it as its global file defines "
                                    "it")
    st.add_argument("--account", type=nonempty, help="an account name or a CLAUDE_CONFIG_DIR folder; default: the caller's account")
    st.add_argument("--model", type=nonempty, help="Claude: a model name or alias; Codex: a model that its models_cache.json lists")
    st.add_argument("--effort", type=nonempty, help="Claude: one of " + ", ".join(EFFORTS) + "; Codex: one of the reasoning efforts "
                                     "that models_cache.json lists for --model, which it needs")
    st.add_argument("--permission-mode", choices=tuple(MODE_FOOTERS),
                    help="start in this mode, keep bypass reachable with shift+tab, and send the brief once the "
                         "footer shows the mode")
    st.add_argument("--brief", type=brief_file, help="a file the agent reads as its brief")
    st.set_defaults(action=start)
    sp = cmds.add_parser("stop", help="end an agent and close its tab",
                         description="Refuse while the agent is working or waits at a question or approval, unless --force. "
                                     "Type /exit in a claude agent's pane, or press ctrl+c in a codex or opencode "
                                     "agent's pane until it quits, wait until herdr frees the name, and close the "
                                     "tab when it is named NAME and has one pane.")
    sp.add_argument("name")
    sp.add_argument("--force", action="store_true",
                    help="stop the agent even while it is working or waits at a question or approval")
    sp.set_defaults(action=stop)
    wt = cmds.add_parser("watch", help="print one line when a named agent finishes a turn, blocks or leaves",
                         description="Follow herdr's agent events and print one line when an agent whose name "
                                     "NAME-REGEX matches finishes a turn, waits at a question or approval, turns "
                                     "unknown, appears, is replaced by an agent with another session, or leaves, so "
                                     "a Monitor on it wakes the orchestrator. It prints each matching agent's state "
                                     "at start.")
    wt.add_argument("names", metavar="NAME-REGEX",
                    help="must match a whole agent name, so agents outside it, such as reviewer subagents, do not "
                         "wake the orchestrator")
    wt.add_argument("--host", action="store_true",
                    help="also print when load, swap use or /tmp inode use crosses its limit and when it recovers")
    wt.set_defaults(action=follow)
    ap.set_defaults(run=run)
