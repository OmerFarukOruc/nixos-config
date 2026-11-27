#!/usr/bin/env bash
target="${ADB_PHONE:?ADB_PHONE names the phone as host:port}"
port="${ANDROID_ADB_SERVER_PORT:-5037}"

adb kill-server >/dev/null 2>&1 || true
adb nodaemon server &
server=$!

until (: </dev/tcp/127.0.0.1/"$port") 2>/dev/null; do
  kill -0 "$server" 2>/dev/null || exit 1
  sleep 0.2
done
echo "adb server listens on 127.0.0.1:$port; keeping $target connected"

last=""
stale_since=0
while kill -0 "$server" 2>/dev/null; do
  state=missing
  while read -r serial st _; do
    if [[ $serial == "$target" ]]; then
      state=$st
    fi
  done < <(adb devices 2>/dev/null)
  if [[ $state != "$last" ]]; then
    echo "$target: $state"
    last=$state
  fi
  case $state in
    device | unauthorized)
      stale_since=0
      ;;
    offline)
      now=$(date +%s)
      ((stale_since == 0)) && stale_since=$now
      if ((now - stale_since >= 60)); then
        adb disconnect "$target" >/dev/null 2>&1 || true
        stale_since=0
      fi
      ;;
    *)
      timeout 20 adb connect "$target" >/dev/null 2>&1 || true
      ;;
  esac
  sleep 10
done
echo "adb server exited"
exit 1
