#!/usr/bin/env bash
# One command: drift check, then exhaustive exploration of the real TeleopSession.
# Exit 0 = only known findings. Exit 1 = new violation, stale finding or drift. Exit 2 = swift missing.
set -uo pipefail

skill="$(cd "$(dirname "$0")/.." && pwd)"
command -v swift >/dev/null || { echo "SKIP: swift is not installed. This is not a pass."; exit 2; }

python3 "$skill/scripts/drift.py"
drift=$?

scratch="${TMPDIR:-/tmp}/verify-session-safety-build"
swift build -c release --package-path "$skill/checker" --scratch-path "$scratch" -q || exit 1
"$scratch/release/SafetyCheck" "${UI_MAP:-$skill/ui-map.tsv}" "$skill/known-findings.txt"
result=$?

[ "$drift" -eq 0 ] && [ "$result" -eq 0 ]
