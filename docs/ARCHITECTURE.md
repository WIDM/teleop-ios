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
- Control actions that move hardware (`toggleGripper`) are gated by `TeleopSession.canControl`: connected, not E-stopped, commands not blocked by latency.
- There is no connection layer yet: `FakeTeleopState` stands in for it. A real transport will replace the state mutations inside `perform` and keep the action vocabulary.

## Where S1 -> P5 navigation lives

1. The S1 Connect button (`App/Sources/Screens/ConnectScreen.swift`, identifier `connect.connect`) sends `.connect`.
2. `TeleopSession.perform(.connect)` calls `state.markConnected()` and `go(.p5)` (`Packages/TeleopCore/Sources/TeleopCore/TeleopSession.swift`).
3. S1 Back sends `.s1Back` -> `go(.p5)`; system back resolves through `BackStackRules.previous(of: .s1) == .p5`.
4. P5 -> S1 is `.changeServer`; any status chip is `.openConnection` -> P5; S1 Disconnect is `.disconnect` -> S7; S7 Reconnect is `.reconnect` -> S1.

Tests: `S1ConnectFlowTests`, `BackStackRulesTests`, `TeleopSessionTests` in `Packages/TeleopCore/Tests`.

## Strings

All user-visible text lives in `App/Resources/Localizable.xcstrings` (English only). `scripts/check-strings.py` fails if a key used in a view is missing from the catalog or a catalog key is unused.
