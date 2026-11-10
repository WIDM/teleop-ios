# Changelog

What each version of the iOS app does. The version shows at the bottom of Settings.

Rules: every build installed on a phone gets a new version here first. `0.x.0` adds or changes behaviour;
`0.x.y` only fixes. `MARKETING_VERSION` in `project.yml` is the single place the number lives, and each
version is tagged `vX.Y.Z` on the commit that carries it.

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
