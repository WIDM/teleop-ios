#!/usr/bin/env bash
# Local logic path: swift test on TeleopCore. Evidence -> $EVIDENCE/core/
set -u; source "$(dirname "$0")/_common.sh"; OUT="$EVIDENCE/core"; mkdir -p "$OUT"
if ! command -v swift >/dev/null; then echo "SKIP swift not installed on this host" | tee "$OUT/result.txt"; exit 2; fi
cd "$CORE_DIR"
swift test --scratch-path "$SCRATCH/core-build" 2>&1 | tee "$OUT/swift-test.log"; RC=${PIPESTATUS[0]}
echo "exit=$RC head=$(git rev-parse --short HEAD)" > "$OUT/result.txt"
grep -E 'Executed [0-9]+ tests' "$OUT/swift-test.log" | tail -1 >> "$OUT/result.txt"
cat "$OUT/result.txt"; exit $RC
