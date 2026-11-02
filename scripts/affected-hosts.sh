#!/usr/bin/env bash
# usage: scripts/affected-hosts.sh [--running] [REV | OLD..REV]
# Prints one line per host: HOST<TAB>STATUS<TAB>DETAIL.
# Without --running it compares each host's system at REV with the system at
# OLD, or at REV^ without OLD. A push of several commits needs OLD, the main
# the push landed on. STATUS is affected, which means the host needs a deploy
# of REV, or unchanged.
# With --running it compares the system each host runs with REV's system.
# STATUS is current, behind (the release the host runs is an ancestor of REV;
# DETAIL lists the subjects of the commits it lacks, so the reader can tell
# whose merges they are), other (the host runs a release that is not an
# ancestor of REV, one from a dirty tree, or one with no release record), or
# unreachable.
# REV defaults to origin/main and must be pushed, because this host evaluates
# it from GitHub. This host keeps each commit's systems in
# ${XDG_CACHE_HOME:-~/.cache}/nixos-config/affected-hosts, one file per commit
# and Nix version, so a later call for the same commit on this host skips its
# evaluation; delete the file to evaluate again. Exits 1 when an evaluation or
# a Git lookup fails, 2 for a usage error.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. scripts/lib/host-systems.sh
# shellcheck source=/dev/null
. scripts/lib/parallel-each.sh
# shellcheck source=/dev/null
. scripts/lib/ssh.sh

usage="usage: $0 [--running] [REV | OLD..REV]"
running=false
if [[ ${1:-} == --running ]]; then
  running=true
  shift
fi
if (($# > 1)) || [[ ${1:-} == -* ]]; then
  echo "$usage" >&2
  exit 2
fi

rev=${1:-origin/main}
old_rev=
if [[ $rev == *..* ]]; then
  if $running; then
    echo "$usage" >&2
    exit 2
  fi
  old_rev=${rev%%..*}
  rev=${rev#*..}
  if [[ -z $old_rev || -z $rev || $rev == .* ]]; then
    echo "$usage" >&2
    exit 2
  fi
fi

if ! command -v nix >/dev/null; then
  echo "$0 evaluates the systems on this host, and nix is not on PATH." >&2
  exit 1
fi
git fetch -q origin
if ! sha=$(git rev-parse --verify -q "$rev^{commit}"); then
  echo "$rev names no commit here." >&2
  exit 1
fi
if [[ -n $old_rev ]] && ! parent=$(git rev-parse --verify -q "$old_rev^{commit}"); then
  echo "$old_rev names no commit here." >&2
  exit 1
fi
for commit in "$sha" ${old_rev:+"$parent"}; do
  if [[ -z $(git branch -r --contains "$commit") ]]; then
    echo "$commit is on no branch of origin; push it first." >&2
    exit 1
  fi
done
url=$(git remote get-url origin)
if [[ ! $url =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
  echo "origin is not a GitHub repository: $url" >&2
  exit 1
fi
repo=${BASH_REMATCH[1]%.git}
this_host=$(</proc/sys/kernel/hostname)

on_host() {
  local host=$1 target=$1 login=
  shift
  if [[ -n ${new:-} ]]; then
    login=$(jq -r --arg h "$host" '.[$h].deployLogin // empty' <<<"$new")
    if [[ -n $login ]]; then target=$login@$host; fi
  fi
  if [[ $host == "$this_host" ]]; then
    (cd && bash -s -- "$@")
  elif (($#)); then
    # shellcheck disable=SC2029 # printf %q quotes the arguments for the remote shell
    ssh "${SSH_OPTS[@]}" "$target" "bash -s -- $(printf '%q ' "$@")"
  else
    ssh "${SSH_OPTS[@]}" "$target" 'bash -s'
  fi
}

systems() {
  on_host "$this_host" "github:$repo/$1" "$HOST_SYSTEM_EXPR" <<'REMOTE'
set -eo pipefail
nix=(nix)
if command -v heavy >/dev/null; then nix=(heavy nix); fi
hosts=$("${nix[@]}" eval --raw --no-update-lock-file "$1#nixosConfigurations" \
  --apply 'c: builtins.concatStringsSep " " (builtins.attrNames c)' </dev/null)
for host in $hosts; do
  "${nix[@]}" eval --json --no-update-lock-file "$1#nixosConfigurations.$host" --apply "$2" </dev/null |
    jq -c --arg host "$host" '{($host): .}'
done | jq -s add
REMOTE
}

evaluated_systems() {
  local json
  json=$(systems "$1") || return 1
  if ! valid_host_systems <<<"$json"; then
    echo "The evaluation of $1 printed no systems." >&2
    return 1
  fi
  store_host_systems "$1" "$json" || true
  printf '%s\n' "$json"
}

if ! $running && [[ -z $old_rev ]] && ! parent=$(git rev-parse --verify -q "$sha^"); then
  echo "$sha has no parent to compare with." >&2
  exit 1
fi
systems_dir=$(mktemp -d)
trap 'rm -rf -- "$systems_dir"' EXIT
systems_of() {
  evaluated_systems "$1" >"$systems_dir/$1"
}
commits=("$sha")
if ! $running && [[ $parent != "$sha" ]]; then
  commits+=("$parent")
fi
pending=()
for commit in "${commits[@]}"; do
  if ! stored_host_systems "$commit" >"$systems_dir/$commit"; then
    fetch_inputs "github:$repo/$commit" --no-update-lock-file
    pending+=("$commit")
  fi
done
parallel_each systems_of "${pending[@]}"
new=$(<"$systems_dir/$sha")
mapfile -t hosts < <(jq -r 'keys[]' <<<"$new")

if ! $running; then
  old=$(<"$systems_dir/$parent")
  for host in "${hosts[@]}"; do
    before=$(jq -r --arg h "$host" '.[$h].drv // "none"' <<<"$old")
    after=$(jq -r --arg h "$host" '.[$h].drv' <<<"$new")
    if [[ $before == "$after" ]]; then
      printf '%s\tunchanged\t%s\n' "$host" "$after"
    else
      printf '%s\taffected\t%s -> %s\n' "$host" "$before" "$after"
    fi
  done
  exit 0
fi

for host in "${hosts[@]}"; do
  want=$(jq -r --arg h "$host" '.[$h].out' <<<"$new")
  if ! state=$(
    {
      cat scripts/lib/running-revision.sh
      cat <<'REMOTE'
readlink -f /run/current-system
running_revision
REMOTE
    } | on_host "$host"
  ); then
    printf '%s\tunreachable\tSSH to %s failed\n' "$host" "$host"
    continue
  fi
  system=$(sed -n 1p <<<"$state")
  read -r revision dirty _ <<<"$(sed -n 2p <<<"$state")" || true
  if [[ $system == "$want" ]]; then
    printf '%s\tcurrent\t%s\n' "$host" "$system"
  elif [[ $dirty == true ]]; then
    printf '%s\tother\truns %s from a dirty tree at %s\n' "$host" "$system" "$revision"
  elif [[ -n $revision ]] && git merge-base --is-ancestor "$revision" "$sha" 2>/dev/null; then
    mapfile -t lacks < <(git log --format=%s "$revision..$sha")
    detail=$(printf '%s; ' "${lacks[@]:0:5}")
    detail=${detail%; }
    ((${#lacks[@]} <= 5)) || detail+=" and $((${#lacks[@]} - 5)) more"
    printf '%s\tbehind\truns %s; lacks %d commit(s): %s\n' "$host" "${revision:0:12}" "${#lacks[@]}" "$detail"
  else
    printf '%s\tother\truns %s from %s\n' "$host" "$system" "${revision:-no release record}"
  fi
done
