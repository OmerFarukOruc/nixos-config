# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # host, unit_name, status and outcome belong to the caller
# The steps that scripts/pull-main.sh (nixos-rog) and scripts/self-deploy.sh
# (servers) share, sourced from the Nix store by the unit that
# nixosModules/deploy-unit.nix builds (DEPLOY_LIB names this file). The caller
# defines warn MESSAGE and fail MESSAGE, the way it reports a quiet and a
# failed run, and sets host and unit_name.

# github_config: when the unit loads a GitHub token as a credential, writes it
# to a private nix.conf and gh config under RUNTIME_DIRECTORY and points
# NIX_CONFIG and GH_CONFIG_DIR at them. Nix fetches the flake inputs through
# GitHub's API, whose limit for a client without a token is too low for an
# evaluation, and deploy.sh asks gh which pull request merged a running release.
# Shell builtins keep the token out of argv, and exported variables carry paths
# only.
github_config() {
  [[ -n ${CREDENTIALS_DIRECTORY:-} ]] || return 0
  local token
  umask 077
  [[ $RUNTIME_DIRECTORY == /* ]]
  token=$(<"$CREDENTIALS_DIRECTORY/github-token")
  [[ $token =~ ^[a-zA-Z0-9_]+$ ]]
  printf 'access-tokens = github.com=%s\n' "$token" >"$RUNTIME_DIRECTORY/nix.conf"
  mkdir -p "$RUNTIME_DIRECTORY/gh"
  printf 'github.com:\n    oauth_token: %s\n    git_protocol: https\n' "$token" >"$RUNTIME_DIRECTORY/gh/hosts.yml"
  chmod 600 "$RUNTIME_DIRECTORY/nix.conf" "$RUNTIME_DIRECTORY/gh/hosts.yml"
  export NIX_CONFIG="include $RUNTIME_DIRECTORY/nix.conf"
  export GH_CONFIG_DIR="$RUNTIME_DIRECTORY/gh"
}

# remote_failed clone|fetch: a failed clone or fetch is quiet only during a
# network outage. Any other failure, such as lost repository access, would stop
# every deploy with no sign, so it fails the run.
remote_failed() {
  # Any HTTP answer, even an error status, shows that GitHub is reachable.
  if curl -sS --max-time 20 --retry 2 -o /dev/null https://github.com; then
    fail "git $1 failed while GitHub answers. See: journalctl -u $unit_name"
    exit 1
  fi
  warn "GitHub is unreachable; the next run tries again."
  exit 0
}

# exit_on_download_failure LOG: LOG is the stderr of an evaluation or build of
# main that failed. A failed download, such as GitHub's API limit, says nothing
# about main, so the run fails without recording this main, and the next run
# tries again. Any other error is main's own. Only an error line counts, because
# Nix also prints a warning for each retry of a download that later succeeds.
exit_on_download_failure() {
  grep -qE '^[[:space:]]*error:.*unable to download' "$1" || return 0
  fail "The evaluation of main at ${main:0:12} could not download an input. main is not recorded as failed, and the next run tries again. See: journalctl -u $unit_name"
  exit 1
}

# sync_main REPOSITORY DIRECTORY: clones the repository when DIRECTORY holds no
# clone, then moves it to origin/main and cleans it. Leaves the shell in
# DIRECTORY and sets main to the commit.
sync_main() {
  local attempt fetched=false
  if [[ ! -d $2/.git ]]; then
    git clone --quiet "$1" "$2" || remote_failed clone
  fi
  cd "$2" || return
  for attempt in 1 2 3; do
    if git fetch --quiet origin main; then
      fetched=true
      break
    fi
    ((attempt == 3)) || sleep 10
  done
  $fetched || remote_failed fetch
  git checkout --quiet --force --detach origin/main
  git clean -fdxq
  main=$(git rev-parse HEAD)
}

# deploy_main: deploys the clone in the current directory to this host with
# deploy.sh. Sets status to deploy.sh's exit status and outcome to
#   done    the host runs main;
#   wait    70 is the pending rollback timer of another deploy, 77 another
#           deploy holding the lock, 78 a running release whose files main lacks.
#           None changed this host;
#   retry   71 is a rollback timer that could not be armed, 74 a full ESP and 79
#           an unmounted /boot. None is main's fault, so the next run tries
#           again;
#   failed  any other status, such as a build that fails again or 73, a switch
#           whose boot entries failed, after which this host runs main while the
#           next boot starts the previous system.
# deploy.sh uploads a release before it finds a pending rollback timer, so asking
# first keeps a held-back run from leaving a release behind.
deploy_main() {
  status=0
  if systemctl is-active --quiet deploy-rollback.timer; then
    echo "A rollback timer from another deploy is pending."
    status=70
  else
    echo "Deploying main at ${main:0:12} to $host."
    ./deploy.sh "$host" switch || status=$?
  fi
  case $status in
    0) outcome='done' ;;
    70 | 77 | 78) outcome='wait' ;;
    71 | 74 | 79) outcome='retry' ;;
    *) outcome='failed' ;;
  esac
}
