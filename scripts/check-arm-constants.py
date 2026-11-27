#!/usr/bin/env python3
"""Fails when a robot's numbers or a named robot profile appear in code instead of in a profile file.

A new arm is meant to need only its profile file (App/Resources/Profiles/<id>.json, docs/PROFILE.md). So outside the
loader, the profile files, the tests, the build settings and the test plans this check refuses:
  1. the name `so101Simulator`, in any scanned file;
  2. a `static let` or `static var` that holds a RobotProfile: its type names RobotProfile (an optional or a
     collection of them included), its value builds one, or, inside the RobotProfile type itself, its type is `Self`
     or its value is `Self(...)` or `.init(...)`; on one line or several, with or without the module name;
  3. a RobotProfile built anywhere but the core's Profile folder: `RobotProfile(...)`, `RobotProfile.init(...)`,
     `.init(...)` where the type is written as RobotProfile, `Self(...)` or `self.init(...)` inside the type, or any
     call with the initializer's `offsetMeasuredAt:` label;
  4. a profile id (the name of a profile file, bundled or test-only, without .json);
  5. a profile's `name`, or its leading words, written as a string in code.
It also refuses a read of `ProfileLoader.current` outside AppModel.swift and OperatingFixtures.swift, tests included:
the profile travels inside the values that carry it.

Metatypes (`RobotProfile.Type`, `RobotProfile.self`), types nested in RobotProfile, and other types' `Self` are not
profiles and pass. Swift comments and the text of string literals are not code: rules 2, 3 and the read rule skip them.

CHECK_ARM_CONSTANTS_ROOT lets scripts/test_check_arm_constants.py point the check at a small test tree.
Exit code 0 = clean, 1 = violations found.
"""

import bisect
import json
import os
import pathlib
import re
import sys

root = pathlib.Path(
    os.environ.get(
        "CHECK_ARM_CONSTANTS_ROOT", pathlib.Path(__file__).resolve().parent.parent
    )
)

# Where a profile may be named or built: the one place that turns an id into a profile, the files themselves, the
# tests, the build setting that names the file a build uses (and the Info.plist made from it), the test plans (a plan
# may pass -robotProfile), the documents, and this check with its own test.
ALLOWED = (
    "App/Sources/Link/ProfileLoader.swift",
    "App/Resources/Profiles/",
    "Tests/",
    "Packages/TeleopCore/Tests/",
    "project.yml",
    "App/Info.plist",
    "TestPlans/",
    "docs/",
    "scripts/check-arm-constants.py",
    "scripts/test_check_arm_constants.py",
)
# The profile type and its file format: the only code that builds a profile.
PROFILE_SOURCES = "Packages/TeleopCore/Sources/TeleopCore/Profile/"
# The only files that may read the chosen profile; everything else is handed it.
CURRENT_READERS = (
    "App/Sources/Link/ProfileLoader.swift",
    "App/Sources/AppModel.swift",
    "App/Sources/Operating/OperatingFixtures.swift",
)
# Where test-only profiles live: their ids and names are refused in app code too.
TEST_PROFILE_GLOBS = (
    "Tests/**/Profiles/*.json",
    "Packages/TeleopCore/Tests/**/Profiles/*.json",
)
SCANNED = {".swift", ".py", ".sh", ".yml", ".yaml", ".plist", ".json", ".xctestplan"}
SKIPPED_DIRS = {".git", ".build", ".swiftpm", "build", "DerivedData", "__pycache__"}

REMOVED = re.compile(r"\bso101Simulator\b")
MODIFIERS = (
    r"(?:(?:public|private|fileprivate|internal|package|nonisolated|final|lazy)"
    r"(?:\(\w+\))?\s+)*"
)
# A static stored or computed property: its type (to the first `=`, `{` or line end) and the first line of its value.
STATIC_DECL = re.compile(
    r"\bstatic\s+"
    + MODIFIERS
    + r"(?:let|var)\s+\w+\s*(?::\s*(?P<type>[^={\n]*))?(?:=\s*(?P<value>[^\n]*))?"
)
# RobotProfile as a type, but not a metatype (`.Type`, `.self`) or a nested type (`RobotProfile.Inner`).
PROFILE_TYPE = re.compile(r"\bRobotProfile\b(?!\s*\.\s*\w)")
SELF_TYPE = re.compile(r"\bSelf\b(?!\s*\.\s*\w)")
BUILDS_PROFILE = re.compile(r"\bRobotProfile\s*(?:\.\s*init\s*)?\(")
# A value that starts by building one, with or without the module name.
STARTS_BUILDING = re.compile(r"(?:\w+\s*\.\s*)*RobotProfile\s*(?:\.\s*init\s*)?\(")
BUILDS_SELF = re.compile(r"(?:Self\s*(?:\.\s*init\s*)?|\.init\s*)\(")
BUILT = (
    BUILDS_PROFILE,
    # `let p: RobotProfile = .init(...)`, `profile: RobotProfile? = .init(...)`
    re.compile(r":\s*(?:\w+\s*\.\s*)?RobotProfile\s*\??\s*=\s*\.init\s*\("),
    # `func f() -> RobotProfile { .init(...) }`
    re.compile(
        r"->\s*(?:\w+\s*\.\s*)?RobotProfile\s*\??\s*\{\s*(?:return\s+)?\.init\s*\("
    ),
    # Any other call of the initializer, such as `AppModel(profile: .init(...))`: it has no defaults, so every call
    # writes this label.
    re.compile(r"(?<![.\w])offsetMeasuredAt\s*:(?!:)"),
)
BUILT_INSIDE = re.compile(
    r"\bSelf\s*(?:\.\s*init\s*)?\(|\bself\s*\.\s*init\s*\(|(?<![\w)\].])\.init\s*\("
)
TYPE_HEAD = re.compile(
    r"\b(?P<kind>extension|struct|class|enum|actor|protocol)\s+"
    r"(?P<name>(?:\w+\s*\.\s*)*\w+)[^{;]*\{"
)
CURRENT = re.compile(r"\bProfileLoader\s*\.\s*current\b")

HINT = (
    "put the number in the robot profile file (App/Resources/Profiles/<id>.json) and read it through "
    "ProfileLoader; see docs/PROFILE.md"
)


def files():
    for folder, dirs, names in os.walk(root):
        dirs[:] = sorted(
            d for d in dirs if d not in SKIPPED_DIRS and not d.endswith(".xcodeproj")
        )
        for name in sorted(names):
            path = pathlib.Path(folder) / name
            if path.suffix in SCANNED:
                yield path


def under(relative, entries):
    return any(
        relative == entry or (entry.endswith("/") and relative.startswith(entry))
        for entry in entries
    )


def swift_code(text):
    """Returns (code, literals). `code` is the text with comments and the text of string literals turned into
    spaces (newlines kept, so offsets and lines hold); interpolated code stays. `literals` are (offset, text)."""
    out = list(text)
    literals = []
    n = len(text)

    def blank(start, end):
        for k in range(start, end):
            if out[k] != "\n":
                out[k] = " "

    def comment_end(i):
        depth, j = 0, i
        while j < n:
            if text.startswith("/*", j):
                depth, j = depth + 1, j + 2
            elif text.startswith("*/", j):
                depth, j = depth - 1, j + 2
                if depth == 0:
                    return j
            else:
                j += 1
        return n

    def string(i):
        hashes = len(text[i:]) - len(text[i:].lstrip("#"))
        quote = '"""' if text.startswith('"""', i + hashes) else '"'
        closing, escape = quote + "#" * hashes, "\\" + "#" * hashes
        j = start = piece = i + hashes + len(quote)
        pieces = []
        while j < n:
            if text.startswith(escape + "(", j):
                pieces.append(text[piece:j])
                blank(piece, j)
                j = code(j + len(escape) + 1, inside_parens=True) + 1
                piece = j
            elif text.startswith(escape, j):
                j += len(escape) + 1
            elif text.startswith(closing, j) or (quote == '"' and text[j] == "\n"):
                break
            else:
                j += 1
        pieces.append(text[piece:j])
        blank(piece, j)
        literals.append((start, "￿".join(pieces)))
        return j + len(closing)

    def code(i, inside_parens=False):
        depth = 0
        while i < n:
            if text.startswith("//", i):
                end = text.find("\n", i)
                end = n if end < 0 else end
                blank(i, end)
                i = end
            elif text.startswith("/*", i):
                end = comment_end(i)
                blank(i, end)
                i = end
            elif text[i] == '"' or (text[i] == "#" and re.match(r'#+"', text[i:])):
                i = string(i)
            elif inside_parens and text[i] == "(":
                depth, i = depth + 1, i + 1
            elif inside_parens and text[i] == ")":
                if depth == 0:
                    return i
                depth, i = depth - 1, i + 1
            else:
                i += 1
        return n

    code(0)
    return "".join(out), literals


def closing_brace(code, opening):
    depth = 0
    for k in range(opening, len(code)):
        if code[k] == "{":
            depth += 1
        elif code[k] == "}":
            depth -= 1
            if depth == 0:
                return k
    return len(code)


def profile_bodies(code):
    """Each RobotProfile declaration's body as (opening, closing, text), with the bodies of types nested in it
    blanked, so only its own members are left."""
    heads = [
        (m, m.end() - 1, closing_brace(code, m.end() - 1))
        for m in TYPE_HEAD.finditer(code)
    ]
    bodies = []
    for head, opening, closing in heads:
        name = re.sub(r"\s", "", head["name"]).split(".")[-1]
        if name != "RobotProfile" or head["kind"] not in ("extension", "struct"):
            continue
        body = list(code)
        for _, inner_open, inner_close in heads:
            if opening < inner_open < closing:
                for k in range(inner_open + 1, inner_close):
                    if body[k] != "\n":
                        body[k] = " "
        bodies.append((opening, closing, "".join(body)))
    return bodies


def profile_files():
    """(id, name) of every profile file, bundled and test-only; name is None when the file has none."""
    paths = sorted((root / "App/Resources/Profiles").glob("*.json"))
    for pattern in TEST_PROFILE_GLOBS:
        paths += sorted(root.glob(pattern))
    found = []
    for path in paths:
        try:
            name = json.loads(path.read_text()).get("name")
        except (ValueError, OSError, AttributeError):
            name = None
        found.append(
            (path.stem, name if isinstance(name, str) and name.strip() else None)
        )
    return found


def name_forms(name):
    """The name and its leading whole words, when they are four characters or more and more than one plain word:
    "SO-101" and "SO-101 (S4" of "SO-101 (S4 simulator)", "Bench arm" of "Bench arm B", but not "Bench"."""
    words = name.split()
    leading = (" ".join(words[:k]) for k in range(1, len(words)))
    return {name} | {
        form for form in leading if len(form) >= 4 and not form.isalpha()
    }


profiles = profile_files()
id_patterns = [
    (pid, re.compile(r"(?<![\w-])" + re.escape(pid) + r"(?![\w-])"))
    for pid, _ in profiles
]
names = [(name, name_forms(name)) for _, name in profiles if name]

found = set()


def check(path):
    relative = path.relative_to(root).as_posix()
    try:
        text = path.read_text()
    except (UnicodeDecodeError, OSError):
        return
    lines = text.splitlines() or [""]
    starts = [0] + [m.end() for m in re.finditer(r"\n", text)]

    def report(offset, what):
        number = bisect.bisect_right(starts, offset)
        line = lines[min(number, len(lines)) - 1].strip()[:160]
        found.add((relative, number, f"{relative}:{number}: {what}: {line}"))

    swift = path.suffix == ".swift"
    code, literals = swift_code(text) if swift else ("", [])

    if swift and not under(relative, CURRENT_READERS):
        for m in CURRENT.finditer(code):
            report(
                m.start(),
                "ProfileLoader.current read outside AppModel and OperatingFixtures; pass the profile in instead",
            )

    if under(relative, ALLOWED):
        return

    for m in REMOVED.finditer(text):
        report(m.start(), "the name so101Simulator")
    for pid, pattern in id_patterns:
        for m in pattern.finditer(text):
            report(m.start(), f"the profile id {pid} named outside the loader")

    if not swift:
        for name, _ in names:
            for m in re.finditer(re.escape(name), text):
                report(m.start(), f"the profile name '{name}' written in code")
        return

    for offset, literal in literals:
        for name, forms in names:
            if name in literal or literal.strip() in forms:
                report(offset, f"the profile name '{name}' written in code")

    bodies = profile_bodies(code)
    for m in STATIC_DECL.finditer(code):
        kind, value = m["type"] or "", (m["value"] or "").strip()
        if PROFILE_TYPE.search(kind) or STARTS_BUILDING.match(value):
            report(m.start(), "a robot profile held in code")
    for opening, closing, body in bodies:
        for m in STATIC_DECL.finditer(body, opening, closing):
            kind, value = m["type"] or "", (m["value"] or "").strip()
            if SELF_TYPE.search(kind) or BUILDS_SELF.match(value):
                report(m.start(), "a robot profile held in code")

    if relative.startswith(PROFILE_SOURCES):
        return
    for pattern in BUILT:
        for m in pattern.finditer(code):
            report(m.start(), "a robot profile built in code")
    for opening, closing, body in bodies:
        for m in BUILT_INSIDE.finditer(body, opening, closing):
            report(m.start(), "a robot profile built in code")


for path in files():
    check(path)

for _, _, line in sorted(found):
    print(line)
if found:
    print(f"{len(found)} arm constant(s) in code: {HINT}.")
sys.exit(1 if found else 0)
