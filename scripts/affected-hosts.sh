#!/usr/bin/env bash
# usage: scripts/affected-hosts.sh [--running] [REV | OLD..REV]
# Prints one line per host: HOST<TAB>STATUS<TAB>DETAIL.
# Without --running it compares each host's system at REV with the system at
# OLD, or at REV^ without OLD. A push of several commits needs OLD, the main
# the push landed on. STATUS is affected, which means the host needs a deploy
# of REV, unchanged, or not-deployed for a host whose machine record sets
# deployed = false, one that does not run this configuration yet.
# With --running it compares the system each host runs with REV's system.
# STATUS is current, behind (the release the host runs is an ancestor of REV;
# DETAIL lists the subjects of the commits it lacks, so the reader can tell
# whose merges they are), other (the host runs a release that is not an
# ancestor of REV, one from a dirty tree, or one with no release record),
# unreachable, or not-deployed.
# REV defaults to origin/main and must be pushed, because this host evaluates
# it from GitHub. This host keeps each commit's systems in
# ${XDG_CACHE_HOME:-~/.cache}/nixos-config/affected-hosts, one file per commit
# and Nix version, so a later call for the same commit on this host skips its
# evaluation; delete the file to evaluate again. Exits 1 when an evaluation or
# a Git lookup fails, 2 for a usage error.
set -euo pipefail
cd "$(dirname "$0")/.."

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
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15)
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
    ssh "${ssh_opts[@]}" "$target" "bash -s -- $(printf '%q ' "$@")"
  else
    ssh "${ssh_opts[@]}" "$target" 'bash -s'
  fi
}

systems() {
  on_host "$this_host" "github:$repo/$1" <<'REMOTE'
set -eo pipefail
nix=(nix)
if command -v heavy >/dev/null; then nix=(heavy nix); fi
hosts=$("${nix[@]}" eval --raw --no-update-lock-file "$1#nixosConfigurations" \
  --apply 'c: builtins.concatStringsSep " " (builtins.attrNames c)' </dev/null)
for host in $hosts; do
  "${nix[@]}" eval --json --no-update-lock-file "$1#nixosConfigurations.$host" \
    --apply "h: { \"$host\" = {
      drv = h.config.system.build.toplevel.drvPath;
      out = h.config.system.build.toplevel.outPath;
      deployed = h.config.oruc.machine.deployed or true;
      deployLogin = h.config.oruc.machine.deployLogin or null;
    }; }" </dev/null
done | jq -s add
REMOTE
}

cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/nixos-config/affected-hosts
nix_version=$(nix --version)
nix_version=${nix_version##* }

valid_systems() {
  jq -e 'type == "object" and length > 0
    and all(.[]; (.drv | type) == "string" and (.out | type) == "string")' \
    >/dev/null 2>&1
}

cached_systems() {
  local file=$cache_dir/$1-nix-$nix_version.json json tmp
  if [[ -s $file ]] && valid_systems <"$file"; then
    cat "$file"
    return
  fi
  json=$(systems "$1") || return 1
  if ! valid_systems <<<"$json"; then
    echo "The evaluation of $1 printed no systems." >&2
    return 1
  fi
  if mkdir -p "$cache_dir" && tmp=$(mktemp "$cache_dir/.$1.XXXXXX"); then
    { printf '%s\n' "$json" >"$tmp" && mv -f "$tmp" "$file"; } || rm -f "$tmp"
  fi
  printf '%s\n' "$json"
}

if ! $running && [[ -z $old_rev ]] && ! parent=$(git rev-parse --verify -q "$sha^"); then
  echo "$sha has no parent to compare with." >&2
  exit 1
fi
new=$(cached_systems "$sha")
mapfile -t hosts < <(jq -r 'keys[]' <<<"$new")
not_deployed() {
  [[ $(jq -r --arg h "$1" '.[$h].deployed' <<<"$new") == false ]]
}

if ! $running; then
  old=$(cached_systems "$parent")
  for host in "${hosts[@]}"; do
    if not_deployed "$host"; then
      printf '%s\tnot-deployed\tthe record sets deployed = false\n' "$host"
      continue
    fi
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
  if not_deployed "$host"; then
    printf '%s\tnot-deployed\tthe record sets deployed = false\n' "$host"
    continue
  fi
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
