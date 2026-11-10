# iOS app v1 skeleton (App/ + Packages/ layout): status

## Done

All 20 routes have a SwiftUI screen: P1, P2, P3, P4, P5, P6, P7, T1, T2, T3, S1, S2, S3a, S3b, S3m, S4, S5, S5a, S6, S7.

- S1 to P5 flow finished first: screens, nav rules, `TeleopSession` actions and 11 flow tests (chip -> P5, Change server -> S1, Connect/Back/chip -> P5, Disconnect -> S7, Reconnect/Back to connect -> S1, every step is a declared forward edge).
- `TeleopCore`: 49 XCTest cases pass on Linux with Swift 6.0.3 and 6.4.2 (`TEST-RESULT.txt`).
- 4 haptic patterns (1, 2, 3 short; long repeating) defined in Core, played by Core Haptics (`HapticsController`); STOP starts the loop, release cancels it, gripper toggle plays 1 or 2 short.
- Strings: 105 keys in `Localizable.xcstrings`, English only, `scripts/check-strings.py` passes. Camera and motion usage text in `InfoPlist.xcstrings`.
- Colours follow visual-spec v1.14: STOP solid red with yellow border; recording `#0F172A` with blinking white dot; error cards amber border; red only on STOP, e-stop, S7 lost connection.
- STOP release (S4) and Discard (S3b) need a 1 second hold, with a fill bar.
- `.github/workflows/ios.yml`: string check, core tests, XcodeGen, `xcodebuild test` on an iPhone simulator, screenshots of P1 to P5/S1/S7 from the UI test (exported from the xcresult), artifacts: xcodebuild log, screenshots, xcresult.

## Not done

- Icons are SF Symbols, not Material Symbols Rounded.
- No Liquid Glass (target is iOS 17); solid surfaces only.
- Hold-to-release shows a fill bar, not the ring from visual-spec.
- No swipe-back gesture; navigation is a custom stack driven by `BackStackRules`.
- P7 uses the system keyboard, not the shared mock keyboard component.
- Left/right arm switch, cloud banner and latency dot from visual-spec v1.5 are not in the Android reference, so not built.
- Camera and motion prompts are shown from S2, and a denial has no follow-up screen.
- ARKit world tracking runs on control screens (P4, P6, S3a, S3m, S5, S5a); each hold logs how far the phone moved (developer mode). Pose is not sent anywhere until the real link exists.
- Volume keys: Camera Control and the Action button also arrive as vol−, since capture events do not name the button.
- Figma could not be read (MCP needs authorization); screens follow the PNG shots and the Android code.

## Only verifiable on a Mac

- The SwiftUI target has never been compiled: Linux has no SwiftUI. Only syntax parsing (`swiftc -parse`) was run on every app and test file. Expect small type-check fixes on first build.
- `xcodegen generate` and Xcode build.
- `TeleopTests`, `TeleopUITests` and the screenshot export step in CI.
- Layout on the 402x874 frame; keyboard behaviour on P7; hold gestures.
- Core Haptics feel on a real iPhone (the simulator has no haptic engine).

## Note on the shared directory

