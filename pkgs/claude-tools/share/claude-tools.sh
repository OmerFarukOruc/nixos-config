claude() {
  local tools="@bin@/claude-tools" pin=0 name="" dir a
  local pick="${CLAUDE_TOOLS_PICK:-}" plain="${CLAUDE_TOOLS_PLAIN:-}"
  local -a rest
  unset CLAUDE_TOOLS_PICK CLAUDE_TOOLS_PLAIN
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
    dir=$("$tools" accounts dir "$name") || return
    if [ -z "$dir" ]; then (
      unset CLAUDE_CONFIG_DIR
      command claude "$@"
    ); else CLAUDE_CONFIG_DIR="$dir" command claude "$@"; fi
  elif [ -n "${CLAUDE_CONFIG_DIR:-}${CLAUDE_TOOLS_ROTATE_ID:-}$plain" ] || [ ! -t 0 ] || [ ! -t 1 ]; then
    command claude "$@"
  else
    CLAUDE_TOOLS_PICK="$pick" "$tools" rotate "$@"
  fi
}

_claude_tools_words() {
  if [ "$1" -le 1 ]; then
    echo accounts usage rotate limit-switch agent orch
    return
  fi
  case "$2" in
    accounts)
      if [ "$1" -eq 2 ]; then
        echo list add rename update prefs delete login login-window login-all names dir dirs --watch --json --cached
      else
        "@bin@/claude-tools" accounts names
      fi
      ;;
    usage) echo --json --cached --max-age --account --quiet --watch --order --skip ;;
    limit-switch) if [ "$1" -eq 2 ]; then echo scan restore switch resume; fi ;;
    agent) if [ "$1" -eq 2 ]; then echo start stop peek; fi ;;
    orch) if [ "$1" -eq 2 ]; then echo notify watch; fi ;;
  esac
}

if [ -n "${ZSH_VERSION:-}" ] && type compdef >/dev/null 2>&1; then
  _claude_tools() { compadd $(_claude_tools_words $((CURRENT - 1)) "${words[2]:-}"); }
  compdef _claude_tools claude-tools
elif [ -n "${BASH_VERSION:-}" ] && type complete >/dev/null 2>&1; then
  _claude_tools() { mapfile -t COMPREPLY < <(compgen -W "$(_claude_tools_words "$COMP_CWORD" "${COMP_WORDS[1]}")" -- "${COMP_WORDS[COMP_CWORD]}"); }
  complete -F _claude_tools claude-tools
fi
