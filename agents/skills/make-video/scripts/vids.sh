# shellcheck shell=bash
# Helpers for driving Google Vids through an agent-browser command. Source in bash 4 or later:
#   VIDS_BROWSER=<browser command> VIDS_SESSION=<session> VIDS_DIR=<scratch dir> source vids.sh
# VIDS_BROWSER: the command of a browser signed in to the user's Google account, words split on
#   spaces (default agent-browser). The browser must write downloads and screenshots on this machine.
# VIDS_DOWNLOADS: the folder where that browser saves downloads (default ~/Downloads).
# VIDS_DIR: a scratch folder for this agent alone; snapshots and screenshots go there.
# Needs bash 4, GNU find and coreutils, and ImageMagick 7 (magick) for cropped screenshots.
# Defines functions and the variables B and D in the calling shell. Every helper returns non-zero
# when a lookup, click or key press fails, so the caller stops before keys land on the wrong element.
# ref and clickr match the snapshot text, because Vids controls are told apart by state such as
# [expanded=false] or [checked=true], which `agent-browser find` does not match.

[ -n "${BASH_VERSION:-}" ] || {
  echo "vids.sh needs bash" >&2
  return 1
}
: "${VIDS_SESSION:?set VIDS_SESSION}" "${VIDS_DIR:?set VIDS_DIR}"
mkdir -p "$VIDS_DIR" || return 1
read -ra B <<<"${VIDS_BROWSER:-agent-browser}"
B+=(--session "$VIDS_SESSION")
D=$VIDS_DIR
VIDS_SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

b() { "${B[@]}" "$@" >/dev/null || {
  echo "FAIL: $*" >&2
  return 1
}; }
snap() { "${B[@]}" snapshot -i >"$D/snap.txt" 2>&1; }
ref() {
  snap || {
    echo "FAIL: snapshot" >&2
    return 1
  }
  local r
  r=$(grep -aE -- "$1" "$D/snap.txt" | tail -1 | sed -nE 's/.*[[ ]ref=(e[0-9]+)[],].*/\1/p')
  [ -n "$r" ] || {
    echo "NOREF: $1" >&2
    return 1
  }
  echo "$r"
}
clickr() {
  local r
  r=$(ref "$1") || return 1
  b click "@$r"
}
shot() {
  "${B[@]}" screenshot "$D/${1:-v1}.png" >/dev/null || return 1
  [ -z "${2:-}" ] || magick "$D/${1:-v1}.png" -crop "$2" +repage "$D/${1:-v1}.png"
}
canvasclick() { b mouse move "$1" "$2" && b mouse down && b mouse up && sleep 0.5; }
totaltime() {
  local v
  v=$("${B[@]}" eval '(()=>{const m=document.body.innerText.match(/\d\d:\d\d\.\d\s*\/\s*(\d\d:\d\d\.\d)/);return m?m[1]:null})()') || return 1
  [ "$v" != null ] || {
    echo "no total time on the page" >&2
    return 1
  }
  echo "$v"
}
hook() { "${B[@]}" eval --stdin <"$VIDS_SCRIPTS/upload-hook.js" >/dev/null || {
  echo "FAIL: upload hook" >&2
  return 1
}; }

setfield() {
  local r
  r=$(ref "$1") || return 1
  b click "@$r" && b press Control+a && b keyboard inserttext "$2" && b press Tab
}
geom() {
  setfield 'spinbutton "Width"' "$1" && setfield 'spinbutton "Height"' "$2" &&
    setfield 'spinbutton "X"' "$3" && setfield 'spinbutton "Y"' "$4"
}
expand_if() {
  snap || return 1
  if grep -aq -- "$1" "$D/snap.txt"; then clickr "$2" && sleep 0.4; fi
}
openfmt() {
  clickr 'menuitem "Format"' && sleep 0.6 && clickr 'menuitem "Format options' && sleep 1.2 || return 1
  expand_if 'button "Size & rotation" \[expanded=false' 'button "Size & rotation"' &&
    expand_if 'button "Position" \[expanded=false' 'button "Position" \[expanded' &&
    expand_if 'checkbox "Lock aspect ratio" \[checked=true' 'checkbox "Lock aspect ratio"'
}

setcolor() {
  local h=${2#\#}
  h=${h,,}
  h=${h:0:6}
  [[ $h =~ ^[0-9a-f]{6}$ ]] || {
    echo "setcolor: '$2' is not a rrggbb colour" >&2
    return 1
  }
  clickr "$1" && sleep 0.8 && snap || return 1
  if grep -aq "gridcell \"Custom Color #${h}" "$D/snap.txt"; then
    clickr "gridcell \"Custom Color #${h}" && sleep 0.5
    return
  fi
  clickr 'button "Add a custom color"' && sleep 1 || return 1
  setfield 'textbox "R"' $((16#${h:0:2})) && sleep 0.3 || return 1
  setfield 'textbox "G"' $((16#${h:2:2})) && sleep 0.3 || return 1
  local r
  r=$(ref 'textbox "B"') || return 1
  b click "@$r" && b press End && b press Backspace && b press Backspace && b press Backspace && b press Backspace &&
    b keyboard inserttext $((16#${h:4:2})) && sleep 0.3 && b press Enter && sleep 0.5
}

style() {
  clickr 'listbox ("Font"|.*docs-font-family)' && sleep 1.5 && clickr "menuitemcheckbox \"${3:-Nunito}" && sleep 1 || return 1
  setfield 'textbox "Font size"' "$1" && sleep 0.4 || return 1
  setcolor 'button "Text color"' "$2"
}

typelines() {
  local text=${1//\\n/$'\n'} first=1 line
  while IFS= read -r line || [ -n "$line" ]; do
    if [ $first = 0 ]; then b press Enter && sleep 0.2 || return 1; fi
    first=0
    if [ -n "$line" ]; then b keyboard inserttext "$line" || return 1; fi
    sleep 0.3
  done <<<"$text"
}

newtext() {
  clickr 'button "Insert text"' && sleep 1.5 || return 1
  clickr "generic \"Add a $1\"" && sleep 1.5 || return 1
  b press Enter && sleep 0.6 && b press Control+a && sleep 0.4 && b press Backspace && sleep 0.4 || return 1
  typelines "$2" || return 1
  sleep 0.4
  b press Control+a && sleep 0.3 && b press Control+Shift+e && sleep 0.3 && b press Escape && sleep 0.5
}

replacetext() {
  b mouse move "$1" "$2" && b mouse down && b mouse up && sleep 0.15 && b mouse down && b mouse up && sleep 0.8 || return 1
  b press Control+a && sleep 0.4 && b press Backspace && sleep 0.4 || return 1
  typelines "$3" || return 1
  sleep 0.5
  b press Escape && sleep 0.4 && b press Escape && sleep 0.6
}

addclip() {
  local name i
  name=$(basename "$2")
  clickr 'button "New scene \(Ctrl\+M\)".*newSceneButton' && sleep 1.5 || return 1
  clickr "button \"Scene $1 of $1\"" && sleep 0.8 || return 1
  clickr 'menuitem "Insert"' && sleep 0.6 || return 1
  clickr 'menuitem "Upload u"' && sleep 0.8 || return 1
  [ "$("${B[@]}" eval 'document.querySelectorAll("#vids-upload-input").length')" = 1 ] || {
    echo "no file input; run hook first" >&2
    return 1
  }
  b upload "#vids-upload-input" "$2" || return 1
  for i in $(seq 1 30); do
    sleep 2
    snap && grep -aqF -e "$name" "$D/snap.txt" && {
      sleep 2
      return 0
    }
  done
  echo "addclip: $name did not appear in scene $1 within 60 s" >&2
  return 1
}

settrans() {
  canvasclick "$1" "$2" && sleep 1.2 || return 1
  clickr 'radio "Dissolve"' && sleep 1 || return 1
  local r
  r=$(ref 'spinbutton "Transition duration') || return 1
  b click "@$r" && b press Control+a && b keyboard inserttext "$3" && b press Enter && sleep 1
}

setsound() {
  clickr 'menuitem "Format"' && sleep 0.6 && clickr 'menuitem "Sound w"' && sleep 1.2 || return 1
  local p re v r
  for p in "spinbutton \"Volume\"|$1" "spinbutton \"Audio transition, fade in|$2" "spinbutton \"Audio transition, fade out|$3"; do
    re=${p%|*}
    v=${p#*|}
    r=$(ref "$re") || return 1
    b click "@$r" && b press Control+a && b keyboard inserttext "$v" && b press Enter && sleep 0.6 || return 1
  done
}

export_mp4() {
  local dest=${1:-} dl=${VIDS_DOWNLOADS:-$HOME/Downloads} before new f size last='' i
  [ -n "$dest" ] && [ -d "$(dirname "$dest")" ] || {
    echo "export_mp4: give a destination path in an existing folder" >&2
    return 1
  }
  before=$(find "$dl" -maxdepth 1 -name '*.mp4' -printf '%f\n' 2>/dev/null | sort)
  b press Escape && sleep 0.3 || return 1
  clickr 'menuitem "File"' && sleep 0.6 && clickr 'menuitem "Download' && sleep 0.6 && clickr 'menuitem "MP4 video' || return 1
  for i in $(seq 1 60); do
    sleep 10
    new=$(comm -13 <(printf '%s\n' "$before") <(find "$dl" -maxdepth 1 -name '*.mp4' -printf '%f\n' | sort) | head -1)
    [ -n "$new" ] || continue
    f="$dl/$new"
    size=$(stat -c %s "$f")
    if [ "$size" = "$last" ]; then
      mv "$f" "$dest" && echo "exported after $((i * 10)) s: $dest"
      return
    fi
    last=$size
  done
  echo "export_mp4: no new MP4 in $dl after 600 s" >&2
  return 1
}
