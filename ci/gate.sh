#!/usr/bin/env bash
# usage: ci/gate.sh [--evaluate-only]
# Runs ci/checks.sh, with --evaluate-only when given, then ci/unit-cycles.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

ci/checks.sh "$@"
ci/unit-cycles.sh
