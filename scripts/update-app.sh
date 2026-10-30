#!/usr/bin/env bash
# usage: scripts/update-app.sh NAME
# Moves pkgs/NAME.nix to the newest release its vendor publishes, and sets the
# hash from the vendor's checksum. The file names one source:
#   passthru.aptIndex     an APT Packages index that lists package NAME
#   passthru.releaseFeed  an electron-builder latest-linux.yml feed
#   passthru.npmPackage   an npm package, at its latest dist-tag. With a
#                         pkgs/NAME/ folder, the package is a wrapper project
#                         there: the script rewrites its package.json and
#                         lockfile and sets npmDepsHash instead of hash.
#   passthru.githubRepo   OWNER/REPO, at its newest release tagged v and
#                         digits. The script sets the source hash and, when
#                         the file has one, the hash of its locked
#                         dependencies: a cargoHash or vendorHash line, or
#                         the outputHash line of a fixed-output derivation.
#                         With a passthru.depsBun line that outputHash also
#                         changes with nixpkgs' bun, so the script learns it
#                         again when bun is not that version.
# A package whose url also embeds a build ID names it in a buildId line, and
# the script moves it to the build ID in the feed's URL for the new version.
# Prints the new version, or nothing when the package is already current or
# names no source.
# On a failure it exits non-zero and prints the problem as the last line on
# stderr; scripts/prepare-update.sh shows that line as a warning.
set -euo pipefail

name=${1:?usage: update-app.sh NAME}
root=$(cd "$(dirname "$0")/.." && pwd)
file=$root/pkgs/$name.nix

attr() { sed -n "s/^  $1 = \"\(.*\)\";$/\1/p" "$file"; }
index=$(attr passthru.aptIndex)
feed=$(attr passthru.releaseFeed)
npm=$(attr passthru.npmPackage)
github=$(attr passthru.githubRepo)
wrapper=$(dirname "$file")/$name
current=$(attr version)
build=$(attr buildId)
newbuild=
[[ -n $index$feed$npm$github ]] || exit 0
[[ -n $current ]] || {
  echo "$file names no version" >&2
  exit 1
}
# shellcheck disable=SC2016 # the Nix ${buildId}, not a shell expansion
if [[ -z $build ]] && grep -qF '${buildId}' "$file"; then
  echo "$file uses \${buildId} but has no buildId line" >&2
  exit 1
fi

if [[ -n $index ]]; then
  entry=$(curl -fsSL --max-time 20 --retry 2 "$index" |
    awk -v name="$name" '/^Package:/ { p = $2 } /^Version:/ { v = $2 } /^SHA256:/ && p == name { print v, $2 }' |
    sort -V | tail -n 1) || entry=
  read -r latest sha <<<"$entry"
elif [[ -n $github ]]; then
  auth=()
  token=${GITHUB_TOKEN:-${GH_TOKEN:-}}
  [[ -n $token ]] && auth=(-H "Authorization: Bearer $token")
  latest=$(curl -fsSL --max-time 20 --retry 2 "${auth[@]}" "https://api.github.com/repos/$github/releases?per_page=30" |
    jq -r '.[] | select(.draft | not) | select(.prerelease | not) | .tag_name | select(test("^v[0-9][0-9.]*$"))' |
    sed 's/^v//' | sort -V | tail -n 1) || latest=
  sha=$([[ -n $latest ]] && nix flake prefetch --json "https://github.com/$github/archive/refs/tags/v$latest.tar.gz" | jq -r .hash) || sha=
elif [[ -n $npm ]]; then
  meta=$(curl -fsSL --max-time 20 --retry 2 "https://registry.npmjs.org/$npm") || meta=
  latest=$(jq -r '."dist-tags".latest // empty' <<<"$meta" 2>/dev/null) || latest=
  sha=$(jq -r --arg v "$latest" '.versions[$v].dist.integrity // empty' <<<"$meta" 2>/dev/null) || sha=
else
  yml=$(curl -fsSL --max-time 20 --retry 2 "$feed") || yml=
  latest=$(sed -n 's/^version: //p' <<<"$yml")
  sha=$(sed -n 's/^sha512: //p' <<<"$yml")
  path=$(sed -n 's/^path: //p' <<<"$yml")
  if [[ -n $build ]]; then
    url=$(awk -v path="$path" '$1 == "-" && $2 == "url:" { n = split($3, part, "/"); if (part[n] == path) { print $3; exit } }' <<<"$yml")
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
  echo "could not read $name from ${index:-${feed:-${github:-npm}}}" >&2
  exit 1
}
depsbun=$(attr passthru.depsBun)
if [[ -n $depsbun ]]; then
  bunv=$(nix eval --raw --impure --expr \
    "(builtins.getFlake \"path:$root\").inputs.nixpkgs.legacyPackages.\${builtins.currentSystem}.bun.version") || {
    echo "could not read the bun version of nixpkgs" >&2
    exit 1
  }
fi
[[ $latest == "$current" && $newbuild == "$build" && ${depsbun:-} == "${bunv:-}" ]] && exit 0

if [[ -n $index ]]; then
  sri=$(nix hash convert --hash-algo sha256 --to sri "$sha")
elif [[ -n $npm || -n $github ]]; then
  sri=$sha
else
  sri=sha512-$sha
fi
edited=$(mktemp)
trap 'rm -f -- "$edited"' EXIT
if [[ -n $npm && -d $wrapper ]]; then
  scratch=$(mktemp -d)
  trap 'rm -f -- "$edited"; rm -rf -- "$scratch"' EXIT
  jq --arg v "$latest" --arg p "$npm" '.version = $v | .dependencies[$p] = $v' "$wrapper/package.json" >"$scratch/package.json"
  (cd "$scratch" && nix shell --inputs-from "$root" nixpkgs#nodejs_26 -c npm install --package-lock-only --ignore-scripts --min-release-age=0 >&2) ||
    {
      echo "npm could not lock $npm $latest" >&2
      exit 1
    }
  deps=$(nix run --inputs-from "$root" nixpkgs#prefetch-npm-deps -- "$scratch/package-lock.json") || {
    echo "prefetch-npm-deps failed for $npm $latest" >&2
    exit 1
  }
  sed -e "s|^  version = \".*\";|  version = \"$latest\";|" \
    -e "s|^  npmDepsHash = \".*\";|  npmDepsHash = \"$deps\";|" "$file" >"$edited"
  if ! grep -qxF "  version = \"$latest\";" "$edited" || ! grep -qxF "  npmDepsHash = \"$deps\";" "$edited"; then
    echo "could not set version $latest and npmDepsHash in $file" >&2
    exit 1
  fi
  cp "$scratch/package.json" "$scratch/package-lock.json" "$wrapper/"
  cat "$edited" >"$file"
  echo "$latest"
  exit 0
fi
sed -e "s|^  version = \".*\";|  version = \"$latest\";|" \
  -e "s|^    hash = \"sha[0-9]*-.*\";|    hash = \"$sri\";|" \
  -e "s|^  buildId = \".*\";|  buildId = \"$newbuild\";|" "$file" >"$edited"
if ! grep -qxF "  version = \"$latest\";" "$edited" || ! grep -qxF "    hash = \"$sri\";" "$edited" ||
  { [[ -n $build ]] && ! grep -qxF "  buildId = \"$newbuild\";" "$edited"; }; then
  echo "could not set version $latest and its hash${build:+ and build ID} in $file" >&2
  exit 1
fi
deps_line='^(    outputHash|  cargoHash|  vendorHash) = "'
if [[ -n $github ]] && grep -qE "$deps_line" "$edited"; then
  key=$(grep -m 1 -oE "$deps_line" "$edited" | sed 's/ = "$//')
  sed -i "s|^$key = \".*\";|$key = \"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\";|" "$edited"
  probe=$(dirname "$file")/.$name.probe.nix
  probelog=$(mktemp)
  trap 'rm -f -- "$edited" "$probe" "$probelog"' EXIT
  cp "$edited" "$probe"
  nix build --no-link --impure --expr \
    "(builtins.getFlake \"path:$root\").inputs.nixpkgs.legacyPackages.\${builtins.currentSystem}.callPackage $probe { }" \
    >/dev/null 2>"$probelog" || true
  deps=$(sed -n 's/^ *got: *//p' "$probelog" | head -n 1)
  if [[ -z $deps ]]; then
    cat "$probelog" >&2
    echo "could not learn the dependencies' hash of $name $latest: $(grep -m 1 'error:' "$probelog" | sed 's/^ *//')" >&2
    exit 1
  fi
  sed -i "s|^$key = \".*\";|$key = \"$deps\";|" "$edited"
  grep -qxF "$key = \"$deps\";" "$edited" || {
    echo "could not set the dependencies' hash in $file" >&2
    exit 1
  }
fi
if [[ -n $depsbun ]]; then
  sed -i "s|^  passthru.depsBun = \".*\";|  passthru.depsBun = \"$bunv\";|" "$edited"
  grep -qxF "  passthru.depsBun = \"$bunv\";" "$edited" || {
    echo "could not set the bun version in $file" >&2
    exit 1
  }
fi
cat "$edited" >"$file"
echo "$latest"
