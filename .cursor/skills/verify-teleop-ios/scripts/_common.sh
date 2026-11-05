# Shared settings. Sourced by the other helpers.
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
# Evidence lives OUTSIDE the repo and survives cleanup.
EVIDENCE_ROOT="${EVIDENCE_ROOT:-$HOME/teleop-ios-evidence}"
EVIDENCE="$EVIDENCE_ROOT/$RUN_ID"
SCRATCH="${SCRATCH:-/tmp/verify-teleop-ios-$RUN_ID}"
GH_REPO="${GH_REPO:-WIDM/teleop-ios}"
CORE_DIR="$REPO_ROOT/Packages/TeleopCore"
mkdir -p "$EVIDENCE"
