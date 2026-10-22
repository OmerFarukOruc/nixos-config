#!/usr/bin/env bash
# usage: scripts/affected-hosts.sh [--running] [REV]
# Prints one line per host: HOST<TAB>STATUS<TAB>DETAIL.
# Without --running it compares each host's system at REV with the system at
# REV^, the main that a squash merge landed on. STATUS is affected, which
# means the host needs a deploy of REV, or unchanged.
# With --running it compares the system each host runs with REV's system.
# STATUS is current, behind (the release the host runs is an ancestor of REV,
# so it needs a deploy), other (the host runs a release that is not an
# ancestor of REV, one from a dirty tree, or one with no release record) or
# unreachable.
# REV defaults to origin/main and must be pushed, because nixos-rog evaluates
# it from GitHub. Exits 1 when an evaluation or a Git lookup fails, 2 for a
# usage error.
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: $0 [--running] [REV]"
running=false
if [[ ${1:-} == --running ]]; then
  running=true
  shift
fi
if (($# > 1)) || [[ ${1:-} == -* ]]; then
  echo "$usage" >&2
  exit 2
fi

git fetch -q origin
if ! sha=$(git rev-parse --verify -q "${1:-origin/main}^{commit}"); then
  echo "${1:-origin/main} names no commit here." >&2
  exit 1
fi
if [[ -z $(git branch -r --contains "$sha") ]]; then
  echo "$sha is on no branch of origin; push it first." >&2
  exit 1
fi
url=$(git remote get-url origin)
if [[ ! $url =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
  echo "origin is not a GitHub repository: $url" >&2
  exit 1
fi
repo=${BASH_REMATCH[1]%.git}
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15)

# systems REV: prints {HOST: {drv, out}} for every host at REV.
systems() {
  # shellcheck disable=SC2029 # printf %q quotes the arguments for the remote shell
  ssh "${ssh_opts[@]}" nixos-rog "bash -s -- $(printf '%q ' "github:$repo/$1")" <<'REMOTE'
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

if ! $running && ! parent=$(git rev-parse --verify -q "$sha^"); then
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
    } | ssh "${ssh_opts[@]}" "$host" 'bash -s'
  ); then
    printf '%s\tunreachable\tSSH to %s failed\n' "$host" "$host"
    continue
  fi
  system=$(sed -n 1p <<<"$state")
  read -r revision dirty <<<"$(sed -n 2p <<<"$state")" || true
  if [[ $system == "$want" ]]; then
    printf '%s\tcurrent\t%s\n' "$host" "$system"
  elif [[ $dirty == true ]]; then
    printf '%s\tother\truns %s from a dirty tree at %s\n' "$host" "$system" "$revision"
  elif [[ -n $revision ]] && git merge-base --is-ancestor "$revision" "$sha" 2>/dev/null; then
    printf '%s\tbehind\truns %s; deploy %s\n' "$host" "$revision" "$sha"
  else
    printf '%s\tother\truns %s from %s\n' "$host" "$system" "${revision:-no release record}"
  fi
done
