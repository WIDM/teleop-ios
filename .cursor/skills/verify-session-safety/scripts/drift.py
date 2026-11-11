#!/usr/bin/env python3
"""Fail when the checker's action list or screen map no longer matches the code.

Also warn when covered files changed after the sync commit recorded in SKILL.md.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

SKILL = Path(__file__).resolve().parents[1]
ROOT = SKILL.parents[2]
# TELEOP_APP_SOURCES lets scripts/mutants.py point this check at a broken copy of the screens.
APP = Path(os.environ.get("TELEOP_APP_SOURCES", ROOT / "App/Sources"))
problems = []

# Every TeleopAction case must be in the checker's action table.
session = (
    ROOT / "Packages/TeleopCore/Sources/TeleopCore/TeleopSession.swift"
).read_text()
enum_body = re.search(r"enum TeleopAction.*?\{(.*?)\n\}", session, re.S).group(1)
enum_cases = set(re.findall(r"case (\w+)", enum_body))
main = (SKILL / "checker/Sources/SafetyCheck/main.swift").read_text()
table_cases = set(re.findall(r'\("\w+", \.(\w+)[(),]', main))
for name in sorted(enum_cases ^ table_cases):
    problems.append(f"TeleopAction case and checker table differ: {name}")

# Every stored FakeTeleopState field must be in the state key or named as excluded.
state_source = (
    ROOT / "Packages/TeleopCore/Sources/TeleopCore/FakeTeleopState.swift"
).read_text()
# An optional field may have no initializer; a computed property ends its line with "{".
stored = set(
    re.findall(r"^ *public (?:private\(set\) )?var (\w+)(?:: *[\w.?]+)? *(?:=|$)", state_source, re.M)
)
key_body = re.search(r"struct StateKey: Hashable \{(.*?)\n\}", main, re.S).group(1)
key_fields = set(re.findall(r"let (\w+):", key_body))
excluded = set(re.search(r"// Not in key.*?: (.*)", main).group(1).split())
for name in sorted(stored - key_fields - excluded):
    problems.append(f"FakeTeleopState.{name} is not in StateKey or the excluded list")


HOLD_ACTIONS = {"holdArmStart", "holdArmEnd"}
# The volume keys reach the input rules (OperatingController): vol+ moves the arm; vol- closes the jaws (scheme A) or
# holds the wrist (scheme B).
KEY_ACTIONS = {"holdArmStart", "holdArmEnd", "gripperStart", "gripperEnd", "wristStart", "wristEnd"}
GRIPPER_ACTIONS = {"gripperStart", "gripperEnd"}
TURN_ACTIONS = {"turnStart", "turnEnd"}
ROOT_VIEW_ACTIONS = {"holdArmEnd"}
STRUCT = re.compile(
    r"^(?:(?:private|fileprivate|public|internal) )?struct (\w+)\b.*?^\}", re.M | re.S
)


def sends(text):
    found = set(re.findall(r"(?:send|perform)\(\.(\w+)", text))
    found |= set(re.findall(r"return \[\.(\w+)[\](]", text))
    # AppModel.connect() sends connect on the fake link; on a live link the server answers with linkUp or linkLost.
    if "model.connect()" in text:
        found.add("connect")
    # The Settings switch: AppModel.liveLink flips the flag, then sends switchLink.
    if "$model.liveLink" in text:
        found.add("toggleLiveLink")
    # LiveLinkController reports what the server did.
    found |= set(re.findall(r"onAction\?\(\.(\w+)", text))
    return found


# Slice the app source by struct, so one screen's controls are never credited to another.
struct_sends = {}
outside_structs = {}
for path in APP.rglob("*.swift"):
    text = path.read_text()
    for match in STRUCT.finditer(text):
        struct_sends[match.group(1)] = sends(match.group(0))
        if ".armHold(model:" in match.group(0):
            struct_sends[match.group(1)] |= HOLD_ACTIONS
        if ".volumeKeys(model:" in match.group(0):
            struct_sends[match.group(1)] |= KEY_ACTIONS
        # The gripper hold reaches a screen through these views.
        if re.search(r"\.gripperHold\(model:|LeftHandles\(|GripperOpenHandle\(|GripperHoldRow\(|GripperHoldButton\(", match.group(0)):
            struct_sends[match.group(1)] |= GRIPPER_ACTIONS
        # The jaw turn reaches a screen through these views.
        if re.search(r"\.turnHold\(model:|LeftHandles\(|JawTurnHandle\(", match.group(0)):
            struct_sends[match.group(1)] |= TURN_ACTIONS
    leftover = sends(STRUCT.sub("", text))
    if leftover:
        outside_structs[str(path.relative_to(APP))] = leftover
# Classes that may send actions. main.swift models each one: see linkEvents and toggleLiveLink there.
allowed_outside = {
    # connect: the fake link's S1 Connect. holdArmEnd, turnEnd, wristEnd: a hold or turn the link could not start.
    # switchLink: the live-link switch. holdArmStart: a button hold the controller asked for. resetScene and
    # sceneResetDone: the top band's reset (the practice link confirms it at once).
    "AppModel.swift": {"connect", "holdArmStart", "holdArmEnd", "turnEnd", "wristEnd", "switchLink", "resetScene", "sceneResetDone"},
    "Link/LiveLinkController.swift": {"holdArmEnd", "gripperEnd", "turnEnd", "wristEnd", "linkUp", "linkLost", "linkLatency", "stop", "sceneResetDone"},
    # The input rules' commands. Keys reach it from screens with .volumeKeys (KEY_ACTIONS). stop, openSettings and the
    # reset come only from touches on the bands, which no shipped screen feeds yet; a screen that installs the touch
    # surface adds them to its ui-map row.
    "Operating/OperatingController.swift": {"holdArmStart", "holdArmEnd", "gripperStart", "gripperEnd", "wristStart", "wristEnd", "stop", "openSettings"},
}
for path, names in sorted(outside_structs.items()):
    if allowed_outside.get(path) != names:
        problems.append(
            f"{path} sends {sorted(names)} outside any struct, expected {sorted(allowed_outside.get(path, set()))}"
        )
for path in sorted(set(allowed_outside) - set(outside_structs)):
    problems.append(f"{path} no longer sends actions; remove it from allowed_outside")

root_view = (APP / "Screens/RootView.swift").read_text()
screen_of_route = dict(re.findall(r"case \.(\w+): (\w+)\(", root_view))

listed_by_struct = {}
map_routes = set()
for line in (SKILL / "ui-map.tsv").read_text().splitlines():
    if line.startswith("#") or not line.strip():
        continue
    route, screen, actions = line.split("\t")
    map_routes.add(route)
    if screen_of_route.get(route) != screen:
        problems.append(
            f"{route}: ui-map says {screen}, RootView shows {screen_of_route.get(route)}"
        )
    # tutorialNext1 -> tutorialNext, gripperStartClosed -> gripperStart: the table names one case per payload.
    names = {
        re.sub(r"^(gripperStart)(Closed|Open)$|^(turnStart)(Positive|Negative|TiltDown|TiltUp)$", lambda m: m.group(1) or m.group(3), re.sub(r"\d+$", "", a))
        for a in actions.split(",")
    }
    for name in sorted(names - struct_sends.get(screen, set())):
        problems.append(f"{route}: ui-map lists {name}, but {screen} does not send it")
    listed_by_struct.setdefault(screen, set()).update(names)
for route in sorted(set(screen_of_route) - map_routes):
    problems.append(f"{route} is in RootView but not in ui-map")

for screen, names in sorted(listed_by_struct.items()):
    for name in sorted(struct_sends.get(screen, set()) - names):
        problems.append(f"{screen} sends {name}, but no ui-map row for it lists it")

# Only these structs may send actions without being a mapped screen.
allowed = {
    "RootView": ROOT_VIEW_ACTIONS,
    "ArmHoldModifier": HOLD_ACTIONS,
    "VolumeKeyModifier": set(),
    "HeldControlModifier": set(),
    "GripperHoldButton": GRIPPER_ACTIONS,
    "GripperOpenHandle": GRIPPER_ACTIONS,
    "GripperHoldRow": GRIPPER_ACTIONS,
    "JawTurnHandle": TURN_ACTIONS,
    "LeftHandles": GRIPPER_ACTIONS | TURN_ACTIONS,
}
for name, expected in allowed.items():
    if struct_sends.get(name) != expected:
        problems.append(
            f"{name} sends {sorted(struct_sends.get(name, set()))}, expected {sorted(expected)}"
        )
for name, names in sorted(struct_sends.items()):
    if names and name not in listed_by_struct and name not in allowed:
        problems.append(f"{name} sends {sorted(names)} but is not in ui-map.tsv")

for problem in problems:
    print(f"DRIFT {problem}")

skill_text = (SKILL / "SKILL.md").read_text()
sync = re.search(r"Sync commit: `([0-9a-f]+)`", skill_text).group(1)
covered = re.findall(
    r"^- `([^`]+)`", skill_text.split("## Coverage", 1)[1].split("\n## ", 1)[0], re.M
)
changed = subprocess.run(
    ["git", "-C", str(ROOT), "diff", "--name-only", sync, "--", *covered],
    capture_output=True,
    text=True,
    check=True,
).stdout.split()
for path in changed:
    print(
        f"REVIEW {path} changed since sync commit {sync[:7]}. Confirm the checker still describes it."
    )

sys.exit(1 if problems else 0)
