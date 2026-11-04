#!/usr/bin/env python3
"""Fails when a string key used in App/Sources is missing from Localizable.xcstrings, or a key is unused."""
import json
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
catalog = json.loads((root / "App/Resources/Localizable.xcstrings").read_text())
keys = set(catalog["strings"])
source = "\n".join(p.read_text() for p in (root / "App/Sources").rglob("*.swift"))
used = set(re.findall(r'"((?:[a-z_0-9]+)\.(?:[a-z_0-9]+)(?:\.[a-z_0-9]+)?)"', source))
used = {k for k in used if k.split(".")[0] in {key.split(".")[0] for key in keys}}
ids = set(re.findall(r'accessibilityIdentifier\("([^"]+)"\)', source))
missing = sorted(k for k in used - ids if k not in keys)
unused = sorted(k for k in keys - used if not k.startswith("app."))
for k in missing:
    print("missing:", k)
for k in unused:
    print("unused:", k)
sys.exit(1 if missing or unused else 0)
