from __future__ import annotations

import json
import subprocess
import time
from collections.abc import Callable
from pathlib import Path

from claude_tools.errors import Failed
from claude_tools.settings import Settings

SERVER_WAIT_S = 30


def error_code(e: Failed) -> str:
    return str(e).rsplit(": ", 1)[-1]


class Herdr:
    def __init__(self, settings: Settings):
        self.home = settings.home
        self.session = settings.herdr_session
        self.cmd = [settings.herdr, *(["--session", self.session] if self.session else [])]
        base = settings.home / ".config/herdr"
        self.socket = str(base / "sessions" / self.session / "herdr.sock" if self.session else base / "herdr.sock")

    def __call__(self, *args: str, check: bool = True) -> dict:
        p = subprocess.run([*self.cmd, *args], capture_output=True, text=True, timeout=300, check=False)
        try:
            data = json.loads(p.stdout or p.stderr or "{}")
        except json.JSONDecodeError:
            data = {}
        if check and p.returncode != 0:
            err = data.get("error") or {}
            raise Failed(f"herdr {args[0]} {args[1]}: {err.get('code') or p.stderr.strip()[:200]}")
        return data

    def screen(self, name: str, source: str = "visible", lines: int = 0) -> str:
        args = [*self.cmd, "agent", "read", name, "--source", source, *(["--lines", str(lines)] if lines else [])]
        try:
            return subprocess.run(args, capture_output=True, text=True, timeout=60, check=False).stdout
        except subprocess.TimeoutExpired:
            return ""

    def agents(self) -> list[dict]:
        return self("agent", "list")["result"]["agents"]

    def server_id(self) -> str | None:
        want = ["--session", self.session, "server"] if self.session else ["server"]
        for p in Path("/proc").iterdir():
            try:
                if not p.name.isdigit():
                    continue
                argv = (p / "cmdline").read_bytes().decode().split("\0")[:-1]
                if argv and Path(argv[0]).name == "herdr" and argv[1:] == want:
                    return f"{p.name}:{(p / 'stat').read_text().rsplit(')', 1)[1].split()[19]}"
            except OSError:
                continue
        return None

    def ensure_server(self, log: Callable[[str], object]) -> str:
        if server := self.server_id():
            return server
        if self.session:
            subprocess.Popen([*self.cmd, "server"], start_new_session=True, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=self.home)
        else:
            subprocess.run(["systemctl", "--user", "start", "herdr-default.service"], check=False)
        deadline = time.time() + SERVER_WAIT_S
        while time.time() < deadline:
            if (server := self.server_id()) and "result" in self("agent", "list", check=False):
                log(f"started the herdr server{' for session ' + self.session if self.session else ''}")
                return server
            time.sleep(1)
        raise Failed(f"the herdr server did not start in {SERVER_WAIT_S} s")
