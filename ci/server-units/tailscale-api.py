# A stand-in for the part of Tailscale's control API that fleet-bots-ts-name
# calls (https://tailscale.com/api): the OAuth token exchange, the device list,
# one device, and the rename of a device, with the fields that the helper
# reads. The helper runs on the Debian box against the real API with these
# fields, but the stand-in's replies are not copied from a live response, so
# the real API's shape stays unproven here. Tailnet state is a JSON file that the test writes and reads:
# {"devices": [...], "fail": bool, "log": [...]}. A device has name (the full
# DNS name), nodeId, addresses, tags and connectedToControl.
#
# usage: tailscale-api CERT KEY
import json
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

STATE = "/var/lib/tsapi/state.json"
# The values of ci/server-boot/secrets.yaml, which the host's sops template
# renders into the credential file.
CLIENT = ("test-client-id", "test-client-secret")
TOKEN = "tskey-api-test-token"
TAILNET = "tailnet-test.ts.net"
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def handle_request(self, method):
        url = urlsplit(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        with lock:
            with open(STATE) as f:
                state = json.load(f)
            state["log"].append(f"{method} {url.path}")
            code, answer = self.route(state, method, url.path, body)
            with open(STATE, "w") as f:
                json.dump(state, f)
        self.reply(code, answer)

    def route(self, state, method, path, body):
        if method == "POST" and path == "/api/v2/oauth/token":
            if state["fail"]:
                return 500, {"message": "the token endpoint fails on purpose"}
            form = parse_qs(body.decode())
            if (form.get("client_id"), form.get("client_secret")) != ([CLIENT[0]], [CLIENT[1]]):
                state["log"].append("token refused: wrong client")
                return 401, {"error": "invalid_client"}
            state["log"].append("token issued")
            return 200, {"access_token": TOKEN, "token_type": "Bearer", "expires_in": 3600}
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            return 401, {"message": "invalid token"}
        if method == "GET" and path == "/api/v2/tailnet/-/devices":
            return 200, {"devices": state["devices"]}
        parts = path.split("/")
        if len(parts) >= 5 and parts[:4] == ["", "api", "v2", "device"]:
            device = next((d for d in state["devices"] if d["nodeId"] == parts[4]), None)
            if device is None:
                return 404, {"message": "device not found"}
            if method == "GET" and len(parts) == 5:
                return 200, device
            if method == "POST" and parts[5:] == ["name"]:
                device["name"] = f"{json.loads(body)['name']}.{TAILNET}"
                return 200, {}
        return 404, {"message": "no such route"}

    def do_GET(self):
        self.handle_request("GET")

    def do_POST(self):
        self.handle_request("POST")

    def log_message(self, *args):
        pass


context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
server = ThreadingHTTPServer(("0.0.0.0", 443), Handler)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
