#!/usr/bin/env bash
# Claude Code status line. Claude Code pipes the session JSON on stdin; the fields are listed at
# https://code.claude.com/docs/en/statusline#available-data
# One row: directory, git, model and effort, account, clock, cost, context bar, 5h and 7d limits. When COLUMNS is
# set, segments that do not fit wrap onto another row.

input=$(cat)
cwd=$(jq -r '.workspace.current_dir // .cwd // empty' <<<"$input")

# The git status goes to jq as a file, because a tree with many untracked files can pass the argv size limit.
git_status=""
git_sha=""
if [[ -n "$cwd" ]]; then
  git_status=$(git --no-optional-locks -C "$cwd" status --porcelain=v1 --branch 2>/dev/null)
  if [[ "$git_status" == "## HEAD (no branch)"* ]]; then
    git_sha=$(git --no-optional-locks -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  fi
fi

# The account this session runs as, shown as profile and plan. claude-tools accounts selects it with CLAUDE_CONFIG_DIR
# and names it after the folder's .claude-profile marker, or the folder suffix when the marker is empty; ~/.claude is
# named in .claude-profile-name. Claude Code keeps the login in .claude.json next to the folder for ~/.claude, inside
# it otherwise.
if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
  profile=$(cat "$CLAUDE_CONFIG_DIR/.claude-profile" 2>/dev/null)
  profile=${profile:-${CLAUDE_CONFIG_DIR##*/.claude-}}
  account_file=$CLAUDE_CONFIG_DIR/.claude.json
else
  profile=$(cat "$HOME/.claude/.claude-profile-name" 2>/dev/null)
  account_file=$HOME/.claude.json
fi
account=(--argjson account '[]')
[[ -r "$account_file" ]] && account=(--slurpfile account "$account_file")

colors_file=${XDG_STATE_HOME:-$HOME/.local/state}/oruc/theme/current/.oruc/statusline
fact=(--argjson fact '[]')
jq -e '(.segments | type) == "object" and (.used | type) == "object"' "$colors_file" >/dev/null 2>&1 &&
  fact=(--slurpfile fact "$colors_file")

jq -rj --rawfile git <(printf '%s' "$git_status") --arg sha "$git_sha" --arg cwd "$cwd" --arg home "$HOME" \
  --arg cols "${COLUMNS:-0}" --arg profile "$profile" "${account[@]}" "${fact[@]}" '
  def light: "248;248;242";
  def dark: "31;35;53";
  def fixed_used: {low: "106;211;158", mid: "255;197;88", high: "255;130;130"};
  def fixed_colors: {
    segments: {dir: {bg: "42;53;72", fg: light}, git: {bg: "252;161;125", fg: dark}, cost: {bg: "154;52;142", fg: light},
      model: {bg: "61;79;99", fg: light}, account: {bg: "60;110;113", fg: light}, clock: {bg: "51;101;138", fg: light},
      ctx: {bg: "14;60;52"}, five_hour: {bg: "72;38;110"}, seven_day: {bg: "92;28;64"}},
    used: {ctx: fixed_used, five_hour: fixed_used, seven_day: fixed_used}};
  def colors: fixed_colors * ($fact[0] // {});
  def segment($name): colors.segments[$name];
  def used_fg($name): colors.used[$name] as $u | if . < 50 then $u.low elif . <= 80 then $u.mid else $u.high end;
  def repeat($s): [range(0; .)] | map($s) | join("");
  def bar: ([([. / 10 | round, 10] | min), 0] | max) as $f | ($f | repeat("█")) + (10 - $f | repeat("░"));
  def fixed($d): pow(10; $d) as $m | (. * $m | round) as $n | ($n % $m | tostring) as $f
    | "\($n / $m | floor).\($d - ($f | length) | repeat("0"))\($f)";
  # Used percentage minus the elapsed percentage of the window: positive burns faster than the window allows.
  def pace($used; $resets; $window): ($resets - now) as $left
    | if $left <= 0 or $left > $window then ""
      else ($used - (1 - $left / $window) * 100 | round) as $d
        | if $d > 5 then " ▲+\($d)%" elif $d < -5 then " ▽\($d)%" else " ≈" end
      end;
  def limit($name; $label; $window; $time_format):
    .rate_limits[$name] // empty
    | (.used_percentage // empty | round) as $p
    | {fg: ($p | used_fg($name)), bg: segment($name).bg,
       text: ("\($label) [\($p | bar)] \($p)%"
         + (.resets_at // null | if . == null then "" else pace($p; .; $window) + " ↺" + strflocaltime($time_format) end))};

  ($git | split("\n") | map(select(length > 0))) as $git_lines
  | [
      # Directory, with $HOME as ~ and long paths cut to their last two parts.
      ($cwd | select(. != "")
        | (if . == $home or startswith($home + "/") then "~" + .[($home | length):] else . end)
        | segment("dir") + {text: (if length > 32 then "…/" + (split("/") | .[-2:] | join("/")) else . end)}),

      # Git: branch, ahead and behind, ! for tracked changes, ? for untracked files.
      (if ($git_lines | length) == 0 then empty else
        ($git_lines[0] | ltrimstr("## ")) as $head
        | (if ($head | startswith("HEAD (no branch)")) then $sha
           elif ($head | startswith("No commits yet on ")) then $head | ltrimstr("No commits yet on ")
           else $head | split("...") | .[0] | split(" ") | .[0] end) as $branch
        | ($head | capture("ahead (?<n>[0-9]+)").n // null) as $ahead
        | ($head | capture("behind (?<n>[0-9]+)").n // null) as $behind
        | ($git_lines[1:] | map(startswith("??"))) as $untracked
        | ((if any($untracked[]; not) then "!" else "" end) + (if any($untracked[]; .) then "?" else "" end)) as $dirty
        | segment("git") + {
           text: (" \($branch)" + (if $ahead then " ⇡\($ahead)" else "" end)
             + (if $behind then " ⇣\($behind)" else "" end) + (if $dirty == "" then "" else " " + $dirty end))}
      end),

      # Model and reasoning effort; Claude Code omits effort for models that do not support it.
      (.effort.level as $effort | .model.display_name // empty
        | segment("model") + {text: (if $effort then "\(.) \($effort)" else . end)}),

      # Account: profile and plan, such as "work1 Max". claude_team becomes Team.
      ([$profile,
        ($account[0].oauthAccount.organizationType // "" | ltrimstr("claude_")
          | if . == "" then . else (.[:1] | ascii_upcase) + .[1:] end)]
       | map(select(. != "")) | join(" ")
       | if . == "" then empty else segment("account") + {text: ("@ " + .)} end),

      segment("clock") + {text: "♥ \(now | strflocaltime("%H:%M"))"},

      # Session cost at API list price, as /cost shows it; a subscription does not bill this amount.
      (.cost.total_cost_usd // empty
        | segment("cost") + {text: ("$" + (if . >= 1 then fixed(2) elif . >= 0.1 then fixed(3) else fixed(4) end))}),

      (.context_window.used_percentage // empty | round | {fg: used_fg("ctx"), bg: segment("ctx").bg, text: "CTX [\(bar)] \(.)%"}),

      limit("five_hour"; "5h"; 18000; "%H:%M"),
      limit("seven_day"; "7d"; 604800; "%a %H:%M")
    ]
  # A segment takes its text, a space on each side and one arrow. Claude Code adds its own margin, which the docs
  # do not give; 4 columns is a guess. A row wider than that wraps onto another row.
  | (($cols | tonumber? // 0) - 4) as $width
  | reduce .[] as $s ({rows: [[]], used: 0};
      ($s.text | length + 3) as $w
      | if $width > 0 and (.rows[-1] | length) > 0 and .used + $w > $width
        then .rows += [[$s]] | .used = $w else .rows[-1] += [$s] | .used += $w end)
  | .rows
  | map(
      reduce .[] as $s ({out: "", prev: null};
        .out += (if .prev == null then "\u001b[38;2;\($s.bg)m"
                 else "\u001b[38;2;\(.prev)m\u001b[48;2;\($s.bg)m" end) + "\u001b[0m"
          + "\u001b[38;2;\($s.fg)m\u001b[48;2;\($s.bg)m \($s.text) \u001b[0m"
        | .prev = $s.bg)
      | .out + "\u001b[38;2;\(.prev)m\u001b[0m")
  | join("\n")
' <<<"$input"
