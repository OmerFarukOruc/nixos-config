from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from claude_tools.commands import agent, limit_switch, orch, rotate, usage
from claude_tools.settings import ACCOUNTS_TOOL, Settings


def parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="claude-tools", description="Claude Code accounts, usage and herdr agents.")
    sub = ap.add_subparsers(dest="command", required=True, metavar="COMMAND")
    sub.add_parser("accounts", add_help=False,
                   help="account folders and logins; `claude-tools accounts help` lists its commands")
    usage.add_parser(sub)
    rotate.add_parser(sub)
    limit_switch.add_parser(sub)
    agent.add_parser(sub)
    orch.add_parser(sub)
    return ap


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    local_bin = str(Path.home() / ".local/bin")
    if local_bin not in os.environ.get("PATH", "").split(":"):
        os.environ["PATH"] = f"{local_bin}:{os.environ.get('PATH', '')}"
    settings = Settings.from_env(os.environ)
    if argv[:1] == ["accounts"]:
        os.execv(ACCOUNTS_TOOL, [str(ACCOUNTS_TOOL), *argv[1:]])
    if argv[:1] == ["rotate"]:
        return rotate.run(settings, argv[1:])
    a = parser().parse_args(argv)
    return a.run(settings, a)
