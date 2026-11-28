#!/usr/bin/env python3
"""Fails when the file printed in docs/PROFILE.md ("The whole file") is not one of the files the app bundles.

The guide prints the whole file so that a reader writing another arm's can see every key and its place. A copy that
drifts from its file teaches the wrong key names, so the two must be the same JSON.

Usage: check-profile-doc.py [repository root]
"""
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent
guide = root / "docs/PROFILE.md"
profiles = sorted((root / "App/Resources/Profiles").glob("*.json"))

text = guide.read_text()
heading = text.find("## The whole file")
block = re.search(r"```json\n(.*?)\n```", text[heading:], re.S) if heading >= 0 else None
if block is None:
    print(f"{guide.relative_to(root)}: no json block under the heading 'The whole file'")
    sys.exit(1)
try:
    printed = json.loads(block.group(1))
except json.JSONDecodeError as error:
    print(f"{guide.relative_to(root)}: the printed file is not JSON: {error}")
    sys.exit(1)
if not any(printed == json.loads(path.read_text()) for path in profiles):
    names = ", ".join(str(path.relative_to(root)) for path in profiles)
    print(
        f"{guide.relative_to(root)}: the file printed under 'The whole file' is none of the bundled files ({names}); "
        "copy the file into the guide again"
    )
    sys.exit(1)
