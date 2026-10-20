#!/usr/bin/env bash
# Runs on nixos-rog from oruc-auto-update.service. Moves the flake inputs and
# every app in pkgs/ that names a release source to their newest release,
# deploys the result to this host with deploy.sh, and squash-merges it to main.
# The kernel and llm-agents move only while a cache holds the builds they need.
# Every other host must build here first, and after the merge the run deploys
# main to each other host that runs another system.
# nixpkgs, dms and sops-nix wait for the cache for a day at most
# (see below).
# A candidate that fails another host's build, this host's build or the activation
# is not tried again until main or an upstream moves. The run retries after
# this host's deploy.sh status 70, 71, 74, 77, 78 or 79, which are not the
# candidate's fault.
# -E lets the ERR trap below fire inside functions too.
set -Eeuo pipefail

repo=OmerFarukOruc/nixos-config
branch=auto-update
host=$(</proc/sys/kernel/hostname)
dir=$STATE_DIRECTORY/repo
failed=$STATE_DIRECTORY/failed-candidate
# The deploy.sh exit status that held the last run back.
waiting=$STATE_DIRECTORY/waiting
# The personal Git config pushes over SSH and signs with an agent key; the
# service has neither.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME="$host auto-update" GIT_AUTHOR_EMAIL="auto-update@$host"
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL

# notify URGENCY TITLE BODY. Succeeds only when the notification was shown, so a
# run records "already notified" only after a delivery; a caller that records
# nothing ends the call with "|| true". The body can start with "- ", which
# notify-send would read as an option without the "--". During a shutdown the
# session bus can stop answering, and notify-send would then wait past the 30 s
# that systemd gives a stopping run before it kills it.
notify() {
  local bus
  bus=/run/user/$(id -u)/bus
  [[ -S $bus ]] || return 1
  DBUS_SESSION_BUS_ADDRESS=unix:path=$bus timeout 5 notify-send -a "System update" -u "$1" -- "$2" "$3"
}
# fail TITLE BODY: the critical popup of a failed run. on_exit sends a generic
# one for a failed exit that sent none, such as an unset variable under set -u,
# which skips the ERR trap.
reported=false
fail() {
  reported=true
  notify critical "$1" "$2" || true
}
held=
on_exit() {
  local status=$?
  if ((status != 0)) && ! $reported; then
    notify critical "Update failed" "Exit $status. See: journalctl -u oruc-auto-update" || true
  fi
  [[ -z $held ]] || rm -rf -- "$held" || true
}
trap on_exit EXIT
# A failure inside $(...) runs this trap in the subshell and again in the main
# shell, so only the main shell reports.
trap '[[ $BASHPID != "$$" ]] || fail "Update failed" "See: journalctl -u oruc-auto-update"' ERR
# systemd ends the run with SIGTERM at the unit's TimeoutStartSec or when the
# system shuts down, and SIGTERM skips the ERR trap.
trap 'fail "Update stopped" "systemd stopped the run at its time limit or for a shutdown. See: journalctl -u oruc-auto-update"; exit 143' TERM

# Config files live only for this service run. Shell builtins keep the token
# out of argv, and exported variables carry paths only.
umask 077
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN token
[[ $RUNTIME_DIRECTORY == /* ]]
mkdir -p -- "$RUNTIME_DIRECTORY/gh"
token=$(<"$CREDENTIALS_DIRECTORY/github-token")
[[ $token =~ ^[a-zA-Z0-9_]+$ ]]
# The run edits flake.lock before it commits, so Nix would call the checkout
# dirty on every evaluation.
printf 'access-tokens = github.com=%s\nwarn-dirty = false\n' "$token" >"$RUNTIME_DIRECTORY/nix.conf"
printf 'github.com:\n    oauth_token: %s\n    git_protocol: https\n' "$token" >"$RUNTIME_DIRECTORY/gh/hosts.yml"
unset token
chmod 600 "$RUNTIME_DIRECTORY/nix.conf" "$RUNTIME_DIRECTORY/gh/hosts.yml"
export NIX_CONFIG="include $RUNTIME_DIRECTORY/nix.conf"
export GH_CONFIG_DIR="$RUNTIME_DIRECTORY/gh"

# deploy.sh, its rsync and nix copy reach another host with plain `ssh HOST`.
# The service has no agent and no personal key, so an ssh first on PATH adds
# this run's config, which names the deploy key from the credentials. The host
# keys come from /etc/ssh/ssh_known_hosts (programs.ssh.knownHosts).
mkdir -p -- "$RUNTIME_DIRECTORY/bin"
cat >"$RUNTIME_DIRECTORY/ssh_config" <<EOF
Host *
  IdentityFile $CREDENTIALS_DIRECTORY/latitude-deploy-key
  IdentitiesOnly yes
  BatchMode yes
  ConnectTimeout 15
  ServerAliveInterval 15
  ServerAliveCountMax 4
  StrictHostKeyChecking yes
  UserKnownHostsFile /dev/null
EOF
printf '#!%s\nexec %q -F %q "$@"\n' "$(command -v bash)" "$(command -v ssh)" "$RUNTIME_DIRECTORY/ssh_config" \
  >"$RUNTIME_DIRECTORY/bin/ssh"
chmod 700 "$RUNTIME_DIRECTORY/bin/ssh"
export PATH="$RUNTIME_DIRECTORY/bin:$PATH"

# A failed clone or fetch is quiet only during a network outage. Any other
# failure, such as a revoked token or lost repository access, would stop every
# update with no sign, so it notifies and fails.
remote_failed() {
  # Any HTTP answer, even an error status, shows that GitHub is reachable.
  if curl -sS --max-time 20 --retry 2 -o /dev/null https://github.com; then
    echo "git $1 failed while GitHub answers; check the token and the repository access." >&2
    fail "Update failed" "git $1 failed while GitHub is reachable. Check the token. See: journalctl -u oruc-auto-update"
    exit 1
  fi
  echo "GitHub is unreachable; the next run tries again."
  exit 0
}

# git asks gh for credentials from the private runtime hosts.yml.
git_auth=(-c 'credential.helper=' -c 'credential.helper=!gh auth git-credential')
if [[ ! -d $dir/.git ]]; then
  git "${git_auth[@]}" clone --quiet "https://github.com/$repo.git" "$dir" || remote_failed clone
fi
cd "$dir"
git "${git_auth[@]}" fetch --quiet origin main || remote_failed fetch
base=$(git rev-parse origin/main)
git checkout --quiet --force -B "$branch" "$base"
git clean -fdxq

# The host-systems-build check (scripts/pr-build.sh) takes the same lock, so a
# PR build and this run never evaluate or build at once. The run lets it go
# before it opens its PR, whose check needs it.
exec {build_lock}>>/run/nixos-config-build.lock
if ! flock -w 1800 "$build_lock"; then
  echo "A PR build has held the build lock for 30 min; the next run tries again."
  exit 0
fi

# Prints the coding agents this host would compile itself because
# cache.numtide.com does not hold their new build yet, or "unknown" when it
# cannot tell.
uncached_agents() {
  local agents plan
  # This evaluates every package of llm-agents, also those this host does not
  # use, so their evaluation warnings show only when the evaluation fails. The
  # host's own build prints the warnings of the packages it uses.
  agents=$(nix eval --impure --raw --expr "
    let pkgs = (builtins.getFlake \"git+file://$PWD\").inputs.llm-agents.packages.\${builtins.currentSystem};
        drv = p: let r = builtins.tryEval p.drvPath; in if r.success then [ r.value ] else [ ];
    in builtins.concatStringsSep \"\\n\" (builtins.concatMap drv (builtins.attrValues pkgs))" \
    2>"$RUNTIME_DIRECTORY/agents-eval.err") ||
    {
      cat "$RUNTIME_DIRECTORY/agents-eval.err" >&2
      echo unknown
      return
    }
  plan=$(nix build --dry-run ".#nixosConfigurations.$host.config.system.build.toplevel" 2>&1) ||
    {
      echo unknown
      return
    }
  grep -Fo -f <(echo "$agents") <<<"$plan" || true
}

other_hosts() {
  nix eval --json .#nixosConfigurations --apply builtins.attrNames | jq -r --arg self "$host" '.[] | select(. != $self)'
}

# Builds HOST's system and prints its path. A second try covers a download
# that failed once, such as a substituter timeout.
build_system() {
  nix build --no-link --print-out-paths ".#nixosConfigurations.$1.config.system.build.toplevel" ||
    nix build --no-link --print-out-paths ".#nixosConfigurations.$1.config.system.build.toplevel"
}

# A candidate merges only when every other host's system builds here too.
other_hosts_build() {
  local hosts other
  hosts=$(other_hosts) || return 76
  for other in $hosts; do
    build_system "$other" >/dev/null ||
      {
        echo "$other does not build."
        return 76
      }
  done
}

# Deploys the checkout's tree to every other host whose running system differs
# from it. The system builds here and is copied first, so the host does not
# compile it. Per host, current-HOST records the tree the host matched,
# failed-HOST a tree whose deploy failed for its own reason, unreachable-HOST
# that the "cannot log in" popup was shown, and waiting-HOST the deploy.sh
# status that held the last try back. The state names a tree, not a commit,
# because the squash merge gives the tree this run deployed a new commit. A host
# that cannot be reached, or a deploy that fails for a reason outside the tree,
# is tried again the next run. The popups here do not go through fail, so a
# later failure of the run still sends its own.
deliver_others() {
  local tree hosts other running want status previous ssh_error
  tree=$(git rev-parse 'HEAD^{tree}')
  hosts=$(other_hosts) || {
    notify critical "Other hosts not updated" "The host list does not evaluate. See: journalctl -u oruc-auto-update" || true
    return 0
  }
  for other in $hosts; do
    [[ -f $STATE_DIRECTORY/current-$other && $(<"$STATE_DIRECTORY/current-$other") == "$tree" ]] && continue
    [[ -f $STATE_DIRECTORY/failed-$other && $(<"$STATE_DIRECTORY/failed-$other") == "$tree" ]] && continue
    if ! running=$(ssh "$other" readlink -f /run/current-system 2>"$RUNTIME_DIRECTORY/ssh.err"); then
      cat "$RUNTIME_DIRECTORY/ssh.err" >&2
      ssh_error=$(tail -n 1 "$RUNTIME_DIRECTORY/ssh.err")
      echo "The updater cannot log in to $other over SSH; the next run tries again."
      if [[ ! -f $STATE_DIRECTORY/unreachable-$other ]]; then
        notify normal "$other not updated" "The updater cannot log in to $other over SSH: ${ssh_error:-no error line}. It deploys main there once it can." &&
          touch "$STATE_DIRECTORY/unreachable-$other"
      fi
      continue
    fi
    rm -f -- "$STATE_DIRECTORY/unreachable-$other"
    if ! want=$(build_system "$other"); then
      echo "$tree" >"$STATE_DIRECTORY/failed-$other"
      notify critical "$other not updated" "Its system at main does not build here. See: journalctl -u oruc-auto-update" || true
      continue
    fi
    if [[ $running != "$want" ]]; then
      # The host downloads what a cache holds itself. A copy that stalls, such
      # as over a Wi-Fi drop, stops after 30 minutes.
      timeout 30m nix copy --substitute-on-destination --to "ssh-ng://$other" "$want" ||
        echo "Copying the system to $other failed; deploy.sh builds it there."
      status=0
      ./deploy.sh "$other" switch || status=$?
      case $status in
        0) ;;
        70 | 71 | 74 | 77 | 79)
          echo "The deploy to $other exited $status, which is not the tree's fault; the next run tries again."
          # The second run in a row with the same status notifies once.
          previous=
          [[ -f $STATE_DIRECTORY/waiting-$other ]] && previous=$(<"$STATE_DIRECTORY/waiting-$other")
          if [[ $previous == "$status" ]]; then
            notify normal "$other update waiting" "deploy.sh $other exited $status in two runs in a row. See the exit codes in docs/deploy.md and journalctl -u oruc-auto-update" &&
              echo "$status notified" >"$STATE_DIRECTORY/waiting-$other"
          elif [[ $previous != "$status notified" ]]; then
            echo "$status" >"$STATE_DIRECTORY/waiting-$other"
          fi
          continue
          ;;
        *)
          echo "$tree" >"$STATE_DIRECTORY/failed-$other"
          rm -f -- "$STATE_DIRECTORY/waiting-$other"
          notify critical "$other update failed" "deploy.sh $other exited $status. The updater tries again once main moves. See: journalctl -u oruc-auto-update" || true
          continue
          ;;
      esac
    fi
    rm -f -- "$STATE_DIRECTORY/failed-$other" "$STATE_DIRECTORY/waiting-$other"
    echo "$tree" >"$STATE_DIRECTORY/current-$other"
  done
}
deliver_others
# deploy.sh copies its completed lock back; keep the tree on main's lock.
git checkout --quiet -- flake.lock

# Succeeds when a cache holds every package of ci/cached-packages.nix that a
# host uses at this lock, since this host builds every host's system. The host-packages-cache workflow builds them every
# hour for the newest inputs; cache.nixos.org holds one that nixpkgs builds
# unchanged.
packages_cached() {
  local paths path
  paths=$(nix eval --impure --raw --expr 'import ./ci/cached-packages.nix (builtins.getFlake (toString ./.))' \
    --apply "hosts: builtins.concatStringsSep \"\\n\" (builtins.concatMap
      (p: map (o: p.\${o}.outPath) p.outputs) (builtins.concatMap builtins.attrValues (builtins.attrValues hosts)))") ||
    {
      echo "ci/cached-packages.nix does not evaluate at this lock."
      return 1
    }
  while read -r path; do
    [[ -n $path ]] || continue
    path=${path#/nix/store/}
    curl -fs --max-time 20 --retry 2 -o /dev/null "https://omerfarukoruc.cachix.org/${path%%-*}.narinfo" ||
      curl -fs --max-time 20 --retry 2 -o /dev/null "https://cache.nixos.org/${path%%-*}.narinfo" ||
      return 1
  done <<<"$paths"
}

# The inputs the packages of ci/cached-packages.nix come from. They move below,
# once the cache holds those packages. The Glass inputs are pinned to a
# commit, so they never move here.
cached_from=(nixpkgs dms sops-nix)
tags=$(scripts/move-inputs.sh --except "${cached_from[@]}")
# The kernel input moves only through update-kernel.sh, which first checks
# that the kernel cache holds the new build.
scripts/update-kernel.sh || echo "The kernel input stays where it is."

held=$(mktemp -d)
hold() { cp flake.nix flake.lock "$held/"; }
release() { cp "$held/flake.nix" "$held/flake.lock" .; }

# A new nixpkgs or DMS release needs new builds of the packages in
# ci/cached-packages.nix, which would compile here at full load. Their inputs
# wait for the cache, but for a day at most, so one broken build cannot hold
# back every other package's fixes.
since=$STATE_DIRECTORY/packages-held-since
hold
cached_tags=$(scripts/move-inputs.sh "${cached_from[@]}")
if cmp -s flake.lock "$held/flake.lock"; then
  :
elif packages_cached; then
  rm -f -- "$since" "$since.notified"
  [[ -n $cached_tags ]] && tags+=${tags:+$'\n'}$cached_tags
else
  [[ -f $since && $(<"$since") =~ ^[0-9]+$ ]] || date +%s >"$since"
  if (($(date +%s) - $(<"$since") < 86400)); then
    echo "The cache lacks builds for the new ${cached_from[*]}; they stay where they are."
    release
  else
    echo "Builds have been missing from the cache for a day; ${cached_from[*]} move and this host compiles them."
    if [[ ! -f $since.notified ]]; then
      notify normal "Builds not in the cache" "nixpkgs waited a day for the host-packages-cache builds. Updates compile them on the laptop until that workflow works again." &&
        touch "$since.notified"
    fi
    [[ -n $cached_tags ]] && tags+=${tags:+$'\n'}$cached_tags
  fi
fi

# llm-agents moves only while cache.numtide.com holds every coding agent of its
# new revision. Unlike the inputs above, it has no day limit.
hold
nix flake update llm-agents
if ! cmp -s flake.lock "$held/flake.lock"; then
  uncached=$(uncached_agents)
  if [[ -n $uncached ]]; then
    echo "cache.numtide.com lacks: ${uncached//$'\n'/ }. llm-agents stays where it is."
    release
  fi
fi
apps=
# Every app in pkgs/ that update-app.sh can move. A new
# version joins the candidate only once it builds on its own, so one broken app
# release never holds back the inputs and the other apps.
while read -r file; do
  app=$(basename "$file" .nix)
  # update-app.sh names the problem on its last stderr line. The first run with
  # a new problem notifies; a run that succeeds clears it.
  failed_check=$STATE_DIRECTORY/check-failed-$app
  if ! version=$(scripts/update-app.sh "$app" 2>"$failed_check.err"); then
    cat "$failed_check.err"
    reason=$(tail -n 1 "$failed_check.err")
    reason=${reason:-update-app.sh failed without a message}
    echo "$app stays where it is."
    if [[ ! -f $failed_check || $(<"$failed_check") != "$reason" ]]; then
      notify normal "$app update check failed" "$reason. $app stays where it is. See: journalctl -u oruc-auto-update" &&
        echo "$reason" >"$failed_check"
    fi
    continue
  fi
  rm -f -- "$failed_check" "$failed_check.err"
  [[ -n $version ]] || continue
  broken=$STATE_DIRECTORY/broken-$app
  build_log=$STATE_DIRECTORY/build-$app.log
  built=true
  nix build --no-link --impure --expr \
    "(builtins.getFlake \"git+file://$PWD\").nixosConfigurations.$host.pkgs.callPackage ./$file { }" \
    </dev/null 2>"$build_log" || built=false
  cat "$build_log" >&2
  if $built; then
    rm -f -- "$broken" "$build_log"
    apps+=$'\n'"- $app: $version"
    continue
  fi
  git checkout -- "$file"
  # shellcheck source=/dev/null
  . scripts/lib/build-error.sh
  reason=$(build_error "$build_log")
  echo "$app $version does not build: ${reason:-no error line}. It stays where it is."
  # Each run builds it again, since a fix on main or a failed download can
  # clear the failure, but only the first failure of a version notifies.
  [[ -f $broken && $(<"$broken") == "$version" ]] && continue
  notify normal "$app update skipped" "$app $version does not build: ${reason:-no error line}. The other updates go ahead. See: journalctl -u oruc-auto-update" &&
    echo "$version" >"$broken"
done < <(printf '%s\n' pkgs/*.nix)

if git diff --quiet; then
  echo "Everything is current."
  exit 0
fi

candidate=$({
  echo "$base"
  git diff
} | sha256sum)
if [[ -f $failed && $(<"$failed") == "$candidate" ]]; then
  echo "This candidate failed before; waiting for main or an upstream to move."
  exit 0
fi

# Inputs that moved to a new release tag are listed by version instead.
changes=$(jq -rn --slurpfile old <(git show "$base:flake.lock") --slurpfile new flake.lock \
  --arg tagged "$(cut -d: -f1 <<<"$tags")" '
  ($tagged | split("\n")) as $skip
  | $new[0].nodes | to_entries[] | select(.value.locked.rev) | .key as $name
  | select($skip | index($name) | not)
  | ($old[0].nodes[$name].locked.rev // "none") as $from | .value.locked.rev as $to
  | select($from != $to) | "- \($name): \($from[0:7]) -> \($to[0:7])"')
[[ -n $tags ]] && changes+=$'\n'"- ${tags//$'\n'/$'\n'- }"
changes+=$apps

git commit --quiet -am "chore(flake): update inputs to their newest releases" -m "$changes"

old_system=$(readlink -f /run/current-system)
status=0
other_hosts_build || status=$?
if ((status == 0)); then
  ./deploy.sh "$host" switch || status=$?
fi
if ((status == 77 || status == 78)); then
  # 77 is another deploy to this host and 78 a running release whose files main
  # lacks. Neither is the candidate's fault, so the next run tries again. 78
  # notifies on the first run it holds back; 77 only when it holds back a second
  # run in a row, because a deploy that holds the lock an hour later is stuck.
  # A 78 notification that was not delivered leaves no record, so the next run
  # sends it; a 77 run keeps its record, so the next run sends it again.
  previous=
  [[ -f $waiting ]] && previous=$(<"$waiting")
  record=$status
  if ((status == 78)) && [[ $previous != 78 ]]; then
    notify normal "Update waiting" "$host runs a release with changes main lacks. Merge them, or deploy main with --replace. See: journalctl -u oruc-auto-update" || record=
  elif ((status == 77)) && [[ $previous == 77 ]]; then
    notify normal "Update waiting" "Another deploy has held $host's deploy lock since the last run. See: journalctl -u oruc-auto-update" || true
  fi
  if [[ -n $record ]]; then
    echo "$record" >"$waiting"
  else
    rm -f -- "$waiting"
  fi
  exit 0
fi
if ((status != 0)); then
  # 70 is a pending rollback timer from another deploy, 71 a rollback timer
  # that could not be armed, 74 a full ESP and 79 an unmounted /boot; none is
  # the candidate's fault, so the next run tries it again.
  if ((status != 70 && status != 71 && status != 74 && status != 79)); then
    echo "$candidate" >"$failed"
  fi
  fail "Update failed" "Exit $status. See: journalctl -u oruc-auto-update"
  exit 1
fi
rm -f -- "$failed" "$waiting"

# deploy.sh copies back a lock that the build completed; keep it in the commit.
if ! git diff --quiet; then
  git commit --quiet --amend --no-edit -a
fi

# Merge only what this host built. If main moved, the next run rebuilds on it.
# A PR that lands between this fetch and the merge below joins main with this
# update unbuilt, the same gap every PR has without an up-to-date rule; CI
# evaluates main after the push.
git "${git_auth[@]}" fetch --quiet origin main
if [[ $(git rev-parse origin/main) != "$base" ]]; then
  notify normal "System updated" "$changes"$'\n'"main moved during the build, so the next run merges." || true
  exit 0
fi

flock -u "$build_lock"
# GitHub answers every push of the branch, which the merge below deletes, with
# a hint to open a pull request; only a failed push shows what it printed.
if ! push_output=$(git "${git_auth[@]}" push --quiet --force origin "$branch" 2>&1); then
  printf '%s\n' "$push_output" >&2
  false
fi
# GitHub caps a PR body at 65536 characters.
system_diff=$(dix --color never "$old_system" "$(readlink -f /run/current-system)" 2>&1) ||
  system_diff="dix could not compare the systems."
if ((${#system_diff} > 50000)); then
  system_diff="${system_diff:0:50000}
(cut at 50000 characters)"
fi
body="$host built and switched to this update.

$changes

<details><summary>System diff</summary>

\`\`\`text
$system_diff
\`\`\`
</details>"
gh pr create --repo "$repo" --base main --head "$branch" \
  --title "chore(flake): update inputs to their newest releases" --body "$body" ||
  gh pr edit "$branch" --repo "$repo" --body "$body"

# The merge waits for the PR's checks on the pushed commit: check, unit-cycles,
# host-systems-build, which builds on this host with the build lock this run
# let go of above, and any other check GitHub starts. Prints "success",
# "retry REASON" or "failure NAMES". A rerun of a check counts by its newest
# run. host-systems-build fails without the commit's fault when this host went
# on battery or the lock stayed busy; its annotation says so.
checks_result() {
  local sha=$1 deadline=$((SECONDS + 45 * 60)) runs failed id
  while ((SECONDS < deadline)); do
    sleep 30
    runs=$(gh api "repos/$repo/commits/$sha/check-runs?per_page=100" \
      --jq '[.check_runs[] | {id, name, status, conclusion}] | group_by(.name) | map(max_by(.id)) | tostring') || continue
    jq -e '([.[].name] | contains(["check", "unit-cycles", "host-systems-build"]))
      and all(.[]; .status == "completed")' <<<"$runs" >/dev/null || continue
    failed=$(jq -r '[.[] | select(.conclusion | IN("success", "skipped", "neutral") | not) | .name] | join(" ")' <<<"$runs")
    if [[ -z $failed ]]; then
      echo success
    elif [[ $failed == host-systems-build ]]; then
      id=$(jq -r '.[] | select(.name == "host-systems-build") | .id' <<<"$runs")
      if [[ $(gh api "repos/$repo/check-runs/$id/annotations" --jq '.[].message') =~ runs\ on\ battery|build\ lock|does\ not\ answer ]]; then
        echo "retry host-systems-build could not build on this host"
      else
        echo "failure $failed"
      fi
    else
      echo "failure $failed"
    fi
    return
  done
  echo "retry the checks did not finish in 45 minutes"
}
checks=$(checks_result "$(git rev-parse HEAD)")
case $checks in
  success) rm -f -- "$waiting" ;;
  retry*)
    echo "The PR's checks are not green: ${checks#retry }. The next run tries again."
    # Notifies from the second run in a row that the checks hold back.
    if [[ -f $waiting && $(<"$waiting") == checks ]]; then
      notify normal "Update waiting" "The update PR's checks are not green: ${checks#retry }. See: journalctl -u oruc-auto-update" || true
    fi
    echo checks >"$waiting"
    exit 0
    ;;
  *)
    echo "$candidate" >"$failed"
    fail "Update not merged" "The update PR's checks failed: ${checks#failure }. The run does not try this update again until main or an upstream moves."
    exit 1
    ;;
esac
gh pr merge "$branch" --repo "$repo" --squash --delete-branch --match-head-commit "$(git rev-parse HEAD)"
notify normal "System updated" "$changes" || true
deliver_others
