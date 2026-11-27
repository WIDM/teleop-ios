# Testing

The app drives a robot arm in Isaac Sim, a robot simulator, on a machine that is slow, shared and out of reach
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
| Core | `Packages/TeleopCore/Tests/TeleopCoreTests` | a wrong rule in the session, the link, the feedback, the recorder narration, the input rules, the buttons mode or the hands-free aids (lock, tap-to-go and the path of a move inside its work box, how a move follows the pinch point a server reports, also against an arm whose pinch point turns with its posture (`GoMoveFollowTests`, `GoingFollowTests`), the work-area cue, the lowest rule), the wrist buttons' angles (`WristButtonTests`), which path a pad hold takes (`ObjectHoldTests`), whether the simulation behind the server runs (`SimStallDetectorTests`), the sorting of a server's refusal (`ServerRefusalClassTests`), the open-the-gripper-first line (`JawsClosedReminderTests`) and the robot profile file's strict format and validation sentences (`ProfileFormatTests`), with hand-written messages and a test clock | anything the real server does differently from what the test author wrote down |
| Server model rules | `RuleTests`, `RecorderTests` (in `RuleTests.swift`), `ProtocolTests`, `ToolTurnTests`, `StallRuleTests` | the model breaking one of the server rules that have bitten the app (each is explained in `docs/PROTOCOL.md`): a start refused `busy` while the last hold finishes; the final ack that comes only after the hold has really ended; no `state` to a client while it keeps sending; the watchdog that ends a hold with no updates; the emergency stop; a scene reset sent right behind a stop; a stopped simulation loop that refuses a start, a scene reset and a stop release; the workspace box; the arm trailing its target; success; the recorder. And the model's two options for tests of a move that follows the pinch point (`ToolTurnTests`): a pinch point that turns with the arm's posture, which the tool point in `state`, the grasp and where the jaw tips stop on the table follow, and a model told during a run to stop reporting the tool point | whether the real server still behaves so |
| Conformance | `ConformanceTests` | the model drifting from the real server in any of the 18 recorded scenarios | situations no recording has: the recorder on, a success, a tracking stop |
| Link against the model | `LinkTests`, `FeedbackFromModelTests`, `NarrationTests` | the app's real `TeleopLink`, `FeedbackMonitor` and `RecorderNarrator` disagreeing with the server's rules, in one process on a test clock | sockets, threads, real time |
| Socket host | `LocalTeleopServerTests` | `LocalTeleopServer` failing to serve the model on a real WebSocket at 127.0.0.1 | the app |
| App | `Tests/TeleopTests` | the wiring of `AppModel`, `OperatingController` and `LiveLinkController` over a fake socket on a test clock (`LiveLinkTests`, `OperatingLinkTests`, `AppModelTests`), and over real sockets to the local server in real time (`LocalServerTests`, `ObserverTests`, and, through raw inputs only, `LocalOperatorTests`, `LocalPickAndPlaceTests` and `LinkStallTests`); the operating state (`OperatingRulesTests`); the guide's numbers (`GuidePictureTests`); the robot profile (`RobotProfileTests`, `ServerModelProfileTests`), the SO-101 file's every field against the number the app ran with before profiles were files (`ProfileFileTests`), and how a build chooses its profile file and refuses a missing, misspelt or invalid one (`ProfileLoaderTests`); the spoken strings in both languages (`SpeechTextTests`); two screen strings' keys resolving to their words in the app's bundle (`LocalizationTests`); the developer log's line on how far the phone moved and turned during a hold, or that it was not tracked (`PoseLogTests`); the hands-free aids: their settings and what the input rules are told (`AssistModelTests`, `OffPlanTests`), each ending of a follow or a move nobody holds carried and heard once (`AssistControllerTests`, `AssistLinkTests`, `LooseEndingHeardTests`, `DriveCuePlayTests`), a "Locked on." still waiting for the voice never said after STOP or a lost link, and, while the camera is stopped, no tap taken and, with the aids off, presses answered as in version 1.0.1 (`AssistControllerTests`), the limits a move to a tapped point meets told by its ending alone while a latched follow is told them as a held hold is, and a held hold after a move told its side again, a tap that waits for an arm position from after the last stop, and where an arm hold's commanded point starts with the aids on and off (`AssistLinkTests`), the guide's cues at the link, a resync's pause included (`GuideAidsLinkTests`), the guide's additions and the on-target window (`GuidePictureAssistTests`, `OnTargetWindowTests`, `SingleGuidePictureTests`), the locked, going and ended states (`OperatingRulesAssistTests`), the tutorial's on-target line and its longer form with the sentence about the guide's arrows, which begins with it word for word in both languages (`TutorialLinesTests`), the profile's numbers for the aids (`RobotProfileAssistTests`), lock and taps through raw inputs against the local server (`LocalAssistTests`), moves that follow a pinch point that turns with the arm's posture against the local server (`LocalFollowTests`), and the helper that counts a move's corrections there, on a clock it is handed (`CommandLegsTests`), the Fine controls panel and its Wrist page (`PrecisionControlTests`, `WristPanelTests`), the paths and refusals of manual holds over a fake socket (`ManualToolControlTests`, `ServerRefusalWordsTests`), the pause of the simulator, Reconnect and the stop kept (`SimStallTests`), the open-the-gripper-first line (`OpenJawsFirstTests`), the line that says the aids are off (`AidsOffWordsTests`) and the record kept on the phone (`SessionRecordTests`) | ARKit (the phone's pose is scripted), real touches, the volume keys themselves, what the operator actually feels or hears, the real server |
| UI | `Tests/TeleopUITests` | every operating state, in both languages and at two screen heights (`OperatingScreenTests`); touches on the bands and the gear (`OperatingTouchTests`); where the STOP band ends on every screen, read from the picture's pixels, and that a press under it does nothing (`StopBandTests`); scheme B's words against everything else on the screen (`SchemeBHintTests`); practice, Settings, Connect, the tutorial and the first-run camera prompt (`PracticeTests`, `SettingsTests`, `ConnectFlowTests`, `ManualCheckTests`); the app connecting to a model served by the test process (`LocalServerUITests`); which haptics the app asks for; the aids' page that the Aids button in the Settings header opens, with the master switch and the lock choices, the word Lock drawn on the page's background as a section header and not on a row, what VoiceOver calls the way back to Settings in both languages, Settings opening on its form again after a STOP on that page, and the aids' tutorial lines (`AssistSettingsTests`), the locked, going and ended states and the guide with its aids (`AssistOperatingScreenTests`, `GuideAidsScreenTests`), and a tap on the drawn view from above that goes and arrives, taps 6 pt outside each of its four edges, which name the top view without starting a move, and 6 pt inside each, which are judged against the view (`GuidePanelTapUITests`), the Fine controls panel and its pages against the local server (`PrecisionPanelUITests`), the voice experiment's control, shown only when asked for (`VoiceAxisEntryUITests`), the words of a refused tap (`TapWordsScreenTests`) and the aids-off line (`AidsOffScreenTests`) | how a haptic feels, the volume keys (XCUITest cannot press them), ARKit motion |
| Live | `OperatorLiveTests`, `ServerMotionTests` in `Tests/TeleopTests` | the app against the real server in Isaac Sim: its lag, its safety stop, a pick-and-place in each control mode | anything, unless someone runs it: it moves the shared arm in Isaac Sim, so it never runs by default or in CI |

At 1.3.0 the core package has 949 test methods, the app tests 656 and the UI tests 101. The Default plan skips the 11
live ones by name (`OperatorLiveTests` has 3, `ServerMotionTests` 8), so it runs 645 app tests and the 101 UI tests.
The counts are the `func test...` methods in `Packages/TeleopCore/Tests`, `Tests/TeleopTests` and
`Tests/TeleopUITests`; a test plan's own list (below) says what it runs.

Two more checks sit beside the tests:

- The **session safety checker** tries every action in every reachable state of the real `TeleopSession`
  (`docs/ARCHITECTURE.md` says what it proves). Run it with
  `tools/session-safety/scripts/check.sh`.
- **Scripts.** `python3 scripts/check-strings.py` checks every string table in `App/Resources`: each key has English
  and Traditional Chinese, the two carry the same format specifiers, the Chinese uses full-width punctuation, and no
  key the code uses is missing and none is unused. `python3 scripts/check-dead-buttons.py` fails on a button with an
  empty action. `scripts/check-format.sh` fails when a Swift file of the app, the core package, the tests or the
  safety checker is not laid out as `.swift-format` says (`swift format lint --strict`); the same file list with
  `swift format format -i --parallel` lays them out. `python3 scripts/check-arm-constants.py` fails when a profile id,
  a profile held in a `static let` or the removed SO-101 constant appears in code outside the profile loader and the
  tests (`docs/PROFILE.md`). `python3 -B -m unittest scripts/test_check_strings.py scripts/test_analyze_holds.py scripts/test_check_arm_constants.py`
  tests three of the scripts; `-B` leaves no `scripts/__pycache__/` behind for `git status` to show.

The camera recovery and wrist re-anchoring use fake camera runs and frame timestamps
(`PoseTrackerTests`, `CameraMarkTests`, `AttitudeFrameTests`). The touch tests check that the failed taps explain
why they did not go and that a second contact still stops a move. The link tests check that the second slow
sample stops a held control, with the cue enabled by the robot profile and the operator's aids setting.

The app keeps a rotating record at `Documents/session.log` in its copy on the phone. It includes settings, tracker
events, screen changes, slow-link samples, touch travel and speech events. Server addresses are masked. On a
simulator use `xcrun simctl get_app_container <udid> widm.teleop.app data` to find the app container and read
the file from its `Documents` directory. The unit-test host has no record unless a test supplies a file.

During translation, `motion` records appear at most once per second. They distinguish requested link-frame
offsets, sent offsets and base-frame targets, and measured arm positions, all in metres. Each retained request
or update has its own age; measured age is time since local receipt, not network latency. Cap, resync and held-back
start flags explain pauses. `ManualMotionRecordTests` compares complete wire messages with logging on and off
for both vertical directions and a resync. The older `pose` summary describes phone movement, not arm movement.

Rear-height regressions cover rising, descending without horizontal drift, changing height while moving, and
requesting descent below the automatic floor. At the floor, that request must explain manual descent and must
not start a move or announce arrival. The floor remains 5 cm with the SO-101 profile. UI screenshots show the
height-only column and the floor instruction; they do not establish physical grasp quality or phone tracking.
Short moves may finish during XCTest's post-tap idle wait. The height UI tests keep the normal server-model
physics and capture bounded command metadata instead of slowing the arm. They require one start and stop with
a successful completion for the same connection and sequence; retargeting must keep that single hold. Exact
endpoint checks remain, and a floor refusal must send no new start. Long moves still check the visible Going state.

## How to run each

### The core package

Everything in `Packages/TeleopCore/Tests`, from the core rules to the socket host, in about a minute, with no
iPhone simulator:

    cd Packages/TeleopCore && swift test

One class or one test (the filter is a regular expression on `Target.Class/test`):

    cd Packages/TeleopCore && swift test --filter ConformanceTests
    cd Packages/TeleopCore && swift test --filter 'RuleTests/testAHoldEnds750MsAfterItsLastUpdateWithoutAnEmergencyStop'

The socket host needs Network.framework, so its tests run only on a Mac.

`InputArbiterPropertyTests` generates 12,000 cases from a fixed seed (`SplitMix64`), so a failure names the case
index and replays the same way every time. `HomeSwipeTests` replays, sample by sample, the swipes home and the
taps on the STOP band that a person's phone logged.

The hands-free aids are held to version 1.0.1 when they are off, without a list of features written by hand:

- `AssistConfigTests` checks by reflection that `Assist.off` has every member nil.
- `OffEqualsVersion101Tests` feeds the property test's 12,000 cases both to today's input rules with `Assist.off`
  and to `InputArbiter101`, a frozen copy of version 1.0.1's input rules in the test target, and wants the same
  commands and the same state of every input at every step. `FeedbackMonitorLowestTests` compares today's
  `FeedbackMonitor` with the lowest rule off against `FeedbackMonitor101`, a frozen copy of version 1.0.1's. Each
  frozen copy says at its top how it was made, and is never edited to make a test pass.
- `AssistPropertyTests` generates 12,000 cases with the aids (one in five with `.off`), checks the promises of lock
  and tap-to-go after every step, and compares each case with an `.off` twin up to the first new gesture.
- The AssistOff plan (below) runs the app's unit tests again with the master switch off.

### The app and UI tests

These need Xcode, XcodeGen and an iPhone simulator. Generate the project first, after any change to
`project.yml` or to the list of source files:

    xcodegen generate

Pick an iPhone simulator the same way CI does, then run the default test plan:

    SIM=$(xcrun simctl list devices available | grep -oE 'iPhone 1[0-9] Pro( Max)?|iPhone 1[0-9]' | head -n 1)
    xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan Default \
      -destination "platform=iOS Simulator,name=$SIM" CODE_SIGNING_ALLOWED=NO

Every test plan runs the tests in English, with the United States as the region, whatever language and region the
iPhone simulator is set to and whatever language the app last saved there. Each plan launches the app's unit tests
with `-appLanguage en`, and a UI test names the app's language at every launch: one that needs Traditional Chinese
asks for it (`-appLanguage zh-Hant`, below).

On a recent Mac a full run of the Default plan took about three quarters of an hour with its build: about seven
minutes of the app's unit tests and more than half an hour of UI tests. The AssistOff plan took about seven minutes.
These times were measured when the Default plan ran 409 app unit tests; it now runs 645, and the times have not been
measured again.
Two things make a run fail for reasons that have nothing to do with the code:

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

The AssistOff plan runs the app's unit tests again with the aids' master switch off (`-assist NO` on launch), and
`OffPlanTests` fails if the switch did not reach them. CI runs it after the Critical or the Default plan, and only
when that plan passed:

    caffeinate -i xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan AssistOff \
      -destination "platform=iOS Simulator,name=$SIM" CODE_SIGNING_ALLOWED=NO

Both plans must pass with the same tests unedited, so the aids' saved settings must never leak from one test into
another. An app test that turns the master switch or the lock choice removes both saved keys in its tearDown and
never puts back a value it read. A UI test cannot remove a saved setting afterwards, so every UI test that needs the
aids pins both at launch (`-assist`, `-lockVariant`, below) and never turns either in the app.

The app's unit tests, and the UI tests that pin neither setting, read whatever the iPhone simulator has saved: a
lock chosen once by hand on it changes what they see. Run them on an iPhone simulator where the aids' settings were
never changed by hand, or erase it first (`xcrun simctl erase <UDID>`, with that iPhone simulator shut down).

### Launch arguments for UI tests

The app reads these from its launch arguments (`XCUIApplication.launchArguments`). Every UI test launch passes
`-quietCues YES`, through `XCUIApplication.quiet` and `XCUIApplication.teleop` in `UITestSupport.swift`, so the
iPhone simulator plays no vibration, sound or speech through the computer's speakers; the app still records every
cue.
The app is silent by itself as the unit-test host.

| Argument | What it does |
|---|---|
| `-quietCues YES` | no haptics, sounds or speech |
| `-robotProfile <id>` | drive the robot profile `App/Resources/Profiles/<id>.json` instead of the one the build names (`docs/PROFILE.md`) |
| `-liveLink NO` | launch in practice instead of on the real server |
| `-serverAddress <host:port>` | the saved server address; on the real server the app connects to it at launch |
| `-startRoute <raw value>` | open on that route (`Route.swift`), for example `s1_connect` |
| `-firstRunDone YES` | skip the permissions screen and the tutorial at launch |
| `-controlMode screenTurns`, `keyTurns` or `buttons`; `-hand left` or `right`; `-taskAid YES` or `NO`; `-appLanguage en` or `zh-Hant` | the saved settings, pinned for one launch |
| `-assist YES` or `NO`; `-lockVariant off`, `pressPress` or `holdThenSlide` | the aids' master switch and lock choice, pinned for one launch; a change in Settings still applies until the app quits |
| `-operatingFixture <name>` | show one of the named displays in `OperatingFixtures.swift` on the operating screen, and nothing else |
| `-screenFrame 375x667x20x0` | draw the app in a frame of that width and height, at the top left, with those top and bottom safe-area insets, to check a smaller phone's layout |
| `-voiceEntry YES` | show the control of the unfinished voice experiment on the operating screen, where it is hidden otherwise (`VoiceAxisEntryUITests`) |
| `-recordHaptics YES` | put the haptics the app asks for into a hidden element (`test.haptics`) that XCUITest can read |
| `-startConnected YES`, `-startBlocked YES`, `-startConnectionLost YES` | start marked connected, with commands blocked as on a slow link, or as a dropped link leaves things |

## The test plans

The scheme has four test plans (`TestPlans/`):

- **Default** runs every test in `TeleopTests` and `TeleopUITests` except `OperatorLiveTests` and
  `ServerMotionTests`. It needs no server: the tests that need one start the model on a local socket themselves.
  CI runs it every night.
- **Critical** runs the same `TeleopTests` and only the UI tests of the five journeys that, broken, leave the app
  useless. CI runs it on every push and pull request, so a run takes minutes instead of most of an hour:
  1. first run, Connect through the tutorial to the operating screen
     (`ConnectFlowTests.testFirstRunWalksThroughTheTutorialToTheOperatingScreen`);
  2. a tap on the STOP band stops; a short press on Release keeps the stop, and a full hold on it leaves the stop
     (`OperatingTouchTests.testATapOnTheStopBandStopsAndAHoldOnReleaseLeavesTheStop`);
  3. a launch with a saved address reaches the local server and shows the guide (both `LocalServerUITests`);
  4. a failed connect says why and offers practice (`ConnectFlowTests.testConnectShowsWhyItFailedAndOffersPractice`);
  5. denied system prompts still reach the tutorial (`ManualCheckTests.testDenyingPromptsStillReachesTutorial`).

  Every other UI test runs only in Default. They pin layouts that change with the design (`OperatingScreenTests`),
  or take minutes each (`StopBandTests`), or cover screens still changing (Settings, practice, scheme B's hint).
  Add a test to Critical only for a journey of the same weight, and keep it to five journeys: each added UI test
  costs every push its run time.
- **AssistOff** runs the same tests of `TeleopTests`, not the UI tests, launched with the hands-free aids' master
  switch off (`-assist NO`), with `TELEOP_EXPECT_ASSIST_OFF` set so that `OffPlanTests` runs and fails if the
  switch did not reach them. It shows that every app test, those written for version 1.0.1 included, passes
  unedited with the aids off. It needs no server either. CI runs it after Critical or Default, and only when that
  plan passed.
- **Live** runs only `OperatorLiveTests` and `ServerMotionTests`, which drive the arm in Isaac Sim.

Every plan sets the environment variable `OS_ACTIVITY_DT_MODE` to `NO`. Without it Xcode starts the tests with
`OS_ACTIVITY_DT_MODE=YES`, which copies every line any framework writes to the system log to the tests' console as
well. The networking threads behind the tests' real sockets write such lines on every connect and close, so when
whatever reads that console stalls for a few seconds, as it can on a CI runner, those threads wait inside the write,
the sockets stop, and a test that waits for a connection fails for a reason that has nothing to do with the app.
With `NO` those lines stay in the system log only. CI checks that the setting reached the unit tests (below).

The live tests move the arm in Isaac Sim on a machine other people use, so three things guard them:

1. They are in the Live plan only; the Default and Critical plans skip them by name.
2. They skip unless the test runner's environment has `TELEOP_MOTION` set, which `xcodebuild` passes on when the
   command line sets `TEST_RUNNER_TELEOP_MOTION=1`.
3. They connect to `127.0.0.1:8765` and skip if nothing answers there. That is the relay's port (below). To drive
   a server at another address, set `TEST_RUNNER_TELEOP_ADDRESS` on the command line, beside
   `TEST_RUNNER_TELEOP_MOTION`; the test runner sees it as `TELEOP_ADDRESS`. For example
   `TEST_RUNNER_TELEOP_ADDRESS=127.0.0.1:9100`.

Run them only when Isaac Sim is free and you mean to move its arm. They need the scene at its reset pose with nobody
else driving it. `OperatorLiveTests` may run in a recording session, where each success saves a take; it has not
been tried in one yet. Each test first resets the scene the way holding the top band does, which also releases an
emergency stop left latched.
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
  way to the goal. A working link that goes down, an emergency stop (on the phone, or in the server's `state`), or
  the server's states stopping while the link stays up (none for 5 s) fails the run at that step, with the app's
  last log lines. The arm and the object are read from the newest `state` on either connection, less than a second
  old. It passes only on what the server reported after the jaws let go on the goal: a `state` with
  `task_success`, or a `state` arriving after the last wait with the object resting inside the goal and the jaws
  reported open. That state, and the control connection's echo of a probe sent after the wait, must both arrive, so
  a link that goes down during the wait fails the run. A new episode alone is no success, because the server
  also resets when the object falls off the table. The test then checks that a success was seen, that the server's
  episode count is 1 (the scene reset once, after the success) and that the server's last `state` has no emergency
  stop. One more test runs it with a recorder on and checks that the guide, the saved take and the server's Wait
  reach the operating screen.
- `OperatorLiveTests`, in the Live plan, once per control mode, against the real server in Isaac Sim at full waits,
  with the same rule for a pass. `ServerMotionTests` adds scripted hand movements, the wrist following the phone,
  and the pick-and-place after many holds.

Every run prints one line, for example:

    PICK RUN (screenTurns): episode 0 -> 1, success seen YES, holds ended by the server 0, link lost no, object in goal no, 24 s, recorder none: PASS

It names the scheme, the server's episode before and after the run, whether a `state` said `task_success` after the
jaws let go, how many holds the server ended while they were held (its watchdog, or a late refusal), whether the
link was lost and during which step, and whether the `state` that arrived after the last wait had the object resting
in the goal with the jaws open. Last comes what the app's own model holds for the recorder at that moment, as the
operating screen's REC line is built from it: its state, the recording session's name and the saved count, for
example `recorder armed (session s-0101, 4 saved)`; `none` when the server records nothing, `not reported` when it
does not say. In a recording session, check the saved count against the session's file. A success there is shown
while the take is saved, but the server's states and the echoes of the app's probes come from its socket side, so
the run's last wait (5 s) needs no extra time: a silence that long is a lost link at 3 s first. It ends in PASS only
when the run passed by the script's rule, FAIL otherwise, or SKIP when the server reports no task.
`testALinkCutAfterTheLiftFailsTheRun` cuts the network path while the object is carried and expects the run to fail
for that reason.

`LinkStallTests` puts a network path under both of the app's sockets that can hold every message back in both
directions and then deliver them together, as an ordinary wireless network was measured doing for up to 1.8 s. A
1.8 s stall during an arm, gripper or wrist hold must cost that hold and nothing else: the link stays up, the
server's watchdog ends the hold, the phone plays LETGO with "Link hiccup." and no refusal, and the next hold
works. A longer stall is a lost link 3 s after the control connection's last message, and STOP pressed during a
short stall reaches the server when the path comes back. A STOP the server has not confirmed when a longer stall
loses the link is owed: the operator hears "No link. Not stopped." after "Link lost.", the screen shows the lost
link, and after connecting again `estop` goes out first and the server is stopped. The same tests cover a confirmed
stop, a stop from the server, a restarted server, an owed STOP released before connecting, a state from before a
release that must not confirm the STOP pressed right after it, and a reset from the stop that the server carried out
but whose answer the lost link kept back.

Before the app connects again, and before a server stops, these tests wait until the local server has read the close
of every socket the app closed (`LocalTeleopServer.openSockets` back to 0). On a CI runner, closing a socket
sometimes held up all networking in the test process for several seconds (3.7 s and 6.4 s were seen), so a connect
made right after a close did not start in time; the server only reads such a close after the hold-up has passed.

`LocalOperatorTests` uses the same hand against the local server for single behaviours: the wrist following the
phone in each scheme, STOP during a hold, the two ways out of a stop, and the holds that end when Settings opens,
the app leaves the foreground or the camera stops.

`LocalAssistTests` does the same for the hands-free aids, with the gestures in `ScriptedOperator+Assist.swift`: a follow
latched by each lock variant in both schemes, and its endings, each heard once; a tap on the guide's view from above
that arrives, in both schemes; a tap in the view's margin, refused with no start; a move that a server with a smaller
box cuts short, heard once as stopped short, in both schemes: before any correction when the move follows the pinch
point the server reports, and after at least one correction and no more than the profile allows when the server
reports none; a stall of the network path during a move, heard once as no arm data; an object held in the
jaws carried by a move; a touch during a move that stops it and starts nothing else while that thumb stays down; a tap
made right after a hold, with the server's answer to its stop held back by a stalled path, refused with "Wait." and
nothing on the wire, after which, once the answer has come, a second tap at the same point goes and arrives; and the
same with that answer lost while the listening connection goes on reporting, where taps are refused until the link's
own wait for an answer has run out, and a tap then goes and arrives. A refused tap is dropped: in both, the tap that
goes is a new one. No view lays out the screen in the unit-test host, so for a tap the hand also reports where the
guide's view from above is drawn, as the operating screen does.

`LocalFollowTests` runs moves to a tapped point the same way against a server model whose pinch point turns with the
arm's posture (`ServerModelConfig.toolTurn`, below): from the reset pose a tap arrives within the profile's tolerance,
heard as GO and "Arrived." alone; on an arm folded so that its jaws go the other way from the gripper link, a tap where
they cannot reach stops short by itself, heard as GO and the stopped-short ending alone; and a server that stops
reporting the pinch point during a move ends it stopped short, the arm stops, and what the link is asked to send never
jumps on the way.

`TeleopServerModel` (`Packages/TeleopCore/Sources/TeleopServerModel`) is one deterministic type with time passed
in. It applies the server's WebSocket rules and runs its simulation loop over a small world. Every number it uses
is in `ServerModelConfig`, with where it came from. `LocalTeleopServer` (`Sources/TeleopServerHost`) serves it on a
real WebSocket at 127.0.0.1, on a port the system picks, in real time. Its default is 60 steps a second, Isaac
Sim's nominal rate, faster than the simulation's machine manages; the protocol timers (the 750 ms watchdog, the
200 ms state broadcast) keep their real lengths.

Three of the model's choices exist for tests of the simulation's stop. `ServerModelConfig.reportsLoopHealth`, off by
default, as the recordings carry neither, puts `sim_stalled` and `loop_age_ms` in every `state`;
`ServerModelConfig.loopStallSeconds` (1 s) is how old the loop's last pass may be before the model calls it stalled;
and `ServerModel.stallLoop()` stops the loop for good while the front end keeps answering. A stalled model refuses
a scene reset `sim_stalled`, and a start and a stop release too once the checks of the stop's state before them have
passed (with the stop latched, a start gets `estop_active` and a release with no stop on gets `estop_not_active`). A
command that was queued but never taken by the loop is refused `sim_stalled` and latches the stop (`StallRuleTests`).

Two of the model's choices exist for tests of a move that follows the pinch point. `ServerModelConfig.toolTurn`, nil
by default, makes the pinch point a point fixed to a gripper that tilts with the arm's posture, as the gripper in
Isaac Sim does near its reset pose; the tool point in `state`, the grasp and where the jaw tips stop on the table then
follow it. `ServerModel.reportsToolPoint` starts as the configuration says and, turned off during a run, makes the
next positions go out without `tool_pos`, as from a server that has stopped reporting one.

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

`.github/workflows/ios.yml` runs on every push and pull request. A newer push to the same branch cancels the run
still going for the older one. `ci/ios.yml` must be an exact copy: the `checks` job fails when the two differ. Three
jobs run side by side, so the fast ones report in a few minutes instead of waiting for the UI tests:

1. `checks`, on Ubuntu: `python3 scripts/check-strings.py`, `python3 scripts/check-dead-buttons.py`,
   `python3 scripts/check-arm-constants.py`, the scripts'
   own unit tests (`python3 -m unittest discover -s scripts -p 'test_*.py'`), the copy check, and a gitleaks scan
   of the whole history for leaked keys and tokens (the gitleaks version is pinned in the workflow).
2. `core`, on GitHub's `macos-15` image with the Xcode that image ships: `scripts/check-format.sh`, which only
   reports (below), `swift test` in `Packages/TeleopCore`, and the session safety checker
   (`tools/session-safety/scripts/check.sh`).
3. `app`, on the same image: XcodeGen at the version pinned in the workflow, `xcodegen generate`, then the first
   available iPhone simulator, picked as above; it boots the device of that name on the newest iOS, the one
   `xcodebuild` takes for a destination given by name, and waits until it has finished booting. Then
   `xcodebuild test` with `CODE_SIGNING_ALLOWED=NO`: the Critical plan on a push or pull request, the Default plan
   in the nightly run (02:00 Asia/Taipei, on the default branch only), and either one when started by hand
   (Actions, ios, Run workflow), logged to `build/xcodebuild.log` with its result bundle, then
   `python3 scripts/check-test-console.py build/xcodebuild.log` (below). Then the AssistOff plan on the same
   simulator, logged to `build/xcodebuild-assist-off.log`, with the same check on that log; this step runs only
   when the first plan and its check passed. It uploads both xcodebuild logs, the screenshots the UI tests attach,
   and the first plan's result bundle as artifacts.

A second workflow, `.github/workflows/git-hygiene.yml`, runs `scripts/check-git-hygiene.py` on every push and on a
pull request when it is opened, edited, updated or reopened. It reads only the pull request's title and body, the
branch name and the new commits' messages, never the files, and fails on Chinese, Japanese or Korean characters (with
the punctuation that goes with them), on co-author trailers and on tool-attribution markers. It can also run as a commit-msg hook.

A failure in the nightly Default run does not block a merge, since the merge rules only see the Critical run of the
pull request. Read the nightly result before a release.

`scripts/check-test-console.py` fails when the system log was copied to the unit tests' console after all, which
means a test plan lost its `OS_ACTIVITY_DT_MODE=NO`. In the unit tests' part of the log it looks for the lines the
networking library writes to the system log: its function names, such as `nw_listener_socket_inbox_create_socket`,
and the names its connection log gives each connection, such as `[C1:2]`. XCTest, `xcodebuild` and the app never
write them, so they reach the console only through that copy. Its message names the test plan to fix. It runs also
when the tests failed, since with the copy on the local-server tests can fail on a stalled console. It reads a local
log the same way: `python3 scripts/check-test-console.py <log>`.

The layout check runs with `continue-on-error`, so a finding shows on the run but does not fail it. CI's Xcode is
older than the one the code was laid out with, and the two `swift format` versions lay out a few constructs
differently, so a file that passes here can be reported there. `.swift-format` names only the settings that differ
from swift format's defaults (four-space indents, 120 columns, no indent inside `#if`, every rewriting rule off), so
that the older version can read it too. The strict check that counts is a step of the release procedure
(`docs/RELEASING.md`), run with the current Xcode.

CI never runs the Live plan or the safety checker's mutation run (`tools/session-safety/scripts/mutants.py`).
Run the mutation run yourself after changing the checker or a guarded code path.

CI's iPhone simulator and Xcode can be older than a current Mac's, so a UI test that passes locally can fail
there. Two differences matter: on iOS 18 a system permission alert's buttons have no identifiers (the UI tests'
`answerSystemPrompts` in `SystemPrompts.swift` falls back to their order), and a SwiftUI control built from `Label`
exposes its icon as a second accessibility element unless it has `.accessibilityElement(children: .ignore)` and an
`.accessibilityLabel`.
