#!/usr/bin/env bash

set -euo pipefail

SERVICE_DIR=$(cd "$(dirname "$0")" && pwd)
STATE="${THREADSIFT_STATE_DIR:-$HOME/.local/state/threadsift}"
KEEP_BACKUPS=7
WAIT_SECONDS=120
HOLD_PROBES=3
HOLD_SECONDS=10

if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "${XDG_RUNTIME_DIR:-}" ]; then
  echo "threadsift-up: XDG_RUNTIME_DIR is unset or not a directory" >&2
  exit 78
fi
if [ "${1:-}" != stop ] && { [ -z "${THREADSIFT_SECRET_KEY:-}" ] || [ -z "${SETUP_CODE:-}" ] || [ -z "${TUNNEL_TOKEN:-}" ]; }; then
  echo "threadsift-up: a sops secret is missing; start it through threadsift.service" >&2
  exit 78
fi

export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
export COMPOSE_PROJECT_NAME=threadsift COMPOSE_FILE="$SERVICE_DIR/compose.yml"
export THREADSIFT_DATA_PATH="$STATE/data"
: "${THREADSIFT_SECRET_KEY:=stop}" "${SETUP_CODE:=stop}" "${TUNNEL_TOKEN:=stop}"
export THREADSIFT_SECRET_KEY SETUP_CODE TUNNEL_TOKEN
export THREADSIFT_IMAGE=unset

set -a
# shellcheck disable=SC1091
. "$SERVICE_DIR/env.public"
set +a

LOCAL_REPO=localhost/threadsift
BACKUPS="$STATE/backups"
GOOD="$STATE/good-image"
REJECTED="$STATE/rejected-image"

image_id() {
  docker image inspect --format '{{.Id}}' "$1"
}

describe() {
  docker image inspect --format '{{.Id}} {{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$1"
}

running_image_id() {
  docker inspect --format '{{.Image}}' threadsift 2>/dev/null
}

local_name() {
  local hex=${1#sha256:}
  echo "$LOCAL_REPO:${hex:0:12}"
}

use_image() {
  THREADSIFT_IMAGE=$(local_name "$1")
  export THREADSIFT_IMAGE
  docker tag "$1" "$THREADSIFT_IMAGE"
}

good_image_id() {
  local id
  id=$(cat "$GOOD" 2>/dev/null || true)
  if [ -n "$id" ] && image_id "$id" >/dev/null 2>&1; then
    echo "$id"
    return
  fi
  if ! image_id "$THREADSIFT_SOURCE_IMAGE" >/dev/null 2>&1; then
    docker pull -q "$THREADSIFT_SOURCE_IMAGE" >/dev/null
  fi
  image_id "$THREADSIFT_SOURCE_IMAGE"
}

app_answers() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$THREADSIFT_PORT/api/session")" = 200 ]
}

tunnel_ready() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$THREADSIFT_TUNNEL_PORT/ready")" = 200 ]
}

ready() {
  app_answers && tunnel_ready
}

restart_count() {
  docker inspect --format '{{.RestartCount}}' threadsift
}

wait_ready() {
  local deadline=$((SECONDS + WAIT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ready; then
      return 0
    fi
    sleep 2
  done
  echo "threadsift-up: GET /api/session and the tunnel's /ready did not both answer 200 within ${WAIT_SECONDS}s" >&2
  return 1
}

hold_window() {
  local restarts probe
  restarts=$(restart_count)
  for ((probe = 0; probe < HOLD_PROBES; probe++)); do
    sleep "$HOLD_SECONDS"
    if ! ready || [ "$(restart_count)" != "$restarts" ]; then
      echo "threadsift-up: the app or the tunnel stopped answering, or restarted, within ${HOLD_PROBES}x${HOLD_SECONDS}s after its first 200" >&2
      return 1
    fi
  done
}

up_stack() {
  mkdir -p "$STATE/data" "$BACKUPS"
  chmod 700 "$STATE" "$STATE/data" "$BACKUPS"
  use_image "$(good_image_id)" && docker compose up -d
}

recreate_app() {
  docker compose up -d --force-recreate --no-deps threadsift
}

start_stack() {
  if ! up_stack || ! wait_ready || ! hold_window; then
    return 1
  fi
  running_image_id >"$GOOD"
}

newest_backup() {
  find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -name '20*' 2>/dev/null | sort | tail -n 1
}

backup_database() {
  local stamp tmp old
  if [ ! -f "$STATE/data/threadsift.db" ]; then
    echo "threadsift-up: no database yet, nothing to copy"
    return 0
  fi
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  tmp="$BACKUPS/.$stamp.tmp"
  if ! { mkdir -p "$BACKUPS" && mkdir "$tmp" && cp "$STATE"/data/threadsift.db* "$tmp"/ && mv "$tmp" "$BACKUPS/$stamp"; }; then
    rm -rf -- "${tmp:?}"
    return 1
  fi
  mapfile -t old < <(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort -r | tail -n +$((KEEP_BACKUPS + 1)))
  if [ "${#old[@]}" -gt 0 ]; then
    rm -rf -- "${old[@]}"
  fi
}

prune_local_images() {
  local tag
  while read -r tag; do
    if [[ $tag == "$LOCAL_REPO":* ]] && [ "$tag" != "$(local_name "$1")" ] && [ "$tag" != "$(local_name "$2")" ]; then
      docker rmi "$tag" >/dev/null 2>&1 || true
    fi
  done < <(docker images --format '{{.Repository}}:{{.Tag}}' "$LOCAL_REPO")
}

resume_image() {
  use_image "$1" && recreate_app && wait_ready
}

install_image() {
  use_image "$1" && recreate_app && wait_ready && hold_window
}

roll_back() {
  local previous_id=$1 failed_id=$2
  echo "threadsift-up: rolling back: $(describe "$failed_id") failed, returning to $(describe "$previous_id")" >&2
  echo "$failed_id" >"$REJECTED"
  if resume_image "$previous_id"; then
    echo "threadsift-up: rollback done, the app answers on $(describe "$previous_id")" >&2
  else
    echo "threadsift-up: the previous image does not answer either; the copy from before the update is $(newest_backup)" >&2
  fi
  prune_local_images "$previous_id" "$previous_id"
}

update_app() {
  local running_id new_id
  if [ "$(docker inspect --format '{{.State.Running}}' threadsift 2>/dev/null)" != true ]; then
    start_stack
    return
  fi
  running_id=$(running_image_id)
  if ! docker pull -q "$THREADSIFT_SOURCE_IMAGE" >/dev/null; then
    echo "threadsift-up: pulling $THREADSIFT_SOURCE_IMAGE failed, the app keeps running $(describe "$running_id")" >&2
    return 1
  fi
  new_id=$(image_id "$THREADSIFT_SOURCE_IMAGE")
  if [ "$new_id" = "$running_id" ]; then
    echo "threadsift-up: $THREADSIFT_SOURCE_IMAGE is already running ($(describe "$running_id"))"
    up_stack && wait_ready
    return
  fi
  if [ "$new_id" = "$(cat "$REJECTED" 2>/dev/null || true)" ]; then
    echo "threadsift-up: $(describe "$new_id") failed its start check earlier; waiting for a newer $THREADSIFT_SOURCE_IMAGE" >&2
    return 1
  fi
  echo "threadsift-up: $THREADSIFT_SOURCE_IMAGE moves from $(describe "$running_id") to $(describe "$new_id")"
  if ! docker compose stop threadsift || ! backup_database; then
    echo "threadsift-up: stopping the app or copying the database failed; the app keeps running $(describe "$running_id")" >&2
    resume_image "$running_id" || echo "threadsift-up: the app does not answer on $(describe "$running_id")" >&2
    return 1
  fi
  if install_image "$new_id"; then
    echo "$new_id" >"$GOOD"
    rm -f "$REJECTED"
    prune_local_images "$new_id" "$running_id"
    echo "threadsift-up: update done, the app answers on $(describe "$new_id")"
    return
  fi
  roll_back "$running_id" "$new_id"
  return 1
}

case "${1:-}" in
  start | "") start_stack ;;
  update) update_app ;;
  stop) exec docker compose stop ;;
  *)
    echo "usage: threadsift-up.sh [start|update|stop]" >&2
    exit 64
    ;;
esac
