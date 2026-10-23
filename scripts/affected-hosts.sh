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
# ancestor of REV, one from a dirty tree, or one with no release record) or
# unreachable.
# REV defaults to origin/main and must be pushed, because nixos-rog evaluates
# it from GitHub. Exits 1 when an evaluation or a Git lookup fails, 2 for a
# usage error.
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

# on_host HOST [ARG...] < SCRIPT: runs SCRIPT with bash in HOST's home
# directory, with the ARGs. This host runs SCRIPT without SSH, as deploy.sh
# does.
on_host() {
  local host=$1
  shift
  if [[ $host == "$this_host" ]]; then
    (cd && bash -s -- "$@")
  elif (($#)); then
    # shellcheck disable=SC2029 # printf %q quotes the arguments for the remote shell
    ssh "${ssh_opts[@]}" "$host" "bash -s -- $(printf '%q ' "$@")"
  else
    ssh "${ssh_opts[@]}" "$host" 'bash -s'
  fi
}

# systems REV: prints {HOST: {drv, out}} for every host at REV.
systems() {
  on_host nixos-rog "github:$repo/$1" <<'REMOTE'
set -e
# heavy (machines/nixos-rog/heavy.nix) caps the memory of each evaluation. One
# evaluation per host stays under that cap; three systems in one evaluation
# did not, and systemd-oomd killed it.
nix=(nix)
if command -v heavy >/dev/null; then nix=(heavy nix); fi
hosts=$("${nix[@]}" eval --raw --no-write-lock-file "$1#nixosConfigurations" \
  --apply 'c: builtins.concatStringsSep " " (builtins.attrNames c)' </dev/null)
for host in $hosts; do
  "${nix[@]}" eval --json --no-write-lock-file "$1#nixosConfigurations.$host.config.system.build.toplevel" \
    --apply "t: { \"$host\" = { drv = t.drvPath; out = t.outPath; }; }" </dev/null
done | jq -s add
REMOTE
}

if ! $running && [[ -z $old_rev ]] && ! parent=$(git rev-parse --verify -q "$sha^"); then
  echo "$sha has no parent to compare with." >&2
  exit 1
fi
new=$(systems "$sha")
mapfile -t hosts < <(jq -r 'keys[]' <<<"$new")

if ! $running; then
  old=$(systems "$parent")
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
  # The first line is the running system. The second holds the commit and the
  # dirty flag of the release record that names it.
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
