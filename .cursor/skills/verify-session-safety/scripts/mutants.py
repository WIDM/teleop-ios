#!/usr/bin/env python3
"""Prove the checker can fail: break a throwaway copy of TeleopCore and expect each result.

Variants prefixed "fix" repair a known finding and expect STALE, which proves that property can pass.
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
SESSION = "Sources/TeleopCore/TeleopSession.swift"

HOLD_GUARDS = """guard acceptsControl else { return }
            guard canControl else {
                pendingHaptics.append(.play(.commandBlocked))
                return
            }
            state.armMoving = true"""

VARIANTS = [
    (
        "connect clears E-stop",
        [
            (
                "case .connect:\n            state.markConnected()",
                "case .connect:\n            state.markConnected()\n            state.emergencyStop = false",
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
                "state.armMoving = false\n            pendingHaptics.append(.play(.emergencyLoop))",
                "pendingHaptics.append(.play(.emergencyLoop))",
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
                "pendingHaptics.append(.play(.emergencyLoop))\n            go(.s4)",
                "pendingHaptics.append(.play(.emergencyLoop))",
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
        "fix S6: losing the link stops the arm",
        [
            (
                "state.simulateHighLatency()\n",
                "state.simulateHighLatency()\n            state.armMoving = false\n",
            ),
            (
                "state.markDisconnected()\n",
                "state.markDisconnected()\n            state.armMoving = false\n",
            ),
        ],
        ["STALE S6"],
    ),
    (
        "fix S8 and U6: one buzz only",
        [
            (
                "pendingHaptics.append(.play(.emergencyLoop))",
                "if !state.emergencyStop { pendingHaptics.append(.play(.emergencyLoop)) }",
            ),
            (
                "state.emergencyStop = true\n            state.armMoving = false\n",
                "state.armMoving = false\n",
            ),
            (
                "go(.s4)\n        case .releaseStop",
                "state.emergencyStop = true\n            go(.s4)\n        case .releaseStop",
            ),
        ],
        ["STALE S8", "STALE U6"],
    ),
    (
        "fix U1: latency row keeps S4",
        [
            (
                "state.simulateHighLatency()\n            go(.p6)",
                "state.simulateHighLatency()\n            go(state.emergencyStop ? .s4 : .p6)",
            )
        ],
        ["STALE U1"],
    ),
    (
        "stop cancels before restarting the buzz",
        [
            (
                "pendingHaptics.append(.play(.emergencyLoop))",
                "pendingHaptics.append(.cancel)\n            pendingHaptics.append(.play(.emergencyLoop))",
            )
        ],
        ["STALE S8", "STALE U6"],
    ),
    (
        "first stop starts two buzzes in one step",
        [
            (
                "pendingHaptics.append(.play(.emergencyLoop))",
                "if !state.emergencyStop { pendingHaptics.append(.play(.emergencyLoop)); pendingHaptics.append(.play(.emergencyLoop)) }",
            ),
            (
                "state.emergencyStop = true\n            state.armMoving = false\n",
                "state.armMoving = false\n",
            ),
            (
                "go(.s4)\n        case .releaseStop",
                "state.emergencyStop = true\n            go(.s4)\n        case .releaseStop",
            ),
        ],
        ["KNOWN S8", "KNOWN U6"],
    ),
    (
        "recording tick on settings opens S4",
        [
            (
                "state.tickRecording()\n",
                "state.tickRecording()\n            if route == .s6 { go(.s4) }\n",
            )
        ],
        ["FAIL U2"],
    ),
]
MAP_VARIANTS = [("S5 loses STOP in the map", "s5", ",stop", ["FAIL U5"])]
FALLBACK_STRUCT = "struct FallbackControlScreen: View {"
SOURCE_VARIANTS = [
    (
        "S5 loses STOP in the source",
        "Screens/RecordingScreens.swift",
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
        path = core / SESSION
        text = path.read_text()
        for old, new in edits:
            if old not in text:
                sys.exit(
                    f"Variant '{label}' no longer applies: {old!r} not found. Update scripts/mutants.py."
                )
            text = text.replace(old, new, 1)
        path.write_text(text)
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
