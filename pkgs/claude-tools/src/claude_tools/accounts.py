from __future__ import annotations

import subprocess
from pathlib import Path

from claude_tools.errors import Failed
from claude_tools.settings import ACCOUNTS_TOOL


def accounts() -> dict[str, str]:
    def run(*a: str) -> str:
        return subprocess.run([str(ACCOUNTS_TOOL), *a], capture_output=True, text=True, check=True).stdout.strip()

    return {n: run("dir", n) for n in run("names").split()}


def folder(config_dir: str, home: Path) -> Path:
    return Path(config_dir) if config_dir else home / ".claude"


def normalize(config_dir: str, home: Path) -> str:
    d = config_dir.rstrip("/")
    return "" if d == str(home / ".claude") else d


def account_of(config_dir: str, dirs: dict[str, str], home: Path) -> str:
    d = normalize(config_dir, home)
    for n, x in dirs.items():
        if x == d:
            return n
    raise Failed(f"CLAUDE_CONFIG_DIR={config_dir!r} is no claude-tools account")


def config_dir_of(account: str, dirs: dict[str, str]) -> str:
    if account in dirs:
        return dirs[account]
    d = account.rstrip("/")
    if d in dirs.values():
        return d
    raise Failed(f"{account!r} is no claude-tools account; accounts: {', '.join(dirs)}")
