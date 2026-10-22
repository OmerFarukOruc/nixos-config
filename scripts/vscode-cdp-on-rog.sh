#!/usr/bin/env bash
# usage: scripts/vscode-cdp-on-rog.sh on|off|run STEPS_JSON
# Drives VS Code on nixos-rog from nixos-desktop over the Chrome DevTools
# Protocol. `on` starts VS Code with a debugging port on the laptop's loopback
# and tunnels it to 127.0.0.1:19229 here. `run` sends steps to the window and
# prints one JSON line per step. `off` closes the tunnel. docs/nixos-rog.md,
# "Drive VS Code", lists the steps and when to use the script.
set -euo pipefail

remote_port=9229
local_port=19229
pidfile=${XDG_RUNTIME_DIR:-/tmp}/vscode-cdp-on-rog.pid
ssh_opts=(-o ConnectTimeout=15 -o BatchMode=yes)

on() {
  if curl -sf "http://127.0.0.1:$local_port/json/version" >/dev/null; then
    echo "http://127.0.0.1:$local_port"
    return
  fi
  ssh "${ssh_opts[@]}" nixos-rog bash -s -- "$remote_port" <<'EOF'
set -euo pipefail
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
# Stopping VS Code here raises its quit dialogs, and a forced stop loses the
# open window, so the user closes it.
if pgrep -u "$(id -u)" -f '[/]lib/vscode/code' >/dev/null; then
  echo "Close VS Code on nixos-rog first; this script never stops it." >&2
  exit 1
fi
systemctl --user stop vscode-cdp.service 2>/dev/null || true
# The code launcher starts VS Code and exits, so the unit keeps running after
# its main process ends and stops only that process.
systemd-run --user --quiet --unit=vscode-cdp -p KillMode=process \
  -p RemainAfterExit=yes -p Slice=app.slice "$(command -v code)" \
  --remote-debugging-port="$1" --remote-debugging-address=127.0.0.1
for _ in $(seq 40); do
  curl -sf "http://127.0.0.1:$1/json/version" >/dev/null && exit 0
  sleep 1
done
echo "VS Code did not open its debugging port within 40 s." >&2
exit 1
EOF
  ssh "${ssh_opts[@]}" -N -o ExitOnForwardFailure=yes \
    -L "127.0.0.1:$local_port:127.0.0.1:$remote_port" nixos-rog </dev/null >/dev/null 2>&1 &
  echo $! >"$pidfile"
  disown
  for _ in $(seq 20); do
    if curl -sf "http://127.0.0.1:$local_port/json/version" >/dev/null; then
      echo "http://127.0.0.1:$local_port"
      return
    fi
    sleep 0.5
  done
  echo "The tunnel to nixos-rog did not open within 10 s." >&2
  exit 1
}

off() {
  if [[ -f $pidfile ]]; then
    pid=$(<"$pidfile")
    if ps -p "$pid" -o args= | grep -q "^ssh .*127.0.0.1:$local_port:"; then
      kill "$pid"
    fi
    rm -f -- "$pidfile"
  fi
  ssh "${ssh_opts[@]}" nixos-rog bash -s <<'EOF'
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
systemctl --user stop vscode-cdp.service 2>/dev/null || true
EOF
  echo "Quit VS Code on nixos-rog to close its debugging port."
}

run() {
  local js
  read -r -d '' js <<'EOF' || true
import { writeFileSync } from 'node:fs';
const [port, stepsJson] = process.argv.slice(1);
const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const page = targets.find((t) => t.type === 'page');
if (!page) throw new Error('VS Code has no window to drive');
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  ws.addEventListener('open', resolve, { once: true });
  ws.addEventListener('error', reject, { once: true });
});
let id = 0;
const pending = new Map();
ws.addEventListener('message', (event) => {
  const message = JSON.parse(event.data);
  pending.get(message.id)?.(message);
  pending.delete(message.id);
});
const call = (method, params = {}) =>
  new Promise((resolve, reject) => {
    const callId = ++id;
    pending.set(callId, (m) => (m.error ? reject(new Error(`${method}: ${m.error.message}`)) : resolve(m.result)));
    ws.send(JSON.stringify({ id: callId, method, params }));
  });
const keyCodes = { Enter: 13, Escape: 27, Tab: 9, End: 35, Home: 36, ArrowDown: 40, ArrowUp: 38, F1: 112 };
for (const step of JSON.parse(stepsJson)) {
  if ('eval' in step) {
    const r = await call('Runtime.evaluate', { expression: step.eval, returnByValue: true, awaitPromise: true });
    console.log(JSON.stringify(r.exceptionDetails ? { exception: r.exceptionDetails.text } : { value: r.result.value }));
  } else if ('key' in step) {
    const k = { key: step.key, code: step.key, windowsVirtualKeyCode: keyCodes[step.key] };
    if (k.windowsVirtualKeyCode === undefined) throw new Error(`unknown key ${step.key}`);
    await call('Input.dispatchKeyEvent', { type: 'rawKeyDown', ...k });
    await call('Input.dispatchKeyEvent', { type: 'keyUp', ...k });
    console.log(JSON.stringify({ key: step.key }));
  } else if ('text' in step) {
    await call('Input.insertText', { text: step.text });
    console.log(JSON.stringify({ text: step.text.length }));
  } else if ('click' in step) {
    const [x, y] = step.click;
    for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased']) {
      await call('Input.dispatchMouseEvent', { type, x, y, button: 'left', clickCount: 1 });
    }
    console.log(JSON.stringify({ click: step.click }));
  } else if ('shot' in step) {
    const r = await call('Page.captureScreenshot', { format: 'png' });
    writeFileSync(step.shot, Buffer.from(r.data, 'base64'));
    console.log(JSON.stringify({ shot: step.shot }));
  } else if ('sleep' in step) {
    await new Promise((resolve) => setTimeout(resolve, step.sleep));
    console.log(JSON.stringify({ sleep: step.sleep }));
  } else {
    throw new Error(`unknown step ${JSON.stringify(step)}`);
  }
}
ws.close();
EOF
  node --input-type=module -e "$js" -- "$local_port" "$1"
}

case ${1:-} in
  on) on ;;
  off) off ;;
  run)
    (($# == 2)) || {
      echo "usage: $0 run STEPS_JSON" >&2
      exit 2
    }
    run "$2"
    ;;
  *)
    echo "usage: $0 on|off|run STEPS_JSON" >&2
    exit 2
    ;;
esac
