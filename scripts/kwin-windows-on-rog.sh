#!/usr/bin/env bash
# usage: scripts/kwin-windows-on-rog.sh
# Prints one JSON object per window of the Plasma session on nixos-rog.
# Glass's WindowClasses list matches resourceClass or resourceName exactly.
set -euo pipefail

ssh -o ConnectTimeout=15 -o BatchMode=yes nixos-rog bash -s <<'EOF'
set -euo pipefail
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
# KWin's print() writes to the user journal, so a marker picks out the lines
# of this run.
marker=kwin-windows-$$-$RANDOM
dir=$(mktemp -d /tmp/kwin-windows.XXXXXX)
cleanup() {
  busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting \
    unloadScript s "$marker" >/dev/null 2>&1 || true
  rm -rf -- "$dir"
}
trap cleanup EXIT
cat >"$dir/list.js" <<JS
for (const w of workspace.windowList()) {
  print("$marker " + JSON.stringify({
    resourceClass: w.resourceClass,
    resourceName: w.resourceName,
    caption: w.caption,
    desktopFileName: w.desktopFileName,
    normalWindow: w.normalWindow,
    minimized: w.minimized,
  }));
}
print("$marker end");
JS
since=$(date +%s)
id=$(busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting \
  loadScript ss "$dir/list.js" "$marker" | cut -d' ' -f2)
busctl --user call org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script run
for _ in $(seq 20); do
  lines=$(journalctl --user --since "@$since" --no-pager -o cat | grep -F "$marker " || true)
  if grep -q "$marker end\$" <<<"$lines"; then
    grep -v "$marker end\$" <<<"$lines" | sed "s/^.*$marker //"
    exit 0
  fi
  sleep 0.5
done
echo "KWin printed no window list within 10 s." >&2
exit 1
EOF
