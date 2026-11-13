from __future__ import annotations

import argparse
import re
import shlex
import sys
import time
from pathlib import Path

from claude_tools.accounts import accounts, config_dir_of
from claude_tools.agents import SKIP_PERMISSIONS, Agents
from claude_tools.errors import Failed, NoProcess
from claude_tools.herdr import Herdr
from claude_tools.settings import Settings
from claude_tools.watch import watch

EFFORTS = ("low", "medium", "high", "xhigh", "max")
MODE_FOOTERS = {"acceptEdits": "accept edits on", "auto": "auto mode on", "bypassPermissions": "bypass permissions on",
                "manual": "manual mode on", "dontAsk": "", "plan": "plan mode on"}
MODE_WAIT_S = 15
NAME = re.compile(r"[a-z][a-z0-9_-]{0,31}")
BUSY = ("working", "blocked")


def agent_name(text: str) -> str:
    if not NAME.fullmatch(text):
        raise argparse.ArgumentTypeError(f"NAME {text!r} must match {NAME.pattern}")
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
        ag.answer_trust(name, screen)
        time.sleep(1)


def caller(settings: Settings, ag: Agents) -> dict | None:
    if not settings.herdr_pane or settings.herdr_session:
        return None
    return ag.herdr("pane", "get", settings.herdr_pane, check=False).get("result", {}).get("pane")


def stop_started(ag: Agents, name: str, pane: str) -> None:
    if "result" in ag.herdr("agent", "get", name, check=False):
        try:
            ag.exit_claude(name, ag.claude_pid(pane))
        except Failed as e:
            print(f"claude-tools agent start: could not stop {name} after the failed start: {e}", file=sys.stderr)


def start(settings: Settings, a: argparse.Namespace) -> None:
    ag = Agents(settings)
    if ag.running(a.name):
        raise Failed(f"{a.name} is already running; `claude-tools agent stop {a.name}` ends it once it is idle")
    config_dir = config_dir_of(a.account, accounts(settings.accounts_file)) if a.account else settings.config_dir
    where = caller(settings, ag)
    created = ag.herdr("tab", "create", "--label", a.name, "--cwd", str(a.cwd), "--no-focus",
                       *(["--workspace", where["workspace_id"]] if where else []))["result"]
    tab, pane = created["tab"]["tab_id"], created["root_pane"]["pane_id"]
    try:
        flags = [*permission_flags(a.permission_mode), *(["--model", a.model] if a.model else []),
                 *(["--effort", a.effort] if a.effort else [])]
        ag.start_claude(pane, a.name, config_dir, flags)
        if a.permission_mode:
            wait_for_mode(ag, a.name, a.permission_mode)
        if a.brief:
            ag.prompt_when_ready(a.name, f"Your brief is in {a.brief.resolve()}. Read it and carry it out.")
    except BaseException:
        stop_started(ag, a.name, pane)
        ag.herdr("tab", "close", tab, check=False)
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
        ag.exit_claude(a.name, ag.claude_pid(agent["pane_id"]))
    except NoProcess:
        try:
            pid = ag.codex_process(agent["pane_id"])
        except Failed as e2:
            raise Failed(f"{e2}, but herdr still lists {a.name}; the tab stays") from e2
        ag.exit_codex(a.name, pid)
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
    ap = sub.add_parser("agent", help="start, stop or watch named Claude agents in herdr")
    cmds = ap.add_subparsers(dest="cmd", required=True)
    st = cmds.add_parser("start", help="start a named Claude agent in its own herdr tab",
                         description="Start a named Claude agent in its own herdr tab, in the caller's workspace, "
                                     "without moving anyone's focus. It runs with --dangerously-skip-permissions "
                                     "and gets one prompt that names the brief file. On a failure after the tab "
                                     "exists, the agent stops and the tab closes, so the command can run again.")
    st.add_argument("name", type=agent_name)
    st.add_argument("--cwd", required=True, type=folder)
    st.add_argument("--account", help="an account name or a CLAUDE_CONFIG_DIR folder; default: the caller's account")
    st.add_argument("--model")
    st.add_argument("--effort", choices=EFFORTS)
    st.add_argument("--permission-mode", choices=tuple(MODE_FOOTERS),
                    help="start in this mode, keep bypass reachable with shift+tab, and send the brief once the "
                         "footer shows the mode")
    st.add_argument("--brief", type=brief_file, help="a file the agent reads as its brief")
    st.set_defaults(action=start)
    sp = cmds.add_parser("stop", help="end an agent and close its tab",
                         description="Refuse while the agent is working or waits at a question or approval, unless --force. "
                                     "Type /exit in a claude agent's pane, or press ctrl+c in a codex agent's pane "
                                     "until codex quits, wait until herdr frees the name, and close the tab when it "
                                     "is named NAME and has one pane.")
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
