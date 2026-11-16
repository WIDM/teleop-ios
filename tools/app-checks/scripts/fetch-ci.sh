#!/usr/bin/env bash
# CI path: download artifacts of a GitHub Actions run of the "ios" workflow.
# Usage: fetch-ci.sh [run-id]   (default: latest run for the current branch)
set -u; source "$(dirname "$0")/_common.sh"; OUT="$EVIDENCE/ci"; mkdir -p "$OUT"
BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
RID="${1:-$(gh run list -R "$GH_REPO" --workflow ios.yml --branch "$BRANCH" -L 1 --json databaseId --jq '.[0].databaseId')}"
[ -n "$RID" ] && [ "$RID" != null ] || { echo "FAIL no ios.yml run found for $BRANCH"; exit 1; }
gh run view "$RID" -R "$GH_REPO" --json status,conclusion,headSha,url,jobs > "$OUT/run.json"
gh run watch "$RID" -R "$GH_REPO" --exit-status >/dev/null 2>&1; RC=$?
gh run view "$RID" -R "$GH_REPO" --json status,conclusion,headSha,url > "$OUT/run.json"
gh run download "$RID" -R "$GH_REPO" -D "$OUT/artifacts" || echo "WARN some artifacts missing"
echo "run=$RID conclusion=$(python3 -c "import json;print(json.load(open('$OUT/run.json'))['conclusion'])")"
ls "$OUT/artifacts" 2>/dev/null; exit $RC
