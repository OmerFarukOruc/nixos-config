from __future__ import annotations

import json
import socket
import subprocess
import time
from collections.abc import Callable
from pathlib import Path

from claude_tools.errors import Failed, HerdrError
from claude_tools.settings import Settings

SERVER_WAIT_S = 30
REQUEST_TIMEOUT_S = 30


def session_of(agent: dict) -> str | None:
    return (agent.get("agent_session") or {}).get("value")


class Stream:
    def __init__(self, conn: socket.socket, method: str):
        self.conn = conn
        self.method = method
        self.buffer = b""

    def messages(self, timeout: float) -> list[dict]:
        self.conn.settimeout(timeout)
        try:
            chunk = self.conn.recv(1 << 16)
        except TimeoutError:
            return []
        except OSError as e:
            raise HerdrError(f"herdr {self.method}: {e}") from e
        if not chunk:
            raise HerdrError(f"herdr {self.method}: the server closed the connection", "closed")
        *lines, self.buffer = (self.buffer + chunk).split(b"\n")
        out = []
        for raw in lines:
            if not raw.strip():
                continue
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError as e:
                raise HerdrError(f"herdr {self.method}: not JSON: {raw[:200]!r}") from e
            if "error" in msg:
                code = (msg["error"] or {}).get("code")
                raise HerdrError(f"herdr {self.method}: {code}", code)
            out.append(msg)
        return out

    def answer(self) -> dict:
        deadline = time.monotonic() + REQUEST_TIMEOUT_S
        while (left := deadline - time.monotonic()) > 0:
            for msg in self.messages(left):
                if "result" in msg:
                    return msg["result"]
        raise HerdrError(f"herdr {self.method}: no answer in {REQUEST_TIMEOUT_S} s")

    def close(self) -> None:
        self.conn.close()


class Herdr:
    def __init__(self, settings: Settings):
        self.home = settings.home
        self.session = settings.herdr_session
        self.cmd = [settings.herdr, *(["--session", self.session] if self.session else [])]
        base = settings.home / ".config/herdr"
        if self.session:
            self.socket = str(base / "sessions" / self.session / "herdr.sock")
        else:
            self.socket = settings.herdr_socket or str(base / "herdr.sock")

    def connect(self, method: str, params: dict) -> socket.socket:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            conn.settimeout(REQUEST_TIMEOUT_S)
            conn.connect(self.socket)
            conn.sendall((json.dumps({"id": method, "method": method, "params": params}) + "\n").encode())
        except OSError as e:
            conn.close()
            raise HerdrError(f"herdr {method}: {e}") from e
        return conn

    def request(self, method: str, params: dict | None = None) -> dict:
        with self.connect(method, params or {}) as conn:
            return Stream(conn, method).answer()

    def subscribe(self, subscriptions: list[dict]) -> Stream:
        conn = self.connect("events.subscribe", {"subscriptions": subscriptions})
        stream = Stream(conn, "events.subscribe")
        try:
            stream.answer()
        except Failed:
            conn.close()
            raise
        return stream

    def __call__(self, *args: str, check: bool = True) -> dict:
        try:
            p = subprocess.run([*self.cmd, *args], capture_output=True, text=True, timeout=300, check=False)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise HerdrError(f"herdr {' '.join(args[:2])}: {e}") from e
        try:
            data = json.loads(p.stdout or p.stderr or "{}")
        except json.JSONDecodeError:
            data = {}
        if check and p.returncode != 0:
            code = (data.get("error") or {}).get("code")
            raise HerdrError(f"herdr {args[0]} {args[1]}: {code or p.stderr.strip()[:200]}", code)
        return data

    def screen(self, name: str, source: str = "visible", lines: int = 0) -> str:
        args = [*self.cmd, "agent", "read", name, "--source", source, *(["--lines", str(lines)] if lines else [])]
        try:
            return subprocess.run(args, capture_output=True, text=True, timeout=60, check=False).stdout
        except (OSError, subprocess.TimeoutExpired):
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
