# Testing

The app drives a robot arm in a simulator on a lab machine that is slow, shared and out of reach of CI. So most
tests run against a model of that simulator's server instead (`TeleopServerModel`), and the model is itself
checked against recordings of the real server. Only the live layer touches the real one.

All commands below run from the repository root unless they say otherwise.

## The layers

Each layer catches a different kind of mistake. Lower layers are fast and exact; higher ones are slower and closer
to the real thing.

| Layer | Where | What it can catch | What it cannot catch |
|---|---|---|---|
| Core | `Packages/TeleopCore/Tests/TeleopCoreTests` | a wrong rule in the session, the link, the feedback, the recorder narration, the input rules or the buttons mode, with hand-written messages and a test clock | anything the real server does differently from what the test author wrote down |
| Server model rules | `RuleTests`, `RecorderTests` (in `RuleTests.swift`), `ProtocolTests` | the model breaking one of the server rules that have bitten the app (each is explained in `docs/PROTOCOL.md`): a start refused `busy` while the last hold finishes; the final ack that comes only after the hold has really ended; no `state` to a client while it keeps sending; the watchdog that ends a hold with no updates; the emergency stop; a scene reset sent right behind a stop; the workspace box; the arm trailing its target; success; the recorder | whether the real server still behaves so |
| Conformance | `ConformanceTests` | the model drifting from the real server in any of the 18 recorded scenarios | situations no recording has: the recorder on, a success, a tracking stop |
| Link against the model | `LinkTests`, `FeedbackFromModelTests`, `NarrationTests` | the app's real `TeleopLink`, `FeedbackMonitor` and `RecorderNarrator` disagreeing with the server's rules, in one process on a test clock | sockets, threads, real time |
| Socket host | `LocalTeleopServerTests` | `LocalTeleopServer` failing to serve the model on a real WebSocket at 127.0.0.1 | the app |
| App | `Tests/TeleopTests` | `AppModel` and `LiveLinkController` wiring, over a fake socket on a test clock (`LiveLinkTests`, `AppModelTests`) and over real sockets to the local server in real time (`LocalServerTests`, `ObserverTests`, `LocalPickAndPlaceTests`); the guide, the volume-key mapping, the spoken strings in both languages (`SpeechTextTests`) | ARKit (the phone's pose is scripted), what the operator actually feels or hears, the volume keys themselves, the real server |
| UI | `Tests/TeleopUITests` | screens, buttons and flows through XCUITest; which haptics the app asks for (`-recordHaptics YES` shows them to the test); the app connecting to a model served by the test process (`LocalServerUITests`) | how a haptic feels, the volume keys (XCUITest cannot press them), ARKit motion |
| Live | `Tests/TeleopTests/ServerMotionTests.swift` | the app against the real simulator: its lag, its safety stop, a scripted pick-and-place | anything, unless someone runs it: it moves the shared simulator's arm, so it never runs by default or in CI |

Two more checks sit beside the tests:

- The **session safety checker** tries every action in every reachable state of the real `TeleopSession`
  (`docs/ARCHITECTURE.md` says what it proves). Run it with
  `.cursor/skills/verify-session-safety/scripts/check.sh`.
- **Scripts**: `python3 scripts/check-strings.py` fails when a string key used in the app is missing from
  `App/Resources/Localizable.xcstrings` or a key there is unused; `python3 scripts/check-dead-buttons.py` fails on a
  button with an empty action; `python3 -m unittest scripts/test_analyze_holds.py` tests the hold analysis tool.

## How to run each

### The core package

Everything in `Packages/TeleopCore/Tests`, from the core rules to the socket host, in about half a minute, with no
simulator:

    cd Packages/TeleopCore && swift test

One class or one test (the filter is a regular expression on `Target.Class/test`):

    cd Packages/TeleopCore && swift test --filter ConformanceTests
    cd Packages/TeleopCore && swift test --filter 'RuleTests/testAHoldEnds750MsAfterItsLastUpdateWithoutAnEmergencyStop'

The socket host needs Network.framework, so its tests run only on a Mac.

`InputArbiterPropertyTests` generates 12,000 cases from a fixed seed (`SplitMix64`), so a failure names the case
index and replays the same way every time.

### The app and UI tests

These need Xcode, XcodeGen and an iPhone simulator. Generate the project first, after any change to
`project.yml` or to the list of source files:

    xcodegen generate

Pick a simulator the same way CI does, then run the default test plan:

    SIM=$(xcrun simctl list devices available | grep -oE 'iPhone 1[0-9] Pro( Max)?|iPhone 1[0-9]' | head -n 1)
    xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan Default \
      -destination "platform=iOS Simulator,name=$SIM" CODE_SIGNING_ALLOWED=NO

A full run takes about ten minutes. While working on one thing, run only that:

    xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan Default \
      -destination "platform=iOS Simulator,name=$SIM" CODE_SIGNING_ALLOWED=NO \
      -only-testing:TeleopTests/LocalizationTests

To see what a plan contains without running it, build once and list the tests:

    xcodebuild build-for-testing -project Teleop.xcodeproj -scheme Teleop -testPlan Default \
      -destination "platform=iOS Simulator,name=$SIM" CODE_SIGNING_ALLOWED=NO
    xcodebuild test-without-building -project Teleop.xcodeproj -scheme Teleop -testPlan Default \
      -destination "platform=iOS Simulator,name=$SIM" -enumerate-tests

## The default and the live test plans

The scheme has two test plans (`TestPlans/`):

- **Default** runs every test in `TeleopTests` and `TeleopUITests` except `ServerMotionTests`. It needs no server:
  the tests that need one start the model on a local socket themselves. It is what CI runs.
- **Live** runs only `ServerMotionTests`, which drive the real simulator.

The live tests move the simulated arm on a machine other people use, so three things guard them:

1. They are in the Live plan only; the Default plan skips them by name.
2. They skip unless the test runner's environment has `TELEOP_MOTION` set, which `xcodebuild` passes on when the
   command line sets `TEST_RUNNER_TELEOP_MOTION=1`.
3. They connect to `127.0.0.1:8765` and skip if nothing answers there. That port is meant for the development
   relay (below).

Run them only when the simulator is free and you mean to move its arm (needs the live server; not part of any
routine check). First start the path to the simulator, each in its own terminal:

    pip install websockets                 # once: dev_relay.py and trace_scenarios.py need it
    scripts/dev_tunnel.sh <user@host>      # an SSH tunnel from 127.0.0.1:8766 to port 8766 on the simulator's machine
    python3 scripts/dev_relay.py           # listens on port 8765 and forwards each client to 127.0.0.1:8766

The tunnel forwards port 8766, the simulator's own port, and reconnects when it drops. The relay listens on 8765
on every network interface of the Mac, so a phone on the same network can connect to it too, and gives each client
its own connection upstream (`--listen` and `--upstream` change the two ports). Then:

    TEST_RUNNER_TELEOP_MOTION=1 xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan Live \
      -destination "platform=iOS Simulator,name=$SIM"

## The scripted operator and the server model

`Tests/TeleopTests/ScriptedOperator.swift` plays the operator's hand: it builds a real `AppModel` with the live link
on, feeds it a scripted phone position instead of ARKit's (`TestPose`), presses and releases the controls through
`AppModel.send`, and runs the main run loop so the app's own timers and sockets work. Its `pickAndPlace` script
grasps the cube, carries it to the goal and lets go.

The same script runs in two places:

- `LocalPickAndPlaceTests`, in every default run, against `LocalTeleopServer` stepping 60 times a second, with the
  script's waits shortened to match (`pace: 0.3`). The script itself fails if the arm cannot reach the grasp point,
  the cube is not lifted, the cube does not end in the goal, or the phone shows an emergency stop at the end. The
  test then checks that the server's episode count is 1 (the scene reset once, after the success) and that the
  server's last `state` has no emergency stop. It does not check that no emergency stop happened along the way.
- `ServerMotionTests.testPickAndPlaceByScript`, in the Live plan, against the real simulator at full waits.

`TeleopServerModel` (`Packages/TeleopCore/Sources/TeleopServerModel`) is one deterministic type with time passed
in. It applies the server's WebSocket rules and runs its simulation loop over a small world. Every number it uses
is in `ServerModelConfig`, with where it came from. `LocalTeleopServer` (`Sources/TeleopServerHost`) serves it on a
real WebSocket at 127.0.0.1, on a port the system picks, in real time. Its default is 60 steps a second, the
simulator's nominal rate, faster than the lab machine manages; the protocol timers (the 750 ms watchdog, the
200 ms state broadcast) keep their real lengths.

## How the conformance tests compare

Strictly: every ack (seq, status, reason, in the same order), whether a `state` came with each ack and that
state's `estop` and `ik`, every error and echo, no other `state` while the client keeps sending at least every
200 ms, the same `state` keys and JSON types, and the final `estop`, `ik`, `episode`, `gripper`, `step`,
`task_success` and recorder fields. Loosely, with the reason in the test's header: the number of states in a
silence, ack times, final positions and angles. Two stalls of the real server's event loop are exempt from the
timing rules (`Exclusion.all`). In s11 the real jaws came down on the cube and stopped a move; the replay puts an
obstacle at that height (`Replay.obstacles`) so the model fails the move the same way and the rest is compared.

No recording so far has the recorder on (`rec` is "none" throughout) or reaches a success, so the recorder, the
success rule and the tracking safety stop are checked only by the rule tests. A recording of a pick-and-place with
the recorder on would close that gap.

The 18 recordings come from two runs of one server on one day: s00 to s14 from the first (s14 on sockets of its
own), s15 to s17 from the second. They are replayed in that order, with the recording script's unrecorded steps
between them (`Replay.plan`), so each scenario has the history it had: the episode count, the fields earlier holds
added, the step size.

## Recording a new scenario

This moves the real simulator's arm a few centimetres: do it only when nobody else is using it (needs the live
server, and the tunnel and the development relay started as in the live tests above; not run for this document).

1. Write it as a function in `scripts/trace_scenarios.py` and add it to `SCENARIOS`.
2. Run `python3 scripts/trace_scenarios.py` with no names: it records the greeting and every scenario in order, in
   one server run, and writes the files into `Packages/TeleopCore/Tests/TeleopServerModelTests/Recordings`.
3. Add the name to `Replay.order` and make `Replay.plan` follow the order the files were recorded in.
4. Add a test method for it in `ConformanceTests` and run `swift test`. A mismatch is a finding: fix the model, or,
   if the recording shows something that should not be modelled, add an `Exclusion` that says what and why. Do not
   loosen a comparison to make it pass.

A single scenario can be re-recorded by name, but its episode numbers then continue from wherever the server was,
so the whole set is the safer unit.

## What the model does not simulate

On purpose, to stay small; every number it does use is in `ServerModelConfig`, with its source.

- The arm is one point that follows its commanded point at a bounded distance per step. It has no joints, does
  not sag under gravity or stop short, and wrist angles do not move it (on the real arm a few degrees of wrist pitch
  move the jaws further than the grasp tolerance, which is why the model grasps only near the start pitch,
  `graspFlexTolerance`). Shoulder and elbow joint commands change those joint angles but not the point.
- The `tool` frame of `jog_start` and `move_delta` is treated as `base`.
- The jaws are a pinch point. They stop on the table but pass through the cube unless they close around it, so
  lowering closed jaws onto the cube does not fail a move as it can on the real server. A test can put an
  obstacle under the arm (`World.obstacleUnderArm`) to get that failure.
- The cube is grasped only with the jaws side by side (wrist roll within 15 degrees of 90) and the wrist near its
  start pitch; front to back, where the real grasp worked 1 time in 16, it never holds. A held cube keeps its
  offset from the pinch point and drops straight down when let go. It never tips, slides or gets pushed.
- Measured jaw and wrist angles are their targets; only the cube stops closing jaws.
- The loop runs at a steady pace (17 steps a second for the conformance tests, 60 in the socket host). The real
  one varies with load and sometimes stalls for half a second.
- The recorder is its state machine and counters only: no files, no camera. It does not send `rec_session` and
  `rec_mode` yet.
- Not modelled at all: cameras, the WebSocket ping, and three settings of the real server's socket side (from its
  source, which is not in this repository): the 8192-byte frame limit, the four-message inbound queue, and the 50 s
  it waits for a one-shot command to finish. The model's `commandDeadline` (45 s) is a different rule: how soon the
  loop must take a one-shot command. Malformed payloads that crash the real handler (an
  array where a name is expected) are answered as invalid instead.

## What CI runs

`.github/workflows/ios.yml` (a copy is kept in `ci/ios.yml`) runs on every push and pull request, on GitHub's
`macos-15` image with the Xcode that image ships:

1. `python3 scripts/check-strings.py` and `python3 scripts/check-dead-buttons.py`;
2. `swift test` in `Packages/TeleopCore`;
3. `brew install xcodegen` and `xcodegen generate`;
4. the first available iPhone simulator, picked as above, and `xcodebuild test` with the Default plan and
   `CODE_SIGNING_ALLOWED=NO`;
5. it uploads the xcodebuild log, the screenshots the UI tests attach, and the result bundle as artifacts.

CI never runs the Live plan, the safety checker or `scripts/test_analyze_holds.py`. Run the safety checker yourself
whenever a change touches the session, its state, the screens' actions or the hold handling.

CI's simulator and Xcode can be older than a current Mac's, so a UI test that passes locally can fail there. Two
differences have bitten before: on iOS 18 a system permission alert's buttons have no identifiers (the UI tests'
`answerSystemPrompts` in `SystemPrompts.swift` falls back to their order), and a SwiftUI control built from `Label`
exposes its icon as a second accessibility element unless it has `.accessibilityElement(children: .ignore)` and an
`.accessibilityLabel`.
