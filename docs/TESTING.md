# Testing

The app drives a robot arm in Isaac Sim, a robot simulator, on a lab machine that is slow, shared and out of reach
of CI. So most tests run against a model of its server instead (`TeleopServerModel`), and the model is itself
checked against recordings of the real server. Only the live layer touches the real one.

Two simulators appear below. *Isaac Sim* is always the robot simulator the server runs in. An *iPhone simulator*
is Xcode's simulated phone, which the app and UI tests run on.

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
| App | `Tests/TeleopTests` | the wiring of `AppModel`, `OperatingController` and `LiveLinkController` over a fake socket on a test clock (`LiveLinkTests`, `OperatingLinkTests`, `AppModelTests`), and over real sockets to the local server in real time (`LocalServerTests`, `ObserverTests`, and, through raw inputs only, `LocalOperatorTests`, `LocalPickAndPlaceTests` and `LinkStallTests`); the operating state (`OperatingRulesTests`); the guide's numbers (`GuidePictureTests`); the robot profile (`RobotProfileTests`, `ServerModelProfileTests`); the spoken strings in both languages (`SpeechTextTests`) | ARKit (the phone's pose is scripted), real touches, the volume keys themselves, what the operator actually feels or hears, the real server |
| UI | `Tests/TeleopUITests` | every operating state, in both languages and at two screen heights (`OperatingScreenTests`); touches on the bands and the gear (`OperatingTouchTests`); practice, Settings, Connect, the tutorial and the first-run camera prompt (`PracticeTests`, `SettingsTests`, `ConnectFlowTests`, `ManualCheckTests`); the app connecting to a model served by the test process (`LocalServerUITests`); which haptics the app asks for | how a haptic feels, the volume keys (XCUITest cannot press them), ARKit motion |
| Live | `OperatorLiveTests`, `ServerMotionTests` in `Tests/TeleopTests` | the app against the real server in Isaac Sim: its lag, its safety stop, a pick-and-place in each control mode | anything, unless someone runs it: it moves the shared arm in Isaac Sim, so it never runs by default or in CI |

Two more checks sit beside the tests:

- The **session safety checker** tries every action in every reachable state of the real `TeleopSession`
  (`docs/ARCHITECTURE.md` says what it proves). Run it with
  `tools/session-safety/scripts/check.sh`.
- **Scripts.** `python3 scripts/check-strings.py` checks every string table in `App/Resources`: each key has English
  and Traditional Chinese, the two carry the same format specifiers, the Chinese uses full-width punctuation, and no
  key the code uses is missing and none is unused. `python3 scripts/check-dead-buttons.py` fails on a button with an
  empty action. `scripts/check-format.sh` fails when a Swift file of the app, the core package, the tests or the
  safety checker is not laid out as `.swift-format` says (`swift format lint --strict`); the same file list with
  `swift format format -i --parallel` lays them out. `python3 -B -m unittest scripts/test_check_strings.py scripts/test_analyze_holds.py` tests two of
  the scripts; `-B` leaves no `scripts/__pycache__/` behind for `git status` to show.

## How to run each

### The core package

Everything in `Packages/TeleopCore/Tests`, from the core rules to the socket host, in about half a minute, with no
iPhone simulator:

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

Pick an iPhone simulator the same way CI does, then run the default test plan:

    SIM=$(xcrun simctl list devices available | grep -oE 'iPhone 1[0-9] Pro( Max)?|iPhone 1[0-9]' | head -n 1)
    xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan Default \
      -destination "platform=iOS Simulator,name=$SIM" CODE_SIGNING_ALLOWED=NO

A full run takes about twenty minutes, most of it the UI tests. Two things make a run fail for reasons that have
nothing to do with the code:

- **Nothing else may use the iPhone simulator while the tests run on it**: no second test run, and no other tool
  that drives, records or streams that device. Another tool attached to the same iPhone simulator can make UI
  tests fail. Give a run its own iPhone simulator, chosen by its UDID (`-destination 'id=<UDID>'`), when
  something else needs one.
- **The Mac must stay awake for the whole run.** A Mac that sleeps, from idle or from a closed lid, breaks the
  timing of the local-server tests and the pick-and-place. Keep the lid open and start the run under
  `caffeinate -i`, which keeps the Mac from idle sleep while the command runs.

While working on one thing, run only that:

    xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan Default \
      -destination "platform=iOS Simulator,name=$SIM" CODE_SIGNING_ALLOWED=NO \
      -only-testing:TeleopTests/OperatingRulesTests

To see what a plan contains without running it, build once and list the tests:

    xcodebuild build-for-testing -project Teleop.xcodeproj -scheme Teleop -testPlan Default \
      -destination "platform=iOS Simulator,name=$SIM" CODE_SIGNING_ALLOWED=NO
    xcodebuild test-without-building -project Teleop.xcodeproj -scheme Teleop -testPlan Default \
      -destination "platform=iOS Simulator,name=$SIM" -enumerate-tests

### Launch arguments for UI tests

The app reads these from its launch arguments (`XCUIApplication.launchArguments`). Every UI test launch passes
`-quietCues YES`, through `XCUIApplication.quiet` and `XCUIApplication.teleop` in `UITestSupport.swift`, so the
iPhone simulator plays no vibration, sound or speech through the computer's speakers; the app still records every
cue.
The app is silent by itself as the unit-test host.

| Argument | What it does |
|---|---|
| `-quietCues YES` | no haptics, sounds or speech |
| `-liveLink NO` | launch in practice instead of on the real server |
| `-serverAddress <host:port>` | the saved server address; on the real server the app connects to it at launch |
| `-startRoute <raw value>` | open on that route (`Route.swift`), for example `s1_connect` |
| `-firstRunDone YES` | skip the permissions screen and the tutorial at launch |
| `-controlMode screenTurns`, `keyTurns` or `buttons`; `-hand left` or `right`; `-taskAid YES` or `NO`; `-appLanguage en` or `zh-Hant` | the saved settings, pinned for one launch |
| `-operatingFixture <name>` | show one of the named displays in `OperatingFixtures.swift` on the operating screen, and nothing else |
| `-screenFrame 375x667x20x0` | draw the app in a frame of that width and height, at the top left, with those top and bottom safe-area insets, to check a smaller phone's layout |
| `-recordHaptics YES` | put the haptics the app asks for into a hidden element (`test.haptics`) that XCUITest can read |
| `-startConnected YES`, `-startBlocked YES`, `-startConnectionLost YES` | start marked connected, with commands blocked as on a slow link, or as a dropped link leaves things |

## The default and the live test plans

The scheme has two test plans (`TestPlans/`):

- **Default** runs every test in `TeleopTests` and `TeleopUITests` except `OperatorLiveTests` and
  `ServerMotionTests`. It needs no server: the tests that need one start the model on a local socket themselves.
  It is what CI runs.
- **Live** runs only `OperatorLiveTests` and `ServerMotionTests`, which drive the arm in Isaac Sim.

The live tests move the arm in Isaac Sim on a machine other people use, so three things guard them:

1. They are in the Live plan only; the Default plan skips them by name.
2. They skip unless the test runner's environment has `TELEOP_MOTION` set, which `xcodebuild` passes on when the
   command line sets `TEST_RUNNER_TELEOP_MOTION=1`.
3. They connect to `127.0.0.1:8765` and skip if nothing answers there. That is the relay's port (below).

Run them only when Isaac Sim is free and you mean to move its arm. They need the scene at its reset pose with
nobody else driving it; `OperatorLiveTests` also needs the server running without a recording session. Each test
first resets the scene the way holding the top band does, which also releases an emergency stop left latched.
Start the path to the server first, each in its own terminal:

    pip install websockets                 # once: dev_relay.py and trace_scenarios.py need it
    scripts/dev_tunnel.sh <user@host>      # an SSH tunnel from 127.0.0.1:8766 to port 8766 on Isaac Sim's machine
    python3 scripts/dev_relay.py           # listens on port 8765 and forwards each client to 127.0.0.1:8766

The tunnel forwards port 8766, the port the server listens on there, and reconnects when it drops. The relay
listens on 8765 on every network interface of the Mac, so a phone on the same network can connect to it too, and
gives each client its own connection upstream. `--listen` takes another port to listen on, and `--upstream` another WebSocket
URL to forward to, such as `ws://127.0.0.1:9000`. Then:

    TEST_RUNNER_TELEOP_MOTION=1 xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan Live \
      -destination "platform=iOS Simulator,name=$SIM"

### Counting live runs

A count of live runs is evidence for the release only when it is taken this way:

1. On a Mac that is doing nothing else: no build, no other test run, no other simulator in use. A busy Mac stalls
   the app's main thread and the relay, and the count then measures the Mac.
2. Each run's `PICK RUN` line is checked against the server's own log: a pass counts only when the server logged a
   success for that episode. On a success the server prints `S4 PICK_PLACE SUCCESS {'episode': N, ...}` to its
   console and writes a `task_success` event with the same episode to its JSON-lines log, then resets to episode
   N + 1; N is the left-hand number of the line's `episode N -> M`. A reset for any other reason
   (`S4 AUTO RESET ... reason=object_fallen`, or `reason=manual`) also starts a new episode and is no success. A run
   whose line says the link was lost is counted apart, as a lost link, with the time it happened.
3. Report how many runs were made in each scheme, how many passed by both the line and the server's log, how many
   lost the link, and the sum of the holds the server ended.

## The scripted operator and the server model

`Tests/TeleopTests/ScriptedOperator.swift` plays the operator's hand through the app's raw inputs only, the way a
person can: the volume keys down and up, touches on the operating screen, the phone's position and attitude as
ARKit would report them (`TestPose`), the pad's buttons, and waiting. It never sends a control action to the
session. It builds a real `AppModel` with the live link on and runs the main run loop, so the app's own timers and
sockets work. Its `pickAndPlace` script opens the jaws, goes to the grasp point the guide shows, closes, lifts,
carries the task object to the goal, lowers it and lets go, each with the chosen mode's own inputs.

The same script runs in two places:

- `LocalPickAndPlaceTests`, in every default run, once per control mode against a model that reports `tool_pos`
  and once against one that does not, against `LocalTeleopServer` stepping 60 times a second, with the script's waits shortened to match (`pace: 0.3`). The script fails if the arm cannot
  reach the grasp point, the jaws do not close on the object, or the object is not lifted or leaves the jaws on the
  way to the goal. A working link that goes down, an emergency stop on the phone, or the server's states stopping
  while the link stays up (none for 5 s) fails the run at that step, with the app's last log lines. It passes only on
  what the server reported after the jaws let go on the goal: a `state` with `task_success`, or a fresh `state` with
  the object resting inside the goal and the jaws not closed. A new episode alone is no success, because the server
  also resets when the object falls off the table. The test then checks that a success was seen, that the server's
  episode count is 1 (the scene reset once, after the success) and that the server's last `state` has no emergency
  stop. One more test runs it with a recorder on and checks that the guide, the saved take and the server's Wait
  reach the operating screen.
- `OperatorLiveTests`, in the Live plan, once per control mode, against the real server in Isaac Sim at full waits,
  with the same rule for a pass. `ServerMotionTests` adds scripted hand movements, the wrist following the phone,
  and the pick-and-place after many holds.

Every run prints one line, for example:

    PICK RUN (screenTurns): episode 0 -> 1, success seen YES, holds ended by the server 0, link lost no, object in goal no, 24 s: PASS

It names the scheme, the server's episode before and after the run, whether a `state` said `task_success` after
the jaws let go, how many holds the server ended while they were held (its watchdog, or a late refusal), whether
the link was lost and during which step, and whether the server's last fresh `state` had the object resting in the
goal. It ends in PASS only when the test passed by the script's rule, FAIL otherwise, or SKIP when the server
reports no task. `testALinkCutAfterTheLiftFailsTheRun` cuts the network path while the object is carried and
expects the run to fail for that reason.

`LinkStallTests` puts a network path under both of the app's sockets that can hold every message back in both
directions and then deliver them together, as an ordinary wireless network was measured doing for up to 1.8 s. A
1.8 s stall during an arm, gripper or wrist hold must cost that hold and nothing else: the link stays up, the
server's watchdog ends the hold, the phone plays LETGO with "Link hiccup." and no refusal, and the next hold
works. A longer stall is a lost link 3 s after the control connection's last message, and STOP pressed during a
short stall reaches the server when the path comes back.

`LocalOperatorTests` uses the same hand against the local server for single behaviours: the wrist following the
phone in each scheme, STOP during a hold, the two ways out of a stop, and the holds that end when Settings opens,
the app leaves the foreground or the camera stops.

`TeleopServerModel` (`Packages/TeleopCore/Sources/TeleopServerModel`) is one deterministic type with time passed
in. It applies the server's WebSocket rules and runs its simulation loop over a small world. Every number it uses
is in `ServerModelConfig`, with where it came from. `LocalTeleopServer` (`Sources/TeleopServerHost`) serves it on a
real WebSocket at 127.0.0.1, on a port the system picks, in real time. Its default is 60 steps a second, Isaac
Sim's nominal rate, faster than the lab machine manages; the protocol timers (the 750 ms watchdog, the
200 ms state broadcast) keep their real lengths.

## How the conformance tests compare

Strictly: every ack (seq, status, reason, in the same order), whether a `state` came with each ack and that
state's `estop` and `ik`, every error and echo, no other `state` while the client keeps sending at least every
200 ms, the same `state` keys and JSON types (the recordings have no `tool_pos`, so the replay turns the model's
`reportsToolPoint` off), and the final `estop`, `ik`, `episode`, `gripper`, `step`,
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

This moves the arm in Isaac Sim a few centimetres: do it only when nobody else is using it (needs the live
server, and the tunnel and the relay started as in the live tests above).

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
  `rec_mode`.
- Not modelled at all: cameras, the WebSocket ping, and three settings of the real server's socket side (from its
  source, which is not in this repository): the 8192-byte frame limit, the four-message inbound queue, and the 50 s
  it waits for a one-shot command to finish. The model's `commandDeadline` (45 s) is a different rule: how soon the
  loop must take a one-shot command. Malformed payloads that crash the real handler (an
  array where a name is expected) are answered as invalid instead.

## What CI runs

`.github/workflows/ios.yml` (a copy is kept in `ci/ios.yml`) runs on every push and pull request, on GitHub's
`macos-15` image with the Xcode that image ships:

1. `python3 scripts/check-strings.py` and `python3 scripts/check-dead-buttons.py`, then `scripts/check-format.sh`,
   which only reports (below);
2. `swift test` in `Packages/TeleopCore`;
3. `brew install xcodegen` and `xcodegen generate`;
4. the first available iPhone simulator, picked as above, and `xcodebuild test` with the Default plan and
   `CODE_SIGNING_ALLOWED=NO`;
5. it uploads the xcodebuild log, the screenshots the UI tests attach, and the result bundle as artifacts.

The layout check runs with `continue-on-error`, so a finding shows on the run but does not fail it. CI's Xcode is
older than the one the code was laid out with, and the two `swift format` versions lay out a few constructs
differently, so a file that passes here can be reported there. `.swift-format` names only the settings that differ
from swift format's defaults (four-space indents, 120 columns, no indent inside `#if`, every rewriting rule off), so
that the older version can read it too. The strict check that counts is a step of the release procedure
(`docs/RELEASING.md`), run with the current Xcode.

CI never runs the Live plan, the safety checker or the scripts' own unit tests. Run the safety checker yourself
whenever a change touches the session, its state, the screens' actions or the hold handling.

CI's iPhone simulator and Xcode can be older than a current Mac's, so a UI test that passes locally can fail
there. Two differences matter: on iOS 18 a system permission alert's buttons have no identifiers (the UI tests'
`answerSystemPrompts` in `SystemPrompts.swift` falls back to their order), and a SwiftUI control built from `Label`
exposes its icon as a second accessibility element unless it has `.accessibilityElement(children: .ignore)` and an
`.accessibilityLabel`.
