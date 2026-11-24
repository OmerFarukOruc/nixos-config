#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check-export.sh <exported.mp4> <out dir> [segments file]

Use a scratch folder as <out dir>, never the delivery folder. The script writes
<out dir>/clean.mp4 (the video and audio streams only; subtitle and caption
tracks removed), <out dir>/sheet.png (one frame per segment) and
<out dir>/frame-<label>.png (a full frame of each card segment), and prints
the streams, each segment's mean and max level, silences, loudness and true
peak, then FAIL lines and a last line PASS or FAIL.

Exit codes: 0 every check passed; 1 a check failed; 2 bad arguments or a
missing tool.

Segments file: one line per scene, "label start end kind", times in seconds,
kind one of:
  card    a text card; its level is checked like music
  music   only music sounds (a muted clip or a still)
  speech  a clip whose own sound, with speech, is kept
  clip    a clip whose own sound, without speech, is kept
Blank lines and lines starting with # are ignored. Example:
  T0  0.5  3.0  card
  S01 4.0  8.5  music
  S02 9.2 14.0  speech

Checks: a malformed segment line; a missing frame image; a card or music
segment quieter than -35 dB mean; a speech segment less than 6 dB above the
average of the music segments; a silence of 0.5 s or more below -50 dB that
starts after 0.5 s and ends before the last 0.5 s; audio segments in a file
without an audio stream.

Needs bash, ffmpeg and ffprobe; when ffmpeg or ffprobe is missing and nix is
present, the script runs itself again under `nix shell nixpkgs#ffmpeg`.
EOF
}

case ${1:-} in --help | -h)
  usage
  exit 0
  ;;
esac
[ $# -ge 2 ] || {
  usage >&2
  exit 2
}

if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then
  command -v nix >/dev/null || {
    echo "ffmpeg or ffprobe not found, and no nix to fetch them" >&2
    exit 2
  }
  exec nix shell nixpkgs#ffmpeg -c bash "$0" "$@"
fi

in=$1 out=$2 seg=${3:-}
case $in in -*) in=./$in ;; esac
[ -f "$in" ] || {
  echo "no such file: $in" >&2
  exit 2
}
[ -z "$seg" ] || [ -f "$seg" ] || {
  echo "no such segments file: $seg" >&2
  exit 2
}
mkdir -p "$out"
clean="$out/clean.mp4"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
failure() {
  echo "FAIL $*"
  fail=1
}

ffmpeg -nostdin -v error -y -i "$in" -map 0:v -map '0:a?' -c copy -movflags +faststart "$clean"
echo "== streams in the export"
ffprobe -v error -show_entries stream=index,codec_type,codec_name -of compact=p=0 "$in"
echo "== clean copy"
ffprobe -v error -show_entries format=duration,size:stream=codec_type,codec_name,width,height,r_frame_rate,sample_rate,channels -of compact=p=0 "$clean"
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$clean")
has_audio=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$clean" | head -1)
[ -n "$has_audio" ] || echo "no audio stream"

levels() {
  ffmpeg -nostdin -nostats -v info -ss "$2" -to "$3" -i "$1" -vn -af volumedetect -f null - 2>&1 |
    sed -nE 's/.*(mean|max)_volume: (-?[0-9.]+) dB.*/\2/p' | paste -sd ' '
}
is_num() { [[ $1 =~ ^[0-9]+([.][0-9]+)?$ ]]; }

if [ -n "$seg" ]; then
  echo "== segments (mean dB, max dB)"
  music_sum=0 music_n=0 i=0
  speech=() frames=()
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    read -r label start end kind extra <<<"$line" || true
    [ -z "${label:-}" ] || [ "${label:0:1}" = "#" ] && continue
    if [ -z "${kind:-}" ] || [ -n "${extra:-}" ]; then
      failure "segment line '$line': needs 4 fields"
      continue
    fi
    case $kind in card | music | speech | clip) ;; *)
      failure "segment $label: unknown kind '$kind'"
      continue
      ;;
    esac
    if ! is_num "$start" || ! is_num "$end" || ! awk -v s="$start" -v e="$end" -v d="$dur" 'BEGIN{exit !(s < e && e <= d + 0.05)}'; then
      failure "segment $label: times $start to $end are not numbers inside 0 to $dur with start before end"
      continue
    fi
    mean='' max=''
    if [ -n "$has_audio" ]; then
      read -r mean max <<<"$(levels "$clean" "$start" "$end")" || true
    elif [ "$kind" != card ]; then
      failure "segment $label: kind $kind needs audio, and the file has no audio stream"
    fi
    printf '%-6s %6s-%-6s %-6s %7s %7s\n' "$label" "$start" "$end" "$kind" "${mean:--}" "${max:--}"
    if [ -n "$has_audio" ]; then
      if [ -z "$mean" ]; then
        failure "segment $label: no level measured"
      else
        case $kind in
          card | music)
            if awk -v m="$mean" 'BEGIN{exit !(m < -35)}'; then failure "segment $label: $kind at $mean dB mean, quieter than -35 dB"; fi
            if [ "$kind" = music ]; then
              music_sum=$(awk -v a="$music_sum" -v m="$mean" 'BEGIN{print a + m}')
              music_n=$((music_n + 1))
            fi
            ;;
          speech) speech+=("$label $mean") ;;
        esac
      fi
    fi
    mid=$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%.2f", (s + e) / 2}')
    tile=$(printf '%s/sheet-%03d.png' "$tmp" "$i")
    if ! ffmpeg -nostdin -v error -y -ss "$mid" -i "$clean" -frames:v 1 -vf scale=480:-2 "$tile" || [ ! -s "$tile" ]; then
      failure "segment $label: no frame at $mid s"
    else
      i=$((i + 1))
    fi
    if [ "$kind" = card ]; then
      if ffmpeg -nostdin -v error -y -ss "$mid" -i "$clean" -frames:v 1 "$out/frame-$label.png" && [ -s "$out/frame-$label.png" ]; then
        frames+=("$out/frame-$label.png")
      else
        failure "segment $label: no full frame at $mid s"
      fi
    fi
  done <"$seg"
  if [ "${#speech[@]}" -gt 0 ]; then
    if [ "$music_n" -gt 0 ]; then
      echo "music segments average $(awk -v a="$music_sum" -v n="$music_n" 'BEGIN{printf "%.1f", a / n}') dB"
      for s in "${speech[@]}"; do
        read -r slabel smean <<<"$s"
        if awk -v m="$smean" -v a="$music_sum" -v n="$music_n" 'BEGIN{exit !(m - a / n < 6)}'; then
          failure "segment $slabel: speech at $smean dB is less than 6 dB above the music average"
        fi
      done
    else
      echo "no music segments: speech level not compared"
    fi
  fi
  rm -f "$out/sheet.png"
  if [ "$i" -gt 0 ]; then
    cols=4
    [ "$i" -lt 4 ] && cols=$i
    rows=$(((i + cols - 1) / cols))
    ffmpeg -nostdin -v error -y -i "$tmp/sheet-%03d.png" -vf "tile=${cols}x${rows}" "$out/sheet.png" || true
  fi
  if [ -s "$out/sheet.png" ]; then
    echo "== frames to look at: $out/sheet.png ${frames[*]:-}"
  else
    failure "no frame sheet written"
  fi
fi

if [ -n "$has_audio" ]; then
  echo "== silences (-50 dB, 0.5 s)"
  while read -r s e; do
    echo "silence $s to $e"
    if awk -v s="$s" -v e="$e" -v d="$dur" 'BEGIN{exit !(s > 0.5 && e < d - 0.5)}'; then
      failure "silent gap inside the film from $s to $e s"
    fi
  done < <(ffmpeg -nostdin -nostats -i "$clean" -vn -af silencedetect=noise=-50dB:d=0.5 -f null - 2>&1 |
    sed -nE 's/.*silence_start: (-?[0-9.]+).*/\1/p; s/.*silence_end: ([0-9.]+).*/\1/p' | paste - - |
    awk -v d="$dur" 'NF == 1 {print $1, d; next} {print}')
  echo "== loudness"
  ffmpeg -nostdin -nostats -i "$clean" -vn -af ebur128=peak=true -f null - 2>&1 | grep -E '^\s+(I|Peak):' | tail -2 || true
fi

if [ "$fail" = 0 ]; then echo "PASS: all checks"; else echo "FAIL: see the lines above"; fi
exit "$fail"
