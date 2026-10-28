#!/usr/bin/env bash
# Points CLIPROXY_PUBLIC_HOST at the cliproxy tailnet node with a DNS-only A record at Cloudflare.
#
#   usage: dns-record.sh plan|apply
#
# cliproxy-up.sh runs `apply` after every start and update. The node's address comes from the
# running cliproxy-share sidecar, and the token from the file cliproxy-up.sh renders from
# the cloudflare-dns-token of secrets/risoluto-dev-1-cliproxy.yaml. The script changes only a single DNS-only A record,
# and moves it only from one tailnet address to another.

set -euo pipefail
umask 077

SERVICE_DIR=$(cd "$(dirname "$0")" && pwd)
die() {
  echo "dns-record: $*" >&2
  exit 1
}

mode=${1:-}
[[ "$mode" =~ ^(plan|apply)$ ]] || die "usage: dns-record.sh plan|apply"
XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

set -a
# shellcheck disable=SC1091
. "$SERVICE_DIR/env.public"
set +a
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
token_file=${CLIPROXY_CLOUDFLARE_TOKEN_PATH:-$XDG_RUNTIME_DIR/cliproxy/cloudflare-dns-token}
[ -s "$token_file" ] || die "$token_file is missing or empty; run this on risoluto-dev-1, where cliproxy.service runs"
name=$CLIPROXY_PUBLIC_HOST
zone=${name#*.}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The token goes in a header file, never argv.
{
  printf 'Authorization: Bearer '
  cat "$token_file"
  printf '\nContent-Type: application/json\n'
} >"$work/headers"

# api METHOD PATH [JSON]: prints .result, fails on success=false.
api() {
  local out="$work/out" args=(-sS -X "$1" "https://api.cloudflare.com/client/v4$2" -H "@$work/headers")
  [ -z "${3:-}" ] || {
    printf '%s' "$3" >"$work/body"
    args+=(--data "@$work/body")
  }
  curl "${args[@]}" >"$out" || die "$1 $2: curl failed"
  jq -e '.success == true' "$out" >/dev/null || die "$1 $2: $(jq -c '.errors' "$out" 2>/dev/null | cut -c1-300)"
  jq -c '.result' "$out"
}

in_tailnet_range() { [[ "$1" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+$ ]]; }

# The sidecar needs a few seconds after a start before it has its address.
addr=
for _ in $(seq 60); do
  addr=$(docker exec cliproxy-share tailscale ip -4 2>/dev/null | head -n1) || true
  in_tailnet_range "$addr" && break
  sleep 1
done
in_tailnet_range "$addr" || die "cliproxy-share has no tailnet IPv4 address"

zone_id=$(api GET "/zones?name=$zone" | jq -r '.[0].id // empty')
[ -n "$zone_id" ] || die "zone $zone not found, or the token cannot read it"

body=$(jq -nc --arg n "$name" --arg a "$addr" \
  '{type: "A", name: $n, content: $a, proxied: false, ttl: 300, comment: "cliproxy tailnet node; nixos-config machines/risoluto-dev-1/cliproxy/dns-record.sh"}')
records=$(api GET "/zones/$zone_id/dns_records?name.exact=$name")
case $(jq length <<<"$records") in
  0)
    method=POST path="/zones/$zone_id/dns_records" change="create A $name to $addr"
    ;;
  1)
    [ "$(jq -r '.[0].type + " " + (.[0].proxied | tostring)' <<<"$records")" = "A false" ] ||
      die "$name has a record that is not a DNS-only A record; refusing to change it"
    have=$(jq -r '.[0].content' <<<"$records")
    if [ "$have" = "$addr" ]; then
      echo "dns-record: A $name matches $addr"
      exit 0
    fi
    in_tailnet_range "$have" || die "$name points to $have, which is not a tailnet address; refusing to change it"
    method=PUT path="/zones/$zone_id/dns_records/$(jq -r '.[0].id' <<<"$records")" change="move A $name from $have to $addr"
    ;;
  *)
    die "$name has several records; refusing to change them"
    ;;
esac

if [ "$mode" = apply ]; then
  api "$method" "$path" "$body" >/dev/null
  echo "dns-record: done: $change"
else
  echo "dns-record: plan: $change"
fi
