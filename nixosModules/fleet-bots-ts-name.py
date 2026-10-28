"""Gives the bot host back its tailnet name after it logs in again.

Usage: fleet-bots-ts-name CREDENTIAL NAME TAG

A machine that logs in while an offline node still holds NAME comes back as NAME-1. When no online node holds NAME
and exactly one online NAME-<n> exists, this renames every offline NAME node to NAME-retired-<node id> and NAME-<n> to
NAME, then prints the renamed node's tailnet IPv4 on stdout. Once a node tagged TAG holds NAME, it also renames every
offline NAME-<n> to NAME-retired-<node id>. It renames only devices tagged TAG and never deletes one, so a node retired
by mistake gets its name back with one rename. It reports on stderr.
CREDENTIAL holds TS_OAUTH_CLIENT_ID= and TS_OAUTH_CLIENT_SECRET= lines for an OAuth client with devices:core write.
"""
import http.client
import json
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.tailscale.com/api/v2"


def header_safe(value):
    return bool(value) and value.isascii() and value.isprintable() and " " not in value


def call(method, path, auth=None, data=None, ctype=None):
    headers = {k: v for k, v in (("Authorization", auth), ("Content-Type", ctype)) if v}
    req = urllib.request.Request(API + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        e.request_path = path
        raise
    return json.loads(raw) if raw else None


def reply_reason(error):
    try:
        body = json.loads(error.read())
    except (OSError, ValueError, RecursionError, http.client.HTTPException):
        body = None
    if not isinstance(body, dict):
        return "a reply that is not a JSON object"
    found = [body[key] for key in ("message", "error", "error_description") if isinstance(body.get(key), str)]
    return "; ".join(found)[:200] if found else "a JSON reply with no message"


def failure_reason(error):
    if isinstance(error, urllib.error.URLError) and isinstance(error.reason, BaseException):
        error = error.reason
    if isinstance(error, ssl.SSLError):
        return f"{type(error).__name__}: {error.reason}"
    if isinstance(error, OSError) and error.strerror:
        return f"{type(error).__name__}: {error.strerror}"
    return type(error).__name__


def label(device):
    return device["name"].split(".")[0]


def rename(device, new_name, auth):
    call("POST", f"/device/{device['nodeId']}/name", auth, json.dumps({"name": new_name}).encode(), "application/json")


def retire_stale(devices, name, tag, auth, keep=None):
    for d in devices:
        if d["nodeId"] == keep or d.get("connectedToControl") or tag not in d.get("tags", []):
            continue
        if not re.fullmatch(re.escape(name) + r"-\d+", label(d)):
            continue
        now = call("GET", f"/device/{d['nodeId']}?fields=all", auth)
        if now.get("connectedToControl") or tag not in now.get("tags", []) or label(now) != label(d):
            print(f"{label(d)} {d['nodeId']} is online, untagged, or renamed; left it", file=sys.stderr)
            continue
        retired = f"{name}-retired-{d['nodeId'].lower()}"
        rename(d, retired, auth)
        print(f"renamed the stale {label(d)} {d['nodeId']}, last seen {d.get('lastSeen', 'never')}, to {retired}", file=sys.stderr)


def main(cred, name, tag):
    try:
        text = Path(cred).read_text(encoding="utf-8")
    except UnicodeDecodeError:
        print(f"{cred} is not UTF-8", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"cannot read {cred}: {e.strerror}", file=sys.stderr)
        return 1
    conf = dict(line.split("=", 1) for line in text.split() if "=" in line)
    missing = [key for key in ("TS_OAUTH_CLIENT_ID", "TS_OAUTH_CLIENT_SECRET") if key not in conf]
    if missing:
        print(f"{cred} lacks {', '.join(missing)}", file=sys.stderr)
        return 1
    form = {"client_id": conf["TS_OAUTH_CLIENT_ID"], "client_secret": conf["TS_OAUTH_CLIENT_SECRET"]}
    token = call("POST", "/oauth/token", data=urllib.parse.urlencode(form).encode()).get("access_token")
    if not isinstance(token, str) or not header_safe(token):
        print("the Tailscale token exchange returned no usable access token", file=sys.stderr)
        return 1
    auth = "Bearer " + token
    devices = call("GET", "/tailnet/-/devices?fields=all", auth)["devices"]
    online = [d for d in devices if d.get("connectedToControl")]
    holder = next((d for d in online if label(d) == name), None)
    if holder:
        if tag in holder.get("tags", []):
            retire_stale(devices, name, tag, auth)
        return 0
    new = [d for d in online if tag in d.get("tags", []) and re.fullmatch(re.escape(name) + r"-\d+", label(d))]
    if len(new) > 1:
        print(f"{len(new)} online nodes named {name}-<n>: {', '.join(map(label, new))}; rename one by hand", file=sys.stderr)
        return 1
    if not new:
        return 0
    for d in devices:
        if label(d) == name:
            # The list is a snapshot: re-read the node so one that came back or lost the tag is left alone.
            now = call("GET", f"/device/{d['nodeId']}?fields=all", auth)
            if now.get("connectedToControl") or tag not in now.get("tags", []) or label(now) != name:
                print(f"{name} {d['nodeId']} is online, untagged, or renamed; left it and renamed nothing", file=sys.stderr)
                return 0
            retired = f"{name}-retired-{d['nodeId'].lower()}"
            rename(d, retired, auth)
            print(f"renamed the offline {name} {d['nodeId']}, last seen {d.get('lastSeen', 'never')}, to {retired}", file=sys.stderr)
    rename(new[0], name, auth)
    print(f"renamed {label(new[0])} {new[0]['nodeId']} to {name}", file=sys.stderr)
    print(next(a for a in new[0]["addresses"] if ":" not in a), flush=True)
    retire_stale(devices, name, tag, auth, keep=new[0]["nodeId"])
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("usage: fleet-bots-ts-name CREDENTIAL NAME TAG", file=sys.stderr)
        sys.exit(2)
    try:
        sys.exit(main(*sys.argv[1:]))
    except urllib.error.HTTPError as e:
        print(f"Tailscale API {e.code} on {e.request_path}: {reply_reason(e)!r}", file=sys.stderr)
        sys.exit(1)
    except (OSError, http.client.HTTPException) as e:
        print(f"Tailscale API request failed: {failure_reason(e)}", file=sys.stderr)
        sys.exit(1)
    except (json.JSONDecodeError, UnicodeDecodeError, RecursionError):
        print("Tailscale API returned a body that is not JSON", file=sys.stderr)
        sys.exit(1)
    except (KeyError, TypeError, AttributeError, ValueError, StopIteration) as e:
        print(f"Tailscale API returned a reply of an unexpected shape: {type(e).__name__}", file=sys.stderr)
        sys.exit(1)
