# Testing

The app drives a robot arm in a simulator on a lab machine that is slow, shared and out of reach of CI. So most
tests run against a model of that simulator's server instead, and the model is itself checked against
recordings of the real server. Only the live layer touches the real one.

## The layers

| Layer | What it checks | Where | How to run |
|---|---|---|---|
| Model | `TeleopServerModel`: the server's WebSocket rules and its simulation loop over a small world, one deterministic type with time passed in | `Packages/TeleopCore/Sources/TeleopServerModel` | (used by everything below) |
| Conformance | each recording of the real server, replayed into the model at its recorded times, comes back the same | `ConformanceTests` | `cd Packages/TeleopCore && swift test` |
| Rules | each server rule that has bitten the app (busy, held-back acks, quiet during holds, watchdog, E-stop, reset behind a stop, workspace, slow arm, success, recorder) | `RuleTests`, `RecorderTests`, `ProtocolTests` | same |
| Link | the app's real `TeleopLink` against the model, in process, on a test clock | `LinkTests` | same |
| Socket host | `LocalTeleopServer`: the model on a WebSocket at 127.0.0.1, a port the system picks, in real time (60 steps a second by default, about 3.5 times the lab server) | `Sources/TeleopServerHost`, `LocalTeleopServerTests` | same |
| App | `AppModel` and the link over a real socket to the local server, including the scripted pick-and-place (`ScriptedOperator`, about 25 s) | `Tests/TeleopTests` (`LocalServerTests`, `LocalPickAndPlaceTests`) | the default test plan |
| UI | screens through XCUITest; `LocalServerUITests` serves the model from the test process and connects the app to it | `Tests/TeleopUITests` | the default test plan |
| Live | `ServerMotionTests`: the same pick-and-place script and hand motion profiles against the lab simulator through the relay on port 8765 | `Tests/TeleopTests/ServerMotionTests.swift` | the `Live` test plan, on purpose only |

The default plan runs everything except the live tests and contacts nothing on port 8765:

    xcodegen generate
    xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan Default \
      -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

The live plan moves the real arm. It runs only `ServerMotionTests`, and those skip unless asked:

    TEST_RUNNER_TELEOP_MOTION=1 xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan Live \
      -destination 'platform=iOS Simulator,name=iPhone 16 Pro'

To see what a plan contains without running it, add `-enumerate-tests` to `xcodebuild test-without-building`.

## How the conformance tests compare

Strictly: every ack (seq, status, reason, in the same order), every error and echo, no `state` while the client
keeps sending at least every 200 ms except right after an ack, the same `state` keys and JSON types, and the
final `estop`, `ik`, `episode`, `gripper`, `step`, `task_success` and recorder fields. Loosely, with the reason
in the test's header: the number of states in a silence, ack times, final positions and angles. Two parts of the
recordings are excluded, each with its reason in `Exclusion.all`: s11 after 8 s (the real jaws landed on the
cube) and two stalls of the real server's event loop.

All 18 recordings come from one server run, so they are replayed in the order they were made, with the recording
script's unrecorded steps between them (`Replay.plan`). That gives each scenario the history it had: the episode
count, the fields earlier holds added, the step size.

## Recording a new scenario

1. Write it as a function in `scripts/trace_scenarios.py` and add it to `SCENARIOS`.
2. When nobody else is using the simulator, run `python3 scripts/trace_scenarios.py` with no names: it records
   the greeting and every scenario in order, in one server run, and writes the files into
   `Packages/TeleopCore/Tests/TeleopServerModelTests/Recordings`.
3. Add the name to `Replay.order` and make `Replay.plan` follow the script's order (one run: the greeting, then
   settle and scenario for each entry of `SCENARIOS`, then s14 on its own sockets).
4. Add a test method for it in `ConformanceTests` and run `swift test`. A mismatch is a finding: fix the model, or,
   if the recording shows something that should not be modelled, add an `Exclusion` that says what and why. Do not
   loosen a comparison to make it pass.

A single scenario can be re-recorded by name, but its episode numbers then continue from wherever the server was,
so the whole set is the safer unit.

## What the model does not simulate

On purpose, to stay small; every number it does use is in `ServerModelConfig`, with its source.

- The arm is one point that follows its commanded point at a bounded distance per step. It has no joints, does
  not sag under gravity or stop short, and wrist angles do not move it (on the real arm a 14 degree wrist pitch
  moved the reported point 1.4 cm). Shoulder and elbow joint commands are accepted and acked but move nothing.
- The `tool` frame of `jog_start` and `move_delta` is treated as `base`.
- The jaws are a pinch point. They stop on the table but pass through the cube unless they close around it, so
  lowering closed jaws onto the cube does not fail a move as it can on the real server.
- The cube is grasped only with the jaws side by side (wrist roll within 15 degrees of 90) and the wrist near its
  start pitch; front to back, where the real grasp worked 1 time in 16, it never holds. A held cube keeps its
  offset from the pinch point (the real one swings up to 2 cm when the shoulder turns) and drops straight down
  when let go. It never tips, slides or gets pushed.
- Measured jaw and wrist angles are their targets; only the cube stops closing jaws.
- The loop runs at a steady pace (17 steps a second for the conformance tests, 60 in the socket host). The real
  one varies between 8 and 19 with load and sometimes stalls for half a second.
- The recorder is its state machine and counters only: no files, no camera.
- Not modelled at all: cameras and multiview, the self-test mode, the WebSocket ping, the 8192-byte frame limit
  and four-message inbound queue, the 50 s server-side timeout for one-shot commands. Malformed payloads that
  crash the real handler (an array where a name is expected) are answered as invalid instead.
