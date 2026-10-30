#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: prepare-update.sh apps|inputs HOST CHANGES"
mode=${1:?$usage}
host=${2:?$usage}
out=${3:?$usage}
[[ $mode == apps || $mode == inputs ]] || {
  echo "$usage" >&2
  exit 2
}
: >"$out"

warn() { echo "warning: $1" >&2; }

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
# shellcheck source=/dev/null
. scripts/lib/build-error.sh

app_files_with_npm_wrapper_dir() {
  local app
  app=$(basename "$1" .nix)
  echo "$1"
  if grep -q '^  passthru.npmPackage = ' "$1" && [[ -d pkgs/$app ]]; then
    echo "pkgs/$app"
  fi
}

# move_apps [FILE...]: moves each app, or every app in pkgs/ without an
# argument, with update-app.sh and keeps each move only when the app builds on
# its own. Appends "- APP: VERSION" lines to $apps.
apps=
move_apps() {
  local file app version reason restore files=("$@")
  ((${#files[@]})) || files=(pkgs/*.nix)
  for file in "${files[@]}"; do
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
    mapfile -t restore < <(app_files_with_npm_wrapper_dir "$file")
    git checkout -- "${restore[@]}"
    reason=$(build_error "$work/build.log")
    warn "$app $version does not build: ${reason:-no error line}. It stays where it is."
  done
}

if [[ $mode == apps ]]; then
  move_apps
  printf '%s\n' "${apps#$'\n'}" | sed '/^$/d' >"$out"
  exit 0
fi

git show HEAD:flake.lock >"$work/base.lock"
git show HEAD:devenv.lock >"$work/base-devenv.lock"
cp flake.nix flake.lock "$work/"

cached_devenv_of_main=$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#devenv)/bin/devenv

eval_error() {
  local h hosts
  hosts=$(nix eval --json .#nixosConfigurations --apply builtins.attrNames 2>"$work/eval.log") || {
    cat "$work/eval.log" >&2
    printf 'the flake does not evaluate: %s\n' "$(eval_line "$work/eval.log")"
    return
  }
  for h in $(jq -r '.[]' <<<"$hosts"); do
    if ! nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath" \
      >/dev/null 2>"$work/eval.log"; then
      cat "$work/eval.log" >&2
      printf '%s does not evaluate: %s\n' "$h" "$(eval_line "$work/eval.log")"
      return
    fi
  done
}
# eval_line LOG: the line of a failed evaluation that names the cause, such as
# a failed assertion, which Nix prints below its error: line.
eval_line() {
  local line
  line=$(sed -n 's/^[[:space:]]*- //p' "$1" | head -n 1)
  [[ -n $line ]] || line=$(grep -m 1 'error:' "$1" | sed 's/^[[:space:]]*//')
  printf '%s\n' "${line:0:200}"
}

tags=$(scripts/move-inputs.sh)
failed=$(eval_error)
if [[ -n $failed ]]; then
  # Nix names lock nodes in walk order, so the root's nixpkgs can have another
  # name in each lock.
  jq --slurpfile old "$work/base.lock" '
    .nodes[.nodes.root.inputs.nixpkgs] = $old[0].nodes[$old[0].nodes.root.inputs.nixpkgs]' \
    flake.lock >"$work/lock"
  cp "$work/lock" flake.lock
  rev() { jq -r '.nodes[.nodes.root.inputs.nixpkgs].locked.rev' "$1"; }
  if [[ $(rev flake.lock) == $(rev "$work/base.lock") ]] && again=$(eval_error) && [[ -z $again ]]; then
    warn "With the new nixpkgs, $failed; nixpkgs stays where it is."
  else
    warn "With the new inputs, $failed; every input stays where it is."
    cp "$work/flake.nix" "$work/flake.lock" .
    tags=
  fi
fi
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
  plan=$(nix build --dry-run ".#nixosConfigurations.$host.config.system.build.toplevel" 2>"$work/plan.log") ||
    {
      cat "$work/plan.log" >&2
      echo "unknown, because $host does not evaluate: $(eval_line "$work/plan.log")"
      return
    }
  plan+=$(cat "$work/plan.log")
  grep -Fo -f <(echo "$agents") <<<"$plan" || true
}

mkdir "$work/agents-base"
cp flake.nix flake.lock "$work/agents-base/"
nix flake update llm-agents
if ! cmp -s flake.lock "$work/agents-base/flake.lock"; then
  uncached=$(uncached_agents)
  if [[ -n $uncached ]]; then
    warn "cache.numtide.com lacks: ${uncached//$'\n'/ }. llm-agents stays where it is."
    cp "$work/agents-base/flake.nix" "$work/agents-base/flake.lock" .
  fi
fi

mapfile -t follow < <(grep -l '^  passthru.depsBun = ' pkgs/*.nix || true)
((${#follow[@]} == 0)) || move_apps "${follow[@]}"

# cachix/devenv moves about 4 times a day (29 commits on main from 2026-10-16
# to 2026-10-23), so it moves only with another move.
git diff --quiet && exit 0
if ! { "$cached_devenv_of_main" update && "$cached_devenv_of_main" build shell; } >"$work/devenv.log" 2>&1; then
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
