#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
PARALLEL_EACH_JOBS=${PARALLEL_EACH_JOBS:-3}
# shellcheck source=/dev/null
. scripts/lib/parallel-each.sh
# shellcheck source=/dev/null
. scripts/lib/host-systems.sh

if (($#)); then
  echo "usage: $0" >&2
  exit 2
fi

log=$(mktemp)
records=$(mktemp -d)
trap 'rm -rf -- "$log" "$records"' EXIT
flake=.

step() {
  local name=$1
  shift
  echo "== $name"
  "$@" 2>&1 || {
    echo "The check \"$name\" failed." >&2
    return 1
  }
}

check() {
  step "$@" 2>&1 | tee -a "$log" || exit 1
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
  {
    nix eval "${NIX_OPTS[@]}" --json --no-write-lock-file "$flake#nixosConfigurations.$1" --apply "
      h:
        let toplevel = h.config.system.build.toplevel; in
        if builtins.isAttrs toplevel && (toplevel.type or null) == \"derivation\"
        then { \"$1\" = ($HOST_SYSTEM_EXPR) h; }
        else throw \"The host toplevel must be a derivation.\"
    " >"$records/$1.json"
  } 2>&1 || {
    echo "$1: the evaluation failed." >&2
    return 1
  }
}

unit_cycles() {
  local host=$1 paths units systemd rc=0 analysis
  paths=$(nix build --no-link --print-out-paths --impure "${NIX_OPTS[@]}" \
    --expr "import ./ci/unit-cycles.nix (builtins.getFlake (toString ./.)) \"$host\"" units systemd) ||
    {
      echo "$host: the units do not build."
      return 1
    }
  units=$(grep -- '-system-units$' <<<"$paths") || {
    echo "$host: the build printed no unit folder."
    return 1
  }
  systemd=$(grep -v -- '-system-units$' <<<"$paths") || {
    echo "$host: the build printed no systemd package."
    return 1
  }
  # systemd-analyze exits 0 also when it finds a cycle, so only its message
  # counts; any other status means it did not check.
  # --man=no: a unit's man page lookup fails where man is not on PATH.
  analysis=$(SYSTEMD_UNIT_PATH=$units "$systemd/bin/systemd-analyze" verify --man=no default.target 2>&1) || rc=$?
  if ((rc != 0)); then
    printf '%s\n' "$analysis" "$host: systemd-analyze could not check the units (exit $rc)."
    return 1
  elif grep -q 'Found ordering cycle' <<<"$analysis"; then
    echo "$host: the units hold an ordering cycle, so the next boot would not finish."
    grep -E 'ordering cycle|Job .* deleted' <<<"$analysis" || true
    return 1
  fi
  echo "$host: no ordering cycle"
}

host_job() {
  echo "== $1"
  host_system "$1" && unit_cycles "$1"
}

other_job() {
  step "flake checks" nix build "${NIX_OPTS[@]}" --no-link --no-write-lock-file \
    .#checks.x86_64-linux.{scheme-catalogue,theme-contrast,patches} &&
    step "box browser feature" box_browser &&
    step "server record" server_record &&
    step "VM tests" vm_tests &&
    step "binary cache copies" cache_copies
}

job() {
  case $1 in
    host:*) host_job "${1#host:}" ;;
    other) other_job ;;
    *)
      echo "job: unknown job '$1'" >&2
      return 2
      ;;
  esac
}

pool() {
  local revision names hosts systems
  revision=$(nix flake metadata "${NIX_OPTS[@]}" --json --no-write-lock-file . | jq -r '.revision // empty') || return 1
  [[ -z $revision ]] || flake="git+file://$PWD?rev=$revision"
  fetch_inputs "$flake" "${NIX_OPTS[@]}" --no-write-lock-file || return 1
  names=$(host_names "$flake" "${NIX_OPTS[@]}") || return 1
  mapfile -t hosts <<<"$names"
  parallel_each job "${hosts[@]/#/host:}" other || return 1
  [[ -n $revision ]] || return 0
  systems=$(cd "$records" && jq -c -s add "${hosts[@]/%/.json}") || return 1
  store_host_systems "$revision" "$systems" ||
    echo "scripts/affected-hosts.sh will evaluate $revision again: its systems could not be stored." >&2
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
  jq -e '.limineHosts | .["nixos-desktop"].secureBoot and all(.[]; .secureBoot == .signingKeyCheck)' \
    <<<"$out" >/dev/null || {
    echo "The firmware of nixos-desktop refuses an unsigned Limine, so its record sets secureBoot, and a secureBoot host checks its signing key before an install: $(jq -c .limineHosts <<<"$out")" >&2
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
    --apply builtins.attrNames) || return 1
  jq -e 'contains(["devbox-boot-bios", "deploy-script"])' <<<"$out" >/dev/null || {
    echo "The flake checks lack the boot test of devbox or the deploy.sh test: $out" >&2
    return 1
  }
}

# With --no-write-lock-file, evaluation accepts an input that flake.lock lacks
# and only warns, so the input follows its upstream unpinned.
check "lock files" lock_files
check formatting nix fmt "${NIX_OPTS[@]}" --no-update-lock-file -- --ci
check "flake outputs" flake_outputs
check "host systems, unit cycles and the other checks" pool
echo

warnings=$(grep -o 'evaluation warning: .*' "$log" | sort -u || true)
if [[ -z $warnings ]]; then
  echo "No evaluation warnings."
else
  printf '%d distinct evaluation warnings:\n%s\n' "$(wc -l <<<"$warnings")" "$warnings"
fi
