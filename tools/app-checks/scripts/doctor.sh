#!/usr/bin/env bash
# Read-only: is this checkout and toolchain worth driving? Usage: doctor.sh [local|ci]
set -u; MODE="${1:-local}"; source "$(dirname "$0")/_common.sh"
ok(){ echo "OK   $*"; }; bad(){ echo "FAIL $*"; FAILED=1; }; FAILED=0
[ -f "$CORE_DIR/Package.swift" ] && ok "TeleopCore package at $CORE_DIR" || bad "no Packages/TeleopCore/Package.swift under $REPO_ROOT"
[ -f "$REPO_ROOT/project.yml" ] && ok "project.yml present" || bad "project.yml missing"
echo "INFO HEAD $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo none)"
python3 -c 'import PIL, numpy' 2>/dev/null && ok "python3 + Pillow + numpy" || bad "pip install pillow numpy"
if [ "$MODE" = local ]; then
  if command -v swift >/dev/null; then ok "$(swift --version 2>&1 | head -1)"; else bad "swift not on PATH: local logic path unavailable, use the ci path"; fi
else
  gh auth status >/dev/null 2>&1 && ok "gh authenticated" || bad "gh not authenticated"
  gh api "repos/$GH_REPO" --jq .full_name >/dev/null 2>&1 && ok "repo $GH_REPO reachable" || bad "repo $GH_REPO not reachable"
  if gh api "repos/$GH_REPO/contents/.github/workflows/ios.yml" >/dev/null 2>&1; then ok ".github/workflows/ios.yml is on the default branch"
  else bad ".github/workflows/ios.yml not pushed (needs the gh 'workflow' scope); CI path unavailable"; fi
fi
exit $FAILED
