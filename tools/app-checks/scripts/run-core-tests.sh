#!/usr/bin/env bash
# Local logic path: swift test on TeleopCore. Evidence -> $EVIDENCE/core/
set -u; source "$(dirname "$0")/_common.sh"; OUT="$EVIDENCE/core"; mkdir -p "$OUT"
if ! command -v swift >/dev/null; then echo "SKIP swift not installed on this host" | tee "$OUT/result.txt"; exit 2; fi
cd "$CORE_DIR"
swift test --scratch-path "$SCRATCH/core-build" 2>&1 | tee "$OUT/swift-test.log"; RC=${PIPESTATUS[0]}
echo "exit=$RC head=$(git rev-parse --short HEAD)" > "$OUT/result.txt"
# swift test prints one "Executed N tests" total per test target; count the test lines instead of reading one total.
echo "passed=$(grep -c "' passed (" "$OUT/swift-test.log") failed=$(grep -c "' failed (" "$OUT/swift-test.log")" >> "$OUT/result.txt"
cat "$OUT/result.txt"; exit $RC
