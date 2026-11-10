#!/usr/bin/env python3
"""Fails when a button in App/Sources has an empty action, so nothing happens on tap."""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
pattern = re.compile(r"\b\w*Button\s*(?:\(\s*action:\s*)?\{\s*\}|action:\s*\{\s*\}")
found = []
for path in sorted((root / "App/Sources").rglob("*.swift")):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if pattern.search(line):
            found.append(f"{path.relative_to(root)}:{number}: {line.strip()}")
for line in found:
    print("empty action:", line)
sys.exit(1 if found else 0)
