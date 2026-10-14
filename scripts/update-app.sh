#!/usr/bin/env bash
# usage: scripts/update-app.sh NAME
# Moves pkgs/NAME.nix to the newest release its vendor publishes, and sets the
# hash from the vendor's checksum. The file names one source:
#   passthru.aptIndex     an APT Packages index that lists package NAME
#   passthru.releaseFeed  an electron-builder latest-linux.yml feed
# A feed release moves the package only once it is minAgeDays old, the same
# wait releaseAgeDays in home-manager/modules/applications.nix gives package
# managers. APT indexes carry no release date, so each candidate waits from
# its first observation, keyed by source, version and checksum.
# Prints the new version, or nothing when the package is already current, its
# newest release is younger than minAgeDays, or it names no source.
# On a failure it exits non-zero and prints the problem as the last line on
# stderr; scripts/auto-update.sh uses that line as the notification text and as
# the key that stops a repeated problem from notifying again.
set -euo pipefail

name=${1:?usage: update-app.sh NAME}
minAgeDays=3
file=$(cd "$(dirname "$0")/.." && pwd)/pkgs/$name.nix

attr() { sed -n "s/^  $1 = \"\(.*\)\";$/\1/p" "$file"; }
index=$(attr passthru.aptIndex)
feed=$(attr passthru.releaseFeed)
current=$(attr version)
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
  released=$(sed -n "s/^releaseDate: '\(.*\)'$/\1/p" <<<"$yml")
  sha=$(sed -n 's/^sha512: //p' <<<"$yml")
  path=$(sed -n 's/^path: //p' <<<"$yml")
  asset=$(sed -n 's|^    url = ".*/\(.*\)";$|\1|p' "$file")
  # shellcheck disable=SC2016 # the Nix ${version}, not a shell expansion
  asset=${asset//'${version}'/$latest}
  if [[ -n $latest && $path != "$asset" ]]; then
    echo "$feed points at $path, not $asset" >&2
    exit 1
  fi
fi
[[ -n $latest && -n $sha ]] || {
  echo "could not read $name from ${index:-$feed}" >&2
  exit 1
}
[[ $latest == "$current" ]] && exit 0
if [[ -n $feed ]]; then
  [[ -n $released ]] && released=$(date -d "$released" +%s 2>/dev/null) || released=
  [[ -n $released ]] || {
    echo "$feed gives no release date for $latest" >&2
    exit 1
  }
  ((released <= $(date +%s) - minAgeDays * 86400)) || exit 0
fi

if [[ -n $index ]]; then
  # A per-candidate lock serializes concurrent runs using this state directory.
  # Rename publishes a complete record, including after an interrupted run.
  apt_old_enough() (
    umask 077
    state=${STATE_DIRECTORY:-${XDG_STATE_HOME:-$HOME/.local/state}/nixos-config}/app-first-seen
    mkdir -p -- "$state" || exit 2
    key=$(printf '%s\0' "$name" "$index" "$latest" "$sha" | sha256sum) || exit 2
    key=${key%% *}
    exec 9>"$state/$key.lock" || exit 2
    flock 9 || exit 2
    now=$(date +%s) || exit 2
    seen=
    [[ ! -f $state/$key ]] || seen=$(<"$state/$key") || exit 2
    if [[ ! $seen =~ ^[0-9]{1,12}$ ]] || ((10#$seen > now)); then
      record=$(mktemp "$state/.first-seen.XXXXXX") || exit 2
      trap 'rm -f -- "$record"' EXIT
      printf '%s\n' "$now" >"$record" || exit 2
      mv -f -- "$record" "$state/$key" || exit 2
      exit 1
    fi
    ((now - 10#$seen >= minAgeDays * 86400))
  )
  quarantine_status=0
  apt_old_enough || quarantine_status=$?
  case $quarantine_status in
    0) ;;
    1) exit 0 ;;
    *)
      echo "could not record the first observation of $name $latest" >&2
      exit 1
      ;;
  esac
fi

if [[ -n $index ]]; then
  sri=$(nix hash convert --hash-algo sha256 --to sri "$sha")
else
  sri=sha512-$sha
fi
# The edit lands only when both lines changed, so a failed match leaves the
# file as it was.
edited=$(mktemp)
trap 'rm -f -- "$edited"' EXIT
sed -e "s|^  version = \".*\";|  version = \"$latest\";|" \
  -e "s|^    hash = \"sha[0-9]*-.*\";|    hash = \"$sri\";|" "$file" >"$edited"
if ! grep -qxF "  version = \"$latest\";" "$edited" || ! grep -qxF "    hash = \"$sri\";" "$edited"; then
  echo "could not set version $latest and its hash in $file" >&2
  exit 1
fi
cat "$edited" >"$file"
echo "$latest"
