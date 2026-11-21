#!/usr/bin/env bash
marker=${STATE_DIRECTORY:?}/failed
if [ "${SERVICE_RESULT:?}" = success ]; then
  rm -f "$marker" "$STATE_DIRECTORY/rerun"
  exit 0
fi
if [ "${2:-}" = --rerun ] && [ "$(systemctl is-system-running 2>/dev/null)" = stopping ]; then
  date -u +%FT%TZ >"$STATE_DIRECTORY/rerun"
  exit 0
fi
printf 'the run at %s ended with result %s (%s %s), %s\n' \
  "$(date -u +%FT%TZ)" "$SERVICE_RESULT" "${EXIT_CODE:-no exit}" "${EXIT_STATUS:-}" "$1" >"$marker"
