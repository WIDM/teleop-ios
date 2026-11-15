#!/usr/bin/env python3
"""Git hygiene check for this repository.

Rejects, in commit messages, branch names, and pull request title/body:
  1. CJK text (Han, Hiragana, Katakana, Hangul, Bopomofo, CJK and
     fullwidth punctuation). Repository history must be English-only.
  2. Co-author trailers ("Co-authored-by:").
  3. Tool attribution markers (case-insensitive, whole-word match), see
     MARKERS below.

Only message, branch and PR text is scanned, never source files, so words
in code are not affected. Because matching is whole-word, "cursor" is
rejected in a message; use "pointer" or "caret" instead.

Usage:
  check-git-hygiene.py --commit-msg-file FILE   # commit-msg hook
  check-git-hygiene.py --branch NAME
  check-git-hygiene.py --title TEXT --body TEXT
  check-git-hygiene.py --range BASE..HEAD       # every commit in range
  check-git-hygiene.py --from-env               # HYGIENE_BRANCH, HYGIENE_PR_TITLE,
                                                # HYGIENE_PR_BODY, HYGIENE_RANGE
Exit code 0 = clean, 1 = violations found, 2 = usage error.
Only python3 standard library is used.
"""
import argparse
import os
import re
import subprocess
import sys

CJK = re.compile(
    "["
    "\u1100-\u11ff"          # Hangul Jamo
    "\u2e80-\u2fdf"          # CJK radicals, Kangxi radicals
    "\u3000-\u303f"          # CJK symbols and punctuation
    "\u3040-\u309f"          # Hiragana
    "\u30a0-\u30ff"          # Katakana
    "\u3100-\u312f"          # Bopomofo
    "\u3130-\u318f"          # Hangul compatibility Jamo
    "\u31a0-\u31ff"          # Bopomofo ext, Katakana phonetic ext
    "\u3200-\u33ff"          # enclosed CJK, CJK compatibility
    "\u3400-\u4dbf"          # CJK ext A
    "\u4e00-\u9fff"          # CJK unified
    "\uac00-\ud7af"          # Hangul syllables
    "\uf900-\ufaff"          # CJK compatibility ideographs
    "\ufe30-\ufe4f"          # CJK compatibility forms
    "\uff00-\uffef"          # halfwidth and fullwidth forms
    "\U00020000-\U0003134f"  # CJK ext B-G
    "]"
)

COAUTHOR = re.compile(r"^\s*co-authored-by\s*:", re.IGNORECASE | re.MULTILINE)

# (label, pattern). Whole-word, case-insensitive.
MARKERS = [
    ("Claude", r"\bclaude\b"),
    ("Anthropic", r"\banthropic\b"),
    ("Codex", r"\bcodex\b"),
    ("OpenAI", r"\bopen\s?ai\b"),
    ("ChatGPT", r"\bchat\s?gpt\b"),
    ("GPT", r"\bgpt(?:\b|(?=[-\d]))"),
    ("Copilot", r"\bco-?pilot\b"),
    ("Cursor", r"\bcursor\b"),
    ("Grok", r"\bgrok\b"),
    ("Gemini", r"\bgemini\b"),
    ("Generated with", r"\bgenerated\s+(?:with|by)\b"),
    ("AI-generated", r"\bai[\s-]?(?:generated|assisted|written)\b"),
    ("robot emoji", "\U0001F916"),
]
MARKER_RES = [(label, re.compile(p, re.IGNORECASE)) for label, p in MARKERS]

NO_FORCE = "Never force-push."

FIX = {
    "commit": {
        "cjk": "Fix: rewrite the message in English. Unpushed: "
               "git commit --amend -m '<English message>' (or git rebase -i for "
               "older unpushed commits). Already pushed: open a new branch with "
               "English commits and a new PR. " + NO_FORCE,
        "coauthor": "Fix: remove the Co-authored-by line. Unpushed: "
                    "git commit --amend and delete the trailer. Already pushed: "
                    "redo the change on a new branch. " + NO_FORCE,
        "marker": "Fix: remove the tool name from the message and describe the "
                  "change itself. Unpushed: git commit --amend. Already pushed: "
                  "redo the change on a new branch. " + NO_FORCE,
    },
    "branch": {
        "cjk": "Fix: rename the branch in English: git branch -m <english-name>, "
               "then push the new name.",
        "coauthor": "Fix: rename the branch: git branch -m <english-name>.",
        "marker": "Fix: use a neutral name such as fix/<topic> or feat/<topic>: "
                  "git branch -m <neutral-name>, then push the new name.",
    },
    "pr-title": {
        "cjk": "Fix: edit the PR title in English (gh pr edit <n> --title '...').",
        "coauthor": "Fix: remove the Co-authored-by text from the PR title.",
        "marker": "Fix: remove the tool name from the PR title (gh pr edit <n> --title '...').",
    },
    "pr-body": {
        "cjk": "Fix: rewrite the PR description in English (gh pr edit <n> --body-file <file>).",
        "coauthor": "Fix: delete the Co-authored-by line from the PR description.",
        "marker": "Fix: remove the tool name or signature line from the PR description "
                  "(gh pr edit <n> --body-file <file>).",
    },
}

WHAT = {
    "commit": "Commit message",
    "branch": "Branch name",
    "pr-title": "PR title",
    "pr-body": "PR description",
}

RULE = "Repository history and PR text must be English-only, with no co-author trailers or tool attribution (WIDM rule)."


def snippet(text, start, end):
    line_start = text.rfind("\n", 0, start) + 1
    line_end = text.find("\n", end)
    if line_end == -1:
        line_end = len(text)
    return text[line_start:line_end].strip()[:120]


def check_text(kind, text, where):
    """Return a list of error strings for one piece of text."""
    errors = []
    if not text:
        return errors
    what = WHAT[kind]
    m = CJK.search(text)
    if m:
        errors.append(
            f"{where}: {what} contains Chinese/Japanese/Korean characters "
            f"or fullwidth punctuation ('{m.group(0)}' in: {snippet(text, m.start(), m.end())!r}). "
            f"{RULE} {FIX[kind]['cjk']}"
        )
    m = COAUTHOR.search(text)
    if m:
        errors.append(
            f"{where}: {what} contains a Co-authored-by trailer "
            f"({snippet(text, m.start(), m.end())!r}). "
            f"{RULE} {FIX[kind]['coauthor']}"
        )
    for label, rx in MARKER_RES:
        m = rx.search(text)
        if m:
            errors.append(
                f"{where}: {what} contains the tool attribution marker '{label}' "
                f"(in: {snippet(text, m.start(), m.end())!r}). "
                f"{RULE} {FIX[kind]['marker']}"
            )
    return errors


def clean_commit_msg(raw):
    """Mimic git's default cleanup: drop comment lines and the scissors tail."""
    out = []
    for line in raw.splitlines():
        if line.startswith("# ------------------------ >8"):
            break
        if line.startswith("#"):
            continue
        out.append(line)
    return "\n".join(out).strip()


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True,
                          text=True, encoding="utf-8").stdout


def check_range(rng):
    errors = []
    out = git("log", "--format=%H%x00%B%x1e", rng)
    for rec in out.split("\x1e"):
        rec = rec.strip("\n")
        if not rec.strip():
            continue
        sha, _, body = rec.partition("\x00")
        errors += check_text("commit", body.strip(), f"commit {sha[:9]}")
    return errors


def main(argv=None):
    ap = argparse.ArgumentParser(description="Reject non-English or attributed git text.")
    ap.add_argument("--commit-msg-file")
    ap.add_argument("--branch")
    ap.add_argument("--title")
    ap.add_argument("--body")
    ap.add_argument("--range", dest="rng")
    ap.add_argument("--from-env", action="store_true")
    a = ap.parse_args(argv)

    if a.from_env:
        a.branch = a.branch or os.environ.get("HYGIENE_BRANCH") or None
        a.title = a.title or os.environ.get("HYGIENE_PR_TITLE") or None
        a.body = a.body or os.environ.get("HYGIENE_PR_BODY") or None
        a.rng = a.rng or os.environ.get("HYGIENE_RANGE") or None

    if not any([a.commit_msg_file, a.branch, a.title, a.body, a.rng]):
        ap.print_usage(sys.stderr)
        return 2

    errors = []
    checked = []
    if a.commit_msg_file:
        with open(a.commit_msg_file, encoding="utf-8", errors="replace") as f:
            errors += check_text("commit", clean_commit_msg(f.read()), "commit-msg")
        checked.append("commit message")
    if a.branch:
        errors += check_text("branch", a.branch, f"branch '{a.branch}'")
        checked.append("branch name")
    if a.title:
        errors += check_text("pr-title", a.title, "PR title")
        checked.append("PR title")
    if a.body:
        errors += check_text("pr-body", a.body, "PR body")
        checked.append("PR body")
    if a.rng:
        try:
            errors += check_range(a.rng)
        except subprocess.CalledProcessError as e:
            print(f"git-hygiene: could not read commits for range {a.rng!r}: "
                  f"{e.stderr.strip()}. Cause: the range is not in the local clone. "
                  f"Fix: fetch full history (actions/checkout fetch-depth: 0, or git fetch --unshallow).",
                  file=sys.stderr)
            return 2
        checked.append(f"commits {a.rng}")

    if errors:
        print(f"git-hygiene: FAILED ({len(errors)} problem(s))", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print(f"git-hygiene: OK ({', '.join(checked)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
