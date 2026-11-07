#!/usr/bin/env bash
# usage: ci/private-scan.sh BASE HEAD
# Refuses the commits in BASE..HEAD when gitleaks finds a token in them, or when a commit message or an added line,
# binary files and merge results included, holds one of the private values listed one per line in
# AGENTS_PRIVATE_VALUES (default /run/secrets/agents-private-values). It prints the commit and the path of a hit,
# never the value.
set -euo pipefail
cd "$(dirname "$0")/.."

base=${1:?usage: ci/private-scan.sh BASE HEAD}
head=${2:?usage: ci/private-scan.sh BASE HEAD}
values=${AGENTS_PRIVATE_VALUES:-/run/secrets/agents-private-values}

if [[ ! -r $values ]]; then
  echo "private-scan: $values is missing or unreadable; push from a host that decrypts secrets/agents.yaml (nixos-desktop, nixos-rog or devbox)" >&2
  exit 1
fi

gitleaks git --no-banner --redact --log-opts="$base..$head" . >&2 || {
  echo "private-scan: gitleaks found a token in $base..$head" >&2
  exit 1
}

git -c core.quotePath=false log --text -p --diff-merges=first-parent --format='commit %H%n%B' "$base..$head" |
  awk -v values="$values" '
    BEGIN {
      while ((status = (getline line < values)) > 0) {
        gsub(/\r/, "", line)
        gsub(/^[ \t]+|[ \t]+$/, "", line)
        if (line != "") wanted[++count] = line
      }
      if (status < 0) { print "private-scan: cannot read " values > "/dev/stderr"; failed = 2; exit }
      if (!count) { print "private-scan: " values " holds no value" > "/dev/stderr"; failed = 2; exit }
    }
    /^commit [0-9a-f]+$/ { commit = substr($2, 1, 12); where = "its message"; inhunk = 0; next }
    /^diff --git / { where = ""; inhunk = 0; next }
    /^\+\+\+ / && !inhunk { where = substr($0, 5); sub(/^b\//, "", where); next }
    /^@@/ { inhunk = 1; next }
    {
      if (inhunk && substr($0, 1, 1) != "+") next
      if (!inhunk && where != "its message") next
      for (i = 1; i <= count; i++) if (index($0, wanted[i])) {
        hit = commit " " where
        if (!(hit in seen)) { seen[hit] = 1; print "private-scan: commit " commit " adds a private value to " where > "/dev/stderr" }
        failed = 1
      }
    }
    END { exit failed }
  ' || {
  echo "private-scan: replace each value with a placeholder such as <tailnet-name> and rewrite those commits, because a pushed commit stays public" >&2
  exit 1
}
