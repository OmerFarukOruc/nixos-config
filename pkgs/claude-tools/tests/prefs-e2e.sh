#!/usr/bin/env bash
set -euo pipefail
ct="$(readlink -f "${1:?usage: $0 BIN-DIR}")/claude-tools"
lock="$(dirname "$(readlink -f "$ct")")/../libexec/claude-tools/config-lock.sh"
s="$(mktemp -d /tmp/prefs-e2e.XXXXXX)"
disk="$(mktemp -d "${PREFS_E2E_DISK_DIR:-/var/tmp}/prefs-e2e.XXXXXX")"
trap 'rm -rf "$s" "$disk"' EXIT
mkdir -p "$s/data"
echo '{"leftArrowOpensAgents": false}' >"$s/data/account-prefs.json"

set_key() {
  jq "$2" "$1" >"$s/t"
  mv "$s/t" "$1"
}
fails=0
expect() {
  if [[ "$2" == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1: got '$2', want '$3'"
    fails=1
  fi
}

mkdir -p "$s/homeC/.claude-p1" "$s/homeC/.claude-p2"
touch "$s/homeC/.claude-p1/.claude-profile" "$s/homeC/.claude-p2/.claude-profile"
echo '{"numStartups":5}' >"$s/homeC/.claude.json"
echo '{"userID":"x"}' >"$s/homeC/.claude-p1/.claude.json"
echo '{"userID":"y","leftArrowOpensAgents":false}' >"$s/homeC/.claude-p2/.claude.json"
chmod 600 "$s/homeC/.claude.json"
chmod 640 "$s/homeC/.claude-p1/.claude.json"
prefs_c() { HOME="$s/homeC" CLAUDE_TOOLS_DATA="$s/data" "$ct" accounts prefs >"$s/out" 2>&1; }
main_c="$s/homeC/.claude.json"
p1_c="$s/homeC/.claude-p1/.claude.json"
p2_c="$s/homeC/.claude-p2/.claude.json"
locks_c() { find "$s/homeC" -name .claude.json.lock | wc -l; }
repo_v=$(jq -c .leftArrowOpensAgents "$s/data/account-prefs.json")
other_v=$(jq -c 'not' <<<"$repo_v")
p2_before=$(stat -c '%i %Y' "$p2_c")
sleep 1
rc=0
prefs_c || rc=$?
expect "prefs with both locks free succeeds" "$rc" "0"
expect "and writes the declared value into the main account" "$(jq -c '[.leftArrowOpensAgents, .numStartups]' "$main_c")" "[false,5]"
expect "and into the profile, keeping its other keys" "$(jq -c '[.leftArrowOpensAgents, .userID]' "$p1_c")" '[false,"x"]'
expect "and keeps each file's mode" "$(stat -c %a "$main_c" "$p1_c" | tr '\n' ' ')" "600 640 "
expect "and leaves a profile that already holds the value untouched" "$(stat -c '%i %Y' "$p2_c")" "$p2_before"
expect "and names only the files it changed" "$(grep -c '^applied leftArrowOpensAgents to ' "$s/out")" "2"
expect "and leaves no lock directory behind" "$(locks_c)" "0"

mkdir -p "$s/homeC/.claude-p3"
touch "$s/homeC/.claude-p3/.claude-profile"
echo '{"userID":' >"$s/homeC/.claude-p3/.claude.json"
rc=0
prefs_c || rc=$?
expect "prefs fails on an account file that does not parse" "$rc" "1"
expect "and names it" "$(grep -c "^prefs: could not read $s/homeC/.claude-p3/.claude.json" "$s/out")" "1"
rm -rf "$s/homeC/.claude-p3"

set_key "$p1_c" ".leftArrowOpensAgents=$other_v"
mkdir "$p1_c.lock"
(
  sleep 2
  jq -c .leftArrowOpensAgents "$p1_c" >"$s/seen"
  rmdir "$p1_c.lock"
) &
rc=0
prefs_c || rc=$?
wait
expect "prefs waits for a lock held for 2 s" "$(cat "$s/seen")" "$other_v"
expect "and then succeeds" "$rc" "0"
expect "and writes the declared value into the profile" "$(jq -c .leftArrowOpensAgents "$p1_c")" "$repo_v"

set_key "$p1_c" ".leftArrowOpensAgents=$other_v"
mkdir "$p1_c.lock"
(for _ in $(seq 12); do
  sleep 1
  touch -c "$p1_c.lock"
done) &
holder=$!
(
  max=0 n=0
  while :; do
    if m=$(stat -c %Y "$s/homeC/.claude.json.lock" 2>/dev/null); then
      a=$(($(date +%s) - m))
      n=$((n + 1))
      ((a <= max)) || max=$a
      echo "$max $n" >"$s/main-lock-age"
    fi
    sleep 0.1
  done
) &
sampler=$!
rc=0
prefs_c || rc=$?
kill "$sampler" "$holder" 2>/dev/null || true
rmdir "$p1_c.lock" 2>/dev/null || true
expect "prefs fails when a lock stays held past 10 s" "$rc" "1"
read -r max_age samples <"$s/main-lock-age"
expect "and the lock it took first never gets older than 3 s while it waits ($samples samples)" "$((samples > 10 && max_age <= 3))" "1"
expect "and names the lock" "$(grep -c "config: not changed, $p1_c.lock is held" "$s/out")" "1"
expect "and leaves the profile as it was" "$(jq -c .leftArrowOpensAgents "$p1_c")" "$other_v"
expect "and releases the lock it took on the main account" "$(find "$s/homeC" -maxdepth 1 -name .claude.json.lock | wc -l)" "0"

mkdir "$p1_c.lock"
touch -d '1 minute ago' "$p1_c.lock"
rc=0
start=$SECONDS
prefs_c || rc=$?
expect "prefs breaks a lock nobody has touched for a minute" "$rc" "0"
expect "and does not wait out the 10 s for it" "$((SECONDS - start < 5))" "1"
expect "and writes the declared value into the profile" "$(jq -c .leftArrowOpensAgents "$p1_c")" "$repo_v"
expect "and leaves no lock directory behind" "$(locks_c)" "0"

rmdir "$p1_c.lock" 2>/dev/null || true

rounds="${E2E_LOCK_ROUNDS:-20}"
lock_sh() { HOME="$s/homeC" bash -c 'source "$1"; shift; '"$1" _ "$lock" "${@:2}"; }

# shellcheck disable=SC2016
released=$(lock_sh '
  set -e
  claude_config_lock "$1"; claude_config_lock "$2"
  rm -rf "$1.lock"
  claude_config_unlock "$1"; claude_config_unlock "$2"
  echo released' "$s/homeC/.claude.json" "$p1_c" 2>&1) || true
expect "unlock of a missing lock returns 0 under set -e" "$released" "released"
expect "and the other lock is released" "$(locks_c)" "0"

# shellcheck disable=SC2016
lock_sh 'claude_config_lock "$1"; kill -9 $$' "$p1_c" || true
touch -d '1 minute ago' "$p1_c.lock"
rc=0
rmdir "$p1_c.lock" 2>/dev/null || rc=$?
expect "Claude Code's rmdir breaks the stale lock a killed holder left" "$rc" "0"
rm -rf "$p1_c.lock"

inode_reuse() {
  local d="$1/probe" ino _
  mkdir "$d"
  ino=$(stat -c %i "$d")
  for _ in $(seq 100); do
    rmdir "$d"
    mkdir "$d"
    [[ "$(stat -c %i "$d")" != "$ino" ]] || {
      rmdir "$d"
      return 0
    }
  done
  rmdir "$d"
  return 1
}
kept=0 reused=0 reuse_tries=3
if inode_reuse "$disk"; then reuse_tries=100; fi
f_disk="$disk/.claude.json"
# shellcheck disable=SC2016
for ((i = 0; i < rounds; i++)); do
  res=$(lock_sh 'claude_config_lock "$1"; ino=$(stat -c %i "$1.lock"); sleep 0.02
    for _ in $(seq "$2"); do rmdir "$1.lock"; mkdir "$1.lock"; [[ $(stat -c %i "$1.lock") == "$ino" ]] && break; done
    [[ $(stat -c %i "$1.lock") == "$ino" ]] && echo reused
    claude_config_unlock "$1"; [[ -d "$1.lock" ]] || echo removed' "$f_disk" "$reuse_tries")
  [[ "$res" == *reused* ]] && reused=$((reused + 1))
  [[ "$res" == *removed* ]] && kept=$((kept + 1))
  rm -rf "$f_disk.lock"
  res=$(lock_sh 'claude_config_lock "$1"; sleep 0.02; rmdir "$1.lock"; mkdir "$1.lock"
    claude_config_unlock "$1"; [[ -d "$1.lock" ]] || echo removed' "$f_disk")
  [[ "$res" == *removed* ]] && kept=$((kept + 1))
  rm -rf "$f_disk.lock"
done
expect "unlock leaves a foreign lock alone ($rounds rounds, two kinds)" "$kept" "0"
if ((reuse_tries == 100)); then
  expect "and the first kind got our inode number back in a recreated directory ($reused of $rounds rounds)" "$((reused > 0))" "1"
else
  echo "SKIP the first kind needs inode numbers that come back, and $disk never hands one out twice; only a foreign lock with a new inode was checked"
fi

cat >"$s/contender.sh" <<'CONTENDER'
source "$1"
until [[ -e "$3" ]]; do :; done
claude_config_lock "$2" || { echo failed >> "$4"; exit 0; }
echo in >> "$4"; sleep 0.1; echo out >> "$4"
claude_config_unlock "$2"
CONTENDER
overlap=0
for ((i = 0; i < rounds; i++)); do
  rm -f "$s/go" "$s/holds"
  mkdir "$p1_c.lock"
  touch -d '1 minute ago' "$p1_c.lock"
  for _ in 1 2 3; do HOME="$s/homeC" bash "$s/contender.sh" "$lock" "$p1_c" "$s/go" "$s/holds" & done
  touch "$s/go"
  wait
  [[ "$(tr '\n' ' ' <"$s/holds")" == "in out in out in out " ]] || overlap=$((overlap + 1))
done
expect "three runs breaking one stale lock hold it one at a time ($rounds rounds)" "$overlap" "0"
expect "and leave no lock directory behind" "$(locks_c)" "0"

((fails)) || echo PASS
exit "$fails"
