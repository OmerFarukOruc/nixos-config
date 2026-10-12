#!/usr/bin/env bash
# usage: ci/build-report.sh [NIX OPTION...]
# Prints, per host, what a machine with an empty store would build itself
# instead of downloading from the caches that host uses, as Markdown. Extra
# arguments go to nix build, such as --store for a local test.
set -euo pipefail
cd "$(dirname "$0")/.."

# Nix lists each kind of path under a header line and indents the paths.
section() { awk -v header="$1" '$0 ~ header { f = 1; next } /^[^ ]/ { f = 0 } f { print $1 }'; }

hosts=$(nix eval --json .#nixosConfigurations --apply builtins.attrNames | jq -r '.[]')
for host in $hosts; do
  # shellcheck disable=SC2016 # a Nix expression, not shell
  caches=$(nix eval --json ".#nixosConfigurations.$host.config.nix.settings" --apply '
    s: {
      substituters = (s.substituters or [ ]) ++ (s.extra-substituters or [ ]);
      keys = (s.trusted-public-keys or [ ]) ++ (s.extra-trusted-public-keys or [ ]);
    }')
  plan=$(nix build --dry-run "$@" \
    --option substituters "$(jq -r '.substituters | join(" ")' <<<"$caches")" \
    --option trusted-public-keys "$(jq -r '.keys | join(" ")' <<<"$caches")" \
    ".#nixosConfigurations.$host.config.system.build.toplevel" 2>&1) || {
    echo "$plan" >&2
    exit 1
  }
  built=$(section 'will be built:$' <<<"$plan" | sed -E 's|^/nix/store/[a-z0-9]{32}-||; s|\.drv$||' | sort)
  fetched=$(section 'will be fetched' <<<"$plan" | wc -l)

  echo "## $host"
  echo
  echo "$(grep -c . <<<"$built" || true) derivations will be built and $fetched paths fetched from $(jq -r '.substituters | join(", ")' <<<"$caches")."
  echo
  echo '<details><summary>Will be built</summary>'
  echo
  echo '```text'
  echo "$built"
  echo '```'
  echo
  echo '</details>'
  echo
done
