# shellcheck shell=bash disable=SC2034 # ci/checks.sh and scripts/affected-hosts.sh read HOST_SYSTEM_EXPR
HOST_SYSTEM_EXPR='h: {
  drv = h.config.system.build.toplevel.drvPath;
  out = h.config.system.build.toplevel.outPath;
  deployed = h.config.oruc.machine.deployed or true;
  deployLogin = h.config.oruc.machine.deployLogin or null;
}'

host_names() {
  local flake=$1 names
  shift
  names=$(nix eval "$@" --json --no-write-lock-file "$flake#nixosConfigurations" --apply builtins.attrNames |
    jq -r '.[]') || return 1
  [[ -n $names ]] || {
    echo "The flake defines no host." >&2
    return 1
  }
  printf '%s\n' "$names"
}

host_systems_file() {
  local version
  version=$(nix --version)
  printf '%s/nixos-config/affected-hosts/%s-nix-%s.json\n' "${XDG_CACHE_HOME:-$HOME/.cache}" "$1" "${version##* }"
}

valid_host_systems() {
  jq -e 'type == "object" and length > 0
    and all(.[]; (.drv | type) == "string" and (.out | type) == "string")' \
    >/dev/null 2>&1
}

store_host_systems() {
  local file tmp
  file=$(host_systems_file "$1")
  valid_host_systems <<<"$2" || return 1
  mkdir -p "${file%/*}" && tmp=$(mktemp "${file%/*}/.$1.XXXXXX") || return 1
  { printf '%s\n' "$2" >"$tmp" && mv -f "$tmp" "$file"; } || {
    rm -f "$tmp"
    return 1
  }
}
