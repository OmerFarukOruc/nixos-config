#!/usr/bin/env bash
# Copies CLIProxyAPI's config from sops-nix to tmpfs and starts the loopback compose stack.
#
#   usage: cliproxy-up.sh [stop|update]
#
# `stop` stops the stack with the same derived paths, so compose can interpolate the file.
# `update` pulls the cliproxy and Tailscale images, rebuilds tls-proxy on a fresh Caddy base,
# recreates a container when it runs an older image, and removes the images it replaced. A
# failed pull or build keeps the running containers. Without a Cloudflare DNS token the
# tls-proxy leaves the CLIPROXY_PUBLIC_HOST site out and serves only CLIPROXY_SHARE_HOST.
#
# The docker CLI talks to the user's rootless Podman socket, whatever DOCKER_HOST the shell set.
#
# cliproxy.service sets CLIPROXY_RENDERED_CONFIG and CLIPROXY_DNS_TOKEN_FILE to the files that
# sops-nix renders from secrets/risoluto-dev-1-cliproxy.yaml, and CLIPROXY_SHARE_HOST and
# CLIPROXY_TS_AUTHKEY through its EnvironmentFile. The panel can change the config, so the app
# gets a writable copy on tmpfs under XDG_RUNTIME_DIR, made again on every start. OAuth token
# files persist under ~/.local/state/fleet/cliproxy/auths because the app owns that store.

set -euo pipefail

SERVICE_DIR=$(cd "$(dirname "$0")" && pwd)
ENV_PUBLIC="$SERVICE_DIR/env.public"
COMPOSE="$SERVICE_DIR/compose.yml"
STATE="${CLIPROXY_STATE_DIR:-$HOME/.local/state/fleet/cliproxy}"
RUNTIME="${CLIPROXY_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-}/cliproxy}"

if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "${XDG_RUNTIME_DIR:-}" ]; then
  echo "cliproxy-up: XDG_RUNTIME_DIR is unset or not a directory" >&2
  exit 78
fi
if [ ! -f "$ENV_PUBLIC" ] || [ ! -f "$COMPOSE" ]; then
  echo "cliproxy-up: cliproxy config files are missing under $SERVICE_DIR" >&2
  exit 78
fi
if [ "${1:-}" = stop ]; then
  # Compose interpolates every variable of the file, also to stop the stack.
  : "${CLIPROXY_SHARE_HOST:=stop}"
elif [ ! -s "${CLIPROXY_RENDERED_CONFIG:-}" ] || [ -z "${CLIPROXY_SHARE_HOST:-}" ]; then
  echo "cliproxy-up: the sops config or CLIPROXY_SHARE_HOST is missing; start it through cliproxy.service" >&2
  exit 78
fi
# An empty key would start an unauthenticated proxy. A secret with a line break
# or a quote breaks the JSON, which jq refuses too.
if [ "${1:-}" != stop ] && ! jq -e '(."api-keys" | length > 0 and all(length > 0))
    and (."remote-management"."secret-key" | length > 0)' "$CLIPROXY_RENDERED_CONFIG" >/dev/null; then
  echo "cliproxy-up: the config is not valid JSON, or it has an empty API key or management key" >&2
  exit 78
fi

export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
export COMPOSE_PROJECT_NAME=cliproxy COMPOSE_FILE="$COMPOSE" COMPOSE_PROFILES=share

mkdir -p "$STATE/auths" "$STATE/logs" "$STATE/plugins" "$STATE/tailscale" "$STATE/caddy" "$RUNTIME/ts-socket"
chmod 700 "$STATE" "$STATE/auths" "$STATE/tailscale" "$STATE/caddy" "$RUNTIME" "$RUNTIME/ts-socket"

export CLIPROXY_CONFIG_PATH="$RUNTIME/config.yaml"
export CLIPROXY_AUTH_PATH="$STATE/auths"
export CLIPROXY_LOG_PATH="$STATE/logs"
export CLIPROXY_PLUGIN_PATH="$STATE/plugins"
export CLIPROXY_TS_STATE="$STATE/tailscale"
export CLIPROXY_TS_SERVE_DIR="$SERVICE_DIR/ts-serve"
export CLIPROXY_TS_SOCKET_DIR="$RUNTIME/ts-socket"
export CLIPROXY_CADDY_DATA="$STATE/caddy"
export CLIPROXY_CLOUDFLARE_TOKEN_PATH="$RUNTIME/cloudflare-dns-token"
# The Caddyfile imports this site block from the Caddy data volume (/data in the container).
PUBLIC_SITE="$STATE/caddy/public-host.caddy"

set -a
# env.public has comments and assignments only.
# shellcheck disable=SC1090,SC1091
. "$ENV_PUBLIC"
set +a

# The legacy builder through Podman's API; compose would hand the build to buildx,
# which leaves a BuildKit container running.
build_tls_proxy() {
  DOCKER_BUILDKIT=0 docker build -q "$@" -t "$CLIPROXY_TLS_IMAGE" "$SERVICE_DIR/tls-proxy" >/dev/null
}

# Keeps the public A record on the node's tailnet address; the stack runs on without it.
ensure_dns() {
  if [ "$(docker inspect --format '{{.State.Running}}' cliproxy-share 2>/dev/null)" = true ]; then
    "$SERVICE_DIR/dns-record.sh" apply ||
      echo "cliproxy-up: warning: the $CLIPROXY_PUBLIC_HOST record check failed" >&2
  fi
}

replaced=()
case "${1:-}" in
  stop)
    exec docker compose stop
    ;;
  update)
    if ! docker compose pull; then
      echo "cliproxy-up: warning: an image pull failed, keeping the local images" >&2
    fi
    if ! build_tls_proxy --pull; then
      echo "cliproxy-up: warning: the tls-proxy build failed, keeping the local image" >&2
    fi
    for c in $(docker compose ps -a -q); do
      read -r image running <<<"$(docker inspect --format '{{.Config.Image}} {{.Image}}' "$c")"
      if [ "$(docker image inspect --format '{{.Id}}' "$image")" != "$running" ]; then
        replaced+=("$running")
      fi
    done
    if [ "${#replaced[@]}" = 0 ] && [ -n "$(docker compose ps -a -q cliproxy)" ]; then
      echo "cliproxy-up: the containers already use the local images"
      ensure_dns
      exit 0
    fi
    ;;
  "") ;;
  *)
    echo "usage: cliproxy-up.sh [stop|update]" >&2
    exit 64
    ;;
esac

if ! docker image inspect "$CLIPROXY_TLS_IMAGE" >/dev/null 2>&1; then
  build_tls_proxy
fi

(
  umask 077
  cat "$CLIPROXY_RENDERED_CONFIG" >"$CLIPROXY_CONFIG_PATH.new"
  mv -f "$CLIPROXY_CONFIG_PATH.new" "$CLIPROXY_CONFIG_PATH"
  # sops-nix's files are 0400, and cp keeps that mode, so each copy replaces the file.
  if [ -s "${CLIPROXY_DNS_TOKEN_FILE:-}" ]; then
    cat "$CLIPROXY_DNS_TOKEN_FILE" >"$CLIPROXY_CLOUDFLARE_TOKEN_PATH.new"
  else
    : >"$CLIPROXY_CLOUDFLARE_TOKEN_PATH.new"
  fi
  mv -f "$CLIPROXY_CLOUDFLARE_TOKEN_PATH.new" "$CLIPROXY_CLOUDFLARE_TOKEN_PATH"
)
chmod 600 "$CLIPROXY_CONFIG_PATH"

# The Cloudflare provider rejects an empty token, and a provider error fails the whole Caddy
# config. Without a token the public site stays out of the config so the share host still works.
if [ -s "$CLIPROXY_CLOUDFLARE_TOKEN_PATH" ]; then
  cat >"$PUBLIC_SITE.new" <<SITE
# Let's Encrypt through the DNS-01 challenge; the public A record points at the node's tailnet address.
https://$CLIPROXY_PUBLIC_HOST {
	tls {
		dns cloudflare {file./run/secrets/cloudflare-dns-token}
		resolvers 1.1.1.1
	}
	import api
}
SITE
  mv "$PUBLIC_SITE.new" "$PUBLIC_SITE"
else
  rm -f "$PUBLIC_SITE"
  echo "cliproxy-up: no Cloudflare DNS token, $CLIPROXY_PUBLIC_HOST left out of the tls-proxy" >&2
fi

if [ -z "${CLIPROXY_TS_AUTHKEY:-}" ]; then
  unset COMPOSE_PROFILES
  echo "cliproxy-up: CLIPROXY_TS_AUTHKEY empty, share sidecar skipped" >&2
fi
docker compose up -d
if [ -z "${CLIPROXY_TS_AUTHKEY:-}" ]; then
  docker rm -f cliproxy-share cliproxy-tls-proxy >/dev/null 2>&1 || true
fi

ensure_dns

if [ "${#replaced[@]}" -gt 0 ]; then
  docker rmi "${replaced[@]}" >/dev/null 2>&1 || true
  # Also drops the current build stage, so the next build compiles Caddy once more.
  docker image prune -f --filter label=dev.risoluto.cliproxy.build-stage=tls-proxy >/dev/null || true
fi

printf 'cliproxy-up: shared panel: https://%s/management.html#/\n' \
  "$CLIPROXY_SHARE_HOST"
