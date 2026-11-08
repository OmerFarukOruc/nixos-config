#!/usr/bin/env python3
"""
Generate or edit images with the image_generation tool of the ChatGPT backend
Responses API, authenticating with the Codex login in ~/.codex/auth.json.

Endpoint: https://chatgpt.com/backend-api/codex/responses (SSE stream; the
image arrives as base64 in the completed image_generation_call output).

Modes:
  generation (default)    text-only prompt
  --reference PATH        repeatable; each image guides subject and style, tool action "auto"
  --style-reference PATH  one image, tool action "edit", with a style-preserving prefix

CLI:
  --prompt "..." | --prompt-file PATH
  --output PATH            output WebP path; directory is created if missing
  --size WxH | auto        default 1536x1024; multiples of 16, edges <= 3840,
                           ratio <= 3:1, 655,360 to 8,294,400 pixels
  --quality LEVEL          low | medium | high | xhigh | max | auto (default medium)
  --image-model MODEL      gpt-image-2.6-sunburst (default) | gpt-image-2.6-flare
  --background MODE        auto | opaque | transparent
  --n COUNT                variations 1-10 (default 1); suffixed -1, -2, ...
  --keep-png               also save the response PNG next to the WebP
  --preflight              run auth diagnostics only, then exit
  --auth-file PATH         override ~/.codex/auth.json

The WebP is a re-encoded copy; --keep-png keeps the response bytes. Each image
has an <output>.json report. The route does not report the image model, so the
report holds requested_model unverified. Exit 5 means files were saved but a
requested setting mismatched or could not be verified.
"""

import argparse
import base64
import http.client
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from io import BytesIO
from pathlib import Path
from typing import NoReturn

try:
    from PIL import Image
except ImportError:
    print("ERROR: Pillow (PIL) is required.", file=sys.stderr)
    print("Install with: pip install --user Pillow  (or: pacman -S python-pillow)", file=sys.stderr)
    sys.exit(2)


VALID_QUALITY = {"low", "medium", "high", "xhigh", "max", "auto"}
VALID_BACKGROUND = {"auto", "opaque", "transparent"}
RESPONSES_MODEL = "gpt-6-astra"
IMAGE_TOOL_MODEL = "gpt-image-2.6-sunburst"
IMAGE_TOOL_MODELS = (IMAGE_TOOL_MODEL, "gpt-image-2.6-flare")
BACKEND_URL = "https://chatgpt.com/backend-api/codex/responses"
TIMEOUT_SECONDS = 300
DEFAULT_AUTH_FILE = Path.home() / ".codex" / "auth.json"

STYLE_LOCK_PREFIX = (
    "Use the same visual style as the reference image (palette, lighting "
    "direction and quality, surfaces, depth of field, grain, color grading). "
    "Apply the new scene and subject described below. Preserve all visual "
    "invariants of the reference image.\n\n"
)


def die(message: str, code: int = 1) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(code)


def run_preflight(auth_file: Path) -> dict:
    report: dict = {"ok": True, "checks": [], "auth_data": {}}

    def check(name: str, passed: bool, message: str, fix: str = "") -> None:
        if not passed:
            report["ok"] = False
        report["checks"].append({
            "name": name,
            "passed": passed,
            "message": message,
            "fix": fix,
        })

    if not auth_file.exists():
        check("auth_file_exists", False,
              f"Auth file not found: {auth_file}",
              "Run `codex login` to create it, or pass --auth-file with the correct path.")
        return report
    check("auth_file_exists", True, f"Found: {auth_file}")

    try:
        data = json.loads(auth_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError as err:
        check("auth_json_valid", False,
              f"Invalid JSON in {auth_file}: {err}",
              "The file is corrupt. Run `codex login` to regenerate it.")
        return report
    if not isinstance(data, dict):
        check("auth_json_valid", False,
              f"{auth_file} does not hold a JSON object.",
              "The file is corrupt. Run `codex login` to regenerate it.")
        return report
    report["auth_data"] = data
    check("auth_json_valid", True, "Valid JSON")

    tokens = auth_tokens(data)
    access_token = tokens.get("access_token", "")
    refresh_token = tokens.get("refresh_token", "")
    account_id = tokens.get("account_id", "")

    if not access_token:
        check("access_token_present", False,
              "No access_token in auth.json.",
              "Run `codex login`; the session has expired.")
    else:
        check("access_token_present", True, "access_token found")

    if access_token:
        try:
            exp = decode_jwt_claims(access_token).get("exp", 0)
            now = time.time()
            if exp < now:
                new_access = refresh_access_token(auth_file, refresh_token) if refresh_token else None
                if new_access:
                    access_token = new_access
                    data = json.loads(auth_file.read_text(encoding="utf-8"))
                    report["auth_data"] = data
                    check("token_not_expired", True, "Expired access token refreshed.")
                else:
                    check("token_not_expired", False,
                          "Access token is expired and could not refresh.",
                          "Run `codex login` to create a fresh session.")
            else:
                remaining = exp - now
                check("token_not_expired", True,
                      f"Token valid for {remaining:.0f}s (expires {time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(exp))}).")
        except (IndexError, ValueError, TypeError, OverflowError, OSError):
            check("token_not_expired", True,
                  "Could not decode JWT expiry (non-fatal).")

    if not refresh_token:
        check("refresh_token_present", False,
              "No refresh_token in auth.json.",
              "Without a refresh token, an expired access token means re-login. Run `codex login`.")
    else:
        check("refresh_token_present", True, "refresh_token found")

    if not account_id:
        check("account_id_present", False,
              "No account_id in auth.json.",
              "The ChatGPT backend requires this header. Run `codex login` to get a fresh session.")
    else:
        check("account_id_present", True, "account_id found")

    if access_token and account_id:
        try:
            ping_payload = json.dumps({
                "model": RESPONSES_MODEL,
                "instructions": "reply with ok",
                "input": [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "ok"}]}],
                "stream": True,
                "store": False,
            }).encode()
            ping_req = urllib.request.Request(
                BACKEND_URL,
                data=ping_payload,
                headers={
                    "Authorization": f"Bearer {access_token}",
                    "Content-Type": "application/json",
                    "Accept": "text/event-stream",
                    "Chatgpt-Account-Id": account_id,
                    "User-Agent": "Mozilla/5.0",
                },
                method="POST",
            )
            with urllib.request.urlopen(ping_req, timeout=15) as resp:
                if resp.status == 200:
                    check("backend_reachable", True,
                          "Backend reachable with valid authentication.")
                else:
                    check("backend_reachable", False,
                          f"Unexpected HTTP {resp.status}.",
                          "Check the selected account and retry.")
        except urllib.error.HTTPError as err:
            err.read()
            if err.code == 401:
                check("backend_reachable", False,
                      "HTTP 401: token rejected by backend.",
                      "The access token is invalid or expired. The script will attempt auto-refresh. "
                      "If that fails, run `codex login`.")
            elif err.code == 429:
                check("backend_reachable", True,
                      "HTTP 429: rate limited. Backend reachable, auth valid.")
            elif err.code == 403:
                check("backend_reachable", False,
                      "HTTP 403 - permission denied.",
                      "Your ChatGPT account may not have access to the Responses API. "
                      "Check your subscription at https://chatgpt.com/account.")
            else:
                check("backend_reachable", False,
                      f"HTTP {err.code} from the backend.",
                      "Unexpected response. Check your network and retry.")
        except urllib.error.URLError as err:
            check("backend_reachable", False,
                  f"Cannot reach chatgpt.com: {err.reason}",
                  "Check your internet connection. If you're on a VPN, verify "
                  "chatgpt.com is reachable.")
        except (OSError, http.client.HTTPException) as err:
            check("backend_reachable", False,
                  f"Connectivity check failed: {err}",
                  "Unexpected error. Retry or check your network.")

    return report


def print_preflight(report: dict) -> None:
    print("\n" + "=" * 60, file=sys.stderr)
    print("  PREFLIGHT REPORT", file=sys.stderr)
    print("=" * 60, file=sys.stderr)

    for c in report["checks"]:
        icon = "✓" if c["passed"] else "✗"
        print(f"  {icon} {c['name']}: {c['message']}", file=sys.stderr)
        if not c["passed"] and c.get("fix"):
            print(f"    FIX: {c['fix']}", file=sys.stderr)

    print("=" * 60, file=sys.stderr)
    if report["ok"]:
        print("  All checks passed.", file=sys.stderr)
    else:
        print("  Some checks failed. See FIX lines above.", file=sys.stderr)
    print("=" * 60 + "\n", file=sys.stderr)


def auth_tokens(data: object) -> dict:
    tokens = data.get("tokens") if isinstance(data, dict) else None
    return tokens if isinstance(tokens, dict) else {}


def load_auth(auth_file: Path) -> dict:
    if not auth_file.exists():
        die(
            f"Auth file not found: {auth_file}\n"
            "FIX: Run `codex login` to create it.",
            code=3,
        )
    try:
        data = json.loads(auth_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError as err:
        die(
            f"Invalid JSON in {auth_file}: {err}\n"
            "FIX: The file is corrupt. Run `codex login` to regenerate it.",
            code=3,
        )
    if not isinstance(data, dict):
        die(
            f"{auth_file} does not hold a JSON object.\n"
            "FIX: The file is corrupt. Run `codex login` to regenerate it.",
            code=3,
        )
    return data


def get_credentials(data: dict) -> tuple[str, str, str]:
    tokens = auth_tokens(data)
    access_token = tokens.get("access_token", "")
    if not access_token:
        die(
            "No access_token in auth.json.\n"
            "FIX: Run `codex login`; the session has expired.",
            code=3,
        )
    account_id = tokens.get("account_id", "")
    if not account_id:
        die(
            "No account_id in auth.json.\n"
            "FIX: The session data is incomplete. Run `codex login`.",
            code=3,
        )
    refresh_token = tokens.get("refresh_token", "")
    return access_token, account_id, refresh_token


def decode_jwt_claims(token: object) -> dict:
    if not isinstance(token, str):
        raise TypeError("JWT is not a string")
    payload_b64 = token.split(".")[1]
    payload_b64 += "=" * (4 - len(payload_b64) % 4)
    claims = json.loads(base64.urlsafe_b64decode(payload_b64))
    if not isinstance(claims, dict):
        raise TypeError("JWT payload is not an object")
    return claims


def refresh_access_token(auth_file: Path, refresh_token: str) -> str | None:
    try:
        data = json.loads(auth_file.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None

    id_token = auth_tokens(data).get("id_token", "")
    client_id = "app_EMoamEEZ73f0CkXaXp7hrann"
    if id_token:
        try:
            aud = decode_jwt_claims(id_token).get("aud", [])
            if isinstance(aud, list) and aud:
                client_id = aud[0]
        except (IndexError, ValueError, TypeError):
            pass

    refresh_payload = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": client_id,
    }).encode()

    req = urllib.request.Request(
        "https://auth.openai.com/oauth/token",
        data=refresh_payload,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read())
    except (OSError, http.client.HTTPException, ValueError):
        return None
    if not isinstance(result, dict):
        return None

    new_access = result.get("access_token")
    new_refresh = result.get("refresh_token")

    if not new_access:
        return None

    tokens = data["tokens"] = auth_tokens(data)
    tokens["access_token"] = new_access
    if new_refresh:
        tokens["refresh_token"] = new_refresh
    data["last_refresh"] = time.strftime("%Y-%m-%dT%H:%M:%S.000000Z", time.gmtime())

    try:
        tmp_path: Path | None = None
        auth_mode = auth_file.stat().st_mode & 0o777
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=auth_file.parent,
            prefix=".auth-refresh-",
            delete=False,
        ) as tmp:
            tmp.write(json.dumps(data, indent=2))
            tmp.flush()
            os.fsync(tmp.fileno())
            tmp_path = Path(tmp.name)
        os.chmod(tmp_path, auth_mode)
        os.replace(tmp_path, auth_file)
    except OSError:
        if tmp_path is not None:
            tmp_path.unlink(missing_ok=True)

    return new_access


def validate_size(size: str) -> str:
    if size == "auto":
        return size
    try:
        w_str, h_str = size.lower().split("x")
        w, h = int(w_str), int(h_str)
    except (ValueError, AttributeError):
        die(f"Invalid --size: {size!r} (expected WxH, e.g. 1536x1024).")
    if w <= 0 or h <= 0:
        die(f"Invalid --size: dimensions must be positive (got {w}x{h}).")
    if w % 16 != 0 or h % 16 != 0:
        die(f"Invalid --size: both edges must be multiples of 16 (got {w}x{h}).")
    if w > 3840 or h > 3840:
        die(f"Invalid --size: max edge must be <=3840 (got {w}x{h}).")
    if max(w, h) > 3 * min(w, h):
        die(f"Invalid --size: ratio must be <=3:1 (got {w}x{h}).")
    total = w * h
    if total < 655_360:
        die(f"Invalid --size: total pixels must be >=655360 (got {total}).")
    if total > 8_294_400:
        die(f"Invalid --size: total pixels must be <=8294400 (got {total}).")
    return f"{w}x{h}"


def validate_n(n: int) -> int:
    if n < 1 or n > 10:
        die(f"Invalid --n: must be between 1 and 10 (got {n}).")
    return n


def load_prompt(args: argparse.Namespace) -> str:
    if args.prompt and args.prompt_file:
        die("Pass --prompt OR --prompt-file, not both.")
    if args.prompt:
        return args.prompt
    if args.prompt_file:
        path = Path(args.prompt_file).expanduser()
        if not path.exists():
            die(f"Prompt file not found: {path}")
        return path.read_text(encoding="utf-8").strip()
    die("Either --prompt or --prompt-file is required.")


def image_to_data_url(image_path: Path) -> str:
    if not image_path.is_file():
        die(f"Reference image not found: {image_path}")
    mime_map = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                 ".webp": "image/webp", ".gif": "image/gif"}
    mime_type = mime_map.get(image_path.suffix.lower())
    if mime_type is None:
        die(f"Reference image must be PNG, JPEG, WebP, or GIF: {image_path}")
    data = image_path.read_bytes()
    return f"data:{mime_type};base64," + base64.b64encode(data).decode()


def build_headers(access_token: str, account_id: str, stream: bool = True) -> dict:
    return {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream" if stream else "application/json",
        "Chatgpt-Account-Id": account_id,
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
        "Originator": "codex",
    }


def build_request(prompt: str, tool: dict, image_urls: list[str]) -> dict:
    return {
        "model": RESPONSES_MODEL,
        "instructions": prompt,
        "input": [{
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": prompt}] + [
                {"type": "input_image", "image_url": url} for url in image_urls],
        }],
        "tools": [{"type": "image_generation", "output_format": "png", **tool}],
        "tool_choice": {"type": "image_generation"},
        "stream": True,
        "store": False,
    }


def parse_sse_response(raw: bytes) -> list[dict]:
    output_items: dict[int, dict] = {}
    fallback_items: list[dict] = []
    completed = None

    for line in raw.split(b"\n"):
        if not line.startswith(b"data: "):
            continue
        event_json = line[6:]
        try:
            event = json.loads(event_json)
        except json.JSONDecodeError:
            continue

        ev_type = event.get("type", "")

        if ev_type == "response.output_item.done":
            item = event.get("item")
            if item:
                idx = event.get("output_index")
                if idx is not None:
                    output_items[idx] = item
                else:
                    fallback_items.append(item)

        elif ev_type in {"response.failed", "response.incomplete", "error"}:
            die(f"Backend stream reported {ev_type}.", code=4)
        elif ev_type == "response.completed":
            completed = event

    if completed is None:
        die("Backend stream ended without a response.completed event.", code=4)

    response = completed.get("response", {})
    if response.get("error") or response.get("status") not in (None, "completed"):
        die("Backend response did not complete successfully.", code=4)
    outputs = response.get("output", [])

    if not outputs and (output_items or fallback_items):
        outputs = [output_items[i] for i in sorted(output_items)]
        outputs.extend(fallback_items)

    images: list[dict] = []
    for item in outputs:
        if item.get("type") != "image_generation_call":
            continue
        result = item.get("result", "")
        if result:
            if item.get("status") != "completed":
                die("Image tool did not report completion.", code=4)
            enums = {
                "quality": VALID_QUALITY,
                "background": VALID_BACKGROUND,
                "output_format": {"png", "webp", "jpeg"},
                "action": {"generate", "edit"},
            }
            metadata = {key: item.get(key) if item.get(key) in allowed else None
                        for key, allowed in enums.items() if isinstance(item.get(key), (str, type(None)))}
            size = item.get("size")
            parts = size.split("x") if isinstance(size, str) else []
            metadata["size"] = (size if len(parts) == 2 and all(
                part.isascii() and part.isdigit() for part in parts
            ) else None)
            images.append({"result": result, "metadata": metadata})

    if not images:
        die("Backend returned no images. The model may have refused the prompt.", code=4)

    return images


def image_report(png_bytes: bytes, returned: dict, requested: dict) -> dict:
    with Image.open(BytesIO(png_bytes)) as image:
        image.load()
        actual = {"size": f"{image.width}x{image.height}",
                  "output_format": image.format.lower()}
        if requested.get("background") == "transparent":
            alpha = image.convert("RGBA").getchannel("A")
            actual["transparent_pixels"] = alpha.getextrema()[0] < 255
    mismatches = []
    unverified = []
    for field, expected in requested.items():
        observed = returned.get(field)
        if observed is None or observed == "auto":
            unverified.append(field)
        elif expected != "auto" and observed != expected:
            mismatches.append(f"returned.{field}")
    if actual.get("transparent_pixels") is False:
        mismatches.append("actual.transparent_pixels")
    for field, observed in actual.items():
        if field == "transparent_pixels":
            continue
        if requested[field] != "auto" and observed != requested[field]:
            mismatches.append(f"actual.{field}")
        if returned.get(field) is not None and returned[field] != observed:
            mismatches.append(f"returned_vs_actual.{field}")
    status = "mismatch" if mismatches else "unverified" if unverified else "verified"
    return {"requested": requested, "returned": returned, "actual": actual,
            "status": status, "mismatches": mismatches, "unverified": unverified}


def call_api_with_retry(
    access_token: str, account_id: str, refresh_token: str,
    auth_file: Path, payload: dict,
) -> bytes:
    token = access_token

    for attempt in range(2):
        body = json.dumps(payload).encode("utf-8")
        headers = build_headers(token, account_id, stream=True)
        req = urllib.request.Request(BACKEND_URL, data=body, headers=headers, method="POST")

        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
                return resp.read()
        except urllib.error.HTTPError as err:
            detail = err.read().decode("utf-8", errors="replace")[:800]

            if err.code == 401 and attempt == 0 and refresh_token:
                print("Access token expired; attempting refresh...", file=sys.stderr)
                new_token = refresh_access_token(auth_file, refresh_token)
                if not new_token:
                    die(
                        "Token refresh failed.\n"
                        "FIX: Run `codex login` to get a fresh session, then retry.",
                        code=3,
                    )
                token = new_token
                print("Token refreshed successfully.", file=sys.stderr)
                continue

            if err.code == 429:
                try:
                    err_data = json.loads(detail) if detail.strip().startswith("{") else {}
                    error_info = err_data.get("error", {})
                    resets_in = error_info.get("resets_in_seconds", 0)
                    resets_at = error_info.get("resets_at", 0)
                    if resets_in:
                        mins = resets_in // 60
                        die(
                            f"Rate limit reached. Resets in {mins}min {resets_in % 60}s.\n"
                            f"FIX: Wait {mins // 60}h{mins % 60}m and retry. "
                            f"Or switch to --quality low for a lighter request.",
                            code=4,
                        )
                    if resets_at:
                        reset_time = time.strftime("%H:%M:%S", time.localtime(resets_at))
                        die(
                            f"Rate limit reached. Resets at {reset_time}.\n"
                            f"FIX: Wait until then and retry.",
                            code=4,
                        )
                except (ValueError, AttributeError, TypeError):
                    pass
                die(
                    "HTTP 429: rate limit reached.\n"
                    "FIX: Wait a few minutes and retry. Your ChatGPT Team plan has "
                    "usage caps that reset periodically.",
                    code=4,
                )

            die(f"HTTP {err.code} from backend.\nFIX: Check the selected account and retry.", code=4)

        except urllib.error.URLError as err:
            die(
                f"Cannot reach {BACKEND_URL}: {err.reason}\n"
                f"FIX: Check your internet connection. If you're on a VPN, verify "
                f"chatgpt.com is reachable.",
                code=4,
            )

        except (OSError, http.client.HTTPException) as err:
            die(
                f"Connection to the backend failed while reading the response ({type(err).__name__}).\n"
                "FIX: The image may have been generated on the server and counted against "
                "your usage. Retry only if another request is acceptable.",
                code=4,
            )

    die("Unreachable.", code=4)


def output_paths(base_output: Path, count: int) -> list[Path]:
    if count == 1:
        return [base_output]
    stem = base_output.stem
    suffix = base_output.suffix
    return [base_output.with_name(f"{stem}-{i + 1}{suffix}") for i in range(count)]


def save_webp(png_bytes: bytes, output_path: Path, keep_png: bool) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(BytesIO(png_bytes)) as image:
        image.load()
        image.save(output_path, format="WEBP", quality=88, method=6)
    if keep_png:
        png_path = output_path.with_suffix(".png")
        png_path.write_bytes(png_bytes)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate images via ChatGPT backend using Codex OAuth tokens.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--prompt", help="Prompt text (use --prompt-file for long prompts).")
    parser.add_argument("--prompt-file", help="Read the prompt from a file.")
    parser.add_argument("--output", required=True, help="Output WebP path (suffixed -1, -2, ... when --n > 1).")
    parser.add_argument("--size", default="1536x1024",
                        help="WxH (default 1536x1024). Edges <=3840, multiples of 16, ratio <=3:1.")
    parser.add_argument("--quality", default="medium", choices=sorted(VALID_QUALITY))
    parser.add_argument("--image-model", default=IMAGE_TOOL_MODEL, choices=IMAGE_TOOL_MODELS,
                        help="Image generator (default: %(default)s).")
    parser.add_argument("--background", choices=sorted(VALID_BACKGROUND),
                        help="Background handling; transparent keeps the alpha channel (omitted: the model default).")
    parser.add_argument("--n", type=int, default=1, help="Variations (1-10, default 1).")
    parser.add_argument("--reference", action="append", default=[],
                        help="Reference image for guided generation; repeat for several. Not with --style-reference.")
    parser.add_argument("--style-reference", help="Reference image for visual style anchoring (edit mode).")
    parser.add_argument("--keep-png", action="store_true", help="Also save raw PNG next to WebP.")
    parser.add_argument("--preflight", action="store_true", help="Run auth diagnostics only, then exit.")
    parser.add_argument("--auth-file", default=str(DEFAULT_AUTH_FILE),
                        help=f"Path to Codex auth.json (default: {DEFAULT_AUTH_FILE}).")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    auth_file = Path(args.auth_file).expanduser()

    if args.preflight:
        report = run_preflight(auth_file)
        print_preflight(report)
        return 0 if report["ok"] else 1

    if args.reference and args.style_reference:
        die("Use --reference or --style-reference, not both.")
    references = [Path(r).expanduser().resolve() for r in args.reference]
    reference_urls = [image_to_data_url(path) for path in references]
    if args.style_reference:
        image_to_data_url(Path(args.style_reference).expanduser().resolve())

    report = run_preflight(auth_file)
    if not report["ok"]:
        print_preflight(report)
        die(
            "Preflight failed. Fix the issues above and retry.\n"
            "Tip: Run with --preflight to diagnose without attempting generation.",
            code=3,
        )
    print("Preflight passed.", file=sys.stderr)

    size = validate_size(args.size)
    n = validate_n(args.n)
    prompt = load_prompt(args)
    if not prompt.strip():
        die("Prompt is empty.")

    auth_data = report["auth_data"]
    access_token, account_id, refresh_token = get_credentials(auth_data)

    output_path = Path(args.output).expanduser().resolve()
    paths = output_paths(output_path, n)
    destinations = [p for target in paths for p in
                    ([target, Path(str(target) + ".json")] +
                     ([target.with_suffix(".png")] if args.keep_png else []))]
    if len(set(destinations)) != len(destinations):
        die("Output and sidecar paths overlap.")
    for destination in destinations:
        if destination.exists():
            die(f"Output already exists: {destination}")

    action = "edit" if args.style_reference else "auto" if references else "generate"
    tool = {"action": action, "model": args.image_model, "size": size, "quality": args.quality}
    if args.background:
        tool["background"] = args.background
    if args.style_reference:
        reference_path = Path(args.style_reference).expanduser().resolve()
        wrapped_prompt = STYLE_LOCK_PREFIX + prompt
        image_urls = [image_to_data_url(reference_path)]
        reference_note = f"reference={reference_path.name}"
    else:
        wrapped_prompt = prompt
        image_urls = reference_urls
        reference_note = f"references={len(references)}"
    print(
        f"Calling ChatGPT backend ({action}): model={args.image_model} size={size} quality={args.quality} "
        f"background={args.background or 'default'} n={n} "
        f"{reference_note}",
        file=sys.stderr,
    )
    payload = build_request(wrapped_prompt, tool, image_urls)

    exit_code = 0
    saved = 0
    try:
        for i, target in enumerate(paths):
            if n > 1:
                print(f"Requesting image {i + 1}/{n}...", file=sys.stderr)
            print("Waiting for response...", file=sys.stderr)
            raw = call_api_with_retry(access_token, account_id, refresh_token, auth_file, payload)
            generated = parse_sse_response(raw)
            if len(generated) != 1:
                die("Expected one image per request.", code=4)
            png_bytes = base64.b64decode(generated[0]["result"])
            requested = {"quality": args.quality, "size": size, "output_format": "png", "action": action}
            if args.background:
                requested["background"] = args.background
            evidence = image_report(png_bytes, generated[0]["metadata"], requested)
            evidence["requested_model"] = args.image_model
            save_webp(png_bytes, target, args.keep_png)
            metadata_path = Path(str(target) + ".json")
            metadata_path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
            saved += 1
            print(f"Saved {target}; settings: {evidence['status']}; report: {metadata_path}", file=sys.stderr)
            print(json.dumps(evidence), file=sys.stderr)
            print(str(target))
            if evidence["status"] != "verified":
                exit_code = 5
    finally:
        if n > 1 and saved < n:
            print(f"Stopped after saving {saved} of {n} images; the saved images and reports are kept.",
                  file=sys.stderr)

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
