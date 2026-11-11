# Architecture

## Module split

| Module | Path | Depends on | Runs on Linux |
|---|---|---|---|
| `TeleopCore` | `Packages/TeleopCore` | Foundation only (no UI imports) | yes (`swift test`) |
| `Teleop` (app target) | `App/Sources` | SwiftUI, Observation, Core Haptics, `TeleopCore` | no (needs Xcode) |
| `TeleopTests` | `Tests/TeleopTests` | `Teleop`, `TeleopCore` | no |
| `TeleopUITests` | `Tests/TeleopUITests` | XCUITest | no |

`project.yml` (XcodeGen) generates `Teleop.xcodeproj`; the project file is not committed.
Every app file that mentions a `TeleopCore` type or `model.session` must `import TeleopCore`; Linux cannot compile the app target, so this is only caught on macOS CI.

## Data flow

```
Screen (SwiftUI view)
   | model.send(TeleopAction)
   v
AppModel (@Observable, App/Sources/AppModel.swift)
   | session.perform(action)           | for cmd in session.drainHaptics()
   v                                   v
TeleopSession (TeleopCore)         HapticsController (Core Haptics)
   |-- FakeTeleopState  (mutated in place, no networking)
   |-- TeleopNavigator  (route stack; BackStackRules gives Back targets)
   '-- pendingHaptics   ([HapticCommand], drained by AppModel)
```

- Screens never mutate navigation directly. They raise a `TeleopAction` (`connect`, `stop`, `openConnection`, ...).
- `TeleopSession.perform(_:)` is the only place where an action becomes a state change, a route change and a haptic cue.
- `RootView` switches on `model.session.route` and picks the screen. There is no `NavigationStack`.
- Control actions that move hardware (`gripperStart`, `turnStart`, `holdArmStart`) are gated by `TeleopSession.canControl`: connected, not E-stopped, commands not blocked by latency.
- Arm hold has one path: vol+ and the on-screen hold areas (S5, S5a) both raise `holdArmStart` on press and `holdArmEnd` on release; `FakeTeleopState.armMoving` is the result. Release always stops; E-stop clears it. The on-screen side is the `armHold(model:)` modifier in `Components/Buttons.swift`. It uses `@GestureState`, so a cancelled gesture (call, Control Center) also sends `holdArmEnd`; `RootView` additionally sends `holdArmEnd` whenever `scenePhase` leaves `.active` while the arm is moving, and the modifier sends it on disappear. The hold area exposes `moving` / `stopped` as its accessibility value.
- Refused control input (`gripperStart`, `holdArmStart`) emits `.commandBlocked` (3 short) while connected and not E-stopped. While E-stopped or disconnected input is ignored silently. Moving the gripper while the arm is held is refused too (haptics-v1 H8). The gripper moves only between `gripperStart` and `gripperEnd`; starting an arm hold ends it, because the server runs one held control at a time. The jaw turn works the same way between `turnStart` and `turnEnd`: starting an arm hold or a gripper hold ends it, starting a turn ends a gripper hold, and a turn is refused while the arm is held. One press turns the jaws by up to 45 degrees from where they were when it began (the server's target is the joint angle at the start of the hold plus the roll asked for), so the sideways jaws a grasp needs take two presses. The same control also tilts the wrist (`tiltDown`, `tiltUp`: rotation about x in `orient_update`, 15 degrees per second to a 10 degree step); only one axis is ever sent. A tilt moves the jaw tips away from where the guide measured them, so `LiveLinkController.wristTilted` stays set until a scene reset or a new connection and the guide shows a caption instead of ready-to-grasp. The guide draws two views that share a scale and a left-right axis: from above, and from behind with the height gap between the jaw tips and the cube (`MiniMapLayout`). The app cannot show the wrist angle because the server does not report it.
- E-stop release emits `cancel` (ends the long buzz) then `.stopReleased` (1 short, haptics-v1 H15).
- Deadband and smoothing live in `FakeTeleopState` (`deadbandDegrees`, `smoothing`, clamped setters), next to `sensitivity`, so S6 shows the same values after leaving and re-entering. They are in memory only, not written to disk.
- P4/P6 prototype shortcuts (simulate latency, on-screen controls) are in a debug sheet, opened by holding the mode pill for 1 second. They are not part of the Figma layout. The sheet carries its own STOP (`StopButton` with accessibility id `stop.debug`; it latches E-stop and dismisses the sheet). The under-sheet STOP is hidden while the sheet is up so XCUITest hits the reachable control.
- There is no connection layer yet: `FakeTeleopState` stands in for it. A real transport will replace the state mutations inside `perform` and keep the action vocabulary.

## Where S1 -> P5 navigation lives

1. The S1 Connect button (`App/Sources/Screens/ConnectScreen.swift`, identifier `connect.connect`) sends `.connect`.
2. `TeleopSession.perform(.connect)` calls `state.markConnected()` and `go(.p5)` (`Packages/TeleopCore/Sources/TeleopCore/TeleopSession.swift`).
3. S1 Back sends `.s1Back` -> `go(.p5)`; system back resolves through `BackStackRules.previous(of: .s1) == .p5`.
4. P5 Close (`.closeConnection`) returns to the screen that opened P5; while E-stop is latched it always returns to S4, and with no origin it returns to P4.
5. P5 -> S1 is `.changeServer`; any status chip is `.openConnection` -> P5; S1 Disconnect is `.disconnect` -> S7; S7 Reconnect is `.reconnect` -> S1.

Tests: `S1ConnectFlowTests`, `BackStackRulesTests`, `TeleopSessionTests` in `Packages/TeleopCore/Tests`.

## Strings

All user-visible text lives in `App/Resources/Localizable.xcstrings` (English only). `scripts/check-strings.py` fails if a key used in a view is missing from the catalog or a catalog key is unused.
