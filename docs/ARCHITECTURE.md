# Architecture

The app turns presses on an iPhone (the volume keys and on-screen controls) and the phone's own movement into
commands for a robot arm in a simulator, and turns the simulator's answers into vibrations, sounds and speech, so
the operator can work mostly without looking at the screen. This note says where each part lives and why it is
split that way. How the messages themselves work is in `docs/PROTOCOL.md`; how the tests are layered is in
`docs/TESTING.md`.

## The layers

| Layer | Where | What it may use | Built and tested by |
|---|---|---|---|
| Core | `Packages/TeleopCore/Sources/TeleopCore` | Foundation and `simd` only: no UI, no sockets, no clock | `swift test` |
| Server model | `Packages/TeleopCore/Sources/TeleopServerModel` | Foundation only | `swift test` |
| Socket host | `Packages/TeleopCore/Sources/TeleopServerHost` | the server model and Network.framework | `swift test` on a Mac |
| App | `App/Sources` | SwiftUI, ARKit, AVFoundation, Core Haptics, the core | Xcode |
| App tests | `Tests/TeleopTests` | the app, the core, the server model, the socket host | Xcode |
| UI tests | `Tests/TeleopUITests` | XCUITest, the server model, the socket host | Xcode |

The three package targets are one Swift package (`Packages/TeleopCore/Package.swift`). The Xcode project is
generated from `project.yml` with XcodeGen (`xcodegen generate`) and is not committed. Every app file that names a
core type needs `import TeleopCore`.

The reason for the split: everything that decides something lives in the core, where it runs in seconds without a
simulator or a phone, and the app target only connects it to the device.

### The core package

| Folder or file | What it is for |
|---|---|
| `TeleopSession.swift`, `FakeTeleopState.swift`, `Route.swift`, `TeleopNavigator.swift`, `BackStackRules.swift`, `HeldControls.swift` | The session: what the operator asked for (`TeleopAction`), the state the screens show, and which screen is up. The only place an action becomes a state change, a screen change or a haptic request. |
| `HapticPattern.swift` | The patterns the operator feels (`Haptic`), and the older requests the session still makes (`HapticCue`, `HapticCommand`). |
| `Link/` | `TeleopLink`, one conversation with the server: builds every message, reads every answer, and keeps the rules about holds, final acks and resets. `ServerState` reads a `state` message. |
| `Feedback/` | What the operator perceives. `FeedbackMonitor` turns link events and states into `FeedbackEvent`s; `CueTable` says how each event is felt, heard or spoken; `CueScheduler` decides which cue plays when two coincide. |
| `Recording/` | The server's recorder as the operator hears it. `RecorderNarrator` compares successive states and says what happened to each take; `StopExits` decides which ways out of an emergency stop to offer. |
| `Input/` | The rules for what a key press, a touch and the phone's rotation mean (`InputArbiter`, `SurfaceLayout`, `RotationMapper`, with every threshold in `InputConstants`). Nothing in the app uses them yet at this commit. |
| `Buttons/` | The buttons mode: a pad of hold buttons and the ramp that turns a held button into arm motion (`ButtonArbiter`, `ButtonRamp`, `ButtonPadLayout`). Not used by the app yet either. |

`FakeTeleopState` keeps its old name from the mock-up. It is the real UI state now: with `liveLink` set, the
connection, the latency and the emergency stop follow the server. With it off, the app runs a built-in demo with no
server, where every press succeeds at once.

### The server model and the socket host

`TeleopServerModel` is a deterministic model of the lab server: its message rules and a small simulated world (the
arm as a point, the cube, the goal, the table). It is only for tests. `TeleopServerHost.LocalTeleopServer` puts that
model behind a real WebSocket on 127.0.0.1, at a port the system picks, so app and UI tests can connect the real app
to it. `ServerModelConfig` holds every number the model uses, each with its source. `docs/TESTING.md` explains how
the model is kept honest against recordings of the real server.

### The app target

| Folder | What it is for |
|---|---|
| `TeleopApp.swift`, `AppModel.swift` | The app's entry point and its one model object. `AppModel` owns the session, the link controller, the cue player and the recorder narrator, and is what every screen talks to. |
| `Link/` | `LiveLinkController` (the sockets, the 30 Hz timer, the listening connection, the hand-to-arm mapping), `LinkTransport` (one WebSocket), and `Guidance.swift` (the robot profile, the task guide and the map layout). |
| `Screens/`, `Components/`, `Theme/` | SwiftUI screens, shared controls and colours. `RootView` picks the screen from `session.route`; there is no `NavigationStack`. |
| `VolumeKeys/` | The volume keys as hold controls (`VolumeKeyMapper` decides, `VolumeKeyInput` listens). |
| `Pose/` | `PoseTracker`: the phone's position from ARKit world tracking. It also keeps the camera in use, which iOS requires before it reports volume-key presses to the app. |
| `Haptics/`, `Audio/` | The players: Core Haptics patterns, the three sounds, and speech. They play what they are told and decide nothing. |
| `Input/` | `TouchSurfaceView`, a UIKit view that reports raw touches for the input rules. Not on any screen yet. |
| `Localization/`, `Permissions/` | The in-app language choice and the camera permission request. |
| `App/Resources/` | The string catalogs (`Localizable`, `Speech`, `Buttons`, `InfoPlist`), each in English and Traditional Chinese, and the app icon. |

## Pure logic takes time as an argument

Nothing in the core reads a clock. Code that needs the time is given it: `TeleopLink(send:now:)` takes a clock
closure, and `FeedbackMonitor`, `CueScheduler` and `RecorderNarrator` take the time in milliseconds on every call
(`observe(_:at:)`, `raise(_:at:currentHold:)`). The server model takes its time in seconds on every call and runs
everything due up to it. So a test can play ten seconds of conversation in a millisecond, and the same input always
gives the same output.

The app passes the real clock in (`AppModel(nowMs:)`, `LiveLinkController(nowMs:)`), and the device parts (haptics,
audio, the socket) sit behind small protocols (`HapticsPlaying`, `SoundPlaying`, `SpeechPlaying`, `LinkTransport`)
that tests replace. ARKit comes in as a closure that returns the phone's position (`AppModel(pose:)`).

## From a press to a message

How a held volume key moves the arm, at this commit:

1. iOS reports vol+ pressed. `VolumeKeyModifier` passes it to `VolumeKeyMapper`, which returns `.holdArmStart`. An
   on-screen hold control sends the same action through `ArmHoldModifier` in `Components/Buttons.swift`.
2. `AppModel.send` calls `TeleopSession.perform(.holdArmStart)`. The session decides: connected, not stopped, not
   blocked by a slow link? Then `state.armMoving` becomes true, and any gripper or wrist hold ends, because the
   server runs one hold at a time. Otherwise the press is refused, and the operator hears why.
3. `AppModel.driveLink` compares the state before and after and mirrors the change onto the link: the arm started
   moving, so it calls `LiveLinkController.startHold`. The session decides; the link only follows. If the link
   cannot start (no tracked phone position, the phone held wrong, a reset pending), the app ends the hold in the
   session again and the operator hears why.
4. `LiveLinkController.startHold` notes where the phone is and calls `TeleopLink.poseStart`, which builds the
   `pose_start` message and hands the text to `WebSocketTransport.send`.
5. A timer ticks 30 times a second (`LiveLinkController.tick`). On each tick it reads the phone's position from
   `PoseTracker`, smooths and scales the movement since the press, turns it into the server's axes, and sends a
   `pose_update`. The same tick sends keepalives during a gripper hold, the rotation during a wrist hold, a probe
   twice a second, and a scene reset that has waited long enough.
6. Releasing the key sends `.holdArmEnd`; the session sets `armMoving` false, and `driveLink` calls `endHold`, which
   sends `pose_stop`.

The gripper (`gripperStart`, `gripperEnd`) and the wrist (`turnStart`, `turnEnd`) take the same path.

## From the server's answer to something felt or heard

1. `WebSocketTransport` delivers each text frame on the main queue to `LiveLinkController.handle` (control
   connection) or `handleObserver` (listening connection).
2. `TeleopLink.receive` reads it and returns a `LinkEvent`: the link came up, a new `state`, a refusal, the end of a
   hold, a round-trip time, a reset done or refused.
3. `LiveLinkController` acts on it three ways:
   - What changes the session goes back to `AppModel` as a `TeleopAction`: `linkUp`, `linkLost`, `linkLatency`, a
     server emergency stop (`stop`), a hold the server ended (`holdArmEnd`, `gripperEnd`, `turnEnd`).
   - Every `state`, from either connection, goes to `FeedbackMonitor` and then to `AppModel.stateArrived`, which
     hands it to `RecorderNarrator`.
   - Refusals and hold ends go to `FeedbackMonitor`, which knows which hold the operator has engaged.
4. `FeedbackMonitor` and `RecorderNarrator` return `FeedbackEvent`s: the hold is live, the press was refused, as
   far as it goes, the jaws closed on something, the hold was ended for you, emergency stop, link lost, a take saved
   or discarded. `AppModel.raise` passes each to the `CuePlayer`.
5. `CuePlayer` asks `CueScheduler` what to play now. The scheduler looks the event up in `CueTable` and resolves
   collisions: one haptic channel with a fixed priority, one voice with levels, sounds at once. It returns outputs,
   and `CuePlayer` gives them to `HapticsController`, `SoundPlayer` and `SpeechPlayer`.

The session's own haptic requests (`HapticCommand`, for example the STOP buzz) take a detour: `AppModel.feedback`
turns them into `FeedbackEvent`s, or drops the ones another event already covers, so everything the operator feels
goes through the one scheduler.

## The session state and the safety checker

`TeleopSession` is a value type: the state, the screen stack and the pending haptic requests, changed only by
`perform(_:)`. That makes it small enough to check exhaustively.

The safety checker in `.cursor/skills/verify-session-safety/` imports the real `TeleopCore`, starts from every way
the app can open, and tries every action in every reachable state. It then checks a list of promises, for example:
the emergency stop stays latched until it is released on purpose; the arm moves only while connected, not stopped
and not blocked by a slow link; releasing a control always stops it; at most one hold is active; every screen but
the stop screen offers STOP. One set of promises (S) must hold for any sequence of actions; another (U) for the
actions the shipped screens can actually send, which `ui-map.tsv` lists per screen. Its `SKILL.md` lists every
promise and what is left out (the wire, gesture timing, real haptics).

Run it from the repository root:

    .cursor/skills/verify-session-safety/scripts/check.sh

It needs `swift` and `python3`. Exit 0 means every promise holds (or is a listed known finding), 1 a new violation,
a stale known finding or drift between the checker's tables and the code, 2 that `swift` is missing (a skip, not a
pass). For a violation it prints the shortest sequence of actions from launch that breaks the promise.

It must be updated, before the change counts as safe:

- when a `TeleopAction` is added: add it to the checker's action table and, if a screen sends it, to `ui-map.tsv`;
- when a stored field is added to `FakeTeleopState`: add it to the checker's state key, or to its list of fields
  no action changes;
- when a screen gains or loses a control that sends an action: update its row in `ui-map.tsv`;
- when a covered file changes (`check.sh` prints `REVIEW` for each): read the change, confirm the checker still
  describes the code, and move the sync commit in `SKILL.md`.

`drift.py`, run by `check.sh`, fails when one of the first three is forgotten. `SKILL.md` has the full procedure,
including how to prove the checker can still fail after it was changed.

A `REVIEW` line is a reminder, not a failure: the run still exits 0 if every promise holds. It lists each covered
file that differs from the sync commit named in `SKILL.md` (uncommitted changes included), and it names files that
have since been deleted as well. At this commit the sync commit is `4d86bab`, older than much of the app, so a clean
checkout prints about twenty `REVIEW` lines, among them screens that no longer exist (`ErrorsScreen.swift`,
`ModeSelectScreen.swift`, `RecordingScreens.swift`, `CloudCheckScreens.swift`). That is a review not done yet, not
a broken check. Whoever does it reads those changes, confirms the checker still describes the code, and moves the
sync commit; until then, look only at the `REVIEW` lines for files your own change touched.

## Where robot and task numbers live

What the app must know about one robot setup is in `RobotProfile` (`App/Sources/Link/Guidance.swift`): the offset
from the point the server reports to where the jaws pinch, where the robot base sits in the world frame, how close
the jaws must be to grasp, the cube's size, the jaw angles that count as fully open and as closed on nothing, and
whether the scene starts with the jaws side by side. `RobotProfile.so101Simulator` is the one profile today, and
nothing outside it should name the cube or the arm.

The server model has its own copy of the same measurements in `ServerModelConfig`.
`Tests/TeleopTests/ServerModelProfileTests.swift` fails when the two disagree, so re-measuring one forces the other.

A few numbers that come from the server's rules rather than from the robot still sit next to the code that uses
them: the 8 cm cap per server hold, the turn and tilt steps and speeds (`LiveLinkController`), the ranges the server
accepts for `pose_start` (`PoseParams` in `TeleopLink.swift`), and the guide's holding radius and goal size
(`Guidance`). The input rules keep every threshold in `InputConstants`; its two sign fields are robot numbers that
the robot profile's owner passes in.
