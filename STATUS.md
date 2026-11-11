# iOS app v1 skeleton (App/ + Packages/ layout): status

## Done

All 20 routes have a SwiftUI screen: P1, P2, P3, P4, P5, P6, P7, T1, T2, T3, S1, S2, S3a, S3b, S3m, S4, S5, S5a, S6, S7.

- S1 to P5 flow finished first: screens, nav rules, `TeleopSession` actions and 11 flow tests (chip -> P5, Change server -> S1, Connect/Back/chip -> P5, Disconnect -> S7, Reconnect/Back to connect -> S1, every step is a declared forward edge).
- `TeleopCore`: 49 XCTest cases pass on Linux with Swift 6.0.3 and 6.4.2 (`TEST-RESULT.txt`).
- 4 haptic patterns (1, 2, 3 short; long repeating) defined in Core, played by Core Haptics (`HapticsController`); STOP starts the loop, release cancels it, the start of a gripper close or open plays 1 or 2 short.
- Strings: 105 keys in `Localizable.xcstrings`, English only, `scripts/check-strings.py` passes. Camera and motion usage text in `InfoPlist.xcstrings`.
- Colours follow visual-spec v1.14: STOP solid red with yellow border; recording `#0F172A` with blinking white dot; error cards amber border; red only on STOP, e-stop, S7 lost connection.
- STOP release (S4) and Discard (S3b) need a 1 second hold, with a fill bar.
- `.github/workflows/ios.yml`: string check, core tests, XcodeGen, `xcodebuild test` on an iPhone simulator, screenshots of P1 to P5/S1/S7 from the UI test (exported from the xcresult), artifacts: xcodebuild log, screenshots, xcresult.

## Real server link

Settings > Real server (off by default) swaps the built-in demo for a WebSocket to the teleop server (hold protocol, envelope v1).

- S1 takes the address (`host:port`, default port 8765). `hello`, then `welcome` and a first `state`, mark the session connected.
- Holding vol+ or the hold pad sends `pose_start`, then the phone's ARKit offset from the start of the hold at 30 Hz as `pose_update` (translation mode), then `pose_stop`. The hold ends on release, lost tracking, moving faster than 0.8 m/s, backgrounding, a rejected start, E-stop or a lost link.
- STOP sends `estop`, release sends `estop_reset`, Reset sends `reset_scene`. Holding vol− (close) or the Open handle sends `gripper_jog_start` with `jog_keepalive` every 133 ms, and `gripper_jog_stop` on release. The one-shot `gripper` message is not used: in Isaac Sim it blocked every other command for about 30 s.
- A server E-stop latches the app on S4. A closed socket, or 2 s with no message at all, marks the link lost (the server is quiet during a hold, so the app's twice-a-second `test` echo is the heartbeat): S7 from a control screen, S4 stays if latched.
- Round trip is measured twice a second with `test`; 400 ms or more blocks commands (P6).
- Checked on the simulator against a model of the server on a local socket (`LocalServerTests`, and the scripted pick-and-place in `LocalPickAndPlaceTests`); see `docs/TESTING.md`.

Not checked yet: the phone itself driving Isaac Sim, and whether ARKit axes match the WebXR axes the server was calibrated for. Sensitivity and smoothing are applied in the app to the phone offset, because the server ignores them in translation mode; deadband is in degrees and has no effect on translation.

Checked by script against Isaac Sim (thomas-s4, 2026-11-10): connect, a 3 s hold, E-stop and release, scene reset, gripper jog open and close.

## Tools

- `scripts/analyze_holds.py --host user@host` reads the server's run log and network log and prints one row per hold (asked, arm moved, share reached, arm speed, edge hits, what ended it), then rule-of-thumb suggestions for sensitivity and smoothing. `--since HH:MM` limits it to later holds. Tests: `python3 -m unittest scripts/test_analyze_holds.py`.

## Not done

- Icons are SF Symbols, not Material Symbols Rounded.
- No Liquid Glass (target is iOS 17); solid surfaces only.
- Hold-to-release shows a fill bar, not the ring from visual-spec.
- No swipe-back gesture; navigation is a custom stack driven by `BackStackRules`.
- P7 uses the system keyboard, not the shared mock keyboard component.
- Left/right arm switch, cloud banner and latency dot from visual-spec v1.5 are not in the Android reference, so not built.
- Camera and motion prompts are shown from S2, and a denial has no follow-up screen.
- Volume keys: Camera Control and the Action button also arrive as vol−, since capture events do not name the button.
- Figma could not be read (MCP needs authorization); screens follow the PNG shots and the Android code.

## Only verifiable on a Mac

- The SwiftUI target has never been compiled: Linux has no SwiftUI. Only syntax parsing (`swiftc -parse`) was run on every app and test file. Expect small type-check fixes on first build.
- `xcodegen generate` and Xcode build.
- `TeleopTests`, `TeleopUITests` and the screenshot export step in CI.
- Layout on the 402x874 frame; keyboard behaviour on P7; hold gestures.
- Core Haptics feel on a real iPhone (the simulator has no haptic engine).

## Note on the shared directory

