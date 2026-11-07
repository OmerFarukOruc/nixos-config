#!/usr/bin/env bash
api=https://openrouter.ai/api/v1
policy_name=threadsift-free-only
key_name=threadsift-verify
workspace_slug=default
max_pages=10
authorable_config='["allow_safety_retention_google","allow_safety_retention_other","allowed_data_regions","allowed_models","allowed_providers","enable_free_model_publication","enable_free_model_training","enable_paid_model_training","enforce_first_party_harness_models","enforce_zdr","enforce_zdr_anthropic","enforce_zdr_google","enforce_zdr_openai","enforce_zdr_other","enforce_zdr_xai","ignored_models","ignored_providers","platform_banned_authors","platform_banned_models","platform_banned_providers","require_eu_data_region"]'

if [ -z "${OPENROUTER_MANAGEMENT_KEY:-}" ]; then
  echo "OPENROUTER_MANAGEMENT_KEY is not set" >&2
  exit 78
fi

call() {
  local method=$1 path=$2
  shift 2
  curl --silent --show-error --fail-with-body --max-time 30 \
    --retry "${retries:-3}" --retry-max-time 60 \
    --request "$method" \
    --header @<(printf 'Authorization: Bearer %s\n' "$OPENROUTER_MANAGEMENT_KEY") \
    --header 'Content-Type: application/json' \
    "$@" "$api$path"
}

write() {
  local out
  if ! out=$(call "$@"); then
    printf '%s\n' "$out" >&2
    return 1
  fi
}

list_all() {
  local path=$1 separator='?' offset=0 page count all='[]' n
  [[ $path == *\?* ]] && separator='&'
  for ((n = 0; n < max_pages; n++)); do
    page=$(call GET "$path${separator}offset=$offset" | jq -ce '.data | arrays')
    count=$(jq length <<<"$page")
    if ((count == 0)); then
      printf '%s\n' "$all"
      return 0
    fi
    all=$(jq -c --argjson page "$page" '. + $page' <<<"$all")
    offset=$((offset + count))
  done
  echo "GET $path has more than $max_pages pages" >&2
  return 1
}

free_models=$(curl --silent --show-error --fail --max-time 30 --retry 3 --retry-max-time 60 "$api/models" | jq -c '
  [.data[]
    | select((.canonical_slug | type) == "string" and (.canonical_slug | length) > 0)
    | select((.pricing | length) > 0 and ([.pricing[] | tonumber? // 1] | all(. == 0)))
    | select(.supported_parameters | index("structured_outputs"))
    | .canonical_slug + ((.id // "") | capture(":(?<variant>[^:/]+)$").variant // "" | if . == "" then "" else ":" + . end)]
  | sort')

if [ "$(jq length <<<"$free_models")" -eq 0 ]; then
  echo "no free model supports structured outputs; the guardrail keeps its list, because an empty list allows every model" >&2
  exit 1
fi

workspace_id=$(list_all /workspaces | jq -er --arg slug "$workspace_slug" '
  map(select(.slug == $slug) | .id)
  | if length == 1 then .[0] else error("expected one workspace with slug \($slug), found \(length)") end')
key_hash=$(list_all "/keys?workspace_id=$workspace_id" | jq -er --arg name "$key_name" '
  map(select(.name == $name) | .hash)
  | if length == 1 then .[0] else error("expected one key named \($name), found \(length)") end')
policy=$(list_all "/guardrails/policies/model-availability?workspace_id=$workspace_id&limit=100" | jq -c --arg name "$policy_name" '
  map(select(.name == $name))
  | if length > 1 then error("expected at most one policy named \($name), found \(length)") else (first // empty) end')

if [ -z "$policy" ]; then
  body=$(jq -n -c \
    --arg name "$policy_name" \
    --arg workspace "$workspace_id" \
    --arg key "$key_hash" \
    --argjson models "$free_models" \
    '{name: $name, policy_type: "model_availability", workspace_id: $workspace,
      config: {allowed_models: $models}, api_key_hashes: [$key], member_ids: []}')
  retries=0 write POST /guardrails/policies/model-availability --data "$body"
  echo "created $policy_name for $key_name with $(jq -r 'join(", ")' <<<"$free_models")"
  exit 0
fi

policy_id=$(jq -er '.id | strings' <<<"$policy")
current=$(call GET "/guardrails/policies/model-availability/$policy_id?workspace_id=$workspace_id" | jq -ce --arg id "$policy_id" '
  .data
  | if type == "object" and .id == $id and (.config | type) == "object"
        and (.api_key_hashes | type) == "array" and (.member_ids | type) == "array"
        and (.opted_out_api_key_hashes | type) == "array"
    then . else error("the detail of policy \($id) is not a policy object with that id") end')

if jq -e --argjson models "$free_models" --arg key "$key_hash" '
  (.config.allowed_models | if type == "array" then sort else null end) == $models
  and (.api_key_hashes | index($key)) != null' <<<"$current" >/dev/null; then
  echo "$policy_name unchanged: $(jq -r 'join(", ")' <<<"$free_models")"
  exit 0
fi

body=$(jq -c \
  --arg name "$policy_name" \
  --arg workspace "$workspace_id" \
  --arg key "$key_hash" \
  --argjson models "$free_models" \
  --argjson authorable "$authorable_config" \
  '{name: $name, workspace_id: $workspace,
    config: (.config | with_entries(select(.key | IN($authorable[]))) + {allowed_models: $models}),
    api_key_hashes: (.api_key_hashes + [$key] | unique),
    member_ids: .member_ids,
    opted_out_api_key_hashes: .opted_out_api_key_hashes,
    opted_out_member_ids: (.opted_out_member_ids // [])}' <<<"$current")
write PUT "/guardrails/policies/model-availability/$policy_id" --data "$body"
jq -r -n --arg name "$policy_name" --argjson old "$(jq -c '.config.allowed_models // [] | sort' <<<"$current")" --argjson new "$free_models" '
  def list: join(", ") | if . == "" then "none" else . end;
  "updated \($name): added \(($new - $old) | list); removed \(($old - $new) | list)"'
