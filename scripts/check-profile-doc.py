#!/usr/bin/env python3
"""Fails when the file printed in docs/PROFILE.md ("The whole file") differs from the file the guide names there.

The guide prints the whole file so that a reader writing another arm's can see every key and its place. A copy that
drifts from its file teaches the wrong key names, so the two must be the same JSON: the same keys, the same values of
the same kind (a boolean is not a number), and no key twice in one object (a reader's JSON parser keeps the last).

Usage: check-profile-doc.py [repository root]
"""
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent
guide = root / "docs/PROFILE.md"
GUIDE = str(guide.relative_to(root))


def fail(message):
    print(f"{GUIDE}: {message}")
    sys.exit(1)


def no_duplicate_keys(pairs):
    keys = [key for key, _ in pairs]
    for key in keys:
        if keys.count(key) > 1:
            raise ValueError(f"the key {key!r} appears twice in one object")
    return dict(pairs)


def load(text):
    return json.loads(text, object_pairs_hook=no_duplicate_keys)


def same(a, b):
    """Equal values of equal kinds: true is not 1, and 1 is not 1.0 written as a boolean."""
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[key], b[key]) for key in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b


text = guide.read_text()
heading = text.find("## The whole file")
if heading < 0:
    fail("no json block under the heading 'The whole file'")
section = text[heading:]
block = re.search(r"```json\n(.*?)\n```", section, re.S)
if block is None:
    fail("no json block under the heading 'The whole file'")
named = re.search(r"App/Resources/Profiles/[\w.-]+\.json", section[: block.start()])
if named is None:
    fail("the text under 'The whole file' does not name the profile file it prints (App/Resources/Profiles/<id>.json)")
file = root / named.group(0)
if not file.is_file():
    fail(f"the guide names {named.group(0)} under 'The whole file', which does not exist")
try:
    printed = load(block.group(1))
except ValueError as error:
    fail(f"the printed file is not valid JSON: {error}")
try:
    bundled = load(file.read_text())
except ValueError as error:
    fail(f"{named.group(0)} is not valid JSON: {error}")
if not same(printed, bundled):
    fail(f"the file printed under 'The whole file' differs from {named.group(0)}; copy the file into the guide again")
