# Teleop iOS app (App/ + Packages/ layout)

SwiftUI app (iOS 17+) for the phone-teleoperation thesis project. 20 Mockup v2 iOS screens (frame 402x874), fake state only. The Android counterpart lives in its own repository.

## Layout

```
project.yml                 XcodeGen spec (Teleop app, TeleopTests, TeleopUITests)
Packages/TeleopCore/        pure Swift package, no UI imports
  Sources/TeleopCore/         Route, BackStackRules, TeleopNavigator, FakeTeleopState,
                              HapticPattern, TeleopSession (actions -> state + navigation + haptics), TeleopLink
  Sources/TeleopServerModel/  a model of the simulator server, for tests (docs/TESTING.md)
  Sources/TeleopServerHost/   that model on a WebSocket at 127.0.0.1, for app and UI tests
App/Sources/                SwiftUI views, theme, Core Haptics controller, AppModel
App/Resources/              Localizable.xcstrings, InfoPlist.xcstrings
Tests/TeleopTests/          app unit tests, local-server tests, the scripted pick-and-place
Tests/TeleopUITests/        XCUITest that walks P1 -> ... -> S1 -> P5 and attaches screenshots
TestPlans/                  Default (everything but the live tests) and Live (only them)
scripts/check-strings.py    every string key used in views exists in the catalog, and none is unused
.github/workflows/ios.yml   macOS CI (source copy in ci/ios.yml)
```

## Build on a Mac

Requires Xcode 16+ and XcodeGen.

```bash
brew install xcodegen
xcodegen generate
open Teleop.xcodeproj
```

Choose an iPhone simulator (iPhone 16 Pro matches the 402x874 frame) and Run. Command line:

```bash
xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan Default \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO
```

The default plan needs no server: the app talks to a model of the simulator server on a local socket, and
nothing in it touches port 8765. The `Live` plan drives the lab simulator and is run only on purpose; see
`docs/TESTING.md` for every layer and how to run it.

Launch any screen directly with the argument `-startRoute s1_connect` (raw values are in `Route.swift`).

## Core tests

```bash
cd Packages/TeleopCore
swift test
```

The local socket host needs Network.framework, so its tests run only on a Mac.

## Navigation rules

Status chip -> P5. P5 "Change server" -> S1. S1 Back and Connect -> P5. S1 Disconnect -> S7. S7 Reconnect -> S1. Latency text appears only on P5 and P7.
