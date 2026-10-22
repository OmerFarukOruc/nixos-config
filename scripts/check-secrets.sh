#!/usr/bin/env bash
# usage: scripts/check-secrets.sh [FILE]
# Proves that this host's SSH host key decrypts its sops file and that the
# file's keys are the secrets the configuration declares. Run it on the host
# after editing secrets/<host>.yaml.
#
# It exits 1 when decryption fails, when a declared secret has no key in the
# file, or when the file holds a key no secret declares (a retired secret left
# behind). Only key names are printed, never a value. It exits 2 on a host
# without a secrets/<host>.yaml, because each host key lives on its own host.
#
# With FILE, it checks FILE instead of secrets/<host>.yaml, against the
# secrets that declare that file, and skips any other sops file.
set -euo pipefail
cd "$(dirname "$0")/.."

(($# <= 1)) || {
  echo "usage: $0 [FILE]" >&2
  exit 2
}
host=$(</proc/sys/kernel/hostname)
main_file=secrets/$host.yaml
[[ -f $main_file ]] || {
  echo "$0 runs on a host with a secrets file, because it decrypts with that host's key:" >&2
  for f in secrets/*.yaml; do
    f=${f#secrets/}
    echo "${f%.yaml}"
  done >&2
  exit 2
}
override=${1:-}

nix=(nix)
if command -v heavy >/dev/null; then nix=(heavy nix); fi

# A declared sopsFile is a store path of the flake source; drop the store
# prefix to get the path in this repository.
declared=$(
  "${nix[@]}" eval --json --no-write-lock-file \
    ".#nixosConfigurations.$host.config.sops.secrets" \
    --apply 'builtins.mapAttrs (_: s: { inherit (s) key; sopsFile = toString s.sopsFile; })' |
    jq -c 'to_entries
      | map({file: (.value.sopsFile | sub("^/nix/store/[^/]+/"; "")), key: .value.key})
      | group_by(.file)
      | map({file: .[0].file, keys: (map(.key) | unique)})
      | .[]'
)

sops=$("${nix[@]}" build --no-link --print-out-paths nixpkgs#sops)/bin/sops
s2a=$("${nix[@]}" build --no-link --print-out-paths nixpkgs#ssh-to-age)/bin/ssh-to-age

status=0
while IFS= read -r entry; do
  file=$(jq -r .file <<<"$entry")
  want=$(jq -c .keys <<<"$entry")
  path=$file
  if [[ -n $override ]]; then
    [[ $file == "$main_file" ]] || continue
    path=$override
  fi

  err=$(mktemp)
  # SOPS_AGE_SSH_PRIVATE_KEY_FILE fails with the host key, because the file's
  # recipient is the age key derived from it.
  if ! have=$(
    sudo -n env SOPS_AGE_KEY_CMD="$s2a -private-key -i /etc/ssh/ssh_host_ed25519_key" \
      "$sops" decrypt --input-type yaml --output-type json "$path" 2>"$err" |
      jq -c 'keys - ["sops"]'
  ) || [[ -z $have ]]; then
    echo "$path: decryption with the host key failed:" >&2
    head -n 5 "$err" >&2
    rm -f "$err"
    status=1
    continue
  fi
  rm -f "$err"

  echo "$path declared: $want"
  echo "$path in file:  $have"
  missing=$(jq -cn --argjson w "$want" --argjson h "$have" '$w - $h')
  extra=$(jq -cn --argjson w "$want" --argjson h "$have" '$h - $w')
  if [[ $missing != '[]' ]]; then
    echo "$path: declared but missing from the file: $missing" >&2
    status=1
  fi
  if [[ $extra != '[]' ]]; then
    echo "$path: in the file but declared by no secret: $extra" >&2
    status=1
  fi
done <<<"$declared"
exit "$status"
