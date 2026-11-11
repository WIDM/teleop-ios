# Changelog

What each version of the iOS app does. The version shows at the bottom of Settings.

Rules: every build installed on a phone gets a new version here first. `0.x.0` adds or changes behaviour;
`0.x.y` only fixes. `MARKETING_VERSION` in `project.yml` is the single place the number lives, and each
version is tagged `vX.Y.Z` on the commit that carries it.

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
- The map's grasp point is now the sideways-jaw one, measured on the S4 simulator: 0.7 cm left, 3.6 cm
  ahead and 8.8 cm below the point the server reports. From the start pose the cube is 2.3 cm right, 2.3 cm
  ahead and 2 cm down. A caption under the map says "Jaws sideways first: hold Turn until it stops, twice" while the cube is
  the target.
- The whole task now passes end to end through the app's own code against the simulator
  (`ServerMotionTests.testPickAndPlaceByScript`, 135 s): open, two presses of Turn, two holds to the grasp
  point, close, lift, carry, lower, open.
- Known limit, in the server as published: every hold lets the wrist droop a little more, about 0.2 to 0.5
  degrees a hold (3 to 6 degrees over the 9 to 35 holds of a hand-driven attempt), because the measured,
  sagged wrist angle is copied into the wrist target at every hold start and stop. The jaw tips then sit up
  to a centimetre behind where the map shows them. On such a server, reach the cube in few holds and Reset
  if it took many. With the wrist target kept as commanded (a four-line change, running on the development
  simulator since 2026-11-11) the wrist stays within 0.2 degrees over 12 holds, and
  `ServerMotionTests.testPickAndPlaceAfterManyHolds` passes.
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

First version driven by hand against Isaac Sim (SO-ARM101, `thomas-s4`).

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
