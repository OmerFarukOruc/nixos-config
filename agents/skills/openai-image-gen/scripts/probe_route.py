#!/usr/bin/env python3
"""
Send one raw image_generation request to the Codex route and print what it
answers, without saving the image.

  probe_route.py '{"model": "gpt-image-2.6-flare", "quality": "low"}'
  probe_route.py '{"quality": "low", "complexity": "low"}'
  probe_route.py '{"quality": "low"}' '{"reasoning": {"effort": "low"}}'

Argument 1 is merged into the image tool entry (action generate, size
1024x1024, output_format png are the defaults). Optional argument 2 is merged
into the top-level request; a null value removes that field.
"""

import json
import sys
import urllib.error
import urllib.request

import generate_image as gi

PROMPT = "A flat illustration of a single red apple on a plain white table."
ERROR_EVENTS = {"error", "response.failed", "response.incomplete"}


def main() -> int:
    if len(sys.argv) not in (2, 3):
        gi.die("Usage: probe_route.py TOOL_JSON [REQUEST_OVERRIDES_JSON]", code=2)
    tool = json.loads(sys.argv[1])
    overrides = json.loads(sys.argv[2]) if len(sys.argv) == 3 else {}
    report = gi.run_preflight(gi.DEFAULT_AUTH_FILE)
    if not report["ok"]:
        gi.print_preflight(report)
        gi.die("Preflight failed.", code=3)
    access_token, account_id, _ = gi.get_credentials(report["auth_data"])
    payload = gi.build_request(PROMPT, {"action": "generate", "size": "1024x1024", **tool}, [])
    for key, value in overrides.items():
        if value is None:
            payload.pop(key, None)
        else:
            payload[key] = value
    request = urllib.request.Request(
        gi.BACKEND_URL, data=json.dumps(payload).encode(),
        headers=gi.build_headers(access_token, account_id), method="POST")
    try:
        raw = urllib.request.urlopen(request, timeout=gi.TIMEOUT_SECONDS).read()
    except urllib.error.HTTPError as err:
        print(f"HTTP {err.code}: {err.read()[:400].decode(errors='replace')}")
        return 1
    errors = []
    for line in raw.split(b"\n"):
        if not line.startswith(b"data: "):
            continue
        try:
            event = json.loads(line[6:])
        except json.JSONDecodeError:
            continue
        if event.get("type") in ERROR_EVENTS:
            error = json.dumps(event.get("error") or event.get("response", {}).get("error"))
            if error not in errors:
                errors.append(error)
                print(f"{event['type']}: {error}")
        item = event.get("item") or {}
        if event.get("type") == "response.output_item.done" and item.get("type") == "image_generation_call":
            fields = {k: item.get(k) for k in ("status", "action", "background", "output_format", "quality", "size", "model")}
            print(f"image: {json.dumps(fields)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
