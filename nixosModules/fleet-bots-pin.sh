# shellcheck shell=bash
# usage: fleet-bots-pin USER AUTHORIZED_KEYS PEER TAG PUBLIC_KEY_FILE [CREDENTIAL_FILE]
#
# Writes the bots' public key as the only line of AUTHORIZED_KEYS, limited to
# the current tailnet IPv4 of PEER (nixosModules/fleet-bots-pin.nix). The
# address is read at run time and never committed.
user=$1 keys=$2 peer=$3 tag=$4 pubkey=$5 cred=${6:-}
group=$(id -gn "$user")
rc=0
ip=
# The user owns the key directory. A symlink there would point this root
# writer, and the unit's ReadWritePaths, at another directory.
if [[ -L ${keys%/*} ]]; then
  echo "${keys%/*} is a symlink; kept the current pin" >&2
  exit 1
fi
# Without the credential a renamed peer keeps its NAME-1 name until fixed by
# hand, and the pin still follows the address that the daemon reports.
if [[ -n $cred && -s $cred ]]; then
  ip=$(fleet-bots-ts-name "$cred" "$peer" "$tag") || rc=$?
fi
[[ -n $ip ]] || ip=$(tailscale ip -4 "$peer" 2>/dev/null | head -n1 || true)
if [[ -z $ip ]]; then
  echo "no tailnet IPv4 address for ${peer}; kept the current pin"
  exit "$rc"
fi
# The address ends up inside from="...", so a value that is not a dotted quad
# must not reach the file.
if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "the address of ${peer} is not an IPv4 address; kept the current pin" >&2
  exit 1
fi
want=$(printf 'from="%s",no-agent-forwarding,no-X11-forwarding,no-port-forwarding %s' "$ip" "$(<"$pubkey")")
if [[ -f $keys && "$(<"$keys")" == "$want" && "$(stat -c '%a %U %G' "$keys")" == "600 ${user} ${group}" ]]; then
  exit "$rc"
fi
tmp=$(mktemp "${keys}.XXXXXX")
printf '%s\n' "$want" >"$tmp"
chmod 0600 "$tmp"
chown "${user}:${group}" "$tmp"
mv -f "$tmp" "$keys"
echo "pinned ${user}'s bot key to ${peer} at ${ip}"
exit "$rc"
