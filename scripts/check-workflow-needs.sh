#!/usr/bin/env bash
# usage: scripts/check-workflow-needs.sh WORKFLOW...
# GitHub skips a job whose if has neither always() nor cancelled() whenever a
# job before it in the needs chain was skipped or failed; an explicit
# success() behaves like the implicit one. So a job that needs a job running
# after skipped or failed jobs (always(), !cancelled(), failure()) needs
# always() or !cancelled() itself.
# https://docs.github.com/en/actions/reference/workflows-and-actions/expressions#status-check-functions
set -euo pipefail

status=0
for workflow in "$@"; do
  found=$(yq -o=json '.jobs // {}' "$workflow" | jq -r --arg file "$workflow" '
    def runs_after_skips: (.if // "" | tostring) | test("(always|cancelled|failure)\\(\\)");
    (to_entries | map(select(.value | runs_after_skips) | .key)) as $tolerant
    | to_entries[]
    | select(.value | runs_after_skips | not)
    | .key as $job
    | (.value.needs // [] | if type == "string" then [.] else . end)[]
    | select(IN($tolerant[]))
    | "\($file): job \($job) needs \(.), which runs after skipped or failed jobs, so \($job) needs always() or !cancelled() in its if"
  ')
  if [[ -n $found ]]; then
    printf '%s\n' "$found" >&2
    status=1
  fi
done
exit "$status"
