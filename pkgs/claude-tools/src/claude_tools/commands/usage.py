from __future__ import annotations

import argparse
import json
import shutil
import socket
import sys
import time
from datetime import datetime

from claude_tools.accounts import accounts
from claude_tools.agents import sessions
from claude_tools.errors import Failed
from claude_tools.selection import GROUPS, ranked, startable
from claude_tools.settings import Settings
from claude_tools.terminal import Cards
from claude_tools.usage import by_name, combined, entries, load_cache, locked_refresh

WATCH_EVERY = 30
WATCH_MAX_AGE = 300


def show(settings: Settings, data: dict) -> str:
    try:
        by_dir = sessions(settings.home)
        live = {n: by_dir[d] for n, d in accounts(settings.accounts_file).items() if by_dir.get(d)}
    except (OSError, Failed):
        live = {}
    color = sys.stdout.isatty() and settings.color
    host = data.get("host") or socket.gethostname()
    cards = combined(data, settings.accounts_file)
    return Cards(color, shutil.get_terminal_size().columns).render(data, host, cards, live)


def watch(settings: Settings, max_age: int) -> int:
    out = sys.stdout
    out.write("\033[?1049h\033[?25l")
    try:
        while True:
            data = locked_refresh(settings, [], max_age)
            stamp = datetime.now().astimezone().strftime("%H:%M:%S")
            head = f"watching all accounts  ·  {stamp}  ·  ctrl+c quits"
            out.write("\033[H\033[2J" + (f"\033[2m{head}\033[0m" if out.isatty() else head) + "\n\n"
                      + show(settings, data) + "\n")
            out.flush()
            time.sleep(WATCH_EVERY)
    except KeyboardInterrupt:
        return 0
    finally:
        out.write("\033[?25h\033[?1049l")
        out.flush()


def run(settings: Settings, a: argparse.Namespace) -> int:
    if a.order:
        names = [n for n in accounts(settings.accounts_file) if n not in a.skip]
        for n in startable(settings, entries(settings), names):
            print(n)
        return 0
    if a.watch:
        return watch(settings, WATCH_MAX_AGE if a.max_age is None else a.max_age)
    data = load_cache(settings) if a.cached else locked_refresh(settings, a.account, a.max_age)
    if a.json:
        readings = by_name(data)
        print(json.dumps({**data, "combined": combined(data, settings.accounts_file),
                          "order": [{"name": n, "group": GROUPS[g], "why": why}
                                    for n, g, why in ranked(settings, readings, list(readings))]}, indent=1))
    elif not a.quiet:
        print(show(settings, data))
    return 0


def add_parser(sub: argparse._SubParsersAction) -> None:
    ap = sub.add_parser("usage", help="usage limits and login state of every account",
                        description="Usage limits and login state of every Claude Code account.")
    ap.add_argument("--json", action="store_true", help="print the cache as JSON")
    ap.add_argument("--cached", action="store_true", help="print the cache; check nothing")
    ap.add_argument("--max-age", type=int, metavar="SECONDS", help="check only when the cache is older than this")
    ap.add_argument("--account", action="append", default=[], metavar="NAME", help="check only this account")
    ap.add_argument("--quiet", action="store_true", help="print nothing")
    ap.add_argument("--watch", action="store_true",
                    help=f"redraw every {WATCH_EVERY} s and check the accounts when the cache is older than "
                         f"--max-age ({WATCH_MAX_AGE})")
    ap.add_argument("--order", action="store_true",
                    help="print the accounts to start on, best first, from the cache; check nothing")
    ap.add_argument("--skip", action="append", default=[], metavar="NAME", help="with --order: an account to leave out")
    ap.set_defaults(run=run)
