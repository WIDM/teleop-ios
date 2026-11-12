#!/usr/bin/env python3
"""Fail when the checker's action list or screen map no longer matches the code.

Also warn when covered files changed after the sync commit recorded in README.md.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1]
ROOT = TOOL.parents[1]
# TELEOP_APP_SOURCES lets scripts/mutants.py point this check at a broken copy of the screens.
APP = Path(os.environ.get("TELEOP_APP_SOURCES", ROOT / "App/Sources"))
problems = []

# Every TeleopAction case must be in the checker's action table.
session = (
    ROOT / "Packages/TeleopCore/Sources/TeleopCore/TeleopSession.swift"
).read_text()
enum_body = re.search(r"enum TeleopAction.*?\{(.*?)\n\}", session, re.S).group(1)
enum_cases = set(re.findall(r"case (\w+)", enum_body))
main = (TOOL / "checker/Sources/SafetyCheck/main.swift").read_text()
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


# The volume keys reach the input rules (OperatingController): vol+ moves the arm; vol- closes the jaws (scheme A) or
# holds the wrist (scheme B).
KEY_ACTIONS = {"holdArmStart", "holdArmEnd", "gripperStart", "gripperEnd", "wristStart", "wristEnd"}
ROOT_VIEW_ACTIONS = set()
# The operating screen feeds every touch to the input rules (OperatingController) and the pad's buttons to its rules,
# so it can cause whatever those send; the top band's reset reaches the session through AppModel.runReset.
TOUCH_ACTIONS = {"holdArmStart", "holdArmEnd", "gripperStart", "gripperEnd", "wristStart", "wristEnd", "stop", "openSettings", "resetScene"}
BUTTON_ACTIONS = {"holdArmStart", "holdArmEnd", "gripperStart", "gripperEnd"}
# What the operating screen sends itself: Release, keep scene, and the not-connected word, which opens Connect.
OWN_ACTIONS = {"releaseStop", "changeServer"}
STRUCT = re.compile(
    r"^(?:(?:private|fileprivate|public|internal) )?struct (\w+)\b.*?^\}", re.M | re.S
)


def sends(text):
    found = set(re.findall(r"(?:send|perform)\(\.(\w+)", text))
    found |= set(re.findall(r"return \[\.(\w+)[\](]", text))
    # AppModel.connect() sends connect on the fake link; on a live link the server answers with linkUp or linkLost.
    if "model.connect()" in text:
        found.add("connect")
    # Practice on and off: AppModel.startPractice and leavePractice flip the flag, then send switchLink.
    if "model.startPractice()" in text or "model.leavePractice()" in text:
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
        if ".volumeKeys(model:" in match.group(0):
            struct_sends[match.group(1)] |= KEY_ACTIONS
        if "model.touch(" in match.group(0):
            struct_sends[match.group(1)] |= TOUCH_ACTIONS
        if "model.buttonDown(" in match.group(0):
            struct_sends[match.group(1)] |= BUTTON_ACTIONS
        # The operating screen's touch surface, pad and own controls reach it through these views.
        if "OperatingSurface(" in match.group(0):
            struct_sends[match.group(1)] |= TOUCH_ACTIONS | BUTTON_ACTIONS | OWN_ACTIONS
        if "OperatingControls(" in match.group(0):
            struct_sends[match.group(1)] |= BUTTON_ACTIONS | OWN_ACTIONS
    leftover = sends(STRUCT.sub("", text))
    if leftover:
        outside_structs[str(path.relative_to(APP))] = leftover
# Classes that may send actions. main.swift models each one: see linkEvents and toggleLiveLink there.
allowed_outside = {
    # connect: the fake link's S1 Connect. holdArmEnd, wristEnd: a hold the link could not start.
    # switchLink: the live-link switch. holdArmStart: a button hold the controller asked for. resetScene and
    # sceneResetDone: the top band's reset (the practice link confirms it at once).
    "AppModel.swift": {"connect", "holdArmStart", "holdArmEnd", "wristEnd", "switchLink", "resetScene", "sceneResetDone"},
    "Link/LiveLinkController.swift": {"holdArmEnd", "gripperEnd", "wristEnd", "linkUp", "linkLost", "linkLatency", "stop", "sceneResetDone"},
    # The input rules' commands. Keys reach it from screens with .volumeKeys (KEY_ACTIONS); touches on the bands (STOP,
    # the gear) and on the control surface from the operating screen's touch surface (TOUCH_ACTIONS).
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

# U1: the checker counts these routes as showing a latched stop. The operating screen's routes must be exactly
# RootView.operatingRoutes, and Settings must draw its STOPPED band.
def route_set(pattern, text):
    found = re.search(pattern, text)
    return set(re.findall(r"\.(\w+)", found.group(1))) if found else None


shows_stop = route_set(r"let showsTheStop: Set<Route> = \[([^\]]*)\]", main)
operating_routes = route_set(r"static let operatingRoutes: Set<Route> = \[([^\]]*)\]", root_view)
if shows_stop is None or operating_routes is None:
    problems.append("cannot read showsTheStop in main.swift or operatingRoutes in RootView.swift")
elif shows_stop - {"s6"} != operating_routes:
    problems.append(f"showsTheStop in main.swift, less s6, differs from RootView.operatingRoutes {sorted(operating_routes)}")
# Leaving the operating screen ends every hold (perform in main.swift models it): the checker's routes and the
# controller's must both be the screen's.
operating_screen = route_set(r"let operatingScreen: Set<Route> = \[([^\]]*)\]", main)
if operating_screen is None or operating_screen != operating_routes:
    problems.append(f"operatingScreen in main.swift differs from RootView.operatingRoutes {sorted(operating_routes or [])}")
controller_source = (APP / "Operating/OperatingController.swift").read_text()
if "static let operatingRoutes: Set<Route> = RootView.operatingRoutes" not in controller_source:
    problems.append("OperatingController.operatingRoutes is not RootView.operatingRoutes, which operatingScreen models")
settings_source = next(
    (m.group(0) for p in APP.rglob("*.swift") for m in STRUCT.finditer(p.read_text()) if m.group(1) == "SettingsScreen"), ""
)
# The band must exist and be drawn whenever the operating screen shows the stop.
draws_band = re.search(r"if case \.stopped = model\.operating\.state \{ stoppedBand \}", settings_source)
if "s6" in (shows_stop or set()) and not (draws_band and 'accessibilityIdentifier("settings.stopped")' in settings_source):
    problems.append("SettingsScreen no longer shows the stop (settings.stopped), but showsTheStop counts s6")
# Settings offers Replay tutorial only while the stop is not latched, as shippedActions in main.swift models: the
# tutorial pages do not show the stop (U1).
hides_tutorial = re.search(r"if !model\.session\.state\.emergencyStop \{[^}]*\.replayTutorial\b", settings_source)
if "replayTutorial" in sends(settings_source) and not hides_tutorial:
    problems.append("SettingsScreen offers replayTutorial while stopped, but shippedActions in main.swift hides it then")
# One case may name several routes ("case .p4, .p5: OperatingScreen(").
screen_of_route = {
    route: screen
    for routes, screen in re.findall(r"case ((?:\.\w+, )*\.\w+): (\w+)\(", root_view)
    for route in re.findall(r"\.(\w+)", routes)
}

listed_by_struct = {}
map_routes = set()
for line in (TOOL / "ui-map.tsv").read_text().splitlines():
    if line.startswith("#") or not line.strip():
        continue
    route, screen, actions = line.split("\t")
    map_routes.add(route)
    if screen_of_route.get(route) != screen:
        problems.append(
            f"{route}: ui-map says {screen}, RootView shows {screen_of_route.get(route)}"
        )
    # tutorialNext1 -> tutorialNext, gripperStartClosed -> gripperStart: the table names one case per payload.
    names = {re.sub(r"^(gripperStart)(Closed|Open)$", r"\1", re.sub(r"\d+$", "", a)) for a in actions.split(",")}
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
    "VolumeKeyModifier": set(),
    "OperatingSurface": TOUCH_ACTIONS | BUTTON_ACTIONS | OWN_ACTIONS,
    "OperatingControls": BUTTON_ACTIONS | OWN_ACTIONS,
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

readme = (TOOL / "README.md").read_text()
sync = re.search(r"Sync commit: `([0-9a-f]+)`", readme).group(1)
covered = re.findall(
    r"^- `([^`]+)`", readme.split("## Coverage", 1)[1].split("\n## ", 1)[0], re.M
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
