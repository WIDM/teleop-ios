---
name: verify-teleop-ios
description: Verify the Teleop iOS app (WIDM/teleop-ios, SwiftUI, 20 Mockup v2 screens) - the phone volume-key teleoperation app. Use before claiming any PR PASS: runs TeleopCore logic tests (swift test), fetches macOS CI xcodebuild results and simulator screenshots, compares each screen page-by-page with the Figma frames, and checks the repo is English-only.
---

# verify-teleop-ios

What the app is: a phone app that teleoperates a robot arm. Hold vol+ to move, release to stop; hold vol- to close the gripper and hold the left edge of the camera view to open it (it moves only while held); haptics report state (haptics-v1 H1-H15: short pulse 60 ms on / 120 ms gap, 1-3 pulses; long buzz 400 on / 200 off reserved for E-stop, disconnect and the 750 ms watchdog). STOP is reachable on every teleop screen; red is used only for STOP, E-stop (S4) and the lost-connection line on S1. All UI text is English. Current build is fake-state only (no robot link).

Sources of truth: Figma `inLwADDDptRo8qIw34DRqP`, page Mockup v2 `121:134`, the iOS frames at 402x874 that the app still has (`scripts/frames.tsv`); per-page acceptance points in `docs/figma-map.md` (owned by the planner, do not edit here); navigation per visual spec v1.14: every status chip -> P5, S1 Connect -> P5, S1 Back -> P5, S1 Disconnect stays on S1, P5 Change server -> S1; a fresh install opens on S2, later launches on P4.

Repo layout: `Packages/TeleopCore` (pure Swift: Route, TeleopSession, HapticPattern; runs on Linux), `App/Sources` (SwiftUI), `Tests/TeleopUITests/ConnectFlowScreenshotTests.swift` (XCUITest that attaches named screenshots like `06-S1-connect`), `ci/ios.yml` -> `.github/workflows/ios.yml`.

Two paths. Pick by host: Linux/no Xcode -> local path (logic only). UI, layout, screenshots -> CI path. Never claim a UI PASS from the local path.

All helpers are in `scripts/` relative to this file. Set `RUN_ID` once per run so evidence lands in one folder:

    export RUN_ID=$(date +%Y%m%d-%H%M%S); V=.cursor/skills/verify-teleop-ios/scripts

## Launch

Local: nothing long-running. `swift test` builds TeleopCore into `$SCRATCH` (`/tmp/verify-teleop-ios-$RUN_ID`).

    $V/run-core-tests.sh        # exit 0 pass, 1 fail, 2 = swift not installed (SKIP, not PASS)

Mac with Xcode (optional local UI): `xcodegen generate && xcodebuild test -project Teleop.xcodeproj -scheme Teleop -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -resultBundlePath $SCRATCH/Teleop.xcresult CODE_SIGNING_ALLOWED=NO`. Any screen can be opened directly with launch argument `-startRoute <raw>` (raw values in `frames.tsv` column 4).

CI: push the branch / open the PR; workflow `ios` (macos-15) runs check-strings, swift test, xcodegen, `xcodebuild test`, exports XCUITest attachments, uploads artifacts `xcodebuild-log`, `screenshots`, `xcresult`. Ready = run conclusion is set.

    $V/fetch-ci.sh [run-id]     # waits for the run, downloads artifacts to $EVIDENCE/ci/

## Doctor

Read-only. Run first and whenever anything looks off.

    $V/doctor.sh local          # package present, Pillow/numpy, swift on PATH
    $V/doctor.sh ci             # gh auth, repo reachable, .github/workflows/ios.yml pushed

Known blocker: pushing `.github/workflows/` needs the gh `workflow` scope, which only the owner can grant. Until then doctor ci FAILs and the CI path is unavailable; report it, do not work around it.

## Drive

- Logic: TeleopCore tests drive `TeleopSession.perform(_:)` with the real actions (`connect`, `s1Back`, `disconnect`, `stop`, `releaseStop`, `gripperStart`, `gripperEnd`, ...) and assert route + drained haptics. Feature files list which test covers which behavior.
- UI: XCUITest via accessibility identifiers (stable handles; never coordinates): `status.chip`, `connection.change_server`, `connect.connect`, `connect.back`, `connect.disconnect`, `stop`, `stop.release`, `permissions.continue`, `tutorial.skip`, `standby.settings`. Screenshot names must contain the screen id token (`NN-<ID>-slug`) so the compare helper can pair them.
- Figma page compare: export frames read-only (see `scripts/export-figma.md`) into `$EVIDENCE/figma/<ID>.png`, then

      $V/figma-compare.py --figma $EVIDENCE/figma --shots $EVIDENCE/ci/artifacts/screenshots --out $EVIDENCE/compare [--only S1,P5] [--threshold 0.10]

  Writes `<ID>-side-by-side.png` (Figma | simulator | diff heatmap), `report.json`, `report.md`. Score = fraction of pixels with channel delta > 32 after scaling the shot to 402x874. Status-bar time/battery always differ; treat a score as a pointer to look, then read the side-by-side against `docs/figma-map.md` acceptance points. MISSING means no screenshot for that screen yet; it is not a PASS.
- English rule:

      $V/check-english.sh origin/main [pr-number]   # any CJK in commits, PR title/body, tracked files or file names = FAIL

## Evidence

Everything goes to `$EVIDENCE_ROOT/$RUN_ID` (default `~/teleop-ios-evidence/<RUN_ID>`, outside the repo): `core/swift-test.log`, `core/result.txt`, `ci/run.json`, `ci/artifacts/{xcodebuild-log,screenshots,xcresult}`, `figma/<ID>.png`, `compare/*`, `english/*`.

Proof standards: drive the real user path (identifiers / session actions), not internal setters; for navigation capture the screen before the tap and after; for haptics assert the drained `HapticCommand` sequence and timings, not just that "something played"; a PASS names the head SHA, the run id and the feature ids covered. A SKIP (no swift, no CI) is reported as SKIP with the reason, never as PASS. The `-startRoute` argument is for page-compare screenshots only, never as proof of navigation.

## Cleanup

    RUN_ID=$RUN_ID $V/cleanup.sh [--sim <udid-you-created>]

Removes only `/tmp/verify-teleop-ios-$RUN_ID` and a simulator you created; never kills by process name; never deletes evidence; prints the kept evidence path and file count (FAIL if gone). CI runners are ephemeral; artifacts expire per repo retention, so the downloaded copy in evidence is the record.

## Feature map

See `features/README.md`. Maintain it with `/maintain-verification-skill` when screens or rules change.
