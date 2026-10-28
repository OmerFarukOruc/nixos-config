# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # host, unit_name, status and outcome belong to the caller

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

remote_failed() {
  if curl -sS --max-time 20 --retry 2 -o /dev/null https://github.com; then
    fail "git $1 failed while GitHub answers. See: journalctl -u $unit_name"
    exit 1
  fi
  warn "GitHub is unreachable; the next run tries again."
  exit 0
}

exit_on_download_failure() {
  grep -qE '^[[:space:]]*error:.*unable to download' "$1" || return 0
  fail "The evaluation of main at ${main:0:12} could not download an input. main is not recorded as failed, and the next run tries again. See: journalctl -u $unit_name"
  exit 1
}

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
