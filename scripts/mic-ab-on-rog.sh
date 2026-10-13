#!/usr/bin/env bash
# usage: scripts/mic-ab-on-rog.sh level VOLUME...
#        scripts/mic-ab-on-rog.sh ab [--label LABEL]
# Records nixos-rog's internal microphone to compare its level or its noise
# suppressors. Someone sits at the laptop and follows the prompts.
#
# level sets the microphone to each wpctl VOLUME in turn (for example 0.3 0.5
# 0.7), records 10 s of speech and prints the speech peak and the noise floor
# in dBFS. Speech peaks between -12 and -6 dBFS leave room without noise.
#
# ab records 60 s at once from the raw microphone, easyeffects_source and
# hushmic_source, and prints a cue every 10 s: silence, typing, speech, speech
# while typing, room noise only, then another voice such as a phone playing
# speech. For each 10 s part it reports the level of each source and how far
# each denoised source sits below the raw one. The noise-only parts should
# drop far; the speech part should not.
#
# Each prompt and cue also shows as a silent notification on rog's screen.
#
# Exit status: 2 for a usage error, 3 when a source is missing.
#
# The recordings hold room audio: they are removed from rog and kept only under
# ${TMPDIR:-/tmp}/mic-ab/TIME-MODE/ here, with report.json. The report names
# this script's git blob as script, so a run cited as evidence can be matched
# to a commit: git rev-parse REV:scripts/mic-ab-on-rog.sh.
# shellcheck disable=SC2016,SC2029 # the remote bash expands the quoted scripts
set -euo pipefail

host=nixos-rog
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=15)
mic=alsa_input.pci-0000_66_00.6.analog-stereo

die() {
  echo "$1" >&2
  exit "${2:-1}"
}

mode=${1:-}
shift || true
label=
case $mode in
  level)
    (($#)) || die "usage: $0 level VOLUME..." 2
    for v in "$@"; do
      [[ $v =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || die "VOLUME takes 0 to 1, not $v" 2
    done
    ;;
  ab)
    if [[ ${1:-} == --label ]]; then
      label=${2:?--label needs a value}
      shift 2
    fi
    (($# == 0)) || die "usage: $0 ab [--label LABEL]" 2
    ;;
  *) die "usage: $0 level VOLUME... | $0 ab [--label LABEL]" 2 ;;
esac

script_blob=$(git hash-object "$0")
out=${TMPDIR:-/tmp}/mic-ab/$(date +%Y%m%dT%H%M%S)-${mode}${label:+-$label}
mkdir -p "$out"
remote=$(ssh "${ssh_opts[@]}" "$host" mktemp -d /tmp/mic-ab.XXXXXXXX)
[[ $remote =~ ^/tmp/mic-ab\.[A-Za-z0-9]{8}$ ]] || die "mktemp on $host printed $remote"

# rog_run SCRIPT ARG...: runs SCRIPT in bash on rog with the user's PipeWire.
rog_run() {
  local script=$1
  shift
  ssh "${ssh_opts[@]}" "$host" "XDG_RUNTIME_DIR=/run/user/\$(id -u) bash -s -- $(printf '%q ' "$@")" <<<"$script"
}

# Prepended to the remote scripts: node_id NAME prints a node's id, or nothing.
lib='node_id() {
  pw-dump | jq -r --arg n "$1" \
    "first(.[] | select(.type == \"PipeWire:Interface:Node\" and .info.props.\"node.name\" == \$n) | .id) // empty"
}'

original_volume=$(rog_run "$lib"$'\n''wpctl get-volume "$(node_id "$1")" | awk "{print \$2}"' "$mic")
[[ -n $original_volume ]] || die "$mic is missing on $host" 3

set_volume() {
  rog_run "$lib"$'\n''wpctl set-volume "$(node_id "$1")" "$2"' "$mic" "$1"
}

cleanup() {
  set_volume "$original_volume" || true
  rog_run 'rm -rf -- "$1"' "$remote" || true
}
trap cleanup EXIT

# record_script DIR SECONDS then NAME TARGET NODE_NAME per recording: records
# each TARGET to DIR/NAME.wav, mono at 48 kHz, all at once. NODE_NAME - keeps
# pw-record's own name.
record_script='
dir=$1 seconds=$2
shift 2
pids=() files=()
while (($#)); do
  name=$1 target=$2 node=$3
  shift 3
  props=()
  [[ $node != - ]] && props=(-P "{ node.name = $node }")
  pw-record --target "$target" "${props[@]}" --rate 48000 --channels 1 --format s16 \
    --sample-count $((seconds * 48000)) "$dir/$name.wav" &
  pids+=($!)
  files+=("$dir/$name.wav")
done
# pw-record exits 1 when --sample-count stops it, so the file sizes decide.
wait "${pids[@]}" || true
for f in "${files[@]}"; do
  (($(stat -c %s "$f") >= seconds * 96000)) || { echo "$f is short" >&2; exit 1; }
done
'

# notify TEXT: prints TEXT here and shows it on rog's screen, where the person
# being recorded looks. The notification plays no sound.
notify() {
  printf '%s  %s\n' "$(date +%T)" "$1"
  rog_run 'DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus busctl --user call \
    org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications \
    Notify susssasa{sv}i mic-ab 0 audio-input-microphone "Microphone test" "$1" 0 1 suppress-sound b true 10000' \
    "$1" >/dev/null || true
}

# cue SECONDS TEXT...: shows each TEXT SECONDS after the one before, counted
# from the first cue, so the time each notify takes does not add up.
cue() {
  local step=$(($1 * 1000000)) start=${EPOCHREALTIME/./} i=0 wait_us
  shift
  for text in "$@"; do
    notify "$text"
    ((i += 1))
    wait_us=$((start + i * step - ${EPOCHREALTIME/./}))
    if ((wait_us > 0)); then
      sleep "$((wait_us / 1000000)).$(printf %06d $((wait_us % 1000000)))"
    fi
  done
}

if [[ $mode == level ]]; then
  for v in "$@"; do
    set_volume "$v"
    notify "Volume $v: in 3 s, read aloud at your normal call voice for 10 s."
    sleep 3
    notify "Recording volume $v: read aloud now."
    rog_run "$record_script" "$remote" 10 "level-$v" "$mic" -
  done
  notify "Level test done. You can stop reading."
else
  for source in easyeffects_source hushmic_source; do
    [[ -n $(rog_run "$lib"$'\n''node_id "$1"' "$source") ]] || die "$source is missing on $host" 3
  done
  echo "Recording 60 s. Follow the cue on each line."
  rog_run "$record_script" "$remote" 60 \
    raw "$mic" - \
    easyeffects easyeffects_source - \
    hushmic hushmic_source - &
  recorder=$!
  sleep 1
  cue 10 "silence: stay quiet" "typing only" "speech only" "speech while typing" \
    "room or fan noise only" "another voice only, such as a phone playing speech"
  wait "$recorder"
  notify "A/B test done. You can stop."
fi

rsync -a "$host:$remote/" "$out/"
hushmic_status=$(rog_run 'hushmic status --json 2>/dev/null || echo null')
preset=$(rog_run 'grep -h "^lastLoadedInputPreset=" ~/.config/easyeffects/db/easyeffectsrc || true')

python3 -I - "$out" "$mode" "$script_blob" "$original_volume" "$hushmic_status" "$preset" <<'PY'
import array, json, math, os, sys, wave

out, mode, blob, volume, hushmic, preset = sys.argv[1:7]

def samples(path):
    with wave.open(path) as w:
        data = array.array("h", w.readframes(w.getnframes()))
    if sys.byteorder != "little":
        data.byteswap()
    return data

def dbfs(values):
    if not values:
        return None
    rms = math.sqrt(sum(v * v for v in values) / len(values)) / 32768
    return round(20 * math.log10(rms), 1) if rms > 0 else -200.0

report = {"mode": mode, "script": blob, "volume_before": volume, "easyeffects": preset.strip()}
try:
    report["hushmic"] = json.loads(hushmic)
except ValueError:
    report["hushmic"] = hushmic
rate = 48000

if mode == "level":
    report["levels"] = {}
    for name in sorted(f for f in os.listdir(out) if f.startswith("level-")):
        x = samples(os.path.join(out, name))
        peak = max((abs(v) for v in x), default=0) / 32768
        windows = [dbfs(x[i:i + rate // 2]) for i in range(0, len(x) - rate // 2, rate // 2)]
        report["levels"][name[6:-4]] = {
            "peak_dbfs": round(20 * math.log10(peak), 1) if peak else -200.0,
            "clipped_samples": sum(1 for v in x if abs(v) >= 32767),
            "noise_floor_dbfs": min(windows) if windows else None,
            "speech_rms_dbfs": dbfs(x),
        }
else:
    parts = ["silence", "typing", "speech", "speech_typing", "room", "other_voice"]
    sources = {n: samples(os.path.join(out, n + ".wav")) for n in ("raw", "easyeffects", "hushmic")}
    report["parts"] = {}
    for i, part in enumerate(parts):
        # 1 s margins hide each source's processing delay and the cue timing.
        a, b = (i * 10 + 1) * rate, (i * 10 + 9) * rate
        level = {n: dbfs(s[a:b]) for n, s in sources.items()}
        report["parts"][part] = {
            "dbfs": level,
            "below_raw_db": {
                n: round(level["raw"] - level[n], 1)
                for n in ("easyeffects", "hushmic")
                if level[n] is not None and level["raw"] is not None
            },
        }

with open(os.path.join(out, "report.json"), "w") as f:
    json.dump(report, f, indent=2)
print(json.dumps(report.get("levels") or report["parts"], indent=2))
print(f"report: {out}/report.json")
PY
