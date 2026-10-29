from __future__ import annotations

import os
import shutil
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

LIBEXEC = Path("@libexec@")
TOOL = Path("@bin@") / "claude-tools"
ACCOUNTS_TOOL = LIBEXEC / "claude-accounts"


@dataclass(frozen=True)
class Settings:
    home: Path
    data: Path
    cache: Path
    state: Path
    config: Path
    runtime: Path
    inbox: Path
    herdr: str
    herdr_session: str
    herdr_pane: str
    config_dir: str
    pick: bool
    color: bool

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> Settings:
        home = Path.home()
        state = Path(env.get("CLAUDE_TOOLS_STATE") or home / ".local/state/claude-tools")
        return cls(
            home=home,
            data=Path(env.get("CLAUDE_TOOLS_DATA") or home / "Desktop/workspace/dotfiles/desktop/claude-code"),
            cache=Path(env.get("CLAUDE_TOOLS_CACHE") or home / ".cache/claude-tools"),
            state=state,
            config=home / ".config/claude-tools",
            runtime=Path(env.get("XDG_RUNTIME_DIR") or f"/tmp/claude-tools-{os.getuid()}") / "claude-tools",
            inbox=Path(env.get("CLAUDE_TOOLS_INBOX") or state / "orch/inbox.log"),
            herdr=shutil.which("herdr") or "/usr/local/bin/herdr",
            herdr_session=env.get("CLAUDE_TOOLS_HERDR_SESSION", ""),
            herdr_pane=env.get("HERDR_PANE_ID", ""),
            config_dir=env.get("CLAUDE_CONFIG_DIR", ""),
            pick=env.get("CLAUDE_TOOLS_PICK") != "0",
            color=not env.get("NO_COLOR"),
        )

    @property
    def accounts_file(self) -> Path:
        return self.data / "accounts.json"

    @property
    def holds_file(self) -> Path:
        return self.state / "limits.json"

    @property
    def usage_cache(self) -> Path:
        return self.cache / "usage.json"

    @property
    def read_key(self) -> Path:
        return self.home / ".ssh/id_ed25519_claude_usage"
