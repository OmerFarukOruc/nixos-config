# shellcheck shell=bash
# Sourced by Home Manager's zsh (home-manager/modules/claude-accounts.nix). It makes `claude` a function and completes
# claude-accounts:
#   claude [ARGS]                 claude-rotate shows every account's usage with the one with the most room under the
#                                 cursor, starts the session on the account you pick, and moves it to the next account
#                                 when it hits a usage limit (CLAUDE_ACCOUNTS_PICK=0 skips the list)
#   claude --account NAME [ARGS]  one session on NAME, without rotation; --account may sit anywhere before a `--`, so
#                                 the clauded alias (claude --dangerously-skip-permissions) takes it too
# Plain claude runs when CLAUDE_CONFIG_DIR is set, inside a claude-rotate session (CLAUDE_ROTATE_ID), for a herdr agent
# that claude-limit-switch moves (CLAUDE_ACCOUNTS_PLAIN=1, which its tools export before `herdr agent start` types
# `claude` at the pane's prompt), and when stdin or stdout is no terminal. A herdr pane you type in gets the list.
# CLAUDE_ACCOUNTS_PICK and CLAUDE_ACCOUNTS_PLAIN count for one start. The function unsets them in the calling shell, so
# a pane that exported them for an agent, or whose tab was created with them in --env, shows the list for the next
# `claude` typed there.

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

# Completion only where the shell has it loaded: an interactive zsh after compinit, an interactive bash.
if [ -n "${ZSH_VERSION:-}" ] && type compdef >/dev/null 2>&1; then
  # shellcheck disable=SC2046 # one completion per word
  _claude_accounts() { compadd $(_claude_accounts_words $((CURRENT - 1))); }
  compdef _claude_accounts claude-accounts
elif [ -n "${BASH_VERSION:-}" ] && type complete >/dev/null 2>&1; then
  # shellcheck disable=SC2207 # one completion per word
  _claude_accounts() { COMPREPLY=($(compgen -W "$(_claude_accounts_words "$COMP_CWORD")" -- "${COMP_WORDS[COMP_CWORD]}")); }
  complete -F _claude_accounts claude-accounts
fi
