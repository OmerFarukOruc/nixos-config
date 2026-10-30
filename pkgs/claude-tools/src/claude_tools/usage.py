from __future__ import annotations

import http.client
import json
import os
import socket
import subprocess
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, wait
from datetime import datetime
from pathlib import Path

from claude_tools.accounts import accounts, env_for, folder, registry
from claude_tools.errors import Failed
from claude_tools.settings import Settings
from claude_tools.store import locked, now, read_json, write_json

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
FRESH = 300
EXPIRING = 5 * 86400
PROBE_TIMEOUT = 90
SSH_TIMEOUT = 20
CHECK_WORKERS = 4
REMOTE_CACHE = ".cache/claude-tools/usage.json"


def oauth(config_dir: str, home: Path) -> dict:
    return read_json(folder(config_dir, home) / ".credentials.json").get("claudeAiOauth") or {}


def identity(config_dir: str, creds: dict, home: Path) -> dict:
    cfg = read_json(Path(config_dir) / ".claude.json" if config_dir else home / ".claude.json")
    acct = cfg.get("oauthAccount") or {}
    email, org = acct.get("emailAddress"), acct.get("organizationName")
    if org and email and org == f"{email}'s Organization":
        org = "personal"
    plan = creds.get("subscriptionType")
    tier = (creds.get("rateLimitTier") or "").rsplit("_", 1)[-1]
    if plan and tier.endswith("x") and tier[:-1].isdigit():
        plan = f"{plan} {tier}"
    return {"email": email, "org": org, "plan": plan}


def epoch(iso: str | None) -> int | None:
    if not iso:
        return None
    return int(datetime.fromisoformat(iso).timestamp())


def claude_version() -> str:
    try:
        out = subprocess.run(["claude", "--version"], capture_output=True, text=True, timeout=30, check=False).stdout
        return out.split()[0]
    except (OSError, IndexError, subprocess.TimeoutExpired):
        return "2"


class ApiError(Exception):
    def __init__(self, status: int, text: str):
        super().__init__(text)
        self.status = status


def api_usage(token: str, version: str) -> dict:
    req = urllib.request.Request(USAGE_URL, headers={
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": f"claude-code/{version}",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        raise ApiError(e.code, f"usage endpoint answered HTTP {e.code}") from None
    except (OSError, ValueError, http.client.HTTPException) as e:
        raise ApiError(0, f"usage endpoint unreachable: {e}") from None

    def window(key: str) -> dict | None:
        w = data.get(key)
        return {"used": float(w["utilization"]), "resets_at": epoch(w.get("resets_at"))} if w else None

    try:
        scoped = [{"label": ((x.get("scope") or {}).get("model") or {}).get("display_name") or "model",
                   "used": float(x["percent"]), "resets_at": epoch(x.get("resets_at"))}
                  for x in data.get("limits") or [] if x.get("kind") == "weekly_scoped"]
        return {"five_hour": window("five_hour"), "seven_day": window("seven_day"), "scoped": scoped}
    except (AttributeError, KeyError, TypeError, ValueError) as e:
        raise ApiError(0, f"usage endpoint answered an unknown shape: {e!r}") from None


class ProbeError(Exception):
    def __init__(self, text: str, logged_out: bool):
        super().__init__(text)
        self.logged_out = logged_out


def probe_windows(stdout: str) -> tuple[dict | None, str]:
    windows, result = None, ""
    for line in stdout.splitlines():
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") == "rate_limit_event":
            uw = (ev.get("rate_limit_info") or {}).get("unifiedWindows") or {}
            windows = {k: {"used": round(float(w["utilization"]) * 100, 1), "resets_at": w.get("resetsAt")}
                       if (w := uw.get(k)) else None for k in ("five_hour", "seven_day")}
        elif ev.get("type") == "result" and ev.get("is_error"):
            result = str(ev.get("result") or ev.get("subtype") or "")
    return windows, result


def probe(config_dir: str, probe_dir: Path) -> dict:
    probe_dir.mkdir(parents=True, exist_ok=True)
    env = env_for({k: v for k, v in os.environ.items() if k != "CLAUDE_TOOLS_ROTATE_ID"}, config_dir)
    cmd = ["claude", "-p", "--safe-mode", "--no-session-persistence", "--model", "haiku", "--max-turns", "1",
           "--output-format", "stream-json", "--verbose", "Reply with ok."]
    try:
        p = subprocess.run(cmd, cwd=probe_dir, env=env, capture_output=True, text=True, timeout=PROBE_TIMEOUT,
                           stdin=subprocess.DEVNULL, check=False)
    except subprocess.TimeoutExpired:
        raise ProbeError(f"claude -p did not finish in {PROBE_TIMEOUT} s", False) from None
    windows, result = probe_windows(p.stdout)
    if windows and (windows["five_hour"] or windows["seven_day"]):
        return windows
    text = (result or p.stderr).strip().replace("\n", " ")[:200]
    if not text:
        raise ProbeError(f"claude -p exited {p.returncode} without a usage reading", False)
    low = text.lower()
    raise ProbeError(text, any(w in low for w in ("login", "log in", "authenticat", "oauth", "401")))


def login_end(creds: dict) -> int | None:
    expires = creds.get("refreshTokenExpiresAt")
    return int(expires) // 1000 if expires else None


def check(settings: Settings, config_dir: str, old: dict | None, version: str) -> dict:
    home = settings.home
    creds = oauth(config_dir, home)
    entry = {**identity(config_dir, creds, home), "state": "ok", "error": None, "five_hour": None,
             "seven_day": None, "scoped": [], "login_expires_at": login_end(creds), "checked": now(), "source": None}
    if not creds.get("refreshToken") or (entry["login_expires_at"] or now() + 1) <= now():
        entry["state"] = "logged-out"
        return entry

    def stale(err: str) -> dict:
        entry["state"], entry["error"] = "error", err
        if old and old.get("five_hour"):
            entry.update(five_hour=old["five_hour"], seven_day=old["seven_day"], scoped=old.get("scoped", []),
                         source="stale", checked=old.get("checked"))
        return entry

    windows = None
    if (creds.get("expiresAt") or 0) // 1000 > now() + FRESH:
        try:
            windows, entry["source"] = api_usage(creds["accessToken"], version), "api"
        except ApiError as e:
            if e.status != 401:
                return stale(str(e))
    if windows is None:
        try:
            windows, entry["source"] = probe(config_dir, settings.cache / "probe"), "probe"
        except ProbeError as e:
            if e.logged_out:
                entry["state"], entry["error"] = "logged-out", str(e)
                return entry
            return stale(str(e))
        creds = oauth(config_dir, home)
        entry.update(identity(config_dir, creds, home))
        entry["login_expires_at"] = login_end(creds) or entry["login_expires_at"]
    if not (windows["five_hour"] or windows["seven_day"]):
        return stale("the usage reading named no window")
    entry.update(windows)
    if entry["login_expires_at"] and entry["login_expires_at"] - now() < EXPIRING:
        entry["state"] = "expiring"
    return entry


def remote(host: str, old: dict | None, read_key: Path) -> dict:
    try:
        key = ["-i", str(read_key)] if read_key.exists() else []
        p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", *key, host,
                            f"cat {REMOTE_CACHE}"], capture_output=True, text=True,
                           timeout=SSH_TIMEOUT, stdin=subprocess.DEVNULL, check=False)
        if p.returncode != 0:
            raise OSError(p.stderr.strip().splitlines()[-1][:200] if p.stderr.strip() else f"ssh exited {p.returncode}")
        data = json.loads(p.stdout)
        return {"host": host, "updated": data.get("updated"), "error": None, "accounts": data.get("accounts", [])}
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as e:
        kept = old or {"updated": None, "accounts": []}
        return {"host": host, "updated": kept["updated"], "error": f"could not read its cache: {e}",
                "accounts": kept["accounts"]}


def load_cache(settings: Settings) -> dict:
    return read_json(settings.usage_cache) or {"version": 1, "host": socket.gethostname(), "updated": 0,
                                               "accounts": [], "hosts": []}


def failed_entry(name: str, old: dict | None, error: Exception) -> dict:
    kept = old or {"email": None, "org": None, "plan": None, "five_hour": None, "seven_day": None,
                   "login_expires_at": None, "checked": now()}
    return {**kept, "name": name, "state": "error", "error": f"claude-tools usage failed: {error!r}"[:200],
            "source": "stale" if kept.get("five_hour") else None}


def by_name(data: dict) -> dict[str, dict]:
    return {a["name"]: a for a in data.get("accounts", [])}


def refresh(settings: Settings, dirs: dict[str, str], only: list[str], max_age: int | None,
            deadline: float | None) -> dict:
    data = load_cache(settings)
    unknown = [n for n in only if n not in dirs]
    if unknown:
        raise Failed(f"no account {', '.join(unknown)} in accounts.json with a folder here; "
                     f"accounts: {', '.join(dirs)}")
    old, at = by_name(data), now()
    keep = {n for n in dirs if n in old and (only and n not in only or max_age is not None
                                             and at - (old[n].get("checked") or 0) <= max_age)}
    me = socket.gethostname()
    hosts = [] if only else [h for h in read_json(settings.accounts_file).get("remote_hosts", {}).get(me, []) if h != me]
    old_hosts = {h["host"]: h for h in data.get("hosts", [])}
    version = claude_version() if len(keep) < len(dirs) else ""
    pool = ThreadPoolExecutor(CHECK_WORKERS)
    checks = {n: pool.submit(check, settings, d, old.get(n), version) for n, d in dirs.items() if n not in keep}
    reads = [pool.submit(remote, h, old_hosts.get(h), settings.read_key) for h in hosts]
    wait([*reads, *(f for n, f in checks.items() if n not in old)])
    wait([f for n, f in checks.items() if n in old], None if deadline is None else max(0.0, deadline - time.time()))
    pool.shutdown(wait=False, cancel_futures=True)
    result = []
    for n in dirs:
        f = checks.get(n)
        if f is None or n in old and (f.cancelled() or not f.done()):
            result.append(old[n])
            continue
        try:
            result.append({"name": n, **f.result()})
        except Exception as e:
            result.append(failed_entry(n, old.get(n), e))
    partial = any(n not in only for n in dirs) if only else False
    data = {"version": 1, "host": me, "updated": data.get("updated", 0) if partial else now(), "accounts": result,
            "hosts": [f.result() for f in reads] if not only else data.get("hosts", [])}
    write_json(settings.usage_cache, data)
    return data


def locked_refresh(settings: Settings, only: list[str], max_age: int | None, deadline: float | None = None) -> dict:
    dirs = accounts(settings.accounts_file)

    def fresh(data: dict) -> bool:
        return (max_age is not None and not only and now() - data.get("updated", 0) <= max_age
                and sorted(by_name(data)) == sorted(dirs))

    data = load_cache(settings)
    if fresh(data):
        return data
    with locked(settings.cache / "lock"):
        data = load_cache(settings)
        return data if fresh(data) else refresh(settings, dirs, only, max_age, deadline)


def entries(settings: Settings) -> dict[str, dict]:
    return by_name(load_cache(settings))


def combined(data: dict, accounts_file: Path) -> list[dict]:
    me = data.get("host") or socket.gethostname()
    hosts = [{"host": me, "local": True, "updated": data.get("updated"), "error": None,
              "accounts": data.get("accounts", [])}]
    hosts += [{**h, "local": False} for h in data.get("hosts", [])]
    names = registry(accounts_file)
    if names is None:
        names = list(dict.fromkeys(a["name"] for h in hosts for a in h["accounts"]))
    return [combined_entry(n, hosts) for n in names]


def combined_entry(name: str, hosts: list[dict]) -> dict:
    logins, readings = [], []
    for h in hosts:
        a = next((x for x in h["accounts"] if x["name"] == name), None)
        if a is None:
            if h["accounts"] or not h["error"]:
                logins.append({"host": h["host"], "local": h["local"], "state": "missing",
                               "login_expires_at": None, "error": None})
            continue
        logins.append({"host": h["host"], "local": h["local"], "state": a["state"],
                       "login_expires_at": a.get("login_expires_at"), "error": a.get("error")})
        if a.get("five_hour") or a.get("seven_day"):
            readings.append((a.get("source") != "stale", a.get("checked") or 0, h["host"], a))
    known = next((a for h in hosts for a in h["accounts"] if a["name"] == name and a.get("email")), {})
    entry = {"name": name, "email": known.get("email"), "org": known.get("org"), "plan": known.get("plan"),
             "five_hour": None, "seven_day": None, "scoped": [], "checked": None, "source": None,
             "read_on": None, "logins": logins}
    if readings:
        *_, host, a = max(readings, key=lambda r: r[:2])
        entry.update(five_hour=a.get("five_hour"), seven_day=a.get("seven_day"), scoped=a.get("scoped", []),
                     checked=a.get("checked"), source=a.get("source"), read_on=host,
                     **{k: a.get(k) or entry[k] for k in ("email", "org", "plan")})
    return entry
