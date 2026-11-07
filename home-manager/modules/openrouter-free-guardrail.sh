#!/usr/bin/env bash
api=https://openrouter.ai/api/v1
policy_name=threadsift-free-only
key_name=threadsift-verify
workspace_slug=default
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/openrouter-free-guardrail

finish() {
  local code=$?
  mkdir -p "$state_dir"
  if ((code)); then
    printf 'the run at %s exited %s, see journalctl --user -u openrouter-free-guardrail\n' \
      "$(date -u +%FT%TZ)" "$code" >"$state_dir/failed"
  else
    rm -f "$state_dir/failed"
  fi
}
trap finish EXIT

if [ -z "${OPENROUTER_MANAGEMENT_KEY:-}" ]; then
  echo "OPENROUTER_MANAGEMENT_KEY is not set" >&2
  exit 78
fi

call() {
  local method=$1 path=$2
  shift 2
  curl --silent --show-error --fail-with-body --max-time 60 --retry 3 \
    --request "$method" \
    --header @<(printf 'Authorization: Bearer %s\n' "$OPENROUTER_MANAGEMENT_KEY") \
    --header 'Content-Type: application/json' \
    "$@" "$api$path"
}

free_models=$(curl --silent --show-error --fail --max-time 60 --retry 3 "$api/models" | jq -c '
  [.data[]
    | select((.pricing | length) > 0 and ([.pricing[] | tonumber? // 1] | all(. == 0)))
    | select(.supported_parameters | index("structured_outputs"))
    | .canonical_slug + (.id | capture(":(?<variant>[^:/]+)$").variant // "" | if . == "" then "" else ":" + . end)]
  | sort')

if [ "$(jq length <<<"$free_models")" -eq 0 ]; then
  echo "no free model supports structured outputs; the guardrail keeps its list, because an empty list allows every model" >&2
  exit 1
fi

workspace_id=$(call GET /workspaces | jq -er --arg slug "$workspace_slug" '.data[] | select(.slug == $slug) | .id')
key_hash=$(call GET /keys | jq -er --arg name "$key_name" '.data[] | select(.name == $name) | .hash')
policy=$(call GET "/guardrails/policies/model-availability?workspace_id=$workspace_id" |
  jq -c --arg name "$policy_name" '[.data[] | select(.name == $name)] | first // empty')

body=$(jq -n -c \
  --arg name "$policy_name" \
  --arg workspace "$workspace_id" \
  --arg key "$key_hash" \
  --argjson models "$free_models" \
  '{name: $name, policy_type: "model_availability", workspace_id: $workspace,
    config: {allowed_models: $models}, api_key_hashes: [$key], member_ids: []}')

if [ -z "$policy" ]; then
  call POST /guardrails/policies/model-availability --data "$body" >/dev/null
  echo "created $policy_name for $key_name with $(jq -r 'join(", ")' <<<"$free_models")"
  exit 0
fi

policy_id=$(jq -er .id <<<"$policy")
current=$(call GET "/guardrails/policies/model-availability/$policy_id?workspace_id=$workspace_id" | jq -c .data)
current_models=$(jq -c '.config.allowed_models // [] | sort' <<<"$current")
assigned=$(jq -c '.api_key_hashes // []' <<<"$current")

if [ "$current_models" = "$free_models" ] && [ "$assigned" = "$(jq -nc --arg key "$key_hash" '[$key]')" ]; then
  echo "$policy_name unchanged: $(jq -r 'join(", ")' <<<"$free_models")"
  exit 0
fi

call PUT "/guardrails/policies/model-availability/$policy_id" \
  --data "$(jq -c 'del(.policy_type)' <<<"$body")" >/dev/null
jq -r -n --argjson old "$current_models" --argjson new "$free_models" \
  '"updated '"$policy_name"': added \(($new - $old) | join(", ") | if . == "" then "none" else . end); removed \(($old - $new) | join(", ") | if . == "" then "none" else . end)"'
