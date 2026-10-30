from __future__ import annotations

import argparse
import re
import sys
import time
from pathlib import Path

from claude_tools.accounts import accounts, config_dir_of
from claude_tools.agents import SKIP_PERMISSIONS, Agents
from claude_tools.errors import Failed, NoProcess
from claude_tools.settings import Settings
from claude_tools.transcripts import answer_of, session_of, status_line

EFFORTS = ("low", "medium", "high", "xhigh", "max")
MODE_FOOTERS = {"acceptEdits": "accept edits on", "auto": "auto mode on", "bypassPermissions": "bypass permissions on",
                "manual": "manual mode on", "dontAsk": "", "plan": "plan mode on"}
MODE_WAIT_S = 15
NAME = re.compile(r"[a-z][a-z0-9_-]{0,31}")
PEEK_LINES = 20


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


def line_count(text: str) -> int:
    if not text.isdigit():
        raise argparse.ArgumentTypeError(f"{text!r} is not a line count")
    return int(text)


def permission_flags(mode: str | None) -> list[str]:
    if mode is None:
        return [SKIP_PERMISSIONS]
    return ["--permission-mode", mode, "--allow-dangerously-skip-permissions"]


def wait_for_mode(ag: Agents, name: str, mode: str) -> None:
    footer = MODE_FOOTERS[mode]
    if not footer:
        return
    deadline = time.time() + MODE_WAIT_S
    while footer not in ag.herdr.screen(name):
        if time.time() >= deadline:
            raise Failed(f"{name} started, but its footer never showed {footer!r}")
        time.sleep(1)


def caller(settings: Settings, ag: Agents) -> dict | None:
    if not settings.herdr_pane or settings.herdr_session:
        return None
    return ag.herdr("pane", "get", settings.herdr_pane, check=False).get("result", {}).get("pane")


def stop_started(ag: Agents, name: str, pane: str) -> None:
    if "result" in ag.herdr("agent", "get", name, check=False):
        try:
            ag.exit_claude(name, ag.claude_process(pane)[0])
        except Failed as e:
            print(f"claude-tools agent start: could not stop {name} after the failed start: {e}", file=sys.stderr)


def start(settings: Settings, a: argparse.Namespace) -> None:
    ag = Agents(settings)
    if ag.running(a.name):
        raise Failed(f"{a.name} is already running; `claude-tools agent stop {a.name}` ends it")
    config_dir = config_dir_of(a.account, accounts(settings.accounts_file)) if a.account else settings.config_dir
    where = caller(settings, ag)
    inbox_env = ["--env", f"CLAUDE_TOOLS_INBOX={settings.inbox.absolute()}"] if settings.inbox_set else []
    created = ag.herdr("tab", "create", "--label", a.name, "--cwd", str(a.cwd), "--no-focus",
                       *(["--workspace", where["workspace_id"]] if where else []), *inbox_env)["result"]
    tab, pane = created["tab"]["tab_id"], created["root_pane"]["pane_id"]
    try:
        flags = [*permission_flags(a.permission_mode), *(["--model", a.model] if a.model else []),
                 *(["--effort", a.effort] if a.effort else [])]
        ag.start_claude(pane, a.name, config_dir, flags)
        if a.permission_mode:
            wait_for_mode(ag, a.name, a.permission_mode)
        if a.brief:
            ag.herdr("agent", "prompt", a.name, f"Your brief is in {a.brief.resolve()}. Read it and carry it out.")
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
    try:
        ag.exit_claude(a.name, ag.claude_process(agent["pane_id"])[0])
    except NoProcess:
        try:
            pid = ag.codex_process(agent["pane_id"])
        except Failed as e2:
            raise Failed(f"{e2}, but herdr still lists {a.name}; the tab stays") from e2
        ag.exit_codex(a.name, pid)
    tab = ag.herdr("tab", "get", agent["tab_id"], check=False).get("result", {}).get("tab", {})
    if is_own_tab(a.name, tab):
        ag.herdr("tab", "close", agent["tab_id"])


def peek(settings: Settings, a: argparse.Namespace) -> None:
    ag = Agents(settings)
    data = ag.herdr("agent", "get", a.name, check=False)
    if "result" not in data:
        raise Failed(f"herdr agent get: {(data.get('error') or {}).get('code', 'no answer')}")
    agent = data["result"]["agent"]
    answer = answer_of(agent, settings.home)
    out = [f"{a.name}: {agent.get('agent_status')}"]
    if answer is not None:
        out += [f"status: {status_line(answer) or 'none'}", f"--- last answer, last {a.lines} lines ---",
                *answer.splitlines()[-a.lines:]]
    else:
        screen = ag.herdr.screen(a.name, "visible")
        out += [f"status: {status_line(screen) or 'none'}",
                f"--- no transcript text for session {session_of(agent)}; visible screen, last {a.lines} lines ---",
                *[ln for ln in screen.splitlines() if ln.strip()][-a.lines:]]
    print("\n".join(out))


def run(settings: Settings, a: argparse.Namespace) -> int:
    try:
        a.action(settings, a)
    except Failed as e:
        print(f"claude-tools agent {a.cmd}: {e}", file=sys.stderr)
        return 1
    return 0


def add_parser(sub: argparse._SubParsersAction) -> None:
    ap = sub.add_parser("agent", help="start, stop or peek at a named Claude agent in herdr")
    cmds = ap.add_subparsers(dest="cmd", required=True)
    st = cmds.add_parser("start", help="start a named Claude agent in its own herdr tab",
                         description="Start a named Claude agent in its own herdr tab, in the caller's workspace, "
                                     "without moving anyone's focus. It runs with --dangerously-skip-permissions "
                                     "and gets one prompt that names the brief file. When CLAUDE_TOOLS_INBOX is set, "
                                     "the agent gets it too, so its plain `claude-tools orch notify` reaches the "
                                     "caller's inbox. On a failure after the tab exists, the agent stops and the "
                                     "tab closes, so the command can run again.")
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
                         description="Type /exit in a claude agent's pane, or press ctrl+c in a codex agent's pane "
                                     "until codex quits, wait until herdr frees the name, and close the tab when it "
                                     "is named NAME and has one pane.")
    sp.add_argument("name")
    sp.set_defaults(action=stop)
    pk = cmds.add_parser("peek", help="print an agent's state, last STATUS: line and last answer",
                         description="Print the agent's state, its last STATUS: or NEED: line, and the last LINES "
                                     "lines of its last answer from the session transcript, or of the visible "
                                     "screen when there is no transcript text.")
    pk.add_argument("name")
    pk.add_argument("lines", nargs="?", type=line_count, default=PEEK_LINES)
    pk.set_defaults(action=peek)
    ap.set_defaults(run=run)
