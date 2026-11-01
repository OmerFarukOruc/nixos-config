# shellcheck shell=bash
host_system_apply() {
  echo 'h: {
    drv = h.config.system.build.toplevel.drvPath;
    out = h.config.system.build.toplevel.outPath;
    deployed = h.config.oruc.machine.deployed or true;
    deployLogin = h.config.oruc.machine.deployLogin or null;
  }'
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
