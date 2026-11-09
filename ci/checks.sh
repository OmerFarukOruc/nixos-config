#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. scripts/lib/parallel-each.sh
# shellcheck source=/dev/null
. scripts/lib/host-systems.sh

build_workstations=true
if (($# > 1)) || { (($# == 1)) && [[ $1 != --evaluate-only ]]; }; then
  echo "usage: $0 [--evaluate-only]" >&2
  exit 2
fi
(($# == 0)) || build_workstations=false

log=$(mktemp)
records=$(mktemp -d)
trap 'rm -rf -- "$log" "$records"' EXIT

check() {
  local name=$1
  shift
  echo "== $name"
  "$@" 2>&1 | tee -a "$log" || {
    echo "The check \"$name\" failed." >&2
    exit 1
  }
}

lock_files() {
  nix flake metadata "${NIX_OPTS[@]}" --no-update-lock-file . >/dev/null || {
    echo "flake.lock does not match flake.nix, as after a new or changed input; Nix's error above names the cause, and scripts/check.sh --fix relocks" >&2
    return 1
  }
}

flake_outputs() {
  nix eval "${NIX_OPTS[@]}" --json --no-write-lock-file '.#.' --apply '
    outputs:
      builtins.attrNames outputs == [ "checks" "formatter" "nixosConfigurations" ]
      && builtins.attrNames outputs.formatter == [ "x86_64-linux" ]
      && builtins.isString outputs.formatter.x86_64-linux.name
      && !builtins.hasContext outputs.formatter.x86_64-linux.name
  ' | jq -e . >/dev/null || {
    echo "Extend ci/checks.sh coverage before changing output kinds or formatter systems; formatter names must be strings without context." >&2
    return 1
  }
}

host_system() {
  local rc=0
  echo "$1"
  nix eval "${NIX_OPTS[@]}" --json --no-write-lock-file "$flake#nixosConfigurations.$1" --apply "
    h:
      let toplevel = h.config.system.build.toplevel; in
      if builtins.isAttrs toplevel && (toplevel.type or null) == \"derivation\"
      then { \"$1\" = ($HOST_SYSTEM_EXPR) h; }
      else throw \"The host toplevel must be a derivation.\"
  " >"$records/$1.json" 2>"$records/$1.err" || rc=$?
  cat "$records/$1.err" >&2
  ((rc == 0)) || echo "$1: the evaluation failed." >&2
  return "$rc"
}

host_systems() {
  local flake=. revision names hosts systems
  revision=$(nix flake metadata "${NIX_OPTS[@]}" --json --no-write-lock-file . | jq -r '.revision // empty') || return 1
  [[ -z $revision ]] || flake="git+file://$PWD?rev=$revision"
  fetch_inputs "$flake" "${NIX_OPTS[@]}" --no-write-lock-file || return 1
  names=$(host_names "$flake" "${NIX_OPTS[@]}") || return 1
  mapfile -t hosts <<<"$names"
  parallel_each host_system "${hosts[@]}" || return 1
  [[ -n $revision ]] || return 0
  systems=$(cd "$records" && jq -c -s add "${hosts[@]/%/.json}") || return 1
  store_host_systems "$revision" "$systems" ||
    echo "scripts/affected-hosts.sh will evaluate $revision again: its systems could not be stored." >&2
}

workstation_builds() {
  local list outputs
  list=$(jq -r '.[] | select(.kind == "workstation") | "\(.drv)^out"' "$records"/*.json) || return 1
  [[ -n $list ]] || {
    echo "No host record has kind workstation, so the check builds nothing." >&2
    return 1
  }
  mapfile -t outputs <<<"$list"
  nix build --no-link "${outputs[@]}"
}

box_browser() {
  local out
  out=$(nix eval "${NIX_OPTS[@]}" --json --impure \
    --expr 'import ./ci/box-browser.nix (builtins.getFlake (toString ./.))') || return 1
  jq -e '.userUnits | contains(["box-browser", "box-display"])' <<<"$out" >/dev/null || {
    echo "nixos-desktop lacks a box browser unit." >&2
    return 1
  }
  jq -e '.displayCommand | contains(" -localhost ") and contains(" -SecurityTypes None")' \
    <<<"$out" >/dev/null || {
    echo "The box display no longer runs Xvnc as -localhost with -SecurityTypes None." >&2
    return 1
  }
  jq -e '(.displayCommand | capture(" (?<display>:[0-9]+) -auth (?<auth>[^ ]+) ")) as $x
    | .browserEnvironment | .DISPLAY == $x.display and .XAUTHORITY == $x.auth' \
    <<<"$out" >/dev/null || {
    echo "box-browser.service does not use the display and the -auth file of box-display, so under Plasma it reads KDE's xauth file and cannot open the display." >&2
    return 1
  }
}

server_record() {
  local out
  out=$(nix eval "${NIX_OPTS[@]}" --json --impure \
    --expr 'import ./ci/server.nix (builtins.getFlake (toString ./.))') || return 1
  jq -e '.workstation | to_entries | map(select(.value)) | map(.key) | . == []' <<<"$out" >/dev/null || {
    echo "The server record gets a workstation piece: $(jq -c '.workstation | with_entries(select(.value)) | keys' <<<"$out")" >&2
    return 1
  }
  jq -e '.access | .tailscale and .tailscaleSsh and .openssh and (.sshOpenFirewall | not)
    and .sshPorts == [2222] and .sshListenAddresses == [] and .sshAuthentication == "publickey"
    and .udpPorts == [.tailscalePort]' \
    <<<"$out" >/dev/null || {
    echo "The server record's access setup changed: $(jq -c .access <<<"$out")" >&2
    return 1
  }
  jq -e '.firewallVariantsNotFailing == []' <<<"$out" >/dev/null || {
    echo "The Tailscale-only firewall assertion does not fail for these firewall variants: $(jq -c .firewallVariantsNotFailing <<<"$out")" >&2
    return 1
  }
  jq -e '.boot | .enable and .efiSupport and .biosSupport and .biosDevice == "/dev/vda"
    and (.canTouchEfiVariables | not) and .efiInstallAsRemovable and .additionalFiles == {}' \
    <<<"$out" >/dev/null || {
    echo "The server record's boot loader does not follow its record: $(jq -c .boot <<<"$out")" >&2
    return 1
  }
  jq -e '.limineHosts | (keys | contains(["nixos-desktop", "nixos-rog"]))
    and all(.[]; (.efiInstallAsRemovable | not) and .fallbackCopy)' \
    <<<"$out" >/dev/null || {
    echo "A Limine host lost the fallback copy of its EFI binary: $(jq -c .limineHosts <<<"$out")" >&2
    return 1
  }
  jq -e '.streamed | .accepted and .workstationAccepted
    and ([.workstation | to_entries[] | select(.value) | .key] | sort)
      == ["browserCertificates", "browserVariable", "desktopPackages", "fontconfig", "mimeApps", "xkbLayout"]
    and (.desktop | .xrdp and (.xserver | not) and (.screensaver | not) and .keyboardLayout == "tr")' \
    <<<"$out" >/dev/null || {
    echo "The server record with a streamed desktop changed: $(jq -c .streamed <<<"$out")" >&2
    return 1
  }
  jq -e '.accepted' <<<"$out" >/dev/null || {
    echo "The schema rejects the server record itself, so the rejection checks below prove nothing." >&2
    return 1
  }
  jq -e '.rejected | to_entries | map(select(.value | not)) | map(.key) | . == []' <<<"$out" >/dev/null || {
    echo "The schema accepts what a server may not set: $(jq -c '.rejected | with_entries(select(.value | not)) | keys' <<<"$out")" >&2
    return 1
  }
}

cache_copies() {
  local want have file status=0
  want=$(nix eval "${NIX_OPTS[@]}" --json --no-write-lock-file .#nixosConfigurations --apply '
    hosts: builtins.concatMap (host: let s = host.config.nix.settings; in
      map (v: "extra-substituters " + v) s.extra-substituters
      ++ map (v: "extra-trusted-public-keys " + v) s.extra-trusted-public-keys) (builtins.attrValues hosts)
  ' | jq -r '.[]' | grep -v -F 'cache.statuslantern.com' | LC_ALL=C sort -u) || return 1
  for file in docs/install-nixos-desktop.md docs/install-nixos-latitude.md .github/workflows/update.yml; do
    have=$(sed -nE "s/^ *(extra-(substituters|trusted-public-keys)) = (.*)/\1 \3/p" "$file" | tr -d "'" |
      awk '{for (i = 2; i <= NF; i++) print $1, $i}' | LC_ALL=C sort -u)
    [[ $have == "$want" ]] && continue
    echo "$file differs from the hosts' nix.settings (<: only the hosts set it, >: only $file has it):" >&2
    diff <(echo "$want") <(echo "$have") | grep '^[<>]' >&2 || true
    status=1
  done
  return "$status"
}

vm_tests() {
  local out
  out=$(nix eval "${NIX_OPTS[@]}" --json --no-write-lock-file .#checks.x86_64-linux \
    --apply 'checks: builtins.mapAttrs (_: test: test.drvPath) checks') || return 1
  jq -e 'keys | contains(["devbox-boot-bios", "deploy-script"])' <<<"$out" >/dev/null || {
    echo "The flake checks lack the boot test of devbox or the deploy.sh test: $(jq -c keys <<<"$out")" >&2
    return 1
  }
}

# With --no-write-lock-file, evaluation accepts an input that flake.lock lacks
# and only warns, so the input follows its upstream unpinned.
check "lock files" lock_files
check formatting nix fmt "${NIX_OPTS[@]}" --no-update-lock-file -- --ci
check "flake outputs" flake_outputs
check "host systems" host_systems
check "flake checks" nix build "${NIX_OPTS[@]}" --no-link --no-write-lock-file \
  .#checks.x86_64-linux.{scheme-catalogue,theme-contrast,patches}
if $build_workstations; then
  check "workstation builds" workstation_builds
fi
echo
check "box browser feature" box_browser
echo
check "server record" server_record
echo
check "VM tests" vm_tests
echo
check "binary cache copies" cache_copies
echo

warnings=$(grep -o 'evaluation warning: .*' "$log" | sort -u || true)
if [[ -z $warnings ]]; then
  echo "No evaluation warnings."
else
  printf '%d distinct evaluation warnings:\n%s\n' "$(wc -l <<<"$warnings")" "$warnings"
fi
