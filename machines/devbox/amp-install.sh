#!/usr/bin/env bash
bin=$HOME/.amp/bin/amp
base=https://static.ampcode.com/cli
mkdir -p "$(dirname "$bin")"
exec 9>"$bin.lock"
flock 9
if "$bin" --version >/dev/null 2>&1; then
  exit 0
fi
fetch() {
  curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 900 "$@"
}
version=$(fetch "$base/cli-version.txt")
expected=$(fetch "$base/$version/linux-x64-amp.sha256")
if [[ ! $expected =~ ^[0-9a-f]{64}$ ]]; then
  echo "amp-install: $base/$version/linux-x64-amp.sha256 is not a SHA-256 digest" >&2
  exit 1
fi
staged=$(mktemp "$bin.XXXXXX")
trap 'rm -f "$staged"' EXIT
fetch "$base/$version/amp-linux-x64.gz" | gunzip >"$staged"
actual=$(sha256sum <"$staged")
actual=${actual%% *}
if [[ $actual != "$expected" ]]; then
  echo "amp-install: checksum mismatch for Amp $version: expected $expected, got $actual" >&2
  exit 1
fi
chmod 0755 "$staged"
mv "$staged" "$bin"
trap - EXIT
"$bin" --version
