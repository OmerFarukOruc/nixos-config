#!/usr/bin/env bash
# usage: scripts/prepare-update.sh HOST CHANGES
# Runs in a clean checkout of main from .github/workflows/update.yml. Moves the
# flake inputs and the apps in pkgs/ to their newest releases in the working
# tree and writes the commit body that lists the moves to CHANGES. It writes
# nothing to CHANGES when nothing moved.
# - Every input except the two below moves with move-inputs.sh.
# - The kernel moves only once the kernel cache holds its build
#   (update-kernel.sh).
# - llm-agents moves only while cache.numtide.com holds every coding agent that
#   HOST's system uses.
# - Each app moves with update-app.sh and stays only when it builds on its own,
#   so one broken release never holds back the rest.
# - devenv.lock moves only with another move and only while the dev shell of
#   devenv.nix builds.
# A move that stays out prints a GitHub warning annotation and the run goes on.
# Needs nix, gh with GH_TOKEN, curl, jq and python3.
set -euo pipefail
cd "$(dirname "$0")/.."

host=${1:?usage: prepare-update.sh HOST CHANGES}
out=${2:?usage: prepare-update.sh HOST CHANGES}
: >"$out"

# warn TEXT: a line in the run's log that GitHub also shows as an annotation.
warn() { echo "::warning::$1"; }

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
git show HEAD:flake.lock >"$work/base.lock"
git show HEAD:devenv.lock >"$work/base-devenv.lock"

# The devenv of main's nixpkgs, which a cache holds, rather than one from the
# nixpkgs this run moves to.
devenv=$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#devenv)/bin/devenv

tags=$(scripts/move-inputs.sh)
scripts/update-kernel.sh || warn "The kernel input stays where it is."

# Prints the coding agents that HOST's system would compile because
# cache.numtide.com does not hold their new build yet, or "unknown" when it
# cannot tell.
uncached_agents() {
  local agents plan
  agents=$(nix eval --impure --raw --expr "
    let pkgs = (builtins.getFlake \"git+file://$PWD\").inputs.llm-agents.packages.\${builtins.currentSystem};
        drv = p: let r = builtins.tryEval p.drvPath; in if r.success then [ r.value ] else [ ];
    in builtins.concatStringsSep \"\\n\" (builtins.concatMap drv (builtins.attrValues pkgs))") ||
    {
      echo unknown
      return
    }
  plan=$(nix build --dry-run ".#nixosConfigurations.$host.config.system.build.toplevel" 2>&1) ||
    {
      printf '%s\n' "$plan" | tail -n 20 >&2
      echo unknown
      return
    }
  grep -Fo -f <(echo "$agents") <<<"$plan" || true
}

cp flake.nix flake.lock "$work/"
nix flake update llm-agents
if ! cmp -s flake.lock "$work/flake.lock"; then
  uncached=$(uncached_agents)
  if [[ -n $uncached ]]; then
    warn "cache.numtide.com lacks: ${uncached//$'\n'/ }. llm-agents stays where it is."
    cp "$work/flake.nix" "$work/flake.lock" .
  fi
fi

apps=
for file in pkgs/*.nix; do
  app=$(basename "$file" .nix)
  if ! version=$(scripts/update-app.sh "$app" 2>"$work/app.err"); then
    cat "$work/app.err" >&2
    warn "$app stays where it is: $(tail -n 1 "$work/app.err")"
    continue
  fi
  [[ -n $version ]] || continue
  if nix build --no-link --impure --expr \
    "(builtins.getFlake \"git+file://$PWD\").nixosConfigurations.$host.pkgs.callPackage ./$file { }" \
    </dev/null 2>"$work/build.log"; then
    cat "$work/build.log" >&2
    apps+=$'\n'"- $app: $version"
    continue
  fi
  cat "$work/build.log" >&2
  # An npm wrapper project keeps its package.json and lockfile in pkgs/NAME/.
  restore=("$file")
  grep -q '^  passthru.npmPackage = ' "$file" && [[ -d pkgs/$app ]] && restore+=("pkgs/$app")
  git checkout -- "${restore[@]}"
  # shellcheck source=/dev/null
  . scripts/lib/build-error.sh
  reason=$(build_error "$work/build.log")
  warn "$app $version does not build: ${reason:-no error line}. It stays where it is."
done

# cachix/devenv moves about 4 times a day (29 commits on main from 2026-10-16
# to 2026-10-23), so it moves only with another move.
git diff --quiet && exit 0
if ! { "$devenv" update && "$devenv" build shell; } >"$work/devenv.log" 2>&1; then
  tail -n 20 "$work/devenv.log" >&2
  git checkout -- devenv.lock
  warn "devenv update or devenv build shell failed; devenv.lock stays where it is."
fi

# Inputs that moved to a new release tag are listed by version instead.
changes=$(jq -rn --slurpfile old "$work/base.lock" --slurpfile new flake.lock \
  --arg tagged "$(cut -d: -f1 <<<"$tags")" '
  ($tagged | split("\n")) as $skip
  | $new[0].nodes | to_entries[] | select(.value.locked.rev) | .key as $name
  | select($skip | index($name) | not)
  | ($old[0].nodes[$name].locked.rev // "none") as $from | .value.locked.rev as $to
  | select($from != $to) | "- \($name): \($from[0:7]) -> \($to[0:7])"')
[[ -n $tags ]] && changes+=$'\n'"- ${tags//$'\n'/$'\n'- }"
devenv_changes=$(jq -rn --slurpfile old "$work/base-devenv.lock" --slurpfile new devenv.lock '
  $new[0].nodes | to_entries[] | select(.value.locked.rev) | .key as $name
  | ($old[0].nodes[$name].locked.rev // "none") as $from | .value.locked.rev as $to
  | select($from != $to) | "- devenv.lock \($name): \($from[0:7]) -> \($to[0:7])"')
[[ -n $devenv_changes ]] && changes+=$'\n'"$devenv_changes"
changes+=$apps
# A leading newline comes from an empty first part.
printf '%s\n' "${changes#$'\n'}" >"$out"
