# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034,SC2086,SC2154,SC2155
check captive-dns-off "$(captive-dns status)" test "$(captive-dns status)" = off
check nextdns-secret "/run/secrets/nextdns-profile" sudo test -s /run/secrets/nextdns-profile
check resolved-dot-nextdns "global DNS uses DoT to NextDNS" \
  bash -c 'resolvectl status | sed -n "/^Global/,/^Link/p" | grep -q "+DNSOverTLS" && resolvectl dns | grep -q "^Global:.*dns\.nextdns\.io"'
check public-name-resolves "resolvectl query nixos.org" resolvectl query nixos.org
risoluto_answer=$(resolvectl query --cache=no --legend=no openchamber.risoluto.dev 2>/dev/null | awk 'NR == 1 { print $2 }')
check risoluto-dev-allowlisted "openchamber.risoluto.dev -> ${risoluto_answer:-no answer}" \
  bash -c '[[ $1 == 100.* ]]' _ "$risoluto_answer"
statuslantern_answer=$(resolvectl query --cache=no --legend=no signoz.statuslantern.com 2>/dev/null | awk 'NR == 1 { print $2 }')
check statuslantern-com-allowlisted "signoz.statuslantern.com -> ${statuslantern_answer:-no answer}" \
  bash -c '[[ $1 == 100.* ]]' _ "$statuslantern_answer"
tailnet_name=$(tailscale status --json --peers=false 2>/dev/null |
  sed -n 's/^ *"DNSName": "\(.*\)\.",$/\1/p')
check tailscale-running "${tailnet_name:-not logged in}" test -n "$tailnet_name"
check magicdns-resolves "$tailnet_name" resolvectl query "$tailnet_name"
