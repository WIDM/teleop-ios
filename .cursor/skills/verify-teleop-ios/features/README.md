# Teleop iOS verification map

Maintained source for verifying user-facing behavior of the Teleop iOS app. Read this index, then use the matching feature file.

## Baseline preconditions

- Checkout of WIDM/teleop-ios at the SHA under test; `scripts/doctor.sh local` or `ci` passes for the path you use.
- `export RUN_ID=...` set once; evidence in `~/teleop-ios-evidence/$RUN_ID`.
- App starts at P1 with fake state (Not connected, gripper open, no E-stop) unless a recipe says otherwise.
- Per-page acceptance points: `docs/figma-map.md`. Navigation: visual spec v1.14.

## Driving conventions

- Logic: `TeleopSession.perform(action)` through the TeleopCore tests (`swift test`).
- UI: XCUITest by accessibility identifier; screenshots named `NN-<SCREEN_ID>-slug`.
- Never use `-startRoute` to prove navigation; only to frame a page for Figma compare.

## Proof and skip reporting

- Record feature id, entry point, head SHA, run id with every artifact.
- Navigation proof = screenshot before and after each tap plus the assertion line in the log.
- Haptics proof = drained `HapticCommand` list with timings from `HapticPattern`.
- No swift / no CI = SKIP with the reason; never report a skipped path as verified via another.

## Features

| id | file | covers |
|---|---|---|
| F1 | connect-to-p5.md | S1 Connect and Back return to P5 |
| F2 | status-chip-to-p5.md | Every status chip opens P5 |
| F3 | disconnect-reconnect.md | S1 Disconnect -> S7 -> Reconnect -> S1 |
| F4 | hold-to-move-haptics.md | vol+ hold/release, vol- gripper, haptic patterns |
| F5 | stop-reachability.md | STOP/E-stop always reachable, red only for STOP/S4/S7 |
