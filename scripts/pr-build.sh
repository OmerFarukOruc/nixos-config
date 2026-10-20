#!/usr/bin/env bash
# The host-systems-build check (.github/workflows/host-systems-build.yml) runs
# this on nixos-rog as the forced command of its SSH key
# (machines/nixos-rog/pr-build.nix), with "PR SHA" as the SSH command. It checks
# with GitHub that SHA is the head of open PR number PR, which targets main from
# this repository. Then it builds the system of every host whose toplevel
# drvPath differs between SHA and its merge base with main. It holds the build
# lock that scripts/auto-update.sh takes too, so the two never build at once.
#
# Exit status: 0 every changed system builds, 1 a system does not evaluate or
# build, 2 a malformed SSH command, 3 nixos-rog runs on battery, 4 SHA is not
# that PR's head, 5 the lock stayed busy, 6 GitHub does not answer, 124 the
# deadline passed or the check's SSH session ended.
set -Eeuo pipefail

repo=OmerFarukOruc/nixos-config
lock=/run/nixos-config-build.lock
cache=${XDG_CACHE_HOME:-$HOME/.cache}/nixos-config-pr-build
# Below the workflow's 120 min job limit, so this side stops first and says so.
deadline=$((110 * 60))
lock_wait=$((60 * 60))

say() { echo "host-systems-build: $*" >&2; }

# sshd leaves the command running when the client goes away, such as when a
# newer push cancels the job. So the build runs in a process group of its own,
# which this outer copy kills once the SSH session process (its parent) exits or
# the deadline passes.
if [[ -z ${PR_BUILD_INNER:-} ]]; then
  session=$PPID
  PR_BUILD_INNER=1 setsid "$0" "$@" &
  inner=$!
  stop_inner() {
    kill -TERM -- "-$inner" 2>/dev/null || true
    sleep 10
    kill -KILL -- "-$inner" 2>/dev/null || true
  }
  trap 'stop_inner; exit 124' HUP INT TERM
  while kill -0 "$inner" 2>/dev/null; do
    if ! kill -0 "$session" 2>/dev/null; then
      stop_inner
      exit 124
    fi
    if ((SECONDS > deadline)); then
      say "the build passed its deadline of $((deadline / 60)) min."
      stop_inner
      exit 124
    fi
    sleep 5
  done
  status=0
  wait "$inner" || status=$?
  exit "$status"
fi

command=${SSH_ORIGINAL_COMMAND:-}
if [[ ! $command =~ ^([0-9]{1,7})\ ([0-9a-f]{40})$ ]]; then
  say "expected 'PR SHA' as the SSH command, got '${command:0:100}'."
  exit 2
fi
pr=${BASH_REMATCH[1]}
sha=${BASH_REMATCH[2]}

mkdir -p -- "$cache/logs"
log=$cache/logs/$(date +%Y%m%dT%H%M%S)-pr$pr-${sha:0:12}.log
# -p keeps writing the log after the SSH session goes away.
exec > >(tee -p -a "$log") 2>&1
say "PR $pr at $sha; nixos-rog keeps this log at $log."
# The newest 50 logs stay.
find "$cache/logs" -maxdepth 1 -name '*.log' -printf '%T@ %p\n' | sort -rn | tail -n +51 | cut -d' ' -f2- |
  xargs -r rm -f --

if ! systemd-ac-power; then
  say "nixos-rog runs on battery, so it builds nothing. Rerun the check once it is on AC power."
  exit 3
fi

if ! pr_json=$(curl -fsS --max-time 20 --retry 2 -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$repo/pulls/$pr"); then
  say "GitHub does not answer for PR $pr."
  exit 6
fi
if ! jq -e --arg repo "$repo" --arg sha "$sha" '.state == "open" and .base.ref == "main"
  and .base.repo.full_name == $repo and .head.repo.full_name == $repo and .head.sha == $sha' \
  <<<"$pr_json" >/dev/null; then
  say "$sha is not the head of an open PR $pr from $repo to main."
  exit 4
fi

exec {lock_fd}>>"$lock"
if ! flock -n "$lock_fd"; then
  say "the updater holds the build lock; waiting up to $((lock_wait / 60)) min."
  if ! flock -w "$lock_wait" "$lock_fd"; then
    say "the build lock stayed busy. Rerun the check later."
    exit 5
  fi
fi

git_dir=$cache/repo.git
[[ -d $git_dir ]] || git init --quiet --bare "$git_dir"
if ! git -C "$git_dir" fetch --quiet --force "https://github.com/$repo.git" \
  "+refs/pull/$pr/head:refs/pr/$pr" "+refs/heads/main:refs/heads/main"; then
  say "fetching PR $pr and main from GitHub failed."
  exit 6
fi
if [[ $(git -C "$git_dir" rev-parse "refs/pr/$pr") != "$sha" ]]; then
  say "PR $pr moved past $sha while this check started."
  exit 4
fi
base=$(git -C "$git_dir" merge-base "$sha" main)
say "comparing with the merge base $base."

flake() { echo "git+file://$git_dir?rev=$1"; }
toplevel_drv() {
  heavy nix eval --raw --no-update-lock-file \
    "$(flake "$1")#nixosConfigurations.$2.config.system.build.toplevel.drvPath"
}

if ! hosts=$(heavy nix eval --json --no-update-lock-file "$(flake "$sha")#nixosConfigurations" \
  --apply builtins.attrNames | jq -r '.[]'); then
  say "the host list does not evaluate at $sha."
  exit 1
fi
failed=()
for host in $hosts; do
  if ! new=$(toplevel_drv "$sha" "$host"); then
    say "$host does not evaluate at $sha."
    failed+=("$host")
    continue
  fi
  old=$(toplevel_drv "$base" "$host" 2>/dev/null) || old=
  if [[ $new == "$old" ]]; then
    say "$host: the PR does not change its system."
    continue
  fi
  say "$host: building $new"
  # Only the evaluations go through heavy. The build runs in nix-daemon, and
  # its client stays in this process group, so a stop of the check cancels it.
  if ! nix build --no-link --print-out-paths "$new^*"; then
    say "$host does not build at $sha."
    failed+=("$host")
  fi
done
if ((${#failed[@]} > 0)); then
  say "failed: ${failed[*]}."
  exit 1
fi
say "every system the PR changes builds."
