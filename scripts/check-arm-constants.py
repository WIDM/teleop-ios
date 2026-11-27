#!/usr/bin/env python3
"""Fails when a robot's numbers or a named robot profile appear in code instead of in a profile file.

A new arm is meant to need only its profile file (App/Resources/Profiles/<id>.json, docs/PROFILE.md). So outside the
loader, the profile files, the tests, the build settings and the test plans this check refuses:
  1. the removed constant `so101Simulator`;
  2. a `static let` or `static var` that holds a RobotProfile;
  3. a profile id (the name of a file in App/Resources/Profiles, without .json) written in a source file.

CHECK_ARM_CONSTANTS_ROOT lets scripts/test_check_arm_constants.py point the check at a small test tree.
Exit code 0 = clean, 1 = violations found.
"""

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
SCANNED = {".swift", ".py", ".sh", ".yml", ".yaml", ".plist", ".json", ".xctestplan"}
SKIPPED_DIRS = {".git", ".build", ".swiftpm", "build", "DerivedData", "__pycache__"}

REMOVED = re.compile(r"\bso101Simulator\b")
# `static let x = RobotProfile(`, `static var x: RobotProfile`, and `static let x = Self(` inside the type.
STATIC_PROFILE = re.compile(
    r"\bstatic\s+(?:let|var)\s+\w+\s*(?::\s*RobotProfile\b|=\s*RobotProfile\s*\()"
)
STATIC_SELF = re.compile(
    r"\bstatic\s+(?:let|var)\s+\w+\s*(?::\s*Self\b|=\s*Self\s*\(|=\s*\.init\s*\()"
)
IN_PROFILE_TYPE = re.compile(r"^\s*(?:public\s+)?(?:extension|struct)\s+RobotProfile\b")

HINT = "put the number in the robot profile file (App/Resources/Profiles/<id>.json) and read it through ProfileLoader; see docs/PROFILE.md"


def files():
    for folder, dirs, names in os.walk(root):
        dirs[:] = sorted(
            d for d in dirs if d not in SKIPPED_DIRS and not d.endswith(".xcodeproj")
        )
        for name in sorted(names):
            path = pathlib.Path(folder) / name
            if path.suffix in SCANNED:
                yield path


def allowed(relative):
    return any(
        relative == entry or (entry.endswith("/") and relative.startswith(entry))
        for entry in ALLOWED
    )


profiles = root / "App/Resources/Profiles"
ids = sorted(path.stem for path in profiles.glob("*.json")) if profiles.is_dir() else []
id_patterns = [
    (name, re.compile(r"(?<![\w-])" + re.escape(name) + r"(?![\w-])")) for name in ids
]

found = []
for path in files():
    relative = path.relative_to(root).as_posix()
    if allowed(relative):
        continue
    try:
        text = path.read_text()
    except (UnicodeDecodeError, OSError):
        continue
    in_profile_type = False
    for number, line in enumerate(text.splitlines(), 1):
        if path.suffix == ".swift":
            if IN_PROFILE_TYPE.match(line):
                in_profile_type = True
            elif re.match(
                r"^(?:public\s+|private\s+|fileprivate\s+)?(?:extension|struct|enum|class|final)\b",
                line,
            ):
                in_profile_type = False
            if REMOVED.search(line):
                found.append(
                    f"{relative}:{number}: the removed constant so101Simulator: {line.strip()}"
                )
            elif STATIC_PROFILE.search(line) or (
                in_profile_type and STATIC_SELF.search(line)
            ):
                found.append(
                    f"{relative}:{number}: a robot profile held in code: {line.strip()}"
                )
        for name, pattern in id_patterns:
            if pattern.search(line):
                found.append(
                    f"{relative}:{number}: the profile id {name} named outside the loader: {line.strip()}"
                )

for line in found:
    print(line)
if found:
    print(f"{len(found)} arm constant(s) in code: {HINT}.")
sys.exit(1 if found else 0)
