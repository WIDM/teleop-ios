# F5 STOP / E-stop reachability

The red STOP control is visible and tappable on every teleop screen; tapping it goes to S4 E-stopped with the long-buzz loop; Release (hold) returns to teleop. Red appears only on STOP, S4 and S7.

## Sub-features

- F5.a `stop` exists and is hittable on P4, S3a, S3m, S5, S5a, S7.
- F5.b STOP -> S4, plays `.emergencyLoop`.
- F5.c S4 Release (hold 1 s) -> back, cancels the loop.
- F5.d No other red element on any of the 20 pages.

## How to get to it (user POV)

- Any teleop screen -> STOP.

## Driving it with XCUITest / swift test

Preconditions: baseline, connected.

- Logic: `swift test --filter TeleopSessionTests` -> `.stop` asserts `.s4` and drained `.play(.emergencyLoop)`; `.releaseStop` asserts `.cancel`.
- UI: on each listed screen assert `app.buttons["stop"].isHittable`, tap it, expect `stop.release`, shot `NN-S4-estopped`.
- Red check: in the Figma compare side-by-sides, review red only on STOP/S4/S7.

## Gotchas

- Current UI test does not tap STOP; F5 is logic-only until a UI test is added.
- A STOP hidden under the keyboard on P7 is a FAIL.
