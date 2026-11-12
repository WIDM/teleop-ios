# Teleop iOS

An iPhone app that drives a robot arm, an SO-101 in Isaac Sim, through a teleoperation server on the network. It is
made to be used mostly without looking at the screen: the volume keys, a thumb on the glass and the phone's own
movement move the arm, the wrist and the jaws, and vibrations, sounds and speech say what happened. It shows what
the server's recorder is doing, and it has a practice mode that needs no robot. The Android app lives in its own
repository.

## What it needs

- An iPhone with iOS 17 or later that supports ARKit world tracking. The volume keys work from iOS 17.2.
- Camera access: ARKit tracks the phone with it, and iOS reports the volume keys only while the camera is in use.
- A server on the same network that speaks the protocol in `docs/PROTOCOL.md`, at `host:port` (the port defaults to
  8765). Without one, practice still works.
- To build: a Mac with Xcode 16 or later and XcodeGen.

## Build, run and test

```bash
brew install xcodegen
xcodegen generate            # after any change to project.yml or to the list of source files
open Teleop.xcodeproj
```

Run on an iPhone simulator or a phone (`docs/RELEASING.md` says how to install on a phone). A simulator has neither
a camera nor volume keys: there the phone modes cannot move the arm, and the buttons mode can.

```bash
(cd Packages/TeleopCore && swift test)        # the core, in about half a minute, no simulator
xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan Default \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO
```

Any available iPhone simulator will do. The default plan needs no server: the tests that need one start a model of
it on a local socket. The `Live` plan drives the real simulator and is run only on purpose.

## Where things are

| Path | What it is |
|---|---|
| `App/` | the SwiftUI app: the operating screen, Connect, Settings, the tutorial, the link, the players |
| `Packages/TeleopCore/` | the pure logic (session, link, input rules, feedback), a model of the server, and its socket host |
| `Tests/` | app tests, the scripted operator, UI tests |
| `scripts/` | the string and button checks, and tools for the live server |
| `docs/ARCHITECTURE.md` | how the app is put together |
| `docs/PROTOCOL.md` | every message between the app and the server |
| `docs/TESTING.md` | the test layers and how to run each |
| `docs/RELEASING.md` | how a version is cut and installed |
| `CHANGELOG.md`, `STATUS.md` | what each version changed; what works and what does not |
