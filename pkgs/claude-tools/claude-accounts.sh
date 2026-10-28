# shellcheck shell=bash

claude() {
  local bin="@bin@" pin=0 name="" dir a
  local pick="${CLAUDE_ACCOUNTS_PICK:-}" plain="${CLAUDE_ACCOUNTS_PLAIN:-}"
  local -a rest
  unset CLAUDE_ACCOUNTS_PICK CLAUDE_ACCOUNTS_PLAIN
  rest=()
  while [ "$#" -gt 0 ]; do
    a=$1
    shift
    case "$a" in
      --account)
        pin=1 name="${1:-}"
        [ "$#" -eq 0 ] || shift
        ;;
      --account=*) pin=1 name="${a#--account=}" ;;
      --)
        rest+=("$a" "$@")
        break
        ;;
      *) rest+=("$a") ;;
    esac
  done
  set -- "${rest[@]}"
  if [ "$pin" = 1 ]; then
    [ -n "$name" ] || {
      echo "usage: claude --account NAME [ARGS]" >&2
      return 2
    }
    dir=$("$bin/claude-accounts" dir "$name") || return
    if [ -z "$dir" ]; then (
      unset CLAUDE_CONFIG_DIR
      command claude "$@"
    ); else CLAUDE_CONFIG_DIR="$dir" command claude "$@"; fi
  elif [ -n "${CLAUDE_CONFIG_DIR:-}${CLAUDE_ROTATE_ID:-}$plain" ] || [ ! -t 0 ] || [ ! -t 1 ]; then
    command claude "$@"
  else
    CLAUDE_ACCOUNTS_PICK="$pick" "$bin/claude-rotate" "$@"
  fi
}

_claude_accounts_words() {
  if [ "$1" -le 1 ]; then
    echo list add rename update prefs delete login login-window login-all names dir --watch --json --cached
  else
    "@bin@/claude-accounts" names
  fi
}

if [ -n "${ZSH_VERSION:-}" ] && type compdef >/dev/null 2>&1; then
  # shellcheck disable=SC2046
  _claude_accounts() { compadd $(_claude_accounts_words $((CURRENT - 1))); }
  compdef _claude_accounts claude-accounts
elif [ -n "${BASH_VERSION:-}" ] && type complete >/dev/null 2>&1; then
  _claude_accounts() { mapfile -t COMPREPLY < <(compgen -W "$(_claude_accounts_words "$COMP_CWORD")" -- "${COMP_WORDS[COMP_CWORD]}"); }
  complete -F _claude_accounts claude-accounts
fi
