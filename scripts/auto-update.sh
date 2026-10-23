#!/usr/bin/env bash
# Runs on nixos-rog from oruc-auto-update.service. Moves the flake inputs and
# every app in pkgs/ that names a release source to their newest release,
# deploys the result to this host with deploy.sh, and publishes the commit it
# deployed to main with a fast-forward push through a PR.
# The kernel and llm-agents move only while a cache holds the builds they need.
# Every other host must build here first, and the checks of check.yml must pass
# here; the run deploys to no other host.
# nixpkgs, dms and sops-nix wait for the cache for a day at most
# (see below).
# When nothing moves and this host runs a system other than main's, the run
# deploys main to this host and merges nothing.
# When main moves before the switch or before the push, the run starts a new
# round on the new main, within the bounds at max_rounds below.
# A candidate that fails another host's build, a check, this host's build or
# the activation is not tried again until main or an upstream moves. The run
# waits and deploys again after this host's deploy.sh status 70 or 77, and
# retries in the next run after 71, 74, 78 or 79; none is the candidate's fault.
# With AUTO_UPDATE_REHEARSAL=1 (oruc-auto-update-rehearsal.service, `upgrade
# --rehearse`) the run starts from main with the flake.lock of before the newest
# update, so that update's moves happen again. It builds this host's system
# instead of deploying it, and merges into a throwaway base branch, because a
# deployed tree that never reaches main makes later deploys of main exit 78.
# AUTO_UPDATE_REHEARSAL_MAIN names a branch the rehearsal reads in place of
# main, so a test can move it during a run.
# -E lets the ERR trap below fire inside functions too.
set -Eeuo pipefail

repo=OmerFarukOruc/nixos-config
branch=auto-update
base_branch=main
# The branch whose movement starts a new round.
main_branch=main
unit_name=oruc-auto-update
pr_title="chore(flake): update inputs to their newest releases"
rehearsal=false
title_prefix=
if [[ ${AUTO_UPDATE_REHEARSAL:-} == 1 ]]; then
  rehearsal=true
  unit_name=oruc-auto-update-rehearsal
  pr_title="chore(flake): rehearse an update of the inputs"
  branch=auto-update-rehearsal
  base_branch=auto-update-rehearsal-base
  main_branch=${AUTO_UPDATE_REHEARSAL_MAIN:-main}
  title_prefix="Rehearsal: "
fi
# Set once the rehearsal pushed its base branch, which on_exit deletes.
base_pushed=false
# True while this host runs an update that this run deployed and has not
# published yet.
unpublished=false
host=$(</proc/sys/kernel/hostname)
dir=$STATE_DIRECTORY/repo
failed=$STATE_DIRECTORY/failed-candidate
# The deploy.sh exit status that held the last run back.
waiting=$STATE_DIRECTORY/waiting
# "<commit> <system>" when main at that commit builds the system this host
# runs, such as after a docs change. The next quiet run on that commit and
# system then skips the evaluation, which made such a run take 58 s and 6.9 GiB
# instead of about 10 s (journal, 2026-10-23).
same=$STATE_DIRECTORY/same-system
# The personal Git config pushes over SSH and signs with an agent key; the
# service has neither.
export GIT_CONFIG_GLOBAL=/dev/null
# git's automatic gc and maintenance run in the foreground, because a detached
# one would inherit the build lock below and hold it after the run.
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=gc.autoDetach GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=maintenance.autoDetach GIT_CONFIG_VALUE_1=false
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
  DBUS_SESSION_BUS_ADDRESS=unix:path=$bus timeout 5 notify-send -a "System update" -u "$1" -- "$title_prefix$2" "$3"
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
    notify critical "Update failed" "Exit $status. See: journalctl -u $unit_name" || true
  fi
  if $unpublished; then
    notify normal "Update published nowhere" "$host runs an update that main lacks. A later run publishes it; until then a deploy of main from another checkout can exit 78. To drop the update, deploy main with --replace. See: journalctl -u $unit_name" || true
  fi
  [[ -z $held ]] || rm -rf -- "$held" || true
  if $base_pushed; then
    # systemd gives a stopping run 30 s, and the TERM trap's popup can take 5.
    timeout 15 git -C "$dir" "${git_auth[@]}" push --quiet origin --delete "$base_branch" || true
  fi
}
trap on_exit EXIT
# A failure inside $(...) runs this trap in the subshell and again in the main
# shell, so only the main shell reports.
trap '[[ $BASHPID != "$$" ]] || fail "Update failed" "See: journalctl -u $unit_name"' ERR
# systemd ends the run with SIGTERM at the unit's TimeoutStartSec or when the
# system shuts down, and SIGTERM skips the ERR trap.
trap 'fail "Update stopped" "systemd stopped the run at its time limit or for a shutdown. See: journalctl -u $unit_name"; exit 143' TERM

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

# A failed clone or fetch is quiet only during a network outage. Any other
# failure, such as a revoked token or lost repository access, would stop every
# update with no sign, so it notifies and fails.
remote_failed() {
  # Any HTTP answer, even an error status, shows that GitHub is reachable.
  if curl -sS --max-time 20 --retry 2 -o /dev/null https://github.com; then
    echo "git $1 failed while GitHub answers; check the token and the repository access." >&2
    fail "Update failed" "git $1 failed while GitHub is reachable. Check the token. See: journalctl -u $unit_name"
    exit 1
  fi
  echo "GitHub is unreachable; the next run tries again."
  exit 0
}

# git asks gh for credentials from the private runtime hosts.yml.
git_auth=(-c 'credential.helper=' -c 'credential.helper=!gh auth git-credential')
# push REFSPEC: force-pushes to origin. GitHub answers a push of a branch with a
# hint to open a pull request; only a failed push shows what it printed.
push() {
  local output
  if ! output=$(git "${git_auth[@]}" push --quiet --force origin "$1" 2>&1); then
    printf '%s\n' "$output" >&2
    return 1
  fi
}

# The host-systems-build check (scripts/pr-build.sh) takes the same lock, so a
# PR build and this run never evaluate or build at once. The run takes it before
# it reads main, because main often moves while it waits: a PR build that ends
# frees the lock, and its PR merges seconds later.
exec {build_lock}>>/run/nixos-config-build.lock
if ! flock -w 1800 "$build_lock"; then
  echo "A PR build or the other updater unit has held the build lock for 30 min; the next run tries again."
  # Notifies from the second run in a row that the lock holds back.
  if [[ -f $waiting && $(<"$waiting") == lock ]]; then
    notify normal "Update waiting" "PR builds or the other updater unit have held the build lock for 30 minutes in two runs in a row. See: journalctl -u $unit_name" || true
  fi
  echo lock >"$waiting"
  exit 0
fi
if [[ -f $waiting && $(<"$waiting") == lock ]]; then
  rm -f -- "$waiting"
fi
locked_at=$SECONDS

if [[ ! -d $dir/.git ]]; then
  git "${git_auth[@]}" clone --quiet "https://github.com/$repo.git" "$dir" || remote_failed clone
fi
cd "$dir"

# fetch_main: updates origin/$main_branch. A second and third try cover a
# network blip after the switch, where a quiet exit would hide the update.
fetch_main() {
  local attempt
  for attempt in 1 2 3; do
    git "${git_auth[@]}" fetch --quiet origin "$main_branch" && return 0
    ((attempt == 3)) || sleep 10
  done
  remote_failed fetch
}

# main_moved: succeeds when main is no longer at the commit this round started
# from.
main_moved() {
  fetch_main
  [[ $(git rev-parse "origin/$main_branch") != "$main" ]]
}

# A run starts a new round on the new main when main moves before its switch
# or before its push, at most max_rounds in all. No round and no deploy retry
# starts after the run has held the build lock for admit_seconds, because PR
# builds wait at most 60 min for it (scripts/pr-build.sh). A round that started
# runs to its end, so the hold can reach admit_seconds plus one round. Of 119
# runs in the journal (2026-10-16 to 2026-10-23), the longest took 19 min and
# the slowest deploy 659 s, so the hold stays below that hour.
max_rounds=3
admit_seconds=$((20 * 60))
may_go_on() { ((SECONDS - locked_at < admit_seconds)); }
may_start_round() { ((round < max_rounds)) && may_go_on; }

# give_up WHEN: main moved WHEN in the last round the bounds allow.
give_up() {
  echo "main moved $1 in round $round, and the bounds allow no further round; the next run tries again."
  # on_exit reports an update this host runs unpublished.
  if ! $unpublished; then
    notify normal "Update not applied" "${changes:+$changes$'\n'}main kept moving during $round rounds, so this run left $host as it was. The next run tries again." || true
  fi
  exit 0
}

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

# The checks of CI's check job (ci/checks.sh) and unit-cycles job, so the PR can
# merge without waiting for GitHub. The builds above cover the hosts job.
# ci/checks.sh forbids import from derivation itself; this covers
# ci/unit-cycles.sh.
local_checks() {
  local -x NIX_CONFIG="$NIX_CONFIG"$'\n''allow-import-from-derivation = false'
  ci/checks.sh && ci/unit-cycles.sh || return 76
}

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

held=$(mktemp -d)
# Each release restores the hold of the same round, since an older one would
# put back the flake files of an older main.
hold() { cp flake.nix flake.lock "$held/"; }
release() { cp "$held/flake.nix" "$held/flake.lock" .; }

# The inputs the packages of ci/cached-packages.nix come from. They move below,
# once the cache holds those packages. The Glass inputs are pinned to a
# commit, so they never move here.
cached_from=(nixpkgs dms sops-nix)
# The system this host ran before the run, which the PR body compares with.
old_system=$(readlink -f /run/current-system)
round=0
# Each round starts at the top of this loop with plain assignments, so no
# value of an earlier round's tree carries over. It stays at the top level,
# outside a function, because bash ignores set -e in a function called from a
# condition.
while :; do
  round=$((round + 1))
  changes=
  fetch_main
  main=$(git rev-parse "origin/$main_branch")
  base=$main
  echo "Round $round starts on $main_branch at ${main:0:12}."
  git checkout --quiet --force -B "$branch" "$base"
  git clean -fdxq
  if $rehearsal; then
    last=$(git log -1 --format=%H --grep='^chore(flake): update inputs' "$base" -- flake.lock)
    if [[ -z $last ]]; then
      echo "$main_branch holds no update commit that changed flake.lock, so the rehearsal has no older lock to start from." >&2
      false
    fi
    git checkout --quiet "$last^" -- flake.lock
    git commit --quiet -m "chore(flake): rehearsal base with the flake.lock of before ${last:0:7}"
    base=$(git rev-parse HEAD)
    base_pushed=true
    push "HEAD:refs/heads/$base_branch"
  fi

  tags=$(scripts/move-inputs.sh --except "${cached_from[@]}")
  # The kernel input moves only through update-kernel.sh, which first checks
  # that the kernel cache holds the new build.
  scripts/update-kernel.sh || echo "The kernel input stays where it is."

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
        notify normal "$app update check failed" "$reason. $app stays where it is. See: journalctl -u $unit_name" &&
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
    notify normal "$app update skipped" "$app $version does not build: ${reason:-no error line}. The other updates go ahead. See: journalctl -u $unit_name" &&
      echo "$version" >"$broken"
  done < <(printf '%s\n' pkgs/*.nix)

  # Without a move, the run deploys main to this host unless the host runs a
  # clean release of it. Each commit on main passed its checks before it merged,
  # so the run skips the commit, the other hosts' builds and the checks, and
  # merges nothing.
  main_only=false
  if git diff --quiet; then
    if $rehearsal; then
      echo "Everything is current."
      exit 0
    fi
    # shellcheck source=/dev/null
    . scripts/lib/running-revision.sh
    if runs_tree_of "$base" ||
      [[ -f $same && $(<"$same") == "$base $(readlink -f /run/current-system)" ]]; then
      echo "Everything is current."
      # main already holds what this host runs.
      unpublished=false
      exit 0
    fi
    main_only=true
  fi

  candidate=$({
    echo "$base"
    git diff
  } | sha256sum)
  if [[ -f $failed && $(<"$failed") == "$candidate" ]]; then
    echo "This candidate failed before; waiting for main or an upstream to move."
    exit 0
  fi

  if $main_only; then
    # A commit that leaves this host's system as it is, such as a docs change,
    # needs no deploy. A failed build goes on to deploy.sh, whose failure records
    # the candidate, so the next runs wait for main to move.
    if new_system=$(build_system "$host") && [[ $new_system == "$(readlink -f /run/current-system)" ]]; then
      # Only a skip of the next evaluation depends on it.
      echo "$base $new_system" >"$same" || true
      echo "Everything is current."
      unpublished=false
      exit 0
    fi
    echo "$host runs a system other than main's; deploying main at ${base:0:12}."
  else
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
  fi

  status=0
  if ! $main_only; then
    other_hosts_build || status=$?
    if ((status == 0)); then
      local_checks || status=$?
    fi
    # This host's own build comes before the check of main below, so that the
    # deploy after it mostly activates and main has less time to move.
    if ((status == 0)); then
      new_system=$(build_system "$host") || status=$?
    fi
    # A switch to a tree that main has left behind would activate a commit that
    # the push below refuses. A deploy of main itself stays on main.
    if ((status == 0)) && main_moved; then
      if may_start_round; then
        echo "main moved before the switch; a new round starts."
        continue
      fi
      give_up "before the switch"
    fi
  fi
  if ((status == 0)) && ! $rehearsal; then
    # 77 is another deploy to this host and 70 the pending rollback timer of one.
    # Neither changed this host, so the run waits and deploys again. The run
    # checks the timer itself first, because deploy.sh finds it only after it
    # uploaded a release.
    while :; do
      status=0
      if systemctl is-active --quiet deploy-rollback.timer; then
        echo "A rollback timer from another deploy is pending."
        status=70
      else
        ./deploy.sh "$host" switch || status=$?
      fi
      # A 78 right after the check of main can come from a newer main that
      # another checkout deployed.
      if ((status == 78)) && may_start_round && main_moved; then
        echo "main moved and deploy.sh found its release; a new round starts."
        continue 2
      fi
      if ((status != 70 && status != 77)) || ! may_go_on; then
        break
      fi
      echo "deploy.sh cannot deploy now (status $status); trying again in 60 s."
      sleep 60
      # The other deploy may have installed a newer main. This tree lacks its
      # files, so deploy.sh would exit 78.
      if main_moved; then
        if may_start_round; then
          echo "main moved while the deploy waited; a new round starts."
          continue 2
        fi
        give_up "while the deploy waited"
      fi
    done
    new_system=$(readlink -f /run/current-system)
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
      notify normal "Update waiting" "$host runs a release with changes main lacks. Merge them, or deploy main with --replace. See: journalctl -u $unit_name" || record=
    elif ((status == 77)) && [[ $previous == 77 ]]; then
      notify normal "Update waiting" "Another deploy has held $host's deploy lock since the last run. See: journalctl -u $unit_name" || true
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
    # 73 is a switch whose boot entries failed, so the host runs what it
    # deployed.
    if ((status == 73)); then
      if $main_only; then unpublished=false; else unpublished=true; fi
    fi
    fail "Update failed" "Exit $status. See: journalctl -u $unit_name"
    exit 1
  fi
  rm -f -- "$failed" "$waiting"
  if $main_only; then
    unpublished=false
    notify normal "System updated" "$host now runs main at ${base:0:12}." || true
    exit 0
  fi
  $rehearsal || unpublished=true

  # deploy.sh copies back a lock that the build completed; keep it in the commit.
  if ! git diff --quiet; then
    git commit --quiet --amend --no-edit -a
  fi

  # When main moved during the switch, a new round builds the update on the new
  # main and switches to that, so main only gets a tree this host runs.
  if main_moved; then
    if may_start_round; then
      echo "main moved during the switch; a new round starts."
      continue
    fi
    give_up "during the switch"
  fi

  push "$branch"
  # GitHub caps a PR body at 65536 characters.
  system_diff=$(dix --color never "$old_system" "$new_system" 2>&1) ||
    system_diff="dix could not compare the systems."
  if ((${#system_diff} > 50000)); then
    system_diff="${system_diff:0:50000}
(cut at 50000 characters)"
  fi
  if $rehearsal; then
    done_text="built this update in a rehearsal and activated nothing."
  else
    done_text="built and switched to this update."
  fi
  body="$host $done_text

$changes

<details><summary>System diff</summary>

\`\`\`text
$system_diff
\`\`\`
</details>"
  gh pr create --repo "$repo" --base "$base_branch" --head "$branch" \
    --title "$pr_title" --body "$body" ||
    gh pr edit "$branch" --repo "$repo" --body "$body"

  # The PR merges at once, since the checks above ran here; GitHub runs check,
  # hosts, unit-cycles and build again on main after the merge and emails a
  # failure. A fast-forward push of the commit this host runs merges it, and
  # GitHub refuses that push when main moved after the check above, where a
  # squash merge would land on the newer main as a tree no host built. GitHub
  # marks a PR merged once its head commit is on the base branch, and then
  # deletes the PR's branch, as the repository's settings ask.
  # A push that fails while main stays put, such as a server error, is tried
  # again. A push whose answer got lost can have landed, so the run first
  # checks whether main holds the commit.
  pushed=false
  for attempt in 1 2 3; do
    if push_output=$(git "${git_auth[@]}" push --quiet origin "HEAD:refs/heads/$base_branch" 2>&1); then
      pushed=true
      break
    fi
    printf '%s\n' "$push_output" >&2
    moved=false
    main_moved && moved=true
    if [[ $base_branch != "$main_branch" ]]; then
      git "${git_auth[@]}" fetch --quiet origin "$base_branch" || true
    fi
    if git merge-base --is-ancestor HEAD "origin/$base_branch"; then
      pushed=true
      break
    fi
    if $moved; then
      if may_start_round; then
        echo "main moved before the push; a new round starts."
        continue 2
      fi
      give_up "before the push"
    fi
    ((attempt == 3)) || sleep 10
  done
  $pushed
  unpublished=false
  notify normal "System updated" "$changes" || true
  exit 0
done
