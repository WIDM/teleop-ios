#!/usr/bin/env python3
"""Prove the checker can fail: break a throwaway copy of TeleopCore and expect each result.

A few variants expect PASS, proving a harmless variation is not reported.
The repository's own source files are never changed.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SKILL = Path(__file__).resolve().parents[1]
ROOT = SKILL.parents[2]
SOURCES = [
    "Sources/TeleopCore/TeleopSession.swift",
    "Sources/TeleopCore/FakeTeleopState.swift",
]
ONE_BUZZ = "if !state.emergencyStop { pendingHaptics.append(.play(.emergencyLoop)) }"

HOLD_GUARDS = """guard acceptsControl else { return }
            guard canControl else {
                pendingHaptics.append(.play(.commandBlocked))
                return
            }
            // The server runs one held control at a time: the arm takes over from the gripper and the wrist.
            state.stopGripper()
            state.stopWrist()
            state.armMoving = true"""

VARIANTS = [
    (
        "connect clears E-stop",
        [
            (
                "guard !state.liveLink else { return }\n            state.markConnected()",
                "guard !state.liveLink else { return }\n            state.markConnected()\n            state.emergencyStop = false",
            )
        ],
        ["FAIL S1"],
    ),
    (
        "hold start has no guards",
        [(HOLD_GUARDS, "state.armMoving = true")],
        ["FAIL S2", "FAIL U4"],
    ),
    (
        "stop leaves the arm moving",
        [
            (
                "state.emergencyStop = true\n            state.armMoving = false\n",
                "state.emergencyStop = true\n",
            )
        ],
        ["FAIL S3"],
    ),
    (
        "gripper ignores arm motion",
        [("guard canControl, !state.armMoving else", "guard canControl else")],
        ["FAIL S4"],
    ),
    (
        "reset ignores E-stop",
        [
            (
                "guard acceptsControl else { return }\n            state.resetScene()",
                "state.resetScene()",
            )
        ],
        ["FAIL S4"],
    ),
    (
        "reset closes the gripper",
        [("        gripper = .open\n        clearLatency()", "        gripper = .closed\n        clearLatency()")],
        ["FAIL S4"],
    ),
    (
        "link switch leaves the arm moving",
        [("    public mutating func leaveSession() {\n        armMoving = false\n", "    public mutating func leaveSession() {\n")],
        ["FAIL S6"],
    ),
    (
        # Harmless: U1 allows S1 while latched, because S1 leads back to S4.
        "lost link opens S1 even while E-stopped",
        [("if !state.emergencyStop, BackStackRules.controlRoutes.contains(route) { go(.s1) }", "go(.s1)")],
        ["PASS U1", "PASS U3"],
    ),
    (
        "lost link or disconnect leaves the arm moving",
        [("        connected = false\n        armMoving = false\n", "        connected = false\n")],
        ["FAIL S6"],
    ),
    (
        "slow link leaves the arm moving",
        [("                state.commandsBlocked = true\n                state.armMoving = false\n", "                state.commandsBlocked = true\n")],
        ["FAIL S6"],
    ),
    (
        "link up clears E-stop",
        [("            state.serverInputError = false\n            if let gripper", "            state.serverInputError = false\n            state.emergencyStop = false\n            if let gripper")],
        ["FAIL S1"],
    ),
    (
        "fake link accepts a server gripper",
        [("        case .linkUp(let gripper):\n            guard state.liveLink else { return }\n", "        case .linkUp(let gripper):\n")],
        ["FAIL S4"],
    ),
    (
        "gripper end does nothing",
        [("// Release always stops, even if the session got blocked while held.\n            state.stopGripper()", "break")],
        ["FAIL S11"],
    ),
    (
        "stop leaves the gripper moving",
        [("state.armMoving = false\n            state.stopGripper()\n            state.stopWrist()\n            go(.s4)", "state.armMoving = false\n            state.stopWrist()\n            go(.s4)")],
        ["FAIL S10"],
    ),
    (
        "arm hold leaves the gripper moving",
        [("            state.stopGripper()\n            state.stopWrist()\n            state.armMoving = true", "            state.stopWrist()\n            state.armMoving = true")],
        ["FAIL S10", "FAIL U7"],
    ),
    (
        "lost link leaves the gripper moving",
        [("        armMoving = false\n        gripperMoving = nil\n        wristMoving = false\n    }\n\n    public mutating func clearLatency", "        armMoving = false\n        wristMoving = false\n    }\n\n    public mutating func clearLatency")],
        ["FAIL S10"],
    ),
    (
        "gripper hold leaves the wrist hold engaged",
        [("            state.stopWrist()\n            state.moveGripper(toward: target)", "            state.moveGripper(toward: target)")],
        ["FAIL S12", "FAIL U8"],
    ),
    (
        "wrist hold leaves the gripper moving",
        [("            state.stopGripper()\n            state.wristMoving = true", "            state.wristMoving = true")],
        ["FAIL S12", "FAIL U8"],
    ),
    (
        "wrist hold ignores the arm hold",
        [("// The arm is moving, so the wrist cannot turn.\n            guard canControl, !state.armMoving else {", "// The arm is moving, so the wrist cannot turn.\n            guard canControl else {")],
        ["FAIL S12", "FAIL S16", "FAIL U8"],
    ),
    (
        "lost link leaves the wrist hold engaged",
        [("        gripperMoving = nil\n        wristMoving = false\n    }\n\n    public mutating func clearLatency", "        gripperMoving = nil\n    }\n\n    public mutating func clearLatency")],
        ["FAIL S13"],
    ),
    (
        "wrist end does nothing",
        [("// Release always stops, even if the session got blocked while held.\n            state.stopWrist()", "break")],
        ["FAIL S15"],
    ),
    (
        "wrist hold has no guards",
        [
            (
                "case .wristStart:\n            guard acceptsControl else { return }\n            // The arm is moving, so the wrist cannot turn.\n            guard canControl, !state.armMoving else {\n                pendingHaptics.append(.play(.commandBlocked))\n                return\n            }\n",
                "case .wristStart:\n",
            )
        ],
        ["FAIL S13", "FAIL S16"],
    ),
    (
        "stop leaves the wrist hold engaged",
        [("state.stopGripper()\n            state.stopWrist()\n            go(.s4)", "state.stopGripper()\n            go(.s4)")],
        ["FAIL S13"],
    ),
    (
        "arm hold leaves the wrist hold engaged",
        [("            state.stopWrist()\n            state.armMoving = true", "            state.armMoving = true")],
        ["FAIL S12", "FAIL U8"],
    ),
    (
        "a STOP leaves an earlier reset able to release it",
        [("            state.resetClearsStop = false\n            state.emergencyStop = true", "            state.emergencyStop = true")],
        ["FAIL S1"],
    ),
    (
        "any confirmed reset releases the stop",
        [("guard state.emergencyStop, state.resetClearsStop else { return }", "guard state.emergencyStop else { return }")],
        ["FAIL S1"],
    ),
    (
        "confirmed reset leaves the buzz playing",
        [("            // The long buzz ends. \"Ready.\" comes from the server's new episode, not from here.\n            pendingHaptics.append(.cancel)\n", "")],
        ["FAIL S9"],
    ),
    (
        "confirmed reset stays where it is",
        [("            // must not lead back to it.\n            go(.p4)", "            // must not lead back to it.\n            if route == .s4 { go(.p4) }")],
        ["FAIL U2"],
    ),
    (
        "hold end does nothing",
        [
            (
                "// Release always stops, even if the session got blocked while held.\n            state.armMoving = false",
                "break",
            )
        ],
        ["FAIL S5"],
    ),
    (
        "stop does not open S4",
        [
            (
                "state.stopWrist()\n            go(.s4)",
                "state.stopWrist()",
            )
        ],
        ["FAIL S7"],
    ),
    (
        "release does not cancel the buzz",
        [("pendingHaptics.append(.cancel)\n", "")],
        ["FAIL S9"],
    ),
    (
        "release stays on S4",
        [
            (
                "pendingHaptics.append(.play(.stopReleased))\n            go(.p4)",
                "pendingHaptics.append(.play(.stopReleased))",
            )
        ],
        ["FAIL U2"],
    ),
    (
        "release does not clear E-stop",
        [
            (
                "case .releaseStop:\n            state.emergencyStop = false",
                "case .releaseStop:",
            )
        ],
        ["FAIL U3"],
    ),
    (
        "second stop restarts the buzz",
        [(ONE_BUZZ, "pendingHaptics.append(.play(.emergencyLoop))")],
        ["FAIL S8", "FAIL U6"],
    ),
    (
        "stop cancels before restarting the buzz",
        [
            (
                ONE_BUZZ,
                "pendingHaptics.append(.cancel)\n            pendingHaptics.append(.play(.emergencyLoop))",
            )
        ],
        ["PASS S8", "PASS U6"],
    ),
    (
        "first stop starts two buzzes in one step",
        [
            (
                ONE_BUZZ,
                "if !state.emergencyStop { pendingHaptics.append(.play(.emergencyLoop)); pendingHaptics.append(.play(.emergencyLoop)) }",
            )
        ],
        ["FAIL S8", "FAIL U6"],
    ),
]
MAP_VARIANTS = [("S5 loses STOP in the map", "s5", ",stop", ["FAIL U5"])]
FALLBACK_STRUCT = "struct FallbackControlScreen: View {"
SOURCE_VARIANTS = [
    (
        "S5 loses STOP in the source",
        "Screens/FallbackScreen.swift",
        FALLBACK_STRUCT,
        "StopButton { model.send(.stop) }",
        "StopButton {}",
        "DRIFT s5: ui-map lists stop, but FallbackControlScreen does not send it",
    ),
    (
        "S4 gains a new control",
        "Screens/EStopScreen.swift",
        "struct EStopScreen: View {",
        "model.send(.releaseStop)",
        "model.send(.releaseStop); model.send(.openSettings)",
        "DRIFT EStopScreen sends openSettings, but no ui-map row for it lists it",
    ),
]


def main():
    work = Path(tempfile.gettempdir()) / "verify-session-safety-mutants"
    core = work / "TeleopCore"
    scratch = work / "build"
    work.mkdir(exist_ok=True)
    env = {**os.environ, "TELEOP_CORE_PATH": str(core)}
    known = SKILL / "known-findings.txt"
    bad = 0

    def fresh_core():
        shutil.rmtree(core, ignore_errors=True)
        shutil.copytree(
            ROOT / "Packages/TeleopCore",
            core,
            ignore=shutil.ignore_patterns(".swiftpm", ".build"),
        )

    def run(label, ui_map, expected):
        nonlocal bad
        subprocess.run(
            [
                "swift",
                "build",
                "-c",
                "release",
                "--package-path",
                str(SKILL / "checker"),
                "--scratch-path",
                str(scratch),
                "-q",
            ],
            env=env,
            check=True,
        )
        out = subprocess.run(
            [str(scratch / "release/SafetyCheck"), str(ui_map), str(known)],
            capture_output=True,
            text=True,
        ).stdout
        missing = [
            e
            for e in expected
            if not any(line.startswith(e + ":") for line in out.splitlines())
        ]
        status = "CAUGHT" if not missing else f"MISSED {missing}"
        bad += bool(missing)
        print(f"{status}: {label} -> {', '.join(expected)}", flush=True)

    for label, edits, expected in VARIANTS:
        fresh_core()
        for old, new in edits:
            path = next(
                (core / s for s in SOURCES if old in (core / s).read_text()), None
            )
            if path is None:
                sys.exit(
                    f"Variant '{label}' no longer applies: {old!r} not found. Update scripts/mutants.py."
                )
            path.write_text(path.read_text().replace(old, new, 1))
        run(label, SKILL / "ui-map.tsv", expected)

    fresh_core()
    for label, route, remove, expected in MAP_VARIANTS:
        lines = (SKILL / "ui-map.tsv").read_text().splitlines()
        changed = [
            l.replace(remove, "") if l.startswith(route + "\t") else l for l in lines
        ]
        tsv = work / "ui-map.tsv"
        tsv.write_text("\n".join(changed) + "\n")
        run(label, tsv, expected)

    for label, file, anchor, old, new, expected in SOURCE_VARIANTS:
        app = work / "AppSources"
        shutil.rmtree(app, ignore_errors=True)
        shutil.copytree(ROOT / "App/Sources", app)
        path = app / file
        before, after = path.read_text().split(anchor, 1)
        if old not in after:
            sys.exit(
                f"Variant '{label}' no longer applies: {old!r} not found. Update scripts/mutants.py."
            )
        path.write_text(before + anchor + after.replace(old, new, 1))
        result = subprocess.run(
            [sys.executable, str(SKILL / "scripts/drift.py")],
            env={**os.environ, "TELEOP_APP_SOURCES": str(app)},
            capture_output=True,
            text=True,
        )
        caught = result.returncode == 1 and expected in result.stdout.splitlines()
        bad += not caught
        print(f"{'CAUGHT' if caught else 'MISSED'}: {label} -> {expected}", flush=True)

    sys.exit(1 if bad else 0)


main()
