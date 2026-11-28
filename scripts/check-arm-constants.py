#!/usr/bin/env python3
"""Fails when a robot's numbers or a named robot profile appear in code instead of in a profile file.

A new arm is meant to need only its profile file (App/Resources/Profiles/<id>.json, docs/PROFILE.md). So outside the
loader, the profile files, the tests, the build settings and the test plans this check refuses:
  1. the name `so101Simulator`, in any scanned file;
  2. a `static let` or `static var` that holds a RobotProfile: its type names RobotProfile (an optional or a
     collection of them included), its value builds one, or, inside the RobotProfile type itself, its type is `Self`
     or its value is `Self(...)`, or `.init(...)` with no type or a profile type; each binding of a declaration
     (`static let a = 1, b: RobotProfile = ...`) and the whole type, on one line or several, with or without the
     module name;
  3. a profile id (the name of a profile file, bundled or test-only, without .json);
  4. a profile's `name`, or its leading words, written as a string in code;
  5. a direction table or conversion that the profile's frames replaced: `OperatorDirection.baseAxis`, the
     `baseVector` and `linkVector` properties of a direction, the `OperatorFrame` conversions and the static
     `GuideProjection.operatorPoint` and `base(fromOperator:)`. Which base axis is forward, left and up, how the link's
     offsets are signed and how the world sits against the base are `robot.directions`, `server.link_signs` and
     `scene.base_axes_in_world` of the profile file, read through `Frames`;
  6. a `Frames` held in a `static let` or `static var`, or built (`Frames(...)`), outside the core's Profile folder and
     the tests: the frames travel inside the values that carry the profile, never as a global or a default. That
     includes a static whose type is not written: its value builds one (`Frames(...)`, `Frames.init(...)`,
     `TeleopCore.Frames(...)`), names a static member of `Frames`, or ends in `.frames` or is `frames`.
  7. a wrist or jaw number that the profile replaced: `WristButton`'s own rates (`turnRate`, `tiltRate`),
     `InputConstants.appendixA` (the default wrist), the jaw thresholds `gripperOpenDeg`, `gripperEmptyDeg`, `openDeg`
     and `emptyDeg`, and any of the profile's wrist and jaw fields given a number as a default or a constant
     (`var turnLimit = 55`, `leadDeg: Double = 2`). The wrist is `robot.wrist` and the jaw `robot.gripper` of the
     profile file, read through `WristProfile` and `GripperProfile`;
  8. a `WristProfile`, `GripperProfile` or `WristLeadLimits` built, or held in a `static let` or `static var`, outside
     the core's Profile folder and the tests: they travel inside the profile.
Naming a profile is not building one. Everywhere but the core's Profile folder and the tests, the loader included, it
refuses a RobotProfile built in code: `RobotProfile(...)`, `RobotProfile.init(...)`, `.init(...)` whose type is
RobotProfile (inside the type, also `Self`): written beside it (`let p: RobotProfile = .init(...)`) or as the type of
the function or computed property that returns it; `Self(...)` or `self.init(...)` inside the type; or a call with the
initializer's `offsetMeasuredAt:` label. A `let` or `var` declaring a field with that name is not a call.
It also refuses a read of `ProfileLoader.current` outside AppModel.swift and OperatingFixtures.swift, tests and the
loader included: the profile travels inside the values that carry it.

Metatypes (`RobotProfile.Type`, `RobotProfile.self`), types nested in RobotProfile, and other types' `Self` are not
profiles and pass. Swift comments and the text of string literals are not code: rules 2, the build rule and the read
rule skip them.

The check reads text, not types. It guards against accidents, not deliberate evasion: a name spelled with Swift
escapes (`"SO-\\u{61}rm"`), a profile built by a helper whose type is inferred, or a name tested by a fragment passes.
Review covers those.

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

# Where a profile may be named or held: the one place that turns an id into a profile, the files themselves, the
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
# The profile type and its file format, and the tests: the only code that builds a profile. The loader reads one
# from its file through the core; it does not build one.
PROFILE_SOURCES = "Packages/TeleopCore/Sources/TeleopCore/Profile/"
BUILDERS = (PROFILE_SOURCES, "Tests/", "Packages/TeleopCore/Tests/")
# The only files that may read the chosen profile; everything else is handed it. The loader defines it and does not
# read it.
CURRENT_READERS = (
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
# Direction tables and conversions that the profile's frames replaced. Each is refused in code (comments and the text
# of strings are not code) of every Swift file outside ALLOWED. A direction's `baseVector` and `linkVector` are
# properties that were removed; `Frames.baseVector(_:)` and `linkVector(_:)` are calls and pass.
REMOVED_DIRECTIONS = (
    (
        re.compile(r"\bbaseAxis\b"),
        "the direction table OperatorDirection.baseAxis, replaced by the profile's frames (robot.directions)",
    ),
    (
        re.compile(r"\.\s*(?:baseVector|linkVector)\b(?!\s*\()"),
        "a direction's baseVector or linkVector property, replaced by the profile's frames",
    ),
    (
        re.compile(r"\bOperatorFrame\b"),
        "OperatorFrame's conversions, replaced by the profile's frames (server.link_signs)",
    ),
    (
        re.compile(r"\bGuideProjection\s*\.\s*(?:operatorPoint|base)\b"),
        "the static GuideProjection conversions, replaced by the profile's frames",
    ),
)
# The wrist's and the jaw's numbers belong to one arm's profile file. These are the statics, defaults and names that held
# them in code before the profile did; each is refused in code of every Swift file outside ALLOWED.
# (`freshStateMs` is left out: the feedback monitor has a number of that name of its own, which is not the wrist's.)
WRIST_JAW_FIELDS = (
    "rollClampDeg|tiltClampDeg|rollWindowDeg|tiltWindowDeg|rollSign|tiltSign|turnLimit|tiltLimit|turnRateDegS|"
    "tiltRateDegS|leadDeg|rateMaxDegS|memoryDeg|closedReading|openReading|validMin|validMax|"
    "fullyOpenAt|emptyAt"
)
REMOVED_WRIST_JAW = (
    (
        re.compile(r"\b(?:turnRate|tiltRate)\b"),
        "the wrist buttons' own rates (WristButton.turnRate, tiltRate), replaced by robot.wrist.turn_rate_deg_s and "
        "tilt_rate_deg_s of the profile",
    ),
    (
        re.compile(r"\bappendixA\b"),
        "InputConstants.appendixA, the default wrist, replaced by robot.wrist of the profile",
    ),
    (
        re.compile(r"\b(?:gripperOpenDeg|gripperEmptyDeg|openDeg|emptyDeg)\b"),
        "the jaw thresholds in degrees, replaced by robot.gripper.fully_open_at and empty_at of the profile",
    ),
    (
        re.compile(
            r"\b(?:" + WRIST_JAW_FIELDS + r")\b\s*(?::\s*[\w<>?\[\]]+\s*)?=\s*[-+]?\d"
        ),
        "a wrist or jaw number written as a default or a constant in code, replaced by robot.wrist and "
        "robot.gripper of the profile",
    ),
)
WRIST_JAW_TYPES = r"(?:WristProfile|GripperProfile|WristLeadLimits)"
BUILDS_WRIST_JAW = re.compile(r"(?<![\w.])" + WRIST_JAW_TYPES + r"\s*(?:\.\s*init\s*)?\(")
# A static's value that is one of these though no type says so: built, or a static member of the type
# (`GripperProfile.so101`; not `.self` or `.Type`).
INFERRED_WRIST_JAW_VALUE = re.compile(
    r"(?:\w+\s*\.\s*)*" + WRIST_JAW_TYPES + r"\s*(?:\.\s*(?!self\b|Type\b)\w+|\()"
)
WRIST_JAW_TYPE = re.compile(r"\b" + WRIST_JAW_TYPES + r"\b(?!\s*\.\s*\w)")
FRAMES_TYPE = re.compile(r"\bFrames\b(?!\s*\.\s*\w)")
BUILDS_FRAMES = re.compile(r"(?<!\w)Frames\s*\(")
# A static's value that is a Frames though no type says so: built, a static member of Frames (`Frames.init(`,
# `Frames.so101`; not `Frames.self` or `.Type`), or read from a profile (`profile.frames`, `frames`).
INFERRED_FRAMES_VALUE = re.compile(
    r"(?:\w+\s*\.\s*)*Frames\s*(?:\.\s*(?!self\b|Type\b)\w+|\()|(?:\w+\s*\.\s*)*frames\s*$"
)
MODIFIERS = (
    r"(?:(?:public|private|fileprivate|internal|package|nonisolated|final|lazy)"
    r"(?:\(\w+\))?\s+)*"
)
# The start of a static stored or computed property; static_bindings reads its bindings from there.
STATIC_HEAD = re.compile(r"\bstatic\s+" + MODIFIERS + r"(?:let|var)\b")
BINDING_NAME = re.compile(r"\s*(`?\w+`?)")
# RobotProfile as a type, but not a metatype (`.Type`, `.self`) or a nested type (`RobotProfile.Inner`).
PROFILE_TYPE = re.compile(r"\bRobotProfile\b(?!\s*\.\s*\w)")
SELF_TYPE = re.compile(r"\bSelf\b(?!\s*\.\s*\w)")
BUILDS_PROFILE = re.compile(r"\bRobotProfile\s*(?:\.\s*init\s*)?\(")
# A value that starts by building one, with or without the module name.
STARTS_BUILDING = re.compile(r"(?:\w+\s*\.\s*)*RobotProfile\s*(?:\.\s*init\s*)?\(")
STARTS_SELF = re.compile(r"Self\s*(?:\.\s*init\s*)?\(")
IMPLICIT_INIT = re.compile(r"(?<![\w)\].])\.init\s*\(")
# Any call of the initializer, such as `AppModel(profile: .init(...))`: it has no defaults, so every call writes this
# label. A field declared with that name (`let offsetMeasuredAt: SIMD3<Float>`) is not a call.
INIT_LABEL = re.compile(r"(?<![.\w])offsetMeasuredAt\s*:(?!:)")
DECLARES = re.compile(r"\b(?:let|var)\s+$")
# A line that declares stored properties: `let id: Int, offsetMeasuredAt: SIMD3<Float>` names a field, not a call.
DECLARATION_LINE = re.compile(
    r"\s*(?:@\w+\s+)*(?:(?:public|private|internal|fileprivate|open|nonisolated|static|lazy|weak|unowned)"
    r"(?:\(set\))?\s+)*(?:let|var)\b"
)
SELF_BUILDS = re.compile(r"\bSelf\s*(?:\.\s*init\s*)?\(|\bself\s*\.\s*init\s*\(")
# What `.init(...)` takes its type from: a type written beside it, or the function or computed property it returns.
ANNOTATED = re.compile(r":\s*(?P<type>[^:=;{}()\n]+?)\s*(?<![=!<>])=\s*$")
RETURNS = re.compile(r".*->\s*(?P<type>[^{}]+?)\s*(?:\bwhere\b[^{}]*)?$", re.S)
COMPUTED = re.compile(r"\b(?:var|let)\s+`?\w+`?\s*:\s*(?P<type>[^{}=]+?)\s*$")
# Blocks inside a function body that an implicit `.init` passes through on its way to the function's return type.
PASSES_THROUGH = re.compile(
    r"(?:else|if|guard|switch|do|catch|for|while|repeat|defer|get|set|_read|_modify)\b"
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


def names_profile(kind, inside):
    """Whether a written type is one RobotProfile: `RobotProfile` or `TeleopCore.RobotProfile`, optional or not, or,
    inside the RobotProfile type, `Self`."""
    kind = re.sub(r"\s", "", kind or "").rstrip("?!")
    return kind.split(".")[-1] == "RobotProfile" or (inside and kind == "Self")


def skip_space(code, i, end):
    while i < end and code[i].isspace():
        i += 1
    return i


def read_type(code, i, end):
    """The type written from i, to the first `=`, `{`, `,` or `;` outside brackets, or to the end of its line once
    some of it is written; an open bracket carries it onto the next line. `->` is not a bracket."""
    depth, j = 0, i
    while j < end:
        c = code[j]
        if code.startswith("->", j):
            j += 2
            continue
        if c in "([<":
            depth += 1
        elif c in ")]>":
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and (c in "={,;}" or (c == "\n" and code[i:j].strip())):
            break
        j += 1
    return code[i:j], j


def read_value(code, i, end):
    """The value written from i, to the first `,` or `;` outside brackets, a closing bracket it did not open, or the
    end of its line once some of it is written. A `<` right after a name opens generic arguments (`Dictionary<K, V>()`)
    and only a `>` closes them; a comparison written without spaces (`1<2`) is read as generics, a known limit."""
    stack, j = [], i
    pairs = {")": "(", "]": "[", "}": "{", ">": "<"}
    while j < end:
        c = code[j]
        if c in "([{" or (c == "<" and j > i and (code[j - 1].isalnum() or code[j - 1] == "_")):
            stack.append(c)
        elif c in ")]}>":
            if c == ">" and (not stack or stack[-1] != "<"):
                pass
            elif not stack:
                break
            else:
                while stack and stack[-1] == "<" and c != ">":
                    stack.pop()
                if stack and stack[-1] == pairs[c]:
                    stack.pop()
                elif not stack:
                    break
        elif not stack and (c in ",;" or (c == "\n" and code[i:j].strip())):
            break
        j += 1
    return code[i:j], j


def static_bindings(code, start=0, end=None):
    """(offset, type, value) of every binding of every static property in code[start:end], so
    `static let a = 1, b: RobotProfile = make()` gives both; type and value are "" when not written."""
    end = len(code) if end is None else end
    for head in STATIC_HEAD.finditer(code, start, end):
        i = head.end()
        while True:
            name = BINDING_NAME.match(code, i, end)
            if not name:
                break
            offset, kind, value = name.start(1), "", ""
            i = skip_space(code, name.end(), end)
            if i < end and code[i] == ":":
                kind, i = read_type(code, i + 1, end)
                i = skip_space(code, i, end)
            if i < end and code[i] == "=":
                value, i = read_value(code, i + 1, end)
                i = skip_space(code, i, end)
            if i < end and code[i] == "{":
                i = skip_space(code, closing_brace(code, i) + 1, end)
            yield offset, kind, value.strip()
            if i < end and code[i] == ",":
                i += 1
            else:
                break


def init_type(code, k, low):
    """The type the `.init(` at k builds, as the text writes it, or "" when the text does not say: a type written
    beside it (`let p: T = .init(`), else, when it is a whole expression (after `{`, `;` or `return`), the return type
    of the function or computed property around it, through any `if`, `switch`, `get` and similar blocks."""
    before = code[max(low, k - 400) : k]
    annotated = ANNOTATED.search(before)
    if annotated:
        return annotated["type"]
    written = before.rstrip()
    if not (written.endswith(("{", ";")) or re.search(r"\breturn$", written)):
        return ""
    depth, j = 0, k - 1
    while j >= low:
        if code[j] == "}":
            depth += 1
        elif code[j] == "{" and depth:
            depth -= 1
        elif code[j] == "{":
            start = max(low, *(code.rfind(c, low, j) + 1 for c in "{};"))
            head = code[start:j].strip()
            for pattern in (RETURNS, COMPUTED):
                found = pattern.search(head)
                if found:
                    return found["type"]
            if not PASSES_THROUGH.match(head):
                return ""
        j -= 1
    return ""


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
    return {name} | {form for form in leading if len(form) >= 4 and not form.isalpha()}


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

    bodies = profile_bodies(code) if swift else []
    if not under(relative, ALLOWED):
        names_or_holds(text, code, literals, bodies, swift, report)
    if swift and not under(relative, BUILDERS):
        builds(code, bodies, report)


def names_or_holds(text, code, literals, bodies, swift, report):
    for m in REMOVED.finditer(text):
        report(m.start(), "the name so101Simulator")
    for pid, pattern in id_patterns:
        for m in pattern.finditer(text):
            report(m.start(), f"the profile id {pid} named outside the loader")

    if swift:
        for pattern, what in REMOVED_DIRECTIONS + REMOVED_WRIST_JAW:
            for m in pattern.finditer(code):
                report(m.start(), what)

    if not swift:
        for name, _ in names:
            for m in re.finditer(re.escape(name), text):
                report(m.start(), f"the profile name '{name}' written in code")
        return

    for offset, literal in literals:
        for name, forms in names:
            if name in literal or literal.strip() in forms:
                report(offset, f"the profile name '{name}' written in code")

    for offset, kind, value in static_bindings(code):
        if PROFILE_TYPE.search(kind) or STARTS_BUILDING.match(value):
            report(offset, "a robot profile held in code")
        if FRAMES_TYPE.search(kind) or INFERRED_FRAMES_VALUE.match(value):
            report(offset, "robot frames held in a static")
        if WRIST_JAW_TYPE.search(kind) or INFERRED_WRIST_JAW_VALUE.match(value):
            report(offset, "a robot's wrist or jaw held in a static")
    for opening, closing, body in bodies:
        for offset, kind, value in static_bindings(body, opening, closing):
            implicit = IMPLICIT_INIT.match(value) and (
                not kind.strip() or names_profile(kind, inside=True)
            )
            if SELF_TYPE.search(kind) or STARTS_SELF.match(value) or implicit:
                report(offset, "a robot profile held in code")


def declared_field(code, k):
    """True when the label at k is one of several properties declared in one statement, outside any call's brackets.

    The statement may run over several lines when each ends in a comma (`let id: Int,` then `offsetMeasuredAt: ...`).
    """
    start = max(code.rfind(c, 0, k) for c in "\n{;") + 1
    while start > 0 and code[start - 1] == "\n" and code[:start - 1].rstrip().endswith(","):
        start = max(code.rfind(c, 0, start - 1) for c in "\n{;") + 1
    line = code[start:k]
    depth = sum(line.count(c) for c in "([") - sum(line.count(c) for c in ")]")
    return depth == 0 and bool(DECLARATION_LINE.match(line))


def builds(code, bodies, report):
    for m in BUILDS_PROFILE.finditer(code):
        report(m.start(), "a robot profile built in code")
    for m in BUILDS_FRAMES.finditer(code):
        report(m.start(), "robot frames built in code")
    for m in BUILDS_WRIST_JAW.finditer(code):
        report(m.start(), "a robot's wrist or jaw built in code")
    for m in INIT_LABEL.finditer(code):
        if not (DECLARES.search(code, max(0, m.start() - 40), m.start()) or declared_field(code, m.start())):
            report(m.start(), "a robot profile built in code")
    for m in IMPLICIT_INIT.finditer(code):
        if names_profile(init_type(code, m.start(), 0), inside=False):
            report(m.start(), "a robot profile built in code")
    for opening, closing, body in bodies:
        for m in SELF_BUILDS.finditer(body, opening, closing):
            report(m.start(), "a robot profile built in code")
        for m in IMPLICIT_INIT.finditer(body, opening, closing):
            if names_profile(init_type(body, m.start(), opening + 1), inside=True):
                report(m.start(), "a robot profile built in code")


for path in files():
    check(path)

for _, _, line in sorted(found):
    print(line)
if found:
    print(f"{len(found)} arm constant(s) in code: {HINT}.")
sys.exit(1 if found else 0)
