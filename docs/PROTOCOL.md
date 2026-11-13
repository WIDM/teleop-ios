# How the app talks to the server

The app drives a simulated SO-101 robot arm. The simulation runs on a lab machine, and a small server inside it
takes commands over a WebSocket (one long-lived, two-way connection that carries text messages). This document is
the conversation between the two: what each side sends, when, and what the app does with each answer.

The app side lives in `Packages/TeleopCore/Sources/TeleopCore/Link/TeleopLink.swift` (the messages and their
rules, no sockets or timers) and `App/Sources/Link/LiveLinkController.swift` (the sockets, the timers and the two
connections). `TeleopServerModel` in the same package is a model of the server for tests; its rules and its
recordings of the real server back most of what is written here.

## Words used here

- **Hold**: a control that runs only while the operator keeps a key, a thumb or a button down. The app sends a *start*
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
- **Gripper link origin**: the point the server reports for the arm (`ee_pos`). It is not where the jaws close.
- **Pinch point**: where the jaws close. A server can report it as `tool_pos`, the grasp point: the point to put on
  an object's centre before the jaws close. Without it the app estimates the pinch point as the gripper link origin
  plus a fixed offset (`RobotProfile.toolOffset` in `App/Sources/Link/Guidance.swift`), which holds while the wrist
  keeps the pose the offset was measured in.
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
- **STOP** is the red band along the bottom of every screen: it latches the emergency stop at touch-down.
  **Reset** is holding the top band of the operating screen for 2 seconds: it asks the server to put the scene
  back as it started (below). **Release, keep scene** is a one-second hold button that appears in the stopped state
  when that way out is offered (below).
- **The guide** is the operating screen's drawing of the arm from above and from behind: where the jaws pinch, and
  the task object (the *target*) and the goal when the server reports them.

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

The example above, and every other example in this document, is copied from the recordings of the real server in
`Packages/TeleopCore/Tests/TeleopServerModelTests/Recordings` (the file is named with each; this one is from
`s02_pose_hold`). The client in those
recordings is `scripts/trace_scenarios.py`, which speaks the same protocol as the app but writes keys in its own
order. Where the app's own payload differs, the text says so. Names and the server's session id are replaced by
placeholders.

In a server message, `seq` is the client message it answers, or the newest one it has seen. For an `ack` the app
reads the acknowledged number from `payload.seq`. A `test` echo is the probe's own text sent back, so there the app
reads the top-level `seq` to find which probe came back. In a `state` it reads `seq` to tell whether the server wrote
that state after it read the app's `estop` (see the emergency stop). In every other server message it ignores `seq`.

## Starting a conversation

The first message on a connection must be `hello`, with exactly these two fields:

```json
{"v": 1, "type": "hello", "ts": 1794378668949, "seq": 1, "payload": {"client": "phone", "name": "<client name>"}}
```

(`s00_hello`.)

`name` is how the server's log names the connection. The app names its control connection
`teleop-ios/<version> (<build>)`, from the bundle's version and build numbers (`LiveLinkController.clientName`), and
its listening connection the same followed by ` observer`. Any other field in the payload, or any other message
before `hello`, is answered with an `error` message.

The server answers with `welcome`, then a first `state` (described below):

```json
{"v": 1, "type": "welcome", "ts": 1794378668966, "seq": 1,
 "payload": {"session": "<uuid>", "config": {"coarse_cm": 2.0, "fine_cm": 0.5}}}
```

(`s00_hello`.)

`session` names the server run: it changes only when the server restarts. The app keeps it to notice a restart
across a reconnect (the scene then starts over). It ignores `config`.

The link is usable once `welcome` and a first `state` have arrived (`TeleopLink.ready`). Until then the app sends
no commands but `estop` on a STOP (see "The emergency stop"). If the link is not ready within 5 seconds, the app drops the socket and reports the link lost.

## What the app sends

| Message | When | Payload the app sends | Answer |
|---|---|---|---|
| `hello` | first, on each connection | `client`, `name` | `welcome`, then `state` |
| `test` | twice a second while the link is up | `{}` | the same text echoed back at once |
| `pose_start` | an arm hold begins (vol+, or a direction button in buttons mode) | see below | a final ack when the hold ends |
| `pose_update` | 30 times a second during an arm hold | the displacement asked for | none |
| `pose_stop` | the arm hold ends | `{}` | an ack at once |
| `gripper_jog_start` | a gripper hold begins | `action`, `step` | a final ack when the hold ends |
| `jog_keepalive` | every 133 ms during a gripper hold | `{}` | none |
| `gripper_jog_stop` | the gripper hold ends | `{}` | an ack at once |
| `orient_start` | a wrist hold (turn or tilt) begins | see below | a final ack when the hold ends |
| `orient_update` | 30 times a second during a wrist hold | the rotation asked for | none |
| `orient_stop` | the wrist hold ends | `{}` | an ack at once |
| `estop` | every STOP, also when the stop is already latched; on both connections when both are up; first on a new control connection whenever the stop is latched at its `welcome` | `{}` | an ack at once |
| `estop_reset` | Release, keep scene is held for 1 s | `{}` | an ack at once |
| `reset_scene` | Reset: the top band is held for 2 s | `{}` | an ack when the reset has finished |

The server also accepts messages the app does not send: `mode`, `move_delta`, `jog_start`, `jog_stop`,
`joint_jog_start`, `joint_jog_stop`, `joint_delta` and the one-shot `gripper`. The one-shot `gripper` is avoided on
purpose: in Isaac Sim one such command kept every other command waiting for tens of seconds.

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

(`s02_pose_hold`.) The app sends the same `pose_start` with `deadband_deg` 0, `gain` from Settings → Arm speed
(0.5 to 2) and `smoothing` from Settings → Smoothing (Off 0, Low 0.3, High 0.6). A button hold sends gain 1 and
smoothing 0.

`p_rel_m` is the displacement asked for since the hold began, in metres, rounded to 0.1 mm: the hand's movement
during a vol+ hold, or, in buttons mode, a target that moves from the press in the button's direction at 1 cm/s
(Fine) or 4 cm/s (Coarse) for as long as the button is held (`ButtonRamp`). It is an absolute target within the
hold, not a speed: the server sends the arm to where it was at the start plus that displacement. The server turns
`[a, b, c]` into a base-frame move of `[a, b, −c]`. So the app sends the operator's right as −x, forward as −y
and up as −z (`OperatorFrame.linkOffset`).

The server requires `frame`, `rate_hz` (exactly 30), `gain` (0.1 to 2), `deadband_deg` (0 to 15) and `smoothing`
(0 to 0.95), and then ignores the last three in translation mode. `frame` is a fixed name, not a choice: `pose_start`
must say `webxr_local` and `orient_start` `phone_body`, and the server refuses any other value
(`invalid_pose_frame`, `invalid_orient_frame`). The app applies gain and smoothing to the hand
itself and sends `deadband_deg` 0. In translation mode the server also ignores `q_rel`, so the app sends no
rotation, and `gripper_delta` is always 0 (the jaws do not move during an arm hold).

Each server hold is limited to 8 cm from where the arm was when it started, because the server E-stops when its
target gets more than 10 cm ahead of the arm (`pose_tracking_safety_stop`). When more is asked for, the app ends
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

The app moves one axis per hold, and the angle it asks for follows the phone. The input rules commit the hold to
turn (roll) or tilt (pitch) from the phone's first clear rotation; from then on the angle is the phone's rotation on
that axis since the input began (the thumb's touch-down in scheme A, the vol− press in scheme B), times
`rollSign` or `tiltSign` from the robot profile (`RotationMapper`). It is held to these limits:

- at most 55 degrees of turn and 20 degrees of tilt per hold (`InputConstants.rollClampDeg`, `tiltClampDeg`);
- the roll asked for stays within 150 degrees either way of zero, judged from the measured roll, and the flex within
  25 degrees of the flex measured after the last reset (`rollWindowDeg`, `tiltWindowDeg`); for a server that reports
  no wrist angles, the tilt commanded since the last reset counts instead;
- the commanded angle never leads the newest measured angle by more than 2 degrees plus 10 degrees for each second
  of that state's age, and with no state younger than 400 ms it does not move further from the wrist
  (`WristLeadBound`). The server keeps moving its target toward a blocked wrist, and the wrist would jump by that
  lead once it is free. A server that reports no wrist angles gets the angle unbounded.

The operator feels a long buzz at a limit. If the start waited behind a finishing hold, the rotation made meanwhile is
dropped. Releasing leaves the wrist where it got to. Each update is also the hold's keepalive.

## What the app receives

| Message | What the app does with it |
|---|---|
| `welcome` | marks the connection welcomed, keeps `session`, opens the listening connection (below) |
| `state` | the first one makes the link ready; every one updates the guide, the operating screen's state, the feedback and the spoken narration of the recorder; on the control connection, `estop: true` latches the emergency stop on the phone; on either connection, `estop: true` in a state written after the server read the app's `estop` confirms a STOP pressed on the phone |
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

While the stop is latched, the server answers every start, stop and keepalive with `rejected estop_active` and
ignores updates. The arm holds its last commanded position.

The app sends `estop` on both connections when both are up (the server takes it from either), and on every STOP,
even when the stop is already latched: a reset asked for from the stop may have cleared the server's stop meanwhile.

A STOP pressed on the phone counts as confirmed only when a `state` saying `estop: true` arrives on a connection that
carried its `estop`, with a `seq` at least that `estop`'s own. The server numbers each `state` with the newest `seq`
it has read on that connection (a command's final ack and the `state` after it carry that command's own, smaller
`seq`), so a state written before the `estop` arrived cannot confirm it, however late it arrives. Until then the
STOP is only sent. A `reset_scene` sent from the stop clears the server's stop as soon as the server reads it, even
when it then refuses the reset, so it makes a confirmed STOP only sent again, and nothing confirms it after that; the
reset's `ok` releases the stop. A STOP pressed after the control connection's `welcome` counts as sent even before
the first `state`: the server reads what follows the `welcome`. If STOP is pressed before that `welcome` with the
listening connection not up (the server may still refuse the `hello`; the `estop` goes out behind it anyway), or the
link is lost before the STOP is confirmed, nothing is known to have reached the robot: the phone says "No link. Not
stopped." (after "Link lost." when the link has just gone), shows the link's state instead of STOPPED (also while
Connect replaces a link that is up), and sends `estop` first thing after the next `welcome`, with the alarm. A STOP
released before that is no longer sent.

Whenever the stop is latched at the control connection's `welcome`, whatever latched it, `estop` goes out first on
that connection: a server restarted meanwhile has forgotten the stop. The listening connection opens only after that,
and only while the control connection is up, so it sends no `estop` at its own `welcome`. A server that is still
stopped answers it with `ok estop_engaged` and stays as it was; the take the first stop discarded is gone already.
The only other effect: until the simulation has held the arm for one more step, it refuses `estop_reset` with
`estop_not_frozen`, as after any stop. That `estop` comes with no alarm and no refusal when the stop was confirmed or
came from the server.

The server engages the stop by itself too, and the app learns of it only from `state.estop`:

- the connection that owns a running hold closes (the phone's socket dropped mid-hold); a new connection then finds
  `estop: true` in its first `state`. The phone gives the cause as "The link dropped during a move" when one of its
  holds was engaged at the loss, and as "The robot was already stopped" when none was, or after a fresh launch;
- the arm falls more than 10 cm behind its target (`pose_tracking_safety_stop`); the final ack with that reason
  comes just before the `state`, and the phone names it as the cause (the arm fell behind);
- another client sent `estop`.

There are two ways out. `StopExits` (`Packages/TeleopCore/Sources/TeleopCore/Recording/StopExits.swift`) decides
which the phone offers, from the newest recorder fields:

- **`reset_scene`** clears the stop and resets the scene in one go; the server accepts it during a stop. Holding the
  top band for 2 seconds sends it, on every server. The phone releases its own stop when the `ok scene_reset` comes
  back, but only for a reset asked for in the stop state with no STOP pressed since; it sends no `estop_reset`
  after it.
- **`estop_reset`** releases the stop and leaves the scene as it is. On a recording server it would leave the
  recorder off, so the next success would not be saved: there the phone does not offer it and refuses it if asked.
  It is offered (the **Release, keep scene** button) for a server that reports no recorder (`rec: none`), and for
  an unknown server (no `rec` key) with the line "Recording, if any, stays off until a reset." The server refuses it
  with `estop_not_frozen` if it comes before the simulation has held the arm for one step, and with
  `estop_not_active` if there is no stop. A `state` sent before the server handled the release can still say
  `estop: true`; the app ignores those for 2 seconds after it sent the release. If the release was refused, the next
  `state` still says `estop: true` and the phone latches the stop again.

## The scene reset

`reset_scene` puts the robot back in its start pose and the task object back on the table. The answer comes only
when the reset has finished, about 1.7 s later on the lab server; meanwhile `state.ik` is `resetting`. Afterwards
`episode` has gone up by one, `gripper` says `closed`, `task_success` is `false`, and a recording server is ready
for a new take.

```json
{"v": 1, "type": "reset_scene", "ts": 1794378712724, "seq": 145, "payload": {}}
{"v": 1, "type": "ack", "ts": 1794378714464, "seq": 145, "payload": {"seq": 145, "status": "ok", "reason": "scene_reset"}}
```

(`s04_stop_then_reset`. A first `reset_scene`, seq 144, sent right behind a `pose_stop`, had been refused `busy`.)

How the app sends it (`AppModel.runReset`, `TeleopLink.resetScene`):

- Refused on the phone while anything is held: the operator lets go first ("Let go first."). The top band does not
  count down while a hold runs, while there is no link, or while the server is showing a success or resetting.
- A reset right behind a stop would be refused `busy`, so it waits for that hold's final ack, at most 800 ms, like
  a start.
- A `busy` answer gets one retry 300 ms later. A second refusal, or `sim_not_ready` (another reset is running, or a
  success is being shown), is told to the operator: the scene was not reset.
- Every start is refused on the phone from the moment the reset is asked for until the answer comes (at most 10 s).

The server also resets by itself: after a success has been shown, and when the task object falls off the table
while no command runs. During those resets, and while a success is shown, starts are refused `sim_not_ready`.

## The second, listening connection

The server sends `state` to a connection only after 200 ms in which that connection sent nothing, and then every
200 ms until it sends again. During a hold the app sends an update every 33 ms, so while the operator moves, the
control connection hears only the echoes of its own probes: not where the arm is, not a clamp, not contact.

So after the control connection's `welcome`, the app opens a second connection to the same address. It says
`hello` (named like the control connection, followed by ` observer`) and then sends nothing but `estop` on a STOP,
so the server sends it a `state` every 200 ms, holds included. It owns no hold, so its closing can never stop the
robot. Its states feed the guide, the operating screen's state, the feedback and the narration, like the control
connection's; a state that left the server earlier than one already handled is dropped
(`LiveLinkController.stateArrived`). Only a `state` on the control connection latches the emergency stop or ends a
resync (`LiveLinkController.handle`). This is what lets the phone tell the operator,
during the hold, that the arm is blocked, that the jaws closed on something, or that the arm reached the edge of
its box.

If it drops, the app opens it again 2 s later without telling the operator. The link counts as lost when the
control connection has heard nothing for 3 s or, while the listening connection is up, when neither has heard
anything for 3 s. During a hold the control connection hears only the echoes of the app's `test` probes, twice a
second, so a stall of the network path of between 2.5 and 3 s can end the link. A shorter stall ends at most the
hold in progress: the server's watchdog finishes it 0.75 s after the last update it received, so a stall under
0.75 s costs nothing.

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
| `ee_pos` | the gripper link origin, base frame, metres | the arm in the guide (plus the tool offset when the state has no `tool_pos`); "blocked" when it stops following during a hold; where a resync continues from |
| `tool_pos` | the grasp point: the point to put on an object's centre before the jaws close; three finite numbers, base frame, metres; `null` or missing when the server does not report it. A held object does not stay at this point: the jaws squeeze it a little way up into them | the guide's jaw marker, its "On target" and the on-target cue use it as it is, never as approximate; the commanded ring and the workspace box are moved by `tool_pos − ee_pos` of the same state, which is exact only while the wrist keeps its pose. Missing, `null`, not three numbers, not finite, or beyond the range of a 32-bit float: the app estimates the point for that state as `ee_pos` plus the profile's tool offset |
| `gripper` | the label of the last gripper command, not a measurement: `closed` after start or reset, `open` or `close` after a command | the phone's gripper state; the app reads `closed` and `close` the same |
| `step` | `coarse` or `fine`, the step size of jog and move commands | not used |
| `ik` | what the server is doing: `ok`, `stopped`, `pose_tracking`, `pose_clamped`, `orienting`, `orient_clamped`, `gripper_jogging`, `gripper_contact`, `resetting`, `task_success`, and labels of commands the app does not send | a clamp label is "as far as it goes"; `gripper_contact` is "the jaws closed on something"; during `resetting` and `task_success` the screen says Wait and every start is refused |
| `estop` | the emergency stop is latched | on the control connection, latches the stop on the phone; confirms a STOP pressed on the phone (see the emergency stop) |
| `object_pos`, `goal_pos` | the task object's centre and the goal's centre, **world** frame, metres | the guide's target and goal, moved into the base frame (`RobotProfile.baseInWorld`) |
| `task_success` | true from the moment the task counts as done until the automatic reset | told to the operator; the screen says Wait (Saving) meanwhile |
| `episode` | counts scene resets of this server run | a change means the scene started over: the jaws hold nothing, and the wrist's tilt limit counts from the new start |
| `wrist_flex_deg`, `wrist_roll_deg`, `gripper_deg` | measured wrist pitch, wrist roll and jaw angle, degrees; `null` when a measurement is not a number | "fully open" when opening, "closed on nothing" when closing; the guide's jaw and wrist read-outs; the wrist limits above. Without the wrist angles, the angle the operating screen shows during a turn or tilt is marked "estimated" |
| `rec` | the recorder: `none` (started without recording), `off` (recording, but nothing is captured: after an emergency stop until a reset, and after a success until the automatic reset), `armed` (the take starts at the next command), `capturing` | the REC line (below), what the operator hears per take, and which ways out of a stop are offered |
| `rec_saved` | demonstrations in the output file, including earlier server runs | a rise is a saved take: "Saved N" on the operating screen for 2 s, and spoken; the count in the REC line and in Settings → Recording |
| `rec_discarded` | takes thrown away since the server started | a rise is a discarded take, spoken; the count in the REC line and in Settings → Recording |
| `rec_samples` | samples in the current take, 30 per simulated second | the take's length in the REC line while capturing |
| `rec_session`, `rec_mode` | the recording session's name and mode label; missing, as in the example above, or `null` when the server was started without recording (`rec: none`) | read, not used; missing and `null` count the same |
| `orient_deg`, `gripper_delta` | appear after the first wrist or arm hold | not used |

The REC line in the top band, and the first row of Settings → Recording, say what the recorder is doing
(`OperatingWords.recLine`):

| `rec` | The REC line says |
|---|---|
| `none` | "Not recording" |
| `armed` | "REC armed · 3 saved · 1 discarded" |
| `capturing` | "● REC 0:12 · 3 saved", with the take's length |
| `off`, while a success is shown or waits for its automatic reset | "REC waiting · 3 saved · 1 discarded" |
| `off`, otherwise | "REC off: reset to record" |
| no `rec` key | nothing; Settings says "The server has not said whether it records." |

In practice it says "Practice: nothing is recorded".

**A server that reports `tool_pos` sends it in every `state` that carries `ee_pos`, on both connections.** A state
without it makes the app estimate the point for that state: the jaw marker and the box jump between the two, and
the on-target cue can be felt again when `tool_pos` returns. JSON has no NaN or Infinity: a server that writes one
(Python's `json.dumps` does by default) sends a message the app cannot read at all, and every other field of that
`state`, `estop` included, is lost with it. Send `null` instead.

**A state without the key `rec` comes from an unknown server, never from one without a recorder.** The phone then
shows no REC line and says nothing about takes, and in a stop it offers both ways out, with the warning that
recording, if any, stays off until a reset.

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

On the phone (`LiveLinkController.tick`, `OperatingController`, `TeleopSession`):

- ARKit loses the phone's position during an arm or wrist hold, or the phone moves faster than 0.8 m/s between two
  samples during an arm hold;
- ARKit stops the camera;
- the app leaves the active state (the home screen, a call, Control Center);
- the operating screen goes away: Settings, Connect or the tutorial opens;
- in buttons mode, the finger slides more than 20 pt off its button;
- the round trip is slow twice in a row (400 ms or more);
- the link is lost: the socket closed, no `welcome` and first `state` within 5 s, or the silence above;
- a resync that does not finish within 1.5 s: in that time the old hold's final ack and then a `state` without
  the emergency stop must both arrive, or the hold ends;
- STOP.

## Limits the server enforces without saying so

- **The workspace box.** The server keeps the arm's target inside a box 8 cm either way, on each axis, of the
  gripper link origin's start position: in the base frame x from −0.059 to 0.101 m, y from −0.221 to −0.061 m and
  z from 0.080 to 0.240 m (`ServerModelConfig.armStart`, `workspaceHalfSize`). A hold asking for more just stops
  there; the only sign is `ik: pose_clamped` in `state`, which the control connection sees only after the hold.
- **Directions the arm cannot go from its start pose.** Measured in Isaac Sim: from the reset pose the arm
  moves no more than about 1.9 cm toward the robot base, and it does not move straight down. The server model does
  not have this limit. The server says nothing; the arm simply stops following. The app notices from the listening
  connection's positions (the target at least 10 mm ahead and the arm moving less than 2 mm in 1 s,
  `FeedbackMonitor`) and tells the operator the arm is blocked.
- **One hold at a time.** The arm, the wrist and the gripper cannot move together. On the phone, starting one
  ends the one running: `TeleopLink` sends its stop first, then keeps the new start back for the final ack.
- **Speeds.** Every speed limit is per simulated second, and the lab machine runs slower than real time, so the
  arm and the wrist often lag the hand. Releasing early leaves them short of where the hand went.
- **The tracking stop.** A target more than 10 cm from the arm engages the emergency stop; the app's 8 cm cap per
  server hold keeps clear of it.

## What the app needs from the server, and what happens without it

The app is built for a server that does everything in the left column. Against one that does not, the app still
works, with the effect in the right column.

| The app expects | Without it |
|---|---|
| `welcome` names the server run (`session`) | a reconnect cannot be told from a new server run: the wrist's tilt limit keeps counting from the last reset seen, and "The server restarted." is never said |
| `state` carries `rec`, with `rec_saved`, `rec_discarded` and `rec_samples` | the server counts as unknown: no REC line, no take narration, and both ways out of a stop are offered, with a warning |
| `state` carries `wrist_flex_deg`, `wrist_roll_deg` and `gripper_deg` | no "fully open" and no "closed on nothing"; no jaw or wrist read-out in the guide; the angle shown during a turn or tilt is marked "estimated"; wrist commands go out without the lead bound, and the tilt limit counts the tilt commanded since the last reset |
| `state` carries `ee_pos`, `object_pos` and `goal_pos` | without `ee_pos` there is no guide, no "blocked", and Moving says "No arm data"; without the object and the goal the guide shows the arm alone |
| a connection that sends nothing gets `state` every 200 ms, holds included | the phone learns where the arm is only between holds: no "blocked", clamp or contact during a hold |
| `state` carries `tool_pos` | the jaw marker is estimated from `ee_pos`, the profile's tool offset and the measured wrist angles. Where the profile's accuracy rule (`RobotProfile.estimateBound`) says the estimate may be off by more than half the on-target window, the marker is a hollow ring, the guide says "Jaw position is approximate", never says "On target", and the on-target cue does not play. Without `wrist_flex_deg` and `wrist_roll_deg` as well, that is everywhere |
| the scene starts with the wrist rolled 90 degrees, jaws side by side | without `tool_pos`: `RobotProfile.toolOffset` is measured for that pose, so the estimated pinch point and "On target" are off until the profile has an offset for the other one |
| a take starts at the first command of any kind | nothing changes on the phone; a take that starts only at the first gripper, jog or move command misses the approach |
| a `reset_scene` sent behind a stop is refused `busy`, and the stop still lands | nothing changes: the app waits for the final ack before it resets |
| a hold that ends (by a stop or the watchdog) keeps the arm where it was commanded | nothing changes in the protocol; an arm whose targets are set back to the measured angles when a hold ends sinks about half a centimetre, and a held object can shake loose |
