# Changelog

What each version of the iOS app does. The version shows at the bottom of Settings.

Rules: every build installed on a phone gets a new version here first. `0.x.0` adds or changes behaviour;
`0.x.y` only fixes. `MARKETING_VERSION` in `project.yml` is the single place the number lives, and each
version is tagged `vX.Y.Z` on the commit that carries it.

## Unreleased

## 1.0.0 (2026-11-13)

One operating screen, held rather than looked at, takes the place of every control screen, and everything the
design mock-up only pretended to do is gone.

What a person using the app notices:

- **One operating screen.** Standby, the camera view and its handles, the high-latency screen, the fallback screens
  and the stop screen are one screen. A red STOP band runs along the bottom and stops at touch-down. The top band
  holds the gear (Settings), the REC line, the link dot and the mode chip; holding it for 2 seconds resets the
  scene. The middle shows one word in a colour (Ready, Moving, Turning, Closing, Wait, Slow link, STOPPED,
  Link lost and others) with a line or two under it. The phone stays awake while it shows.
- **Three control modes**, in Settings → Control → Mode, and Settings → Hand for the hand that holds the phone:
  - Screen turns (A): hold vol+ and the arm follows the phone; hold vol− to close the jaws; hold a thumb on the
    glass and turn the phone to turn or tilt the wrist; slide the thumb up and hold to open the jaws.
  - Key turns (B): hold vol+ and the arm follows the phone; hold vol− and turn the phone to turn or tilt the wrist;
    hold the half of the screen under the thumb to close the jaws, the other half to open them.
  - Buttons: hold Forward, Back, Left, Right, Up, Down, Open or Close; Fine and Coarse set the speed. The phone's
    movement is not used, and the volume keys change the volume.
- **The wrist follows the phone** while its input is held: one axis per hold, up to 55 degrees of turn or 20 of
  tilt, and never more than about 2 degrees ahead of the measured wrist. The Turn and Tilt handles are gone.
- **One thing at a time.** A press made while another control is held does nothing until it is let go, and the
  phone signals that it did nothing. Every hold ends, with its stop sent, when the app leaves the foreground, when
  Settings or Connect opens, and when the camera stops; a key or a thumb held across that stays dead until it is
  released.
- **Closing again while the jaws hold something is refused** ("Already gripping."), because a second close
  loosens the grip.
- **The upright prompt no longer buzzes as the phone moves.** A vol+ press with the phone held sideways or face down
  is refused with "Hold the phone upright."
- **You hear and feel what happened** without looking: a vibration pattern for each kind of event, three sounds,
  and spoken reasons, limits, stops and recorder news in English or Traditional Chinese. The tutorial teaches them.
- **On target is felt.** When the open jaws come onto the target the server reports (where the guide says "On
  target"), the phone plays one tick and then a short soft swell, once per approach; no sound, no speech. It plays
  in Buttons too, where no guide is drawn. It stays silent while the jaw position is approximate, while the robot is
  stopped, with the task aid off, when no target is reported, and in practice.
- **The recorder shows.** The REC line says whether the server records and whether it is armed, capturing,
  waiting or off, with the take's length and the saved and discarded counts. A saved take shows "Saved N" for
  2 seconds and is spoken. Settings → Recording repeats the counts.
- **Leaving a stop.** Holding the top band for 2 seconds resets the scene and, once the server confirms it,
  releases the stop. **Release, keep scene** (hold 1 second) is offered only in practice and when the server
  reports no recorder or does not say. Every STOP is sent to the server, also when the robot is already stopped.
  A STOP pressed with no link goes out after the next connection; until then the screen shows the link's state,
  not STOPPED. Settings shows a red STOPPED band while the robot is stopped.
- **The guide**, drawn in the two phone modes, shows the work area from above and from behind: where the jaws
  pinch, where the arm is being sent, the height above the table, how far the jaws are open, the wrist's turn and
  tilt, and, when the server reports a task, the target, the goal, "On target" and "Holding". It works for any arm
  and replaces the guide drawn for the cube task. It is on by default (Settings → Task aid). Buttons shows the pad
  in its place.
- **Where the jaws close.** When the server reports its grasp point (`tool_pos`), the guide's jaw marker is that
  point. Otherwise the app estimates it from the arm's position and the wrist angles; where the estimate may be
  off by more than half the on-target window, the marker is a hollow ring with no centre dot, an orange line says
  "Jaw position is approximate", and the guide never says "On target".
- **Practice without a robot** takes the place of the Real server switch: Connect → "Practice without a robot", or
  Settings → Practice. Purple stripes and PRACTICE 練習 mark it, nothing is sent or recorded, and every launch is
  on the real server. It cannot start or end while the robot is stopped.
- **Connect** opens from a tap on "Not connected", and says "Connection lost. The arm stopped." after a lost link.
  The address field starts empty.
- **Settings** has Mode, Hand, Arm speed (in place of Sensitivity), Smoothing (Off, Low, High), Task aid,
  Recording, Server, Practice, Replay tutorial, Language and About; five taps on the version show the developer
  log.
- **First launch** asks for the camera only, then shows three tutorial pages for the control mode; once the
  operating screen has been reached, launches open on it and connect to the saved server. Settings → Replay
  tutorial shows the pages again; it is hidden while the robot is stopped, because the tutorial pages do not show
  the stop.
- **The tutorial's last page** says what the on-target cue means, in every mode. Only in the two phone modes does
  it also say to keep holding and keep still until the arm stops: in Buttons a held arrow keeps moving the arm.
- Fixed: on a busy phone a press could end at once with "Too fast." although the hand moved slowly, when two
  readings of the phone's position came a millisecond apart. The speed is now measured over at least 16 ms.
- Fixed: when the phone stalled for more than a second, the app said "Link lost." and closed the connection,
  although the server had kept sending. Silence is now counted only while the app is running.
- Fixed: a short stall of an ordinary wireless network ended the session. The link now counts as lost only after
  3 seconds in which the server answers nothing, so a stall of up to about 2.5 s no longer ends the session. One
  longer than 0.75 s costs the hold in progress (the server's own watchdog ends it, and the phone says "Link
  hiccup."), and the next press works.
- **Link lost** on the operating screen now says "Connect again in Settings": the app does not reconnect by itself.
- Gone, because they only pretended: the mode choice and cloud mode, base mode, the Record, Save and Discard
  screens, the "Recent" servers, the errors screen, the connection details sheet with its fixed heartbeat line, the
  faked latency and its debug sheet, the Motion permission, the Deadband slider, the Developer switch and
  "Send hello".
- Every screen keeps its own colours on a phone in dark mode.

What a maintainer needs to know:

- The input rules are in `TeleopCore`: `InputArbiter` (schemes A and B), `ButtonArbiter`, `SurfaceLayout`,
  `RotationMapper` and `InputConstants`. `OperatingController` is the one place where keys, touches, the phone's
  attitude and the pad become commands. `OperatingRules` works out the screen's state and the arm reading, and
  `GuidePicture` the guide, as pure functions.
- Feedback: `FeedbackMonitor`, `CueTable` and `CueScheduler` decide every cue; `RecorderNarrator` speaks for the
  recorder; `StopExits` chooses the ways out of a stop; `WristLeadBound` bounds wrist commands. The players for
  haptics, sounds and speech decide nothing.
- A second, listening connection receives `state` during holds. The app names itself
  `teleop-ios/<version> (<build>)` in `hello`. The link counts as lost after 3 s with nothing on the control
  connection, or on either connection while the listening one is up (it was 2 s and 1.2 s).
- Session: `wristStart`, `wristEnd`, `sceneResetDone` and `switchLink` are new. The jaw turn (`turnStart`,
  `turnEnd`) is gone, and so are the routes of the removed screens, with their actions: the mode choice and cloud
  mode (`p1_mode_select`, `p2_cloud_pass`, `p3_cloud_fail`), recording and base mode (`s3a_recording`,
  `s3b_record_end`, `s3m_base`), the fallback screens (`s5_fallback`, `s5a_fallback_recording`) and the errors
  screen (`s7_errors`). `TeleopAction.replayTutorial` is sent from Settings, never while the stop is latched.
  `FakeTeleopState.resetClearsStop` records a reset asked for in the stop state. Practice starts and ends only
  through `AppModel.startPractice` and `leavePractice`.
- Tests: `TeleopServerModel`, checked against 18 recordings of the real server, and `LocalTeleopServer`, which serves
  it on a local socket. `ScriptedOperator` presses raw inputs only, and `LocalPickAndPlaceTests` runs a whole
  pick-and-place in each control mode in every default run; a run passes only on the server's own report of the
  object in the goal or of a success, and a link that goes down fails it. `LinkStallTests` stalls the network path
  under the app against the local server. The scheme has a Default and a Live test plan; the Live plan holds
  `OperatorLiveTests` and `ServerMotionTests`.
- UI tests launch silent (`-quietCues YES`) and draw every operating state from `OperatingFixtures`, in both
  languages and at two screen heights (`-screenFrame`).
- `scripts/check-strings.py` checks all four string catalogs in both languages, their format specifiers and the
  Chinese punctuation; `scripts/check-dead-buttons.py` fails on a button with an empty action.
- `RobotProfile` holds the object and goal sizes, the workspace box, the table height, the wrist signs and whether
  a second close loosens the grip; `ServerModelProfileTests` holds the server model to the same numbers.
- The session safety checker covers the new routes and state. Its promise that every screen shows a latched stop
  (U1) names the one exception: a STOP that reached no server.
- The guide's pinch point comes from `RobotProfile.pinchPoint`: the server's `tool_pos` when a state carries it,
  else the gripper link origin plus `toolOffset`, approximate where `estimateBound` allows more than 3 mm of error.
  The server model reports `tool_pos` unless `ServerModelConfig.reportsToolPoint` is off, and the pick-and-place
  runs against both. `OnTargetCue` decides the on-target haptic.
- An upload to App Store Connect has what the repository can give it: a privacy manifest
  (`App/PrivacyInfo.xcprivacy`: user defaults for the app's own settings, the system uptime for timing events, no
  tracking, no collected data) and `ITSAppUsesNonExemptEncryption` set to false. `docs/RELEASING.md` lists the
  steps only the Apple account holder can take.
- The maintenance tools are in `tools/`: the session safety checker in `tools/session-safety` and the app check
  scripts in `tools/app-checks`, each with a README.
- CI builds with Xcode 16.4 again: it could not type-check two long expressions in time. The developer log's line
  for a link that never got ready says "no welcome or first state from server".
- `.swift-format` holds the layout the Swift code is written in, and all of it is laid out so.
  `scripts/check-format.sh` checks it strictly; it is a release step, and CI runs it only as a report.
- `docs/ARCHITECTURE.md`, `docs/PROTOCOL.md`, `docs/TESTING.md` and `docs/RELEASING.md` describe the app as it is.

## 0.10.0 (2026-11-11)

The wrist can tilt, and the guide shows how high the jaws are.

- Two new hold-to-tilt handles sit under the two Turn handles: Tilt down points the jaws more toward the table,
  Tilt up lifts them away from it. They work like Turn: one press tilts by up to 10 degrees from where the wrist
  was when the press began, and it stays there on release. Press again to tilt further.
- The guide now has two views, one under the other, lined up left to right and at the same scale. "From above" is
  the map you had, with a small grey square for the robot base so you can tell which side the arm is on. "From
  behind" shows the table as a line, the cube sitting on it, the goal on the table, the ring at the height of the jaw
  tips with a pair of jaws above it, and one number: how far the jaw tips are above or below the cube's centre, for
  example "2.1 cm above", "0.6 cm below" or "level". While you carry the cube it measures to the goal's height. The
  old height bar is gone.
- After you tilt the wrist the map no longer shows where the jaw tips are, because it was measured at the start
  tilt. The guide stops saying "On the cube" and says so instead. Press Reset to use it again.
- On a scene that starts with the jaws already side by side (a start wrist roll of 90 degrees), the caption
  "Jaws sideways first" no longer shows and nothing has to be turned before a grasp. The app shows that caption
  only for a setup whose scene starts the jaws front to back.
- Known limit: the app expects the arm's targets to stay as commanded when a hold ends. Then, through the app's
  own code, no cube was dropped and the task succeeded 10 times in 10 (seven plain runs and three after a dozen
  extra holds). Without it, when the measured arm and gripper angles are copied into their targets at that moment,
  the arm sinks about half a centimetre and bounces, and a cube held at the jaw tips is shaken out: the cube was
  dropped in 3 of 6 runs and the task succeeded 1 time in 4.
- Why: in a hand test the jaws were closed 1 to 2 cm from the grasp point and not side by side, because
  nothing on the screen showed how high they were, the turn had to be remembered after every Reset, and the
  wrist tilt could not be moved at all. The cube, wedged between the jaws and the table, trembled by 4 to 7 mm.

## 0.9.1 (2026-11-11)

Two fixes to the held controls.

- Fixed: pressing Turn twice in a row, or going from the Open handle to vol−, or from the gripper to the arm
  hold, no longer needs a pause. The server takes a moment to finish the control you just let go of and refuses
  a new one until then, so the second press could be refused and nothing moved. The app now holds the new
  press back until the server says the old one is done (at most 0.8 s), then starts it.
- Fixed: letting go of one control no longer stops another. With one finger on Turn and a second finger taking
  over on the other Turn handle, lifting the first finger used to stop the turn the second was still holding.
  The same went for the Open handle and vol−. A release now only ends the hold that its own control started.

## 0.9.0 (2026-11-11)

The jaws can turn now, so the cube can be held.

- Two new hold-to-turn handles sit under Open on the left edge of the camera view: counterclockwise and
  clockwise. The jaws turn while a handle is held and stay where they are on release. The server reports no
  wrist angle, so there is no readout: watch the video. One press turns the jaws by up to 45 degrees from
  where they were when the press began, so hold until they stop, and press twice for sideways jaws.
- Why: with the jaws as they start (open front to back) a scripted, position-exact grasp lifted the cube 1
  time in 19 and never placed it. With the jaws turned 90 degrees (side by side) it lifted the cube 8 times
  in 10, and the server counted the task done 6 times in 10. `scripts/sim_pick_place.py` repeats the
  measurement.
- The map's grasp point is now the sideways-jaw one, measured on the simulator: 0.7 cm left, 3.6 cm
  ahead and 8.8 cm below the point the server reports. From the start pose the cube is 2.3 cm right, 2.3 cm
  ahead and 2 cm down. A caption under the map says "Jaws sideways first: hold Turn until it stops, twice" while the cube is
  the target.
- The whole task now passes end to end through the app's own code against the simulator
  (`ServerMotionTests.testPickAndPlaceByScript`, 135 s): open, two presses of Turn, two holds to the grasp
  point, close, lift, carry, lower, open.
- Known limit: the app expects the wrist target to stay as commanded when a hold starts and stops. Then the
  wrist stays within 0.2 degrees over 12 holds, and `ServerMotionTests.testPickAndPlaceAfterManyHolds` passes.
  Without it, when the measured, sagged wrist angle is copied into the wrist target at every hold start and stop,
  every hold lets the wrist droop a little more, about 0.2 to 0.5 degrees a hold (3 to 6 degrees over the 9 to
  35 holds of a hand-driven attempt), and the jaw tips sit up to a centimetre behind where the map shows them.
  Then reach the cube in few holds, and Reset if it took many.
- Only one of the arm hold, the gripper hold and the jaw turn runs at a time, as on the server: starting one
  ends the other, and a turn is refused while the arm is held.
- The turn handles are not on the fallback screens (no volume keys) yet.
- Fixed: the on-screen gripper button is one accessibility element, so it can be pressed in the iOS 18
  simulator (it exposed its icon as a second one).
- Fixed: the UI tests' helper that answers the system permission prompt works on iOS 18.

## 0.8.0 (2026-11-11)

The map pointed at the wrong place. Now the ring is where the jaws close.

- Two things were wrong in how the app read the server's state, and together they put the cube about 8 cm
  from where the map drew it. The point the server reports for the arm is the gripper link origin, while the
  jaws pinch 6.6 cm ahead of it and 8.65 cm below. And the arm is reported in the robot base frame while the
  cube and goal are in the world frame, with the base 5 cm above the world origin.
- `RobotProfile` carries those two facts per robot setup (tool offset, base position). The SO-101 simulator
  profile was measured by grasping the cube in Isaac Sim; the robot's USD model predicts 5.8 cm and 8.9 cm.
- From the start pose the cube is nearly under the jaws: 1.6 cm right, 0.7 cm back, 2.1 cm down. Earlier
  versions sent the operator 6 cm forward, onto the cube.
- The ring turns green and the caption says "On the cube. Hold vol− to grasp." when the pinch point is within
  6 mm of the cube across the table and 8 mm in height.
- Known limit: in this simulator a grasp at the start wrist angle is fragile. Of about fifteen scripted
  attempts around the measured pose one lifted the cube; the others pushed it or squeezed it out. The app has
  no wrist control yet (the server's `wrist` control mode), which is the likely way to a square grasp.

## 0.7.0 (2026-11-10)

A picture instead of numbers.

- The centre of the camera view is a top-down map of the task: a white ring for the gripper, a red square
  for the cube, a dashed green square for the goal. Up on the map is the operator's forward. A bar beside
  it shows height: the ring comes down toward the red mark. The map zooms to keep all three in view, and a
  held cube travels with the ring.
- The numeric offsets of 0.5.0 are gone from the screen. Nobody read them while moving the phone.
- `-demoGuidance YES` shows the map without a server, for screenshots and UI tests.

## 0.6.0 (2026-11-10)

Directions were skewed by 45 degrees; now they are straight.

- ARKit's camera axes are fixed to the sensor, which sits landscape. The app had read them as if they were
  the edges of a portrait phone, so with the phone upright "forward" pointed 45 degrees to the right of
  where the operator faced. Right, forward and up now come from the phone's real edges (`PhoneAxes`).
- The same mistake had the upright prompt backwards in 0.5.1: it showed for an upright phone and cleared
  for a flat one. It now shows only when the phone is sideways, facing the floor or upside down.
- The prompt is felt as well as seen: two short buzzes when the phone goes wrong, one when it is right
  again, with a 10 degree margin so it does not chatter at the limit. Silent while E-stop is latched.

## 0.5.1 (2026-11-10)

- "Hold the phone upright" was nearly impossible to clear: it fired past 35 degrees of any tilt, and a phone
  held to be read leans back 40 to 60 degrees. It now fires only for what breaks the direction mapping:
  sideways by more than 40 degrees, the screen turned toward the floor by more than 30, or upside down.
  Leaning back is fine all the way to flat.

## 0.5.0 (2026-11-10)

Guidance for the pick-and-place task, and no more safety stops from a fast hand.

- The centre of the camera view says where the cube is from the gripper, in cm right or left, forward or
  back, up or down. Once the gripper is closed on the cube it says where the goal is. It updates during a
  hold from where the arm is being sent.
- "Hold the phone upright" replaces everything in the centre when the phone is tilted more than 35 degrees.
- One server hold never asks for more than 8 cm. When the hand wants more, the app ends the server hold,
  reads the arm's real position, and starts the next one from there, about every 1.5 s. This replaces the
  arm-speed estimate of 0.4.0, which still tripped the server when the arm was stuck.
- "The arm is at the edge of its range this way" appears when the arm did not move during one of those
  stretches. The simulator limits the arm to 8 cm either way from where it started on each axis.
- Shorter hints ("Hold vol−: close. Left edge: open"), and the Open handle sits 20 pt lower so the latency
  banner does not cover it.
- `ServerMotionTests` drives the real app code with scripted phone motion against the server:
  `TEST_RUNNER_TELEOP_MOTION=1 xcodebuild test ... -only-testing:TeleopTests/ServerMotionTests`.

## 0.4.0 (2026-11-10)

Why E-stop happens, and fewer of them.

- S4 says what latched E-stop: STOP pressed, the arm fell more than 10 cm behind the phone, the robot was
  already stopped when the app connected, or the server's own reason code.
- The command never leads the estimated arm position by more than 8 cm, under the server's 10 cm trip
  (`pose_tracking_safety_stop`). Past that the command waits for the arm and the screen says
  "Arm is catching up. Slow down."
- The arm speed behind that estimate starts at 1.5 cm/s and is corrected after each hold from where the
  server says the arm ended, by 30% at most per hold.
- Settings shows the version.

## 0.3.0 (2026-11-10)

First version driven by hand against Isaac Sim (SO-ARM101).

- Gripper moves only while held. vol− closes; a left-edge Open handle opens (P4, P6, S3a, S3m). S5 and S5a
  have Hold: close and Hold: open buttons. The one-shot toggle blocked the simulated arm for about 30 s.
- Phone offset is sent as right, forward and up as the operator sees them at the start of the hold, upright
  or flat. Raw ARKit axes had sent the arm backward when the phone went up.
- Sensitivity and smoothing now take effect: they are applied in the app, since the server ignores them in
  translation mode. Deadband still has no effect on translation.
- During a live hold the centre of the camera view shows the commanded offset in cm.

## 0.2.0 (2026-11-10)

Real server link.

- Settings > Real server swaps the built-in demo for a WebSocket to the teleop server (hold protocol,
  envelope v1). Off by default.
- Hold streams the ARKit offset at 30 Hz; STOP, release and Reset map to `estop`, `estop_reset` and
  `reset_scene`. A lost link opens S7, or keeps S4 if latched.
- Round trip is measured twice a second; two slow samples in a row block commands.
- S3m shows the "Gripper aim" label like P4.

## 0.1.0 (2026-11-10 and before)

Built-in demo only, no networking.

- All 20 screens of Mockup v2 iOS, in English and Traditional Chinese with an in-app language switch.
- Volume keys: vol+ hold moves the arm, vol− toggles the gripper. Haptics for gripper, blocked commands and
  E-stop.
- Camera and motion permission prompts from S2. ARKit world tracking on control screens.
- Reset scene, switch mode back to mode select, developer mode with an action log.
