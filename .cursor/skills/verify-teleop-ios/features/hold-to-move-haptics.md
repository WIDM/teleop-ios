# F4 Hold-to-move and haptic patterns

Holding vol+ moves the arm and releasing stops it; vol- toggles the gripper; haptics confirm state without looking.

## Sub-features

- F4.a vol+ down -> moving; vol+ up -> stop immediately.
- F4.b vol- toggles gripper: close = 1 short pulse, open = 2 short pulses.
- F4.c Blocked command = 3 short pulses.
- F4.d Short pulse 60 ms on / 120 ms gap; long buzz 400/200 repeating only for E-stop, disconnect, 750 ms watchdog.
- F4.e S5 screen fallback: on-screen hold area behaves like vol+.

## How to get to it (user POV)

- From P4 Standby / S3m Teleop press the volume keys; S5 fallback via `standby.fallback`.

## Driving it with XCUITest / swift test

Preconditions: baseline, connected, not E-stopped.

- Logic: `swift test --filter HapticPatternTests` (timings) and `TeleopSessionTests` (`.toggleGripper` drains `.play(.gripperClosed)` then `.play(.gripperOpened)`).
- UI: volume keys cannot be pressed by XCUITest; on CI only S5 fallback (`fallback.toggle`) is drivable. Real vol+/vol- needs a physical iPhone.

## Gotchas

- TeleopCore currently has no vol+ hold/release action and no 750 ms watchdog; F4.a and the watchdog part of F4.d are NOT verifiable yet. Report as gap, not PASS.
- Simulator has no haptic engine; haptic proof is the command list, not feel.
