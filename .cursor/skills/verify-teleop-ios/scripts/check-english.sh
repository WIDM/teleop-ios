#!/usr/bin/env bash
# Repo rule: everything in git is English. Any CJK character in commit messages,
# PR title/body, or tracked text files is a FAIL.
# Usage: check-english.sh [base-ref] [pr-number]   (default base: origin/main)
set -u; source "$(dirname "$0")/_common.sh"; BASE="${1:-origin/main}"; PR="${2:-}"
OUT="$EVIDENCE/english"; mkdir -p "$OUT"; FAIL=0
CJK='[\x{3000}-\x{303f}\x{3040}-\x{30ff}\x{3400}-\x{4dbf}\x{4e00}-\x{9fff}\x{f900}-\x{faff}\x{ff00}-\x{ffef}\x{ac00}-\x{d7af}]'
cd "$REPO_ROOT"
if git log --format=%B "$BASE..HEAD" | grep -nP "$CJK" > "$OUT/commits.txt"; then echo "FAIL CJK in commit messages ($BASE..HEAD)"; FAIL=1; else echo "OK   commit messages $BASE..HEAD"; fi
git ls-files -z | xargs -0 grep -IlP "$CJK" > "$OUT/files.txt" 2>/dev/null
if [ -s "$OUT/files.txt" ]; then echo "FAIL CJK in tracked files:"; cat "$OUT/files.txt"; FAIL=1; else echo "OK   tracked files"; fi
if git ls-files | grep -P "$CJK" > "$OUT/filenames.txt"; then echo "FAIL CJK in file names"; FAIL=1; else echo "OK   file names"; fi
if [ -n "$PR" ]; then
  gh pr view "$PR" -R "$GH_REPO" --json title,body --jq '.title + "\n" + .body' > "$OUT/pr.txt"
  if grep -nP "$CJK" "$OUT/pr.txt"; then echo "FAIL CJK in PR #$PR title/body"; FAIL=1; else echo "OK   PR #$PR title/body"; fi
fi
echo "english_check=$([ $FAIL = 0 ] && echo PASS || echo FAIL)" | tee "$OUT/result.txt"; exit $FAIL
