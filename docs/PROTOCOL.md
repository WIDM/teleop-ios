# How the app talks to the server

The app drives a simulated SO-101 robot arm. The simulation runs on a lab machine, and a small server inside it
takes commands over a WebSocket (one long-lived, two-way connection that carries text messages). This document is
the conversation between the two: what each side sends, when, and what the app does with each answer.

The app side lives in `Packages/TeleopCore/Sources/TeleopCore/Link/TeleopLink.swift` (the messages and their
rules, no sockets or timers) and `App/Sources/Link/LiveLinkController.swift` (the sockets, the timers and the two
connections). `TeleopServerModel` in the same package is a model of the server for tests; its rules and its
recordings of the real server back most of what is written here.

## Words used here

- **Hold**: a control that runs only while the operator keeps a key or button pressed. The app sends a *start*
  when the press begins, *updates* or *keepalives* while it lasts, and a *stop* when it ends. The server runs one
  hold at a time.
- **Ack** (acknowledgement): the server's answer to one message, naming that message's sequence number.
- **Final ack**: the ack a start gets when the hold it started has ended, sent from the simulation loop and
  followed by a `state`. A scene reset gets one too, when the reset is done.
- **Immediate refusal**: the ack a start gets instead when the server refuses it on arrival (`busy`,
  `sim_not_ready`, `estop_active`, or a validation code such as `invalid_pose_start`). No `state` follows it, and no
  final ack comes later. Every start gets exactly one of the two.
- **E-stop** (emergency stop): a latched state in which the server refuses every motion until it is released.
- **Physics step**: one pass of the simulation loop. The simulation counts 60 steps per simulated second; the lab
  machine runs fewer than 60 per real second, so every server speed is slower in real time than its number says.
- **Base frame**: positions measured from the robot's base, in metres. +x points toward the goal (the operator's
  left), −y points forward onto the table, +z points up. **World frame**: the simulation's own origin; the base
  sits 5 cm above it, so a base-frame position is the world-frame one minus (0, 0, 0.05).
- **Gripper link origin**: the point the server reports for the arm. It is not where the jaws close; that point
  (the *pinch point*) is a fixed offset away while the wrist stays put (`RobotProfile.toolOffset` in
  `App/Sources/Link/Guidance.swift`).
- **Wrist roll** turns the jaws about the forearm; **wrist pitch** (the server says *flex*) tips them toward or
  away from the table. **Jaws** are the two fingers of the gripper.
- **Clamp**: the server cuts a target short at a limit, for example the edge of the box the arm must stay in. The
  arm goes as far as it may and no further; the phone tells the operator "as far as it goes".
- **`ik`**: a field of `state`, named after *inverse kinematics* (working out the joint angles that put the gripper
  at a given point). It reports what the server is doing, for example `pose_tracking` or `resetting`.
- **Recorder, take, demonstration**: the server can record what the arm does while a person works the task, so the
  lab collects examples of the task done by hand. The *recorder* is that part of the server. A *take* is one
  recorded attempt, from the first command after a reset to the end of the attempt. A take that ends in success is
  kept as a *demonstration* in the server's output file; any other take is thrown away.
- **STOP** and **Reset** are controls on the phone: STOP latches the emergency stop, Reset asks the server to put
  the scene back as it started (below).
- **The map** is the phone's top-down drawing of the arm, the cube and the goal. **The guide** tells the operator
  where the cube or the goal is from the jaws.

## The envelope

Every message in both directions is one JSON object with five keys:

```json
{"v": 1, "type": "pose_stop", "ts": 1794378689520, "seq": 66, "payload": {}}
```

| Key | Meaning |
|---|---|
| `v` | Protocol version. The app always sends 1. The server accepts 0 or 1 and fixes the version for the connection at its first message. |
| `type` | What the message is. |
| `ts` | The sender's clock, in milliseconds since 1970. The server does not compare it with anything. |
| `seq` | A number that must grow with every message on one connection. The app starts at 1 and adds 1 each time. The server drops a message whose `seq` is not larger than the last one, without a word. |
| `payload` | An object with the message's own fields; `{}` when there are none. |

The app writes keys in sorted order. Its JSON encoder may print a decimal such as 0.3 as `0.29999999999999999`;
the server reads both as the same number.

The examples in this document are copied from the recordings of the real server in
`Packages/TeleopCore/Tests/TeleopServerModelTests/Recordings` (the file is named with each). The client in those
recordings is `scripts/trace_scenarios.py`, which speaks the same protocol as the app but writes keys in its own
order. Where the app's own payload differs, the text says so. Names and the server's session id are replaced by
placeholders.

In a server message, `seq` is the client message it answers, or the newest one it has seen. The app ignores it and
reads the acknowledged number from `payload.seq` instead.

## Starting a conversation

The first message on a connection must be `hello`, with exactly these two fields:

```json
{"v": 1, "type": "hello", "ts": 1794378668949, "seq": 1, "payload": {"client": "phone", "name": "<client name>"}}
```

(`s00_hello`.)

`name` is how the server's log names the connection (`TeleopLink.hello(name:)` has the app's default). Any other
field in the payload, or any other message before `hello`, is answered with an `error` message.

The server answers with `welcome`, then a first `state` (described below):

```json
{"v": 1, "type": "welcome", "ts": 1794378668966, "seq": 1,
 "payload": {"session": "<uuid>", "config": {"coarse_cm": 2.0, "fine_cm": 0.5}}}
```

(`s00_hello`.)

`session` names the server run: it changes only when the server restarts. The app keeps it to notice a restart
across a reconnect (the scene then starts over). It ignores `config`.

The link is usable once `welcome` and a first `state` have arrived (`TeleopLink.ready`). Until then the app sends
no commands. If the link is not ready within 5 seconds, the app drops the socket and reports the link lost.

## What the app sends

| Message | When | Payload the app sends | Answer |
|---|---|---|---|
| `hello` | first, on each connection | `client`, `name` | `welcome`, then `state` |
| `test` | twice a second while the link is up | `{}` | the same text echoed back at once |
| `pose_start` | an arm hold begins | see below | a final ack when the hold ends |
| `pose_update` | 30 times a second during an arm hold | the hand's displacement | none |
| `pose_stop` | the arm hold ends | `{}` | an ack at once |
| `gripper_jog_start` | a gripper hold begins | `action`, `step` | a final ack when the hold ends |
| `jog_keepalive` | every 133 ms during a gripper hold | `{}` | none |
| `gripper_jog_stop` | the gripper hold ends | `{}` | an ack at once |
| `orient_start` | a wrist hold (turn or tilt) begins | see below | a final ack when the hold ends |
| `orient_update` | 30 times a second during a wrist hold | the rotation asked for | none |
| `orient_stop` | the wrist hold ends | `{}` | an ack at once |
| `estop` | STOP is pressed | `{}` | an ack at once |
| `estop_reset` | STOP is released | `{}` | an ack at once |
| `reset_scene` | Reset is pressed | `{}` | an ack when the reset has finished |

The server also accepts messages the app does not send today: `mode`, `move_delta`, `jog_start`, `jog_stop`,
`joint_jog_start`, `joint_jog_stop`, `joint_delta` and the one-shot `gripper`. The one-shot `gripper` is avoided on
purpose: in the simulator one such command kept every other command waiting for tens of seconds.

### `test`: the round trip and the heartbeat

```json
{"v": 1, "type": "test", "ts": 1794378679453, "seq": 3, "payload": {}}
```

(`s01_idle`, sent and echoed.) The server echoes the text unchanged. The app times the echo (`.latency`). Two round trips of 400 ms or more in a
row block commands and end anything held, until a faster one comes (`TeleopSession`, `linkLatency`). The echo is
also what keeps the link counted as alive during a hold, when the server sends nothing else on this connection.

### `pose_start`, `pose_update`, `pose_stop`: moving the arm

```json
{"v": 1, "type": "pose_start", "ts": 1794378687456, "seq": 5,
 "payload": {"frame": "webxr_local", "rate_hz": 30, "control_mode": "translation", "gain": 1.0, "deadband_deg": 2.5, "smoothing": 0.3}}
{"v": 1, "type": "pose_update", "ts": 1794378688418, "seq": 34,
 "payload": {"p_rel_m": [0.0, 0.0097, 0.0], "q_rel": [0, 0, 0, 1], "gripper_delta": 0}}
{"v": 1, "type": "pose_stop", "ts": 1794378689520, "seq": 66, "payload": {}}
```

(`s02_pose_hold`.) The app sends the same `pose_start` with `deadband_deg` 0 and the gain and smoothing chosen in
its settings.

`p_rel_m` is the hand's displacement since the hold began, in metres, rounded to 0.1 mm. It is an absolute target
within the hold, not a speed: the server sends the arm to where it was at the start plus that displacement. The
server turns `[a, b, c]` into a base-frame move of `[a, b, −c]`. So the app sends the operator's right as −x,
forward as −y and up as −z (`LiveLinkController.serverOffset`).

The server requires `frame`, `rate_hz` (exactly 30), `gain` (0.1 to 2), `deadband_deg` (0 to 15) and `smoothing`
(0 to 0.95), and then ignores the last three in translation mode. `frame` is a fixed name, not a choice: `pose_start`
must say `webxr_local` and `orient_start` `phone_body`, and the server refuses any other value
(`invalid_pose_frame`, `invalid_orient_frame`). The app applies gain and smoothing to the hand
itself and sends `deadband_deg` 0. In translation mode the server also ignores `q_rel`, so the app sends no
rotation, and `gripper_delta` is always 0 (the jaws do not move during an arm hold).

Each server hold is limited to 8 cm from where the arm was when it started, because the server E-stops when its
target gets more than 10 cm ahead of the arm (`pose_tracking_safety_stop`). When the hand wants more, the app ends
the server hold and starts a new one from where the arm really got to, every 1.5 s, while the operator keeps
holding (a *resync*, `LiveLinkController.maxLeadMeters` and `resyncAfterMs`).

### `gripper_jog_start`, `jog_keepalive`, `gripper_jog_stop`: the jaws

```json
{"v": 1, "type": "gripper_jog_start", "ts": 1794378699557, "seq": 100, "payload": {"action": "open", "step": "coarse"}}
{"v": 1, "type": "jog_keepalive", "ts": 1794378700699, "seq": 102, "payload": {}}
{"v": 1, "type": "gripper_jog_stop", "ts": 1794378701687, "seq": 110, "payload": {}}
```

(`s03_busy_handoff`.)

`action` is `open` or `close`. The jaws move until the stop. Closing on something does not end the hold: the
server stops squeezing harder, holds what it has, and reports `ik: gripper_contact` in `state`. The server expects a
keepalive every 150 ms and ends the hold 750 ms after the last one; the app sends one every 133 ms.

### `orient_start`, `orient_update`, `orient_stop`: the wrist

```json
{"v": 1, "type": "orient_start", "ts": 1794378790763, "seq": 274,
 "payload": {"frame": "phone_body", "rate_hz": 30, "gain": 1.0, "deadband_deg": 0.0, "smoothing": 0.0}}
{"v": 1, "type": "orient_update", "ts": 1794378791761, "seq": 304, "payload": {"q_rel": [0, -0.087156, 0, 0.996195]}}
{"v": 1, "type": "orient_stop", "ts": 1794378792827, "seq": 335, "payload": {}}
```

(`s10_orient_hold`; the app sends the same `orient_start`.)

`q_rel` is a quaternion (four numbers `[x, y, z, w]` that describe a rotation; their squares add up to 1). The
server reads the rotation about y, negated, as a change of wrist roll, and the rotation about x as a change of
wrist pitch, both measured from the wrist as it was when the hold began. It clamps them to 60 degrees of roll and
35 degrees of pitch per hold. The example asks for 10 degrees of roll. A positive pitch points the jaws more toward
the table.

The app moves one axis per hold and ramps the angle from 0: a turn at 30 degrees a second up to 45 degrees, a tilt
at 15 degrees a second up to 10 degrees (`LiveLinkController.turnStepDegrees`, `tiltStepDegrees`). Releasing early
leaves the wrist where the ramp had got to. To go further the operator presses again. Each update is also the
hold's keepalive.

## What the app receives

| Message | What the app does with it |
|---|---|
| `welcome` | marks the connection welcomed, keeps `session`, opens the listening connection (below) |
| `state` | the first one makes the link ready; every one updates the map, the guide, the feedback and the spoken narration of the recorder; `estop: true` latches the emergency stop on the phone |
| `ack` | matched to the message it names (below) |
| `test` | the echo of a probe: one round-trip time |
| `error` | ignored. The server sends it for a malformed message (below). |

### `error`

The answer to a message the server cannot take, here one of an unknown type (`s12_invalid`):

```json
{"v": 1, "type": "error", "ts": 1794378841695, "seq": 369, "payload": {"code": "unknown_type", "msg": "unsupported type=no_such_type"}}
```

The app should never get one, and ignores it if it does (`TeleopLink.receive` returns no event for it).

### `ack`

```json
{"v": 1, "type": "ack", "ts": 1794378689529, "seq": 5, "payload": {"seq": 5, "status": "ok", "reason": "pose_stopped"}}
```

(`s02_pose_hold`: the final ack of the `pose_start` above.)

`status` is `ok` or `rejected`, or `clamped` for messages the app does not send: a `jog_start` hold that reached
the edge of the box, and a one-shot `move_delta`, `joint_delta` or `gripper` whose target was cut short. `reason`
says why. A final ack is followed by a `state` on the same connection. So is the ack of a stop, an `estop` or an
`estop_reset`, except a stop refused `estop_active` and a message whose payload was invalid. An immediate refusal
is not. The ones that matter:

| Ack | Reason examples | What the app does |
|---|---|---|
| a stop's own ack, at once | `pose_stop_requested`, `gripper_jog_stop_requested`, `orient_stop_requested` | nothing; the hold has not finished yet |
| a final ack, `ok` | `pose_stopped`, `gripper_jog_stopped`, `orient_stopped` | the hold is over; a start kept back for it goes out now |
| a final ack, `ok`, with no stop sent | `task_success` | the task was done while the hold ran; the hold is over, and it is not a refusal |
| an immediate refusal of a start | `busy`, `sim_not_ready`, `estop_active`, a validation code such as `invalid_pose_start` | the press did nothing: the operator feels the refusal and the hold ends on the phone |
| a final ack, `rejected` | `pose_watchdog_timeout`, `gripper_jog_watchdog_timeout`, `estop` | the server ended a hold the operator still holds |
| `reset_scene` | a final ack `ok scene_reset`; an immediate refusal `busy` or `sim_not_ready` | the reset is done, retried once, or reported as not done |
| `estop`, `estop_reset` | `ok estop_engaged`, `ok estop_reset`, `rejected estop_not_frozen` | a refusal is logged; the phone follows `state.estop` |

Only an ack that names the running hold's start ends it on the phone. A late refusal of an earlier press does not
cancel the hold that runs now (`TeleopLink.endActive`).

## A hold from start to final ack

This is an arm hold as the lab server answered it (recording `s02_pose_hold`, times in seconds from the start):

| Time | Direction | Message |
|---|---|---|
| 0.000 | app → server | `pose_start`, seq 5 |
| 0.000 to 2.030 | app → server | `pose_update`, seq 6 to 65, one every 33 ms; no answer to any of them |
| 2.064 | app → server | `pose_stop`, seq 66 |
| 2.079 | server → app | `ack` seq 66, `ok pose_stop_requested`, then a `state` |
| 2.094 | server → app | `ack` seq 5, `ok pose_stopped`, then a `state` |

Three rules follow from this:

1. **No ack says a start was accepted.** Silence means it was. A refusal comes back within tens of milliseconds,
   so the app treats a start as live when no refusal has come within a short wait (100 to 300 ms, from the measured
   round trip; `FeedbackMonitor.acceptMinMs`, `acceptMaxMs`). Only then does the operator feel the "your hold is
   live" tick.
2. **The final ack carries the start's seq, not the stop's.** It comes one or two physics steps after the stop,
   when the server has really finished the hold.
3. **A start or a reset sent before that final ack is refused `busy`.** The server keeps one command at a time.
   Recording `s03_busy_handoff` shows it: a gripper start sent right behind a `pose_stop` was refused 18 ms later.
   So `TeleopLink` keeps the next start back until the final ack of the hold just stopped, or for at most 800 ms
   (`finishWaitMs`), and then sends it; if it is still too early, the server's `busy` reaches the operator as a
   refusal. A stop for a start that was kept back sends nothing, because nothing was started.

### The watchdog

The server ends a hold 750 ms after its last update or keepalive (`pose_update` for an arm hold, `orient_update`
for a wrist hold, `jog_keepalive` for a gripper hold; a keepalive does not keep an arm or wrist hold alive). The
final ack is `rejected pose_watchdog_timeout` (or the gripper or wrist equivalent), `state.ik` becomes `stopped`,
and it is not an emergency stop. The app sends updates and keepalives well inside that time, so a watchdog end
means the phone stopped sending: the app was suspended, the radio stalled, or the network dropped messages.

## The emergency stop

STOP sends `estop`. The server answers at once with `ok estop_engaged` and a `state` with `estop: true`; the hold
that was running ends with a final ack `rejected estop`. From `s06_estop_in_hold`, the stop and, two seconds later,
its release (the server's clock runs a few milliseconds behind the client's):

```json
{"v": 1, "type": "estop", "ts": 1794378738294, "seq": 210, "payload": {}}
{"v": 1, "type": "ack", "ts": 1794378738290, "seq": 210, "payload": {"seq": 210, "status": "ok", "reason": "estop_engaged"}}
{"v": 1, "type": "estop_reset", "ts": 1794378740297, "seq": 213, "payload": {}}
{"v": 1, "type": "ack", "ts": 1794378740290, "seq": 213, "payload": {"seq": 213, "status": "ok", "reason": "estop_reset"}}
```
 While the stop is latched, the server answers every start,
stop and keepalive with `rejected estop_active` and ignores updates. The arm holds its last commanded position.

The app sends `estop` on both connections when both are up (the server takes it from either). If neither is up,
nothing reached the robot: the phone says so, and sends `estop` first thing after the next `welcome`.

The server engages the stop by itself too, and the app learns of it only from `state.estop`:

- the connection that owns a running hold closes (the phone's socket dropped mid-hold); a new connection then finds
  `estop: true` in its first `state`, and the phone shows the stop as found on connecting;
- the arm falls more than 10 cm behind its target (`pose_tracking_safety_stop`); the final ack with that reason
  comes just before the `state`, and the phone names it as the cause (the arm fell behind);
- another client sent `estop`.

There are two ways out:

- **`estop_reset`** releases the stop and leaves the scene as it is. The server refuses it with
  `estop_not_frozen` if it comes before the simulation has held the arm for one step, and with `estop_not_active`
  if there is no stop. This is what releasing STOP on the phone sends today. A `state` sent before the server handled
  the release can still say `estop: true`; the app ignores those for 2 seconds after it sent the release. If the
  release was refused, the next `state` still says `estop: true` and the phone latches the stop again.
- **`reset_scene`** clears the stop and resets the scene in one go. The server accepts it during a stop. The phone
  does not send it while stopped today: the stop screen offers only the release. `StopExits`
  (`Packages/TeleopCore/Sources/TeleopCore/Recording/StopExits.swift`) already works out which ways out to offer,
  and `AppModel.stopExits` keeps its answer up to date, but no screen reads it yet. The reason it exists: on a
  recording server, `estop_reset` alone leaves the recorder off, so the next success would not be saved.

## The scene reset

`reset_scene` puts the robot back in its start pose and the cube back on the table. The answer comes only when the
reset has finished, about 1.7 s later on the lab server; meanwhile `state.ik` is `resetting`. Afterwards `episode`
has gone up by one, `gripper` says `closed`, `task_success` is `false`, and a recording server is ready for a new
take.

```json
{"v": 1, "type": "reset_scene", "ts": 1794378712724, "seq": 145, "payload": {}}
{"v": 1, "type": "ack", "ts": 1794378714464, "seq": 145, "payload": {"seq": 145, "status": "ok", "reason": "scene_reset"}}
```

(`s04_stop_then_reset`. A first `reset_scene`, seq 144, sent right behind a `pose_stop`, had been refused `busy`.)

How the app sends it (`TeleopLink.resetScene`):

- Refused on the phone while anything is held: the operator lets go first.
- A reset right behind a stop would be refused `busy`, so it waits for that hold's final ack, at most 800 ms, like
  a start.
- A `busy` answer gets one retry 300 ms later. A second refusal, or `sim_not_ready` (another reset is running, or a
  success is being shown), is told to the operator: the scene was not reset.
- Every start is refused on the phone from the moment Reset is pressed until the answer comes (at most 10 s).

The server also resets by itself: after a success has been shown, and when the cube falls off the table while no
command runs. During those resets, and while a success is shown, starts are refused `sim_not_ready`.

## The second, listening connection

The server sends `state` to a connection only after 200 ms in which that connection sent nothing, and then every
200 ms until it sends again. During a hold the app sends an update every 33 ms, so while the operator moves, the
control connection hears only the echoes of its own probes: not where the arm is, not a clamp, not contact.

So after the control connection's `welcome`, the app opens a second connection to the same address. It says
`hello` (named `teleop-ios/1.0.0 observer`) and then sends nothing, so the server sends it a `state` every 200 ms,
holds included. It owns no hold, so its closing can never stop the robot. Its states go through the same path as
the control connection's; a state that left the server earlier than one already handled is dropped
(`LiveLinkController.stateArrived`). This is what lets the phone tell the operator, during the hold, that the arm is
blocked, that the jaws closed on something, or that the arm reached the edge of its box.

If it drops, the app opens it again 2 s later without telling the operator. The link counts as lost when the
control connection has heard nothing for 2 s or, while the listening connection is up, when neither has heard
anything for 1.2 s.

## The `state` message

From `s00_hello`, the first `state` after `welcome`:

```json
{"v": 1, "type": "state", "ts": 1794378668967, "seq": 1, "payload": {
  "ee_pos": [0.020616760477423668, -0.14141811430454254, 0.15998485684394836],
  "gripper": "closed", "step": "coarse", "ik": "ok", "estop": false,
  "object_pos": [0.00499999662861228, -0.20000001788139343, 0.10249999910593033],
  "goal_pos": [0.075, -0.2, 0.1035], "task_success": false, "episode": 0,
  "wrist_flex_deg": 40.24, "wrist_roll_deg": 90.0, "gripper_deg": 0.0,
  "rec": "none", "rec_saved": 0, "rec_discarded": 0, "rec_samples": 0}}
```

The app reads it in `ServerState(payload:)`. A field that is missing or of the wrong type counts as missing.

| Field | Meaning | What the app does with it |
|---|---|---|
| `ee_pos` | the gripper link origin, base frame, metres | the arm on the map (plus the tool offset); "blocked" when it stops following during a hold; where a resync continues from |
| `gripper` | the label of the last gripper command, not a measurement: `closed` after start or reset, `open` or `close` after a command | the phone's gripper state; the app reads `closed` and `close` the same |
| `step` | `coarse` or `fine`, the step size of jog and move commands | not used |
| `ik` | what the server is doing: `ok`, `stopped`, `pose_tracking`, `pose_clamped`, `orienting`, `orient_clamped`, `gripper_jogging`, `gripper_contact`, `resetting`, `task_success`, and labels of commands the app does not send | a clamp label is "as far as it goes"; `gripper_contact` is "the jaws closed on something"; `resetting` and `task_success` mean nothing can start |
| `estop` | the emergency stop is latched | latches the stop on the phone |
| `object_pos`, `goal_pos` | the cube's centre and the goal's centre, **world** frame, metres | the map and the guide, after subtracting the base's height |
| `task_success` | true from the moment the task counts as done until the automatic reset | told to the operator |
| `episode` | counts scene resets of this server run | a change means the scene started over (the jaws hold nothing) |
| `wrist_flex_deg`, `wrist_roll_deg`, `gripper_deg` | measured wrist pitch, wrist roll and jaw angle, degrees; `null` if not a number | "fully open" when opening, "closed on nothing" when closing |
| `rec` | the recorder: `none` (started without recording), `off` (recording, but nothing is captured: after an emergency stop until a reset, and after a success until the automatic reset), `armed` (the take starts at the next command), `capturing` | what the operator hears per take |
| `rec_saved` | demonstrations in the output file, including earlier server runs | "saved", by comparing with the last value |
| `rec_discarded` | takes thrown away since the server started | "discarded", the same way |
| `rec_samples` | samples in the current take, 30 per simulated second | the length of the take, kept in `AppModel.recorder`, which no screen shows yet |
| `rec_session`, `rec_mode` | the recording session's name and mode label; `null` when not recording | read, not used yet |
| `orient_deg`, `gripper_delta` | appear after the first wrist or arm hold | not used |

**A state without the key `rec` comes from an unknown server, never from one without a recorder.** The phone then
says nothing about takes. (`StopExits` would offer both ways out of an emergency stop, with a warning that recording,
if any, stays off until a reset; as said above, no screen shows that choice yet.)

When `state` arrives: right after `welcome`; after a final ack and after the ack of a stop, `estop` or
`estop_reset` (not after an immediate refusal); and after every 200 ms of silence from the client.
On the control connection that means about five times a second when idle and never while a hold streams; on the
listening connection, five times a second all the time.

## What ends a hold besides the operator

On the server:

- the watchdog, 750 ms after the last update or keepalive;
- an emergency stop, from any of the causes above;
- the task succeeding while the hold runs (final ack `ok task_success`);
- an immediate refusal of the start itself: `busy`, `sim_not_ready`, `estop_active`, or a validation code.

On the phone (`LiveLinkController.tick` and `AppModel`):

- ARKit loses the phone's position, or the phone moves faster than 0.8 m/s between two samples;
- the app leaves the foreground (home, a call, Control Center), which ends an arm hold, or the system cancels the
  touch on an on-screen control, or the screen with the control goes away;
- the round trip is slow twice in a row (400 ms or more);
- the link is lost: the socket closed, no `welcome` in 5 s, or the silence above;
- a resync whose old hold gets no final ack within 1.5 s;
- STOP.

## Limits the server enforces without saying so

- **The workspace box.** The server keeps the arm's target inside a box 8 cm either way, on each axis, of the
  gripper link origin's start position: in the base frame x from −0.059 to 0.101 m, y from −0.221 to −0.061 m and
  z from 0.080 to 0.240 m (`ServerModelConfig.armStart`, `workspaceHalfSize`). A hold asking for more just stops
  there; the only sign is `ik: pose_clamped` in `state`, which the control connection sees only after the hold.
- **Directions the arm cannot go from its start pose.** Measured on the simulator, not enforced by any rule in
  the server: from the reset pose the arm moves no more than about 1.9 cm toward the robot base, and it does not
  move straight down. The server says nothing; the arm simply stops following. The app notices from the listening
  connection's positions (the target at least 10 mm ahead and the arm moving less than 2 mm in 1 s,
  `FeedbackMonitor`) and from a resync that finds the arm has not moved.
- **One hold at a time.** The arm, the wrist and the gripper cannot move together. On the phone, starting one
  ends the one running: `TeleopLink` sends its stop first, then keeps the new start back for the final ack.
- **Speeds.** Every speed limit is per simulated second, and the lab machine runs slower than real time, so the
  arm and the wrist often lag the hand. Releasing early leaves them short of where the hand went.
- **The tracking stop.** A target more than 10 cm from the arm engages the emergency stop; the app's 8 cm cap per
  server hold keeps clear of it.

## Where the app relies on the owner's copy of the server

The lab runs a copy of the published server with a few local changes. The app is built against that copy. Against
the published server it still works, with these differences:

| The owner's copy | The published server | Effect on the app |
|---|---|---|
| `state` carries `rec`, `rec_saved`, `rec_discarded`, `rec_samples`, `rec_session`, `rec_mode` | none of them | an unknown server: no take narration |
| `state` carries `wrist_flex_deg`, `wrist_roll_deg`, `gripper_deg` | none of them | no "fully open" and no "closed on nothing" cues |
| the wrist starts rolled 90 degrees, jaws side by side | jaws start front to back | `RobotProfile.jawsStartSideways` is true for the owner's copy; on the published server the operator must turn the jaws a quarter turn before a grasp |
| a take starts at the first command of any kind | a take starts only at the first gripper, jog or move command; arm and wrist holds never start one | none on the phone; on the published server a take misses the approach to the cube |
| a `reset_scene` sent behind a stop is refused `busy`, and the stop still lands | the refused reset also cancels the pending stop, and the hold runs on until the watchdog | none: the app waits for the final ack before it resets |
| a hold that ends (stop or watchdog) keeps the arm where it was commanded | the end copies the measured joint angles into the targets: the arm sinks about half a centimetre, and a held cube can shake loose | none in the protocol; the published server feels worse |

`rec_session` and `rec_mode` are the newest of these fields: the server model and the recordings in the repository
do not have them yet.
