#!/usr/bin/env bash
# usage: scripts/update-app.sh NAME
# Moves pkgs/NAME.nix to the newest release its vendor publishes, and sets the
# hash from the vendor's checksum. The file names one source:
#   passthru.aptIndex     an APT Packages index that lists package NAME
#   passthru.releaseFeed  an electron-builder latest-linux.yml feed
# A package whose url also embeds a build ID names it in a buildId line, and
# the script moves it to the build ID in the feed's URL for the new version.
# Prints the new version, or nothing when the package is already current or
# names no source.
# On a failure it exits non-zero and prints the problem as the last line on
# stderr; scripts/auto-update.sh uses that line as the notification text and as
# the key that stops a repeated problem from notifying again.
set -euo pipefail

name=${1:?usage: update-app.sh NAME}
file=$(cd "$(dirname "$0")/.." && pwd)/pkgs/$name.nix

attr() { sed -n "s/^  $1 = \"\(.*\)\";$/\1/p" "$file"; }
index=$(attr passthru.aptIndex)
feed=$(attr passthru.releaseFeed)
current=$(attr version)
build=$(attr buildId)
newbuild=
[[ -n $index$feed ]] || exit 0
[[ -n $current ]] || {
  echo "$file names no version" >&2
  exit 1
}

if [[ -n $index ]]; then
  entry=$(curl -fsSL --max-time 20 --retry 2 "$index" |
    awk -v name="$name" '/^Package:/ { p = $2 } /^Version:/ { v = $2 } /^SHA256:/ && p == name { print v, $2 }' |
    sort -V | tail -n 1) || entry=
  read -r latest sha <<<"$entry"
else
  # The top-level sha512 is the base64 digest of the file at the top-level path,
  # which must be the file the package's url names.
  yml=$(curl -fsSL --max-time 20 --retry 2 "$feed") || yml=
  latest=$(sed -n 's/^version: //p' <<<"$yml")
  sha=$(sed -n 's/^sha512: //p' <<<"$yml")
  path=$(sed -n 's/^path: //p' <<<"$yml")
  if [[ -n $build ]]; then
    # The build ID comes from the <version>-<digits> segment of the URL that
    # the feed lists for the file at path.
    url=$(awk -v path="$path" '$1 == "-" && $2 == "url:" { n = split($3, part, "/"); if (part[n] == path) print $3 }' <<<"$yml")
    segment='/[^/]*-([0-9]+)/'
    [[ $url =~ $segment ]] && newbuild=${BASH_REMATCH[1]}
    want=$(sed -n 's|^    url = "\(.*\)";$|\1|p' "$file")
    # shellcheck disable=SC2016 # the Nix ${version} and ${buildId}, not shell expansions
    want=${want//'${version}'/$latest}
    # shellcheck disable=SC2016
    want=${want//'${buildId}'/$newbuild}
    if [[ -n $latest && -z $url ]]; then
      echo "$feed lists no URL for $path" >&2
      exit 1
    elif [[ -n $latest && $url != "$want" ]]; then
      echo "$feed points at $url, not $want" >&2
      exit 1
    fi
  else
    asset=$(sed -n 's|^    url = ".*/\(.*\)";$|\1|p' "$file")
    # shellcheck disable=SC2016 # the Nix ${version}, not a shell expansion
    asset=${asset//'${version}'/$latest}
    if [[ -n $latest && $path != "$asset" ]]; then
      echo "$feed points at $path, not $asset" >&2
      exit 1
    fi
  fi
fi
[[ -n $latest && -n $sha ]] || {
  echo "could not read $name from ${index:-$feed}" >&2
  exit 1
}
[[ $latest == "$current" && $newbuild == "$build" ]] && exit 0

if [[ -n $index ]]; then
  sri=$(nix hash convert --hash-algo sha256 --to sri "$sha")
else
  sri=sha512-$sha
fi
# The edit lands only when every line changed, so a failed match leaves the
# file as it was.
edited=$(mktemp)
trap 'rm -f -- "$edited"' EXIT
sed -e "s|^  version = \".*\";|  version = \"$latest\";|" \
  -e "s|^    hash = \"sha[0-9]*-.*\";|    hash = \"$sri\";|" \
  -e "s|^  buildId = \".*\";|  buildId = \"$newbuild\";|" "$file" >"$edited"
if ! grep -qxF "  version = \"$latest\";" "$edited" || ! grep -qxF "    hash = \"$sri\";" "$edited" ||
  { [[ -n $build ]] && ! grep -qxF "  buildId = \"$newbuild\";" "$edited"; }; then
  echo "could not set version $latest and its hash${build:+ and build ID} in $file" >&2
  exit 1
fi
cat "$edited" >"$file"
echo "$latest"
