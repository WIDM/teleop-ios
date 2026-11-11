#!/usr/bin/env python3
"""Checks every string table in App/Resources. Exits 1 on any problem.

For each table: every key has an English and a Traditional Chinese value; the two carry the same format specifiers;
Chinese values use full-width punctuation, no dashes, and never the English words STOP or Reset (the bilingual
band label is the one exception); no key the code asks for is missing and no key is unused.

Where the keys come from:
- Localizable: string literals in App/Sources that look like keys. A key that only a unit test in Tests/TeleopTests
  looks up still counts as used, and is listed, so it can go when the test does.
- Buttons: Text(..., tableName: "Buttons") in App/Sources.
- Speech: the "say." raw values of SpeechKey in the core package.
- InfoPlist: the Info.plist keys project.yml sets.
"""

import json
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
resources = root / "App/Resources"
problems = []


def swift(path):
    return "\n".join(p.read_text() for p in sorted(path.rglob("*.swift")))


app = swift(root / "App/Sources")
tests = swift(root / "Tests/TeleopTests")
core = swift(root / "Packages/TeleopCore/Sources")
literal = re.compile(r'"([a-z_0-9]+(?:\.[a-z_0-9]+)+)"')

# Keys that may hold an English word in their Chinese value: shown to everyone in both languages.
BILINGUAL = {"band.stop", "state.practice"}
SPECIFIER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\d+f|%)")
HALF_WIDTH = re.compile(r"[,;:?!()]")


def values(name):
    catalog = json.loads((resources / f"{name}.xcstrings").read_text())
    table = {}
    for key, entry in catalog["strings"].items():
        found = {}
        for language in ("en", "zh-Hant"):
            unit = (
                entry.get("localizations", {}).get(language, {}).get("stringUnit", {})
            )
            found[language] = unit.get("value")
            if not found[language]:
                problems.append(f"{name}: {key} has no {language} value")
        table[key] = found
    return table


def check_values(name, table):
    for key, found in table.items():
        en, zh = found.get("en") or "", found.get("zh-Hant") or ""
        if sorted(SPECIFIER.findall(en)) != sorted(SPECIFIER.findall(zh)):
            problems.append(f"{name}: {key} format specifiers differ: {en!r} / {zh!r}")
        bare = SPECIFIER.sub("", zh)
        if key not in BILINGUAL and re.search(r"\b(STOP|Reset)\b", bare):
            problems.append(f"{name}: {key} Chinese value says STOP or Reset: {zh!r}")
        if HALF_WIDTH.search(bare):
            problems.append(
                f"{name}: {key} Chinese value has half-width punctuation: {zh!r}"
            )
        if "—" in bare or "--" in bare:
            problems.append(f"{name}: {key} Chinese value has a dash: {zh!r}")


def check_use(name, table, used, allowed_unused=frozenset()):
    for key in sorted(used - set(table)):
        problems.append(f"{name}: missing {key}")
    for key in sorted(set(table) - used - allowed_unused):
        problems.append(f"{name}: unused {key}")


# Localizable.
localizable = values("Localizable")
check_values("Localizable", localizable)
prefixes = {key.split(".")[0] for key in localizable}
in_buttons = set(re.findall(r'"([a-z_0-9.]+)",\s*tableName:\s*"Buttons"', app))
in_app = {k for k in literal.findall(app) if k.split(".")[0] in prefixes} - in_buttons
ids = set(re.findall(r'accessibilityIdentifier\("([^"]+)"\)', app))
in_tests = {k for k in literal.findall(tests) if k in localizable}
test_only = sorted(in_tests - in_app)
check_use(
    "Localizable",
    localizable,
    (in_app - (ids - set(localizable))) | in_tests,
    {"app.name"},
)

# Buttons.
buttons = values("Buttons")
check_values("Buttons", buttons)
check_use(
    "Buttons",
    buttons,
    set(re.findall(r'"([a-z_0-9.]+)",\s*tableName:\s*"Buttons"', app)),
)

# Speech.
speech = values("Speech")
check_values("Speech", speech)
check_use("Speech", speech, set(re.findall(r'"(say\.[a-z_0-9.]+)"', core)))

# InfoPlist.
info = values("InfoPlist")
check_values("InfoPlist", info)
project = (root / "project.yml").read_text()
check_use(
    "InfoPlist",
    info,
    set(re.findall(r"^\s+((?:NS|CF)\w+(?:Description|DisplayName)):", project, re.M)),
)

for line in test_only:
    print(f"note: Localizable {line} is used only by a unit test")
for problem in problems:
    print(problem)
sys.exit(1 if problems else 0)
