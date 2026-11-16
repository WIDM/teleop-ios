#!/usr/bin/env bash
# Repo rule: everything in git is English. Any CJK character in commit messages,
# PR title/body, or tracked text files is a FAIL.
# Usage: check-english.sh [base-ref] [pr-number]   (default base: origin/main)
set -u; source "$(dirname "$0")/_common.sh"; BASE="${1:-origin/main}"; PR="${2:-}"
OUT="$EVIDENCE/english"; mkdir -p "$OUT"; FAIL=0
# The search runs in Perl, which macOS and Linux both ship. The grep that ships with macOS has no -P: there every
# search printed a usage message and the check said OK without having searched.
command -v perl > /dev/null 2>&1 || { echo "FAIL cannot search: perl is not installed"; exit 2; }
CJK='[\x{3000}-\x{303f}\x{3040}-\x{30ff}\x{3400}-\x{4dbf}\x{4e00}-\x{9fff}\x{f900}-\x{faff}\x{ff00}-\x{ffef}\x{ac00}-\x{d7af}]'
# Prints each line of standard input that holds such a character, with its number; exits 1 when none does.
cjk_lines() { perl -MEncode=decode -ne 'BEGIN { $none = 1 } if (decode("UTF-8", $_) =~ /'"$CJK"'/) { print "$.:$_"; $none = 0 } END { exit $none }'; }
# Reads NUL-separated paths and prints each text file holding such a character; binary files are skipped, as grep -I does.
cjk_files() { perl -MEncode=decode -0 -ne 'chomp; my $p = $_; next unless -f $p && !-B $p; open(my $h, "<:raw", $p) or next; local $/ = "\n"; while (<$h>) { if (decode("UTF-8", $_) =~ /'"$CJK"'/) { print "$p\n"; last } }'; }
cd "$REPO_ROOT"
if git log --format=%B "$BASE..HEAD" | cjk_lines > "$OUT/commits.txt"; then echo "FAIL CJK in commit messages ($BASE..HEAD)"; FAIL=1; else echo "OK   commit messages $BASE..HEAD"; fi
git ls-files -z | cjk_files > "$OUT/files.txt"
if [ -s "$OUT/files.txt" ]; then echo "FAIL CJK in tracked files:"; cat "$OUT/files.txt"; FAIL=1; else echo "OK   tracked files"; fi
# Unquoted: git otherwise prints such a name as octal escapes, which no search can match.
if git -c core.quotepath=off ls-files | cjk_lines > "$OUT/filenames.txt"; then echo "FAIL CJK in file names"; FAIL=1; else echo "OK   file names"; fi
if [ -n "$PR" ]; then
  gh pr view "$PR" -R "$GH_REPO" --json title,body --jq '.title + "\n" + .body' > "$OUT/pr.txt"
  if cjk_lines < "$OUT/pr.txt"; then echo "FAIL CJK in PR #$PR title/body"; FAIL=1; else echo "OK   PR #$PR title/body"; fi
fi
echo "english_check=$([ $FAIL = 0 ] && echo PASS || echo FAIL)" | tee "$OUT/result.txt"; exit $FAIL
