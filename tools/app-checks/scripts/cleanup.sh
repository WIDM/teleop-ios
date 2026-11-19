#!/usr/bin/env bash
# Remove scratch state this run created. Never touches $EVIDENCE_ROOT.
# Usage: RUN_ID=<id> cleanup.sh [--sim <udid>]
set -u; source "$(dirname "$0")/_common.sh"
case "$SCRATCH" in /tmp/teleop-app-checks-*) rm -rf "$SCRATCH"; echo "removed $SCRATCH";; *) echo "refusing to remove $SCRATCH";; esac
if [ "${1:-}" = --sim ] && [ -n "${2:-}" ] && command -v xcrun >/dev/null; then
  xcrun simctl shutdown "$2" 2>/dev/null; xcrun simctl delete "$2" && echo "deleted simulator $2"; fi
[ -d "$EVIDENCE" ] && echo "evidence kept: $EVIDENCE ($(find "$EVIDENCE" -type f | wc -l) files)" || { echo "FAIL evidence missing: $EVIDENCE"; exit 1; }
