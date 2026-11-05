# Teleop iOS app (App/ + Packages/ layout)

SwiftUI app (iOS 17+) for the phone-teleoperation thesis project. 20 Mockup v2 iOS screens (frame 402x874), fake state only. The Android counterpart lives in its own repository.

## Layout

```
project.yml                 XcodeGen spec (Teleop app, TeleopTests, TeleopUITests)
Packages/TeleopCore/        pure Swift package, no UI imports; `swift test` runs on Linux
  Sources/TeleopCore/         Route, BackStackRules, TeleopNavigator, FakeTeleopState,
                              HapticPattern, TeleopSession (actions -> state + navigation + haptics)
App/Sources/                SwiftUI views, theme, Core Haptics controller, AppModel
App/Resources/              Localizable.xcstrings, InfoPlist.xcstrings
Tests/TeleopTests/          app unit tests
Tests/TeleopUITests/        XCUITest that walks P1 -> ... -> S1 -> P5 and attaches screenshots
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
xcodebuild test -project Teleop.xcodeproj -scheme Teleop \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO
```

Launch any screen directly with the argument `-startRoute s1_connect` (raw values are in `Route.swift`).

## Core tests (Linux or Mac)

```bash
cd Packages/TeleopCore
swift test
```

## Navigation rules

Status chip -> P5. P5 "Change server" -> S1. S1 Back and Connect -> P5. S1 Disconnect -> S7. S7 Reconnect -> S1. Latency text appears only on P5 and P7.
