# Robot profiles

A **robot profile** is a JSON file that holds what the app must know about one robot setup: the arm, its gripper, the
scene around it and the hands-free aids it allows. The server's messages do not carry these numbers, so each setup
the app drives needs one profile. The app ships one: the SO-101 arm in the S4 pick-and-place simulator,
`App/Resources/Profiles/so101-s4-sim.json`.

Not every number about an arm is in the profile yet. The ones still in code are listed under "Where robot and task
numbers live" in `ARCHITECTURE.md`.

To drive a new arm: write its file with the SO-101's as the model (the last two sections read that file top to bottom
and print it whole), measure each field the way its section says, then run the direction check (the section "Before
the first move on a new arm") before the arm moves under the app for the first time.

## Choosing a profile

Profile files live in `App/Resources/Profiles/` and are bundled with the app. A profile's **id** is its file name
without `.json`.

- The build names the profile it drives in its Info.plist under `TeleopRobotProfile`, set in `project.yml`
  (`TeleopRobotProfile: so101-s4-sim`). Run `xcodegen generate` after changing it.
- The launch argument `-robotProfile <id>` overrides it for one launch, for example in a UI test. An empty id, a
  value that is not text or an id with no file stops the launch with the reason; it never falls back to the build's
  profile.
- There is no screen to choose one: one build drives one arm. To drive another arm, add its file, name it in
  `project.yml` and build again. No Swift change is needed.

`ProfileLoader` (`App/Sources/Link/ProfileLoader.swift`) is the only code that turns an id into a profile. If the
chosen file is missing, cannot be read or fails validation, the app stops at launch with a sentence that names the
file and the fault. A check in CI (`scripts/check-arm-constants.py`) fails when any other code names a profile id or a
profile's name, holds a profile in a `static let` or `static var` or names `so101Simulator`; when any code but the
core's `Profile` folder and the tests builds a profile, the loader included (it reads one through the core); when
code outside the tests holds a direction table or a conversion by base axis (`OperatorDirection.baseAxis`,
`OperatorFrame`, a direction's `baseVector` or `linkVector` property, the static `GuideProjection` conversions) or
holds or builds a `Frames` outside the core's `Profile` folder, a static whose type is not written included; and when any code,
tests and the loader included, reads `ProfileLoader.current` outside `AppModel` and `OperatingFixtures`. The
check reads text, not types: it catches accidents, and review catches deliberate workarounds. Tests read profiles
through `TestProfiles` in `Tests/TeleopTests`.

## The file format

```json
{
  "profile_version": 1,
  "name": "SO-101 (S4 simulator)",
  "robot":    { "directions": { ... }, "wrist": { ... }, "gripper": { ... }, "motion": { ... } },
  "server":   { "link_signs": [ ... ], "stop_distance_m": ..., "resync": { ... }, ... },
  "scene":    { ..., "base_axes_in_world": { ... }, "tool_offset": { ..., "error_bound": { ... } } },
  "response": { "directional_blocked_feedback": ..., "blocked": { ... }, "lowest": { ... } },
  "assist":   { "lock": ..., "go_to": { ..., "pacing": { ... } }, "guide": ..., "explain": ..., "views": ... }
}
```

The rules:

- **Every key must be there.** A missing key stops the load with its path, such as `scene.tool_offset.offset_m`.
  An optional value is written as `null`; leaving its key out is still a missing key.
- **No unknown keys.** A key the format does not know, a misspelt one included, stops the load with its path. A
  typo therefore cannot fall back to another arm's number without a word.
- **Each key once.** A key written twice in one object stops the load with its path.
- **Values of the right kind.** A section, value or array element of the wrong kind (text where a number goes)
  stops the load with its path; an element's place follows its key in brackets, such as `scene.base_in_world_m[0]`.
- **`profile_version`** is 1, and is read first: a file of another version is refused as that, whatever its keys.
- **Units are in the key's name:** `_m` metres, `_deg` degrees, `_deg_s` degrees per second, `_s` seconds, `_ms`
  milliseconds, `_mps` metres per second, `_mm_per_cm` millimetres per centimetre, `_mm_per_deg` millimetres per
  degree. A key without a unit is a count, a sign, a share (a number between 0 and 1), a factor or a yes/no; a word
  from a fixed set (`held_object_point`, `stall_detection`) is written as text, and any other word stops the load with
  a sentence that names the words it accepts. The exception is the jaw's readings
  (`closed_reading`, `open_reading`, `valid_min`, `valid_max`, `fully_open_at`, `empty_at`): they are in the unit that
  `robot.gripper.unit` names, `deg` or `mm`.
- **Vectors are arrays:** `[x, y, z]` in the robot base frame, or `[across, height]`. An array of the wrong length is
  refused.
- **Axes are written as text:** `+x`, `-x`, `+y`, `-y`, `+z` or `-z`. Those six are the only ones: the app handles
  quarter turns, so a direction at another angle (a base mounted at 30 degrees, say) cannot be given. Anything else
  stops the load with a sentence that says so.
- **The robot base frame** is the frame the server reports the arm in. For the SO-101 in the S4 simulator, base +x
  is the operator's left, base −y is forward (away from the base) and +z is up (`robot.directions`).

After the format, the values are validated. Each fault gives one sentence that names the field, and the load
reports all of them at once. A profile is refused when:

- `name` is empty;
- `robot.directions`: forward, left and up do not lie along three different base axes, one each; or they do but make
  a mirror image of the operator's view and not a turn of the base (this catches one wrong sign; two wrong signs are a
  valid half turn that the load cannot see, and the direction check's read-back cannot either: it only warns when the
  work box lies behind the base, and a person watching the arm tells, see "Before the first move on a new arm"); or a direction built in code has a sign other than
  1 or -1 (a file cannot say one);
- `robot.directions.up` is not the base axis that `scene.base_axes_in_world` puts along world +z, the same way; the
  sentence names both fields;
- `server.link_signs` has a value that is not 1 or -1;
- `server.stop_distance_m` is not above zero; `server.resync.after_ms`, `tool_after_ms` or `timeout_ms` is not above
  zero; `server.held_object_point` is neither `gripper_link` nor `tool_point`, or `server.stall_detection` is neither
  `simulation` nor `none` (each sentence names the two);
- `robot.motion.fine_mps`, `coarse_mps`, `max_lead_m` or `tool_max_lead_m` is not above zero, or `max_lead_m` or
  `tool_max_lead_m` is not under `server.stop_distance_m` (the sentence names the cap);
- `response.blocked`: a distance, window, freshness or arrival gap (`short_m`, `moved_m`, `window_ms`, `fresh_ms`,
  `arrival_gap_ms`, `exclusion_m`) is not above zero, a share (`lead_progress_share`, `following_share`) is not above
  0 and at most 1, or `same_way_deg` is not above 0 and below 90;
- `response.lowest`: any of `sustain_m`, `quick_short_m`, `quick_moved_m`, `quick_ms` and `descent_mps` is not above
  zero;
- `scene.base_axes_in_world`: x, y and z do not lie along three different world axes, or they make a mirror image (the
  base's x cross y must be its z), or one has a sign other than 1 or -1 when built in code; `scene.base_in_world_m` is
  not finite numbers;
- `robot.wrist.roll_sign` or `tilt_sign` is not 1 or -1;
- `robot.wrist`: a window or a per-hold limit (`roll_window_deg`, `tilt_window_deg`, `roll_clamp_deg`,
  `tilt_clamp_deg`) is not above zero, a limit is above its window, `tilt_centre_deg` is a number that is not finite,
  a button rate (`turn_rate_deg_s`, `tilt_rate_deg_s`) is not above zero, `lead.lead_deg`, `lead.rate_max_deg_s` or
  `lead.memory_deg` is negative, or `lead.fresh_state_ms` is not above zero;
- `robot.gripper.unit` is neither `deg` nor `mm` (the sentence names the two), `closed_reading` and `open_reading` are
  not different finite numbers, `closed_reading` is not below `open_reading` (a jaw whose reading falls as it opens is
  not supported), `valid_min` is not below `valid_max`, `closed_reading` or `open_reading` is not inside the valid
  readings, `empty_at` is below `closed_reading`, `fully_open_at` is above `open_reading`, or `empty_at` is not below
  `fully_open_at`;
- a position is not a finite number, or `scene.workspace_min_m` is not below `scene.workspace_max_m` on every axis;
- a size or tolerance (`target_size_m`, `goal_size_m`, `grasp_tolerance_m`, `on_target_window_m` when given) is not
  above zero, `on_target_window_m` is narrower than `grasp_tolerance_m` on either axis, or a rate of `error_bound` is
  negative;
- `assist.lock.time_limit_s` is not above zero;
- a number of `assist.go_to` is out of range: the travel height, speed, arrival tolerance, settle time, time factor
  and arm-data timeout must be above zero; the correction reach, allowance and start grace zero or more; the
  corrections a whole number zero or more; in `assist.go_to.pacing`, `follow_share`, `slowest_share` and
  `start_share` must be above 0 and at most 1, `pace_gain`, `path_watch_tolerances`, `fresh_ms` and `still_m` above
  zero, and `pace_change_share` between 0 and 1;
- `assist.views` has a height that is not above zero or is below the travel height, a move limit that is not above
  zero, or is given without `assist.go_to`;
- `assist.explain` is given without `assist.guide`.

## Before the first move on a new arm

Run the direction check against the server before the arm moves under the app for any other reason. It presses each of
the six directions once on the pad, for about 1 cm each (the time the Fine speed takes to cover 1 cm), and reads the
point the buttons drive from the server's state after each: `tool_pos` when the server reports a tool point (the app
then drives that point), else `ee_pos`. It judges each press as soon as it is read and stops at the first failure.
A direction passes when the arm went the way the file names: the move lies within 30 degrees of the named base axis,
the named way. A move under 2 mm counts as no move. How far it went is not part of passing: a move outside 0.5 to
1.5 cm along the axis prints a warning (lag at the start of a hold, a `robot.motion.fine_mps` that is not the arm's real
speed on Fine, `robot.motion.tool_max_lead_m` where a tool point is driven, or a limit can cause it) and the check goes on.

**Before you run it.** The check does not reset the scene and does not release a stop: it connects, reads and
presses. So bring the arm yourself, with the server's own controls, to a start pose that is clear of its limits and has
at least 2 cm free around the point that moves in every direction. The first run is unproven for every direction, so any of
the six may go the wrong way by a centimetre. Keep a hand on the server's stop, or on the arm's power if the server has
no stop. A stop that is latched when the check starts is not released: the check fails at its first read, naming the
stop, and you clear it and start again.

To run it, put the new file in `App/Resources/Profiles/`, run `xcodegen generate`, start the server and the path to it
(`TESTING.md`, "The test plans"), and run, with the file's id for `<id>` and the server's address for `<address>`:

    TEST_RUNNER_TELEOP_MOTION=1 TEST_RUNNER_TELEOP_ADDRESS=<address> TEST_RUNNER_TELEOP_PROFILE=<id> \
      xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan Live \
      -only-testing:TeleopTests/OperatorLiveTests/testEveryDirectionGoesTheNamedWay \
      -destination "platform=iOS Simulator,name=$SIM"

Each press prints a line (`DIRECTION forward (base -y, ee_pos): moved +0.0 -1.0 +0.0 cm`), and a failure is one sentence
that begins with the direction. Pairs of presses (forward and back, left and right, up and down) leave the arm about
where it started, not exactly: each press is judged from where the arm was just before it, and lag and drift add up to
a few millimetres. When the check ends, look at where the arm is and at the space around it before you press anything
else. Without a server the same check runs against the in-app server model for the SO-101 and for a second, different
arm in the Default plan, which is how the check itself is tested.

What each failure means and what to change:

| The sentence says | It means | Change |
|---|---|---|
| the hold did not start | the app did not start a hold: a stop is latched, the state is old or the server refused | read the app's log lines the test prints; clear a stop yourself; check the address; run again |
| the arm did not move | the hold started and the point moved under 2 mm: the server did not act on it, or the arm was against a limit at its start pose | move the arm's start pose off any limit with the server's own jog and run again; check that the server accepts the app's holds |
| the arm went the wrong way along an axis | the sign of that axis differs between what the app sends and what the server does with it. For both `up` and `down` it is the sign of the vertical axis | `server.link_signs`: flip the sign of the base axis the sentence names, and run the check again |
| the arm went along another axis instead | one possible cause is a server frame with axes swapped relative to the base, which a profile cannot say; a limit near the start pose, a sag under gravity or a path that is not straight (a move of 8 mm along x with 9 mm of sag in z lands here too) are others | stop; move the start pose clear of limits and look at the move with the server's own tools; only a frame confirmed swapped there means this arm's server needs code, not only a file |
| the arm went along the axis but also along another (more than 30 degrees off) | the arm was against a limit, sagged under gravity or moved on a path that is not straight; the app's signs cannot make a single-axis move leave its axis | move the start pose clear of limits and run again; if it repeats on one direction, look at that arm's path with the server's own tools |

A warning about distance is not a failure; when it is large or repeats on every direction, measure the speed
(`robot.motion`) and write it.

**The work box and forward.** The work box (`scene.workspace_min_m`, `scene.workspace_max_m`) is measured in the base
frame with no reference to `robot.directions`, so it can tell something the read-back cannot. The check assumes the
operator stands behind the base, looking at the work area (or, for an arm that hangs over its work area, at the near edge
of the table, looking at the arm), so the box's centre less the base origin should point along forward and not along
back. When the centre lies behind the base along forward by more than a quarter of the box's width, the check prints a
warning before the first press. It is a plausibility rule, not a proof: it cannot tell a work area that lies beside
the arm, and it never refuses a file. It also has a dead zone: an arm that hangs over its work area has the box's
centre near the base, and inside the quarter of the box's width the check says nothing. Bench arm B's box is 16 cm
wide with its centre 2.8 cm behind the base along forward, against a dead zone of 4 cm, so neither B nor B with forward
and left both reversed is warned. The warning helps for an arm whose work area lies clearly in front of it; a person
watching the arm, and the look at the six buttons below, are still required.

**A pass says that what the app sends and what the server does agree, and nothing about the room.** Then look at
the arm and press each of the six buttons once on the pad. Forward must go away from the operator, left to the operator's
left and up up. If not:

- forward goes toward you and left goes to your right: flip the sign of both in `robot.directions` (one flip alone makes a
  mirror image, and the load refuses it);
- forward goes to your left or right, or left goes toward or away from you: the axis is wrong, not its sign. Find the
  three axes again as `robot.directions` says and write forward, left and up afresh. If forward goes to your left and left
  goes away from you, the two are exchanged: write each axis in the other's field, and look at `up` as well, because a
  file that exchanged them and had `up` right would have been refused;
- up goes down: `up` is the other way, and so is one of forward or left (the load refuses one flip alone as a mirror
  image): flip `up` and that one. Then `scene.base_axes_in_world` must put the new `up` along world +z, which the load
  checks and names both fields when they differ; if the world's vertical in that field was also wrong, fix it too.

Run the check again after any change.

## Fields

Each table gives the key, its unit, what it does, and the SO-101 value with how it was found.

### `robot.directions`

Which base axis, and which way along it, is forward, left and up as the operator at the table sees them; right, back
and down are the opposites. Buttons, voice and the phone all send these directions, and the guide draws them.

**Where the operator stands.** Behind the base, looking at the work area: forward is away from the operator, toward the
work area, and left is the operator's own left. For an arm that hangs over its work area (the work box then lies close
to the base), the operator stands at the table's near edge, looking at the arm, and forward is again away from them. The
file does not say where the operator is; it says which base axis each of these directions is, so measure it from that
place.

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `forward` | axis | the base axis the arm moves along, away from the operator, when told forward | `-y` |
| `left` | axis | the base axis the arm moves along toward the operator's left | `+x`: toward the goal |
| `up` | axis | the base axis the arm moves along when told up; "height" everywhere in the app (the table, "lowest", the travel height) is the part along this axis | `+z` |

The SO-101's values: base +x runs toward the goal, which is at the operator's left; base −y is away from the base,
which is forward; base +z is up. A wrong value goes wrong in the loudest way: every direction moves the arm the
wrong way, the guide is mirrored, or, with one sign wrong, the arm moves toward the operator. To find them for a new
arm, stand where the operator stands, with the arm's start pose clear. Move the arm a few centimetres along one base
axis at a time by anything the server gives that names a base axis (its own jog, or a `move_delta`, `PROTOCOL.md`), and
read the change of `ee_pos` in the server's state. For each of +x, +y and +z, say whether the arm went away from you
(forward), toward your left, or up; the opposite axis is back, right or down. Write the three axes for forward, left
and up. The load refuses a set that makes a mirror image. It cannot refuse a set with two wrong signs (told forward
and left, the arm goes back and right), and the direction check cannot either, because the app sends what the file
says and the arm then goes there: after the check passes, look at the arm for each direction once.
After a pass, the check also warns when the work box lies clearly behind the base along forward, which catches a
forward and left that are both the wrong way round for an operator who stands as above. `up` must also be the base axis that `scene.base_axes_in_world` puts along world +z: the two fields say the same fact
about the mounting, and the load refuses a file in which they differ.

### `server`

What the server does to what it is sent and how it behaves, which is a fact about the server, not about the arm.

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `link_signs` | [x, y, z], each 1 or -1 | the server moves the base by a translation hold's offset with each axis multiplied by these: the frame the app sends offsets in is the base frame with some axes mirrored | [1, 1, -1]: the S4 server was calibrated on a WebXR phone (mapping `phone_axes_20261025_v1`, `frame: webxr_local`) and moves the arm by [p0, p1, −p2] of the offset it is sent. A server whose z is up in its own frame would give [1, 1, 1] |
| `stop_distance_m` | m | the server stops the arm for good when the position it is asked for is farther than this from where the arm is. No command may ask for more: `robot.motion.max_lead_m` and `tool_max_lead_m` must be under it, and the load refuses a file in which they are not | 0.10: the S4 server's `pose_tracking_safety_stop` distance |
| `resync.after_ms` | ms | the server reports no arm position during a hold. When the hand wants more than the lead cap, the server hold is ended and started again from where the arm got to after this long of catching up, on the gripper link's path | 1500; no measurement is recorded in the code for it |
| `resync.tool_after_ms` | ms | the same on the tool point's path | 500; no measurement is recorded either |
| `resync.timeout_ms` | ms | the longest wait for the server to finish the old hold during a resync before the operator's hold ends | 1500 |
| `held_object_point` | `gripper_link` or `tool_point` | which point a pad hold moves while the jaws hold an object. `gripper_link`: the gripper link's origin, with no coordinated height, once the jaws hold something; `tool_point`: the tool point, held or not | `gripper_link`: carrying the simulator's cube on the tool point's path, the arm lifted it in 1 of 10 trials, and on the gripper link's path in 9 of 10. That is a fact about the S4 server, so another server that lifts fine through the tool point says `tool_point` |
| `stall_detection` | `simulation` or `none` | `simulation`: the server runs a simulation loop that can stop, and the app reads its signs (`sim_stalled`, `busy` answers, stale timing, a stop nobody answers) to pause and then say "Simulator not responding". `none`: the server has no such loop, and the detector never fires | `simulation`: the S4 server's loop stopped once while its network side kept answering, and the timed rules (2 s old states, 3 s busy, 3 s for a stop's answer) were set from that one recorded stop; they are not profile fields |

A wrong sign reverses that axis: for the SO-101's z, every vertical move would go the other way. To find them, send a
translation hold of +1 cm along each of the link's axes and read the change of `ee_pos`; the sign of the change is the
sign.

The full sentence for a stop because the arm fell behind (`stop.cause_arm_behind`, built by `StopCause.text`) takes
the profile's `server.stop_distance_m` as its number, in centimetres, in both languages: 10 cm for the SO-101, 6 cm for
a server that stops at 6 cm. The operating screen shows the short cause (`cause.behind`), which carries no number.

How to measure the rest on a new arm:

- `stop_distance_m`: read it in the server's source or its documentation; or, on a test arm, ask for larger and larger
  offsets until it stops the arm, and write a little under the largest distance it let through.
- `resync.after_ms`, `tool_after_ms`: hold a button for 10 s on Coarse and watch whether the arm keeps up with the
  command; write how long the arm may fall behind before the hold should be ended and started again from where the arm
  is. Start from the SO-101's numbers and shorten them while holds still arrive.
- `resync.timeout_ms`: time from sending the end of a hold to the server's final answer (`pose_stopped`) on a loaded
  server, and write about twice the longest.
- `held_object_point`: see the last item below.
- `stall_detection`: does the server run a simulation loop that can stop while its network side still answers
  (`sim_stalled` in its states)? `simulation` if so, else `none`.

What goes wrong when a value is wrong:

- A stop distance that is larger than the server's lets the load accept a lead cap the server then answers with an
  emergency stop. Read the distance in the server's source or find it by asking for larger and larger offsets on a
  test arm.
- A resync time that is too short ends and restarts holds that were about to arrive, so the arm moves in steps; too
  long and the hand runs far ahead of an arm that does not follow. A timeout that is shorter than the server needs to
  finish a hold ends the operator's hold in every resync.
- `gripper_link` for a server that lifts fine through the tool point costs the coordinated height and the tool's
  accuracy while carrying; `tool_point` for a server that does not lifts the object badly or has moves refused once it
  is gripped. Lift an object both ways, ten times each, and keep the one that places it.
- `simulation` for a server with no loop reads a slow bus as a stopped simulation and pauses the operator for nothing;
  `none` for a server with a loop never says that the simulator has stopped.

### `robot.motion`

How fast the arm is asked to move from the buttons, and how far a command may run ahead of where the server's hold
began.

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `fine_mps`, `coarse_mps` | m/s | how fast a held direction button moves the arm's target on the Fine and on the Coarse switch, in wall time | 0.01 and 0.04: coarse is the pad's default and the speed of tap-to-go, near the measured median following speed of 0.034 m/s, and Fine is a quarter of it |
| `max_lead_m` | m | the most a translation command on the gripper link's path may run ahead of where the server's hold began. Under `server.stop_distance_m`, whatever the arm's speed | 0.08: under the S4 server's 10 cm stop distance with 2 cm to spare; no measurement is recorded for the 2 cm |
| `tool_max_lead_m` | m | the same on the tool point's path | 0.005: tuned to the S4 simulator; no measurement is recorded for it |

What goes wrong when a value is wrong:

- A speed that is faster than the arm follows makes a held button run away from the arm, and the cap then holds the
  command back; one that is much slower than the arm's own speed makes coarse a crawl. Hold a button for 5 s on the
  arm and compare the change of `ee_pos` with speed times 5.
- A cap that is under what the arm follows in one resync period slows every hold; a cap near the stop distance leaves
  no room for the lead that arrives while a command is in flight, and an emergency stop follows.

### `robot.wrist`

The wrist turns (roll) and tilts (flex): two directions, in server degrees. The phone's rotation and the Wrist page's
four buttons both drive them, with one pair of signs.

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `roll_sign` | 1 or -1 | server wrist roll = this × the turn. The turn is clockwise as the operator sees the screen; the Turn right button is the same turn | 1: Turn right is a positive roll, as seen in the top and side views |
| `tilt_sign` | 1 or -1 | server wrist flex = this × the tilt. The tilt is the top of the phone away from the operator; the Tilt down button is the same tilt | 1. A positive pitch points the jaws toward the table (PROTOCOL.md, "the wrist"), so Tilt down is positive |
| `roll_window_deg` | deg | the roll a hold asks for stays within this either way of 0, judged from the measured roll; a hold may always turn back toward 0 | 150. The S4 server's soft limit is ±160, so this keeps 10 degrees clear of it |
| `tilt_window_deg` | deg | the flex stays within this either way of `tilt_centre_deg` | 25: chosen, not measured |
| `roll_clamp_deg`, `tilt_clamp_deg` | deg | the most one hold may turn or tilt the wrist from where the hold began; never above the window of the same direction | 55 and 20: inside the S4 server's own per-hold clamps of 60 and 35 degrees |
| `tilt_centre_deg` | deg, or null | where the tilt window is centred. A number is a fixed flex; null centres it on the flex measured in the first state after the last reset | null: centred on the flex measured after the last reset |
| `turn_rate_deg_s`, `tilt_rate_deg_s` | deg/s | how fast a held wrist button moves the wrist, whichever way | 20 and 10: a held Turn button reaches the 55 degree limit in 2.75 s and a Tilt button the 20 degree limit in 2 s; no measurement is recorded for them |
| `lead.lead_deg` | deg | the commanded angle may lead the newest fresh measured angle by this much, always | 2 |
| `lead.rate_max_deg_s` | deg/s | and by this much more for each second of that state's age. Not a speed limit of the wrist | 10 |
| `lead.memory_deg` | deg | the lead left by one hold counts for the next only if the wrist has moved no more than this since | 0.5 |
| `lead.fresh_state_ms` | ms | a measured angle older than this is not fresh; with none fresh the command may only come back toward the wrist | 400 |

How to measure on a new arm:

- `roll_window_deg`, `tilt_window_deg`, `roll_clamp_deg`, `tilt_clamp_deg`: read the wrist's range and per-hold limits
  from the server (`orient_start` is clamped at its limits, `PROTOCOL.md`), or turn and tilt the wrist to each end with
  the server's own jog and read `wrist_roll_deg` and `wrist_flex_deg`. Write a window a few degrees inside the range
  and a clamp inside the server's own per-hold clamp.
- `tilt_centre_deg`: the flex at the pose the arm starts from after a reset, if it is always the same; null if it is
  not.
- `turn_rate_deg_s`, `tilt_rate_deg_s`: hold a wrist button for 3 s and divide the change of the angle the server
  reports by 3; write the speed the arm follows without lagging.
- `lead.*`: the lead is how far the command may run ahead of the measured wrist. Hold a wrist button on the arm and
  note how far the measured angle trails the command: `lead_deg` a little above that, `rate_max_deg_s` the wrist's own
  speed, `memory_deg` the smallest angle the server's report resolves, `fresh_state_ms` about twice the interval
  between the server's states. Both joints, roll and flex, use the same rule: the command may lead the measured angle
  by `lead_deg + rate_max_deg_s × the state's age`, and there is no second cap on `lead_deg` alone. So one
  `rate_max_deg_s` serves both joints, and where their speeds differ a rate that fits the faster joint loosens the
  slower joint's allowance too. Example: `lead_deg` 3 and `rate_max_deg_s` 40 allow 3 + 40 × 0.3 = 15 degrees at 0.3 s
  of state age, on the slow joint as on the fast one. To choose: start with the faster joint's speed for
  `rate_max_deg_s` and the steady lag for `lead_deg`; then hold each of the two wrist buttons against the arm and compare
  how far the measured angle trails the command with the allowance at your server's state age. If the slower joint's
  allowance is larger than you can accept, lower `rate_max_deg_s` (the faster joint is then held back a little) or
  lower `lead_deg`.

What goes wrong when a value is wrong:

- A sign other than the arm's turns or tilts the wrist the wrong way, and does so for the phone and the buttons
  alike. Check each direction on the arm before the first grasp: turn right once and read `wrist_roll_deg`, tilt down
  once and read `wrist_flex_deg`.
- A window wider than the arm's range makes the app ask for angles the server clamps or refuses silently; one that is
  too narrow wastes range (a wrist with a ±90 degree roll limit and a window of 150 asks for 60 degrees it cannot
  have).
- A tilt centre that is not where the arm's neutral wrist is leaves the tilt window off to one side: an arm with no
  flex that a reset decides should give a number, not null.
- A rate that is too fast for the arm makes a held button overshoot what the operator meant; too slow makes the
  button useless.
- Lead numbers that are too small hold back a wrist that follows well; too large let the commanded angle run far
  ahead of a blocked wrist, which then jumps once it is free.

### `robot.gripper`

What the jaw's readings mean. The jaw reading is the server's `gripper_deg`: the field keeps that name whatever the
unit, and carries the reading in `unit`. Three things are kept apart: the two readings the opening share is drawn
between, the readings that count at all, and the two thresholds the feedback rules use.

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `unit` | `deg` or `mm` | what the readings are measured in; the session record writes it beside the jaw reading (`jaw_unit`) | `deg`: a hinged jaw |
| `closed_reading`, `open_reading` | reading | the readings the jaw's opening share is drawn between: the share is 0 at the first and 1 at the second, held to that range, and the guide's jaw drawing and its percentage use it. Different numbers, closed below open | 0 and 97: the S4 jaw reads 0 with the jaws shut and 97 when they are open as far as they go; the joint's limit is 100 |
| `valid_min`, `valid_max` | reading | the readings that count as a jaw reading; a `gripper_deg` outside them is read as if the server had not sent it. The wrist joints have their own bound (a full turn either way) | -360 and 360: wide enough for any reading the S4 jaw gives, and it keeps a number an integer cannot hold from reaching the guide |
| `fully_open_at` | reading | a reading at or above this while opening counts as fully open | 97 |
| `empty_at` | reading | at or below this when a close has ended with no contact, the jaws closed on nothing; below `fully_open_at` | 2: an empty close settled at 0.4 degrees on the S4 simulator, and a check on the device may set it later |
| `reclose_loosens_grip` | yes/no | a second close while gripping is refused until the jaws have opened, because a close starts from the measured reading and so loosens the grip | true; a robot that must squeeze harder to hold would set it false |

How to measure on a new arm:

- `unit`: read it off the server: a hinged jaw reports an angle (`deg`), parallel jaws a gap (`mm`).
- `closed_reading`, `open_reading`: read `gripper_deg` with the jaws shut on nothing and with them open as far as they
  go.
- `valid_min`, `valid_max`: a little beyond those two readings; as wide as the server's own limits for the joint.
- `fully_open_at`: the reading while the jaws are open, a little under the open reading so a jaw that stops just short
  still counts.
- `empty_at`: close the jaws on nothing, let them settle, and write the reading a little above it; then close on the
  smallest object the arm picks and check that its reading stays above `empty_at`.
- `reclose_loosens_grip`: close on an object, send a second close, and see whether the grip loosens (true) or tightens
  (false).

What goes wrong when a value is wrong:

- Readings and `unit` that do not match the server's: the jaw is drawn open when it is shut, "fully open" is told at
  the wrong place or never. Read `gripper_deg` with the jaws shut and with them open as far as they go, and write
  those two numbers.
- `valid_min` and `valid_max` that are too narrow throw away good readings (the jaw seems to report nothing, so
  "fully open" and "closed on nothing" are never told); too wide let a nonsense number through to the guide.
- A `fully_open_at` that is beyond what the jaw can reach is never told; an `empty_at` that is above the reading of a
  gentle grip tells "closed on nothing" when the jaws hold something small. `empty_at` must be at or above
  `closed_reading`, `fully_open_at` at or below `open_reading` and `empty_at` below `fully_open_at`; the two readings
  must lie inside the valid readings. The load refuses a file that breaks any of these.
- A jaw whose reading falls as it opens is not supported: the rules read "at or above" for open and "at or below" for
  closed.

### `scene`

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `base_in_world_m` | m, [x, y, z] | where the robot base sits in the world frame; the server reports the arm in the base frame and objects in the world frame, and this brings objects into the base frame | [0, 0, 0.05], `ROBOT_BASE_POS_W` in the simulator's source |
| `base_axes_in_world` | axes, `x`, `y`, `z` | which world axis each axis of the robot base lies along: the quarter turn from the base to the world, applied with the shift above | `x`: `+x`, `y`: `+y`, `z`: `+z`: the SO-101's base axes lie along the world's. The base axis that lies along world +z must be `robot.directions.up`, the same way |
| `table_height_m` | m | the table surface's height over the base origin, along up (`robot.directions.up`), for the guide | 0.04: the simulator's `TABLE_TOP_Z_M` minus the base height. For a base whose up is the other way along its z, the table under it has a negative height |
| `workspace_min_m`, `workspace_max_m` | m, [x, y, z] | the box the server keeps the **pinch point** inside (the point where the jaws close, not the gripper link), as the pinch point's position in the robot base frame with the wrist in the pose it keeps while the operator works; for the guide and the "Blocked." rule. The box for the gripper link's reported point is this box less `scene.tool_offset.offset_m` | the simulator clamps the gripper link's reported point to 8 cm either way of where it is after a reset; the file holds that box plus `offset_m`, which is the pinch point's box. It holds while the wrist keeps its start pose; when the server reports a tool point, the guide moves the box by the measured offset instead |
| `target_size_m` | m | the task object's size across, to draw it true to size | 0.025, the cube |
| `goal_size_m` | m | the goal area's size across; the goal is the box the server judges success in | 0.05 |
| `grasp_tolerance_m` | m, [across, height] | how close the pinch point must be to the object's centre for a close to take hold of it; also the level word, the threshold for an approximate estimate, and the server model's grasp window | [0.006, 0.008]: in the simulator the window is a few millimetres either way |
| `on_target_window_m` | m, [across, height], or null | a wider window for the guide's "On target" and its cue, used when the guide's aids ask for it; never narrower than `grasp_tolerance_m` on either axis | null: the grasp tolerance is used |

How to measure on a new arm, and what goes wrong:

- `base_in_world_m`, `base_axes_in_world`: from the server's scene setup if it gives where the base sits and how it is
  turned; else measure them. First `base_axes_in_world`: move the pinch point a few centimetres along base x, y and z in
  turn and see which world axis, and which way, the pinch point went (from the mounting, or from the world position the
  server reports for an object the jaws carry); write that world axis for each base axis. Then `base_in_world_m`, the
  base origin in the world frame: put the pinch point on an object whose world position the server reports, read the
  pinch point in the base frame, and take **origin = the object's world position less R times the pinch point's base
  position**, where R turns a base position into a world one: the base x coordinate times the world axis x lies along,
  plus the base y coordinate times the world axis y lies along, plus the base z coordinate times the world axis z lies
  along. Only for a base that is not turned does this reduce to the plain difference. For example, a base whose x lies
  along world +y, y along world +x and z along world −z, with the pinch point at base (−0.05, −0.07, 0.2675) on an
  object at world (0.03, −0.25, 0.1325): R times the base position is (−0.07, −0.05, −0.2675), so the origin is
  (0.10, −0.20, 0.40). A wrong value draws the object, the goal and the table in the wrong place on the guide, so
  "On target" is told at the wrong place or never.
- `table_height_m`: lower the arm onto the table and read the pinch point's height along up; it is negative for a base
  that hangs above the table with up pointing down. A wrong value gives a wrong table line and a wrong "lowest" and
  travel height.
- `workspace_min_m`, `workspace_max_m`: the box the **pinch point** can reach, in the base frame, with the wrist in
  the pose it keeps while the operator works. Measure it by driving the arm with the server's own jog against each of
  the box's six faces and reading the pinch point there: `tool_pos` where the server reports it, else `ee_pos` plus
  `scene.tool_offset.offset_m`. If the server's own limit is given for the gripper link's reported point (`ee_pos`), add
  `offset_m` to both corners. The box is the same in every place of this guide: never the gripper link's box. The check
  in "Before the first move on a new arm" uses the box's centre. Too small a box tells "Blocked." where the arm could
  still go; too large a box lets the guide draw the arm outside what the server allows; a box for the gripper link
  written here is off by the tool offset, so the guide's work area sits that far from where the arm can reach.
- `target_size_m`, `goal_size_m`: measure the object and the goal area, or read them from the server's scene.
- `grasp_tolerance_m`: close the jaws with the pinch point off the object's centre by 2, 4, 6 and 8 mm across and in
  height, and write where the object still lifts. Too tight and "On target" is never told; too loose and it is told
  where the grasp misses.
- `on_target_window_m`: null unless the guide should say "On target" in a wider window than the grasp needs; never
  narrower than `grasp_tolerance_m`.

### `scene.tool_offset`

When the server's state has no `tool_pos`, the app estimates where the jaws pinch as the reported gripper point plus
this offset. The estimate is exact where the offset was measured and grows less certain away from it.

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `offset_m` | m, [x, y, z] | from the point the server reports for the arm (the gripper link origin) to where the jaws pinch, robot base frame; holds while the wrist joints stay put | [0.007, -0.036, -0.088]: measured on the S4 simulator with the jaws turned sideways, where the reported point sat at the cube's centre plus (−0.007, +0.036, +0.088). The scene starts with the jaws sideways (wrist roll 90 degrees), so the offset holds from the start pose |
| `measured_at_m` | m, [x, y, z] | the reported point where the offset was measured (the cube's resting centre minus the offset) | [-0.002, -0.164, 0.1405] |
| `measured_flex_deg`, `measured_roll_deg` | deg | the wrist flex and roll at that measurement | 40.24 and 90 |
| `error_bound` | see below | how far the estimate may be off elsewhere; past half of `grasp_tolerance_m` across, the guide draws the pinch point as approximate | see below |

To measure the offset on a new arm: with the wrist at the pose it keeps while the operator works, bring the jaws so
that a close takes hold of the object, centred. Read `ee_pos` there (`measured_at_m`) and the wrist's flex and roll
(`measured_flex_deg`, `measured_roll_deg`); the offset is the object's centre (in the base frame) less `ee_pos`. A server
that reports `tool_pos` makes the offset unnecessary, but the file still needs one. To measure `error_bound`, move the arm
a few centimetres along each axis and turn the wrist a few degrees, measure the offset again each time, and write for
each axis and each wrist angle the largest change of the offset per centimetre or per degree, rounded up. A wrong offset
draws the pinch point away from where the jaws close, so the operator lines up the wrong point and the grasp misses; a
bound that is too small hides that the estimate is approximate.

`error_bound` adds, in millimetres: so many per centimetre the reported point has moved from `measured_at_m` along
each base axis (`x_mm_per_cm` and `z_mm_per_cm` either way along that axis; `plus_y_mm_per_cm` when the point has moved
toward base +y and `minus_y_mm_per_cm` when toward base −y, because the offset changes at a different rate each way), plus
so many per degree the wrist's flex and roll are from their measured values (`flex_mm_per_deg`, `roll_mm_per_deg`). Without both wrist angles there is no bound and the estimate is approximate.
For the SO-101 the rates are 2.56, 11.12, 1.80, 8.43, 1.65 and 0.23. They were computed from the SO-101's
description and the server's solver, fitted never to underestimate within 6 cm across and 5 cm above the measured
place, and tested with tilt and turn up to 30 degrees. Below the measured height, where the fit has no places, the
rate for up is used; outside the fitted region the bound is already over 10 mm. The line at half the grasp
tolerance comes from hand trials, where a lift needed the jaws within about 1 cm, and the SO-101's tolerance is
6 mm.

### `response`

How the app tells that an arm is held back, and that it cannot go lower. The numbers come from how one arm and its
server answer a command: the SO-101 in the S4 simulator reports about 12 to 17 passes a second and follows slowly, so a
faster arm stalls inside a one second window and a slower one is told it is blocked while it is still moving. To
find them on a new arm, drive it into the table and into a wall on purpose, log the states, and read how far the
measured point moves in a second and how often states arrive.

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `directional_blocked_feedback` | yes/no | with the guide's additions on, "Blocked." is told by the direction asked, using the box for the gripper link (the work box less the tool offset) | true: the box has been checked against the workspace in the server's recordings |

#### `response.blocked`

"Blocked." is told when the commanded point is ahead of the measured arm and the arm makes little progress over a window
of fresh states.

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `short_m` | m | the command must be at least this far ahead of the measured point | 0.010 |
| `moved_m` | m | over the window the measured point moved less than this: the arm stood still. It is also the distance within which two points are the same place | 0.002 |
| `window_ms` | ms | the window the arm is judged over | 1000: the code's comment names the simulator's 12 to 17 passes a second as where the window comes from |
| `fresh_ms` | ms | a measured position older than this says nothing about now | 400: the listening connection reports about every 0.2 s |
| `arrival_gap_ms` | ms | no two states of a judged window arrived further apart than this: states held back and delivered together say nothing about how the arm stood between them | 400; no measurement is recorded for it. An ordinary wireless network was measured holding every message back for up to 1.8 s and then delivering them together, which is what this number is there to ignore |
| `lead_progress_share` | share | with a work box, an arm that made less progress along the lead than the lesser of `moved_m` and this share of the lead is not following | 0.10 |
| `exclusion_m` | m | with a work box, an arm that moved this far, in any direction, is following, not held back | 0.04 |
| `following_share` | share | with a work box, an arm that moved along the command's own travel by at least this share of it is following | 0.5 |
| `same_way_deg` | deg | with a work box, a lead that turns by less than this is part of the same request | 45 |

#### `response.lowest`

"Can't go lower." is told when the height alone stands against an ask for lower: an arm on a table slides along it, so
it is never still in all three directions.

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `sustain_m` | m | the full stall: every state of the window was sent at least this much lower (the newest at least `blocked.short_m`) | 0.005 |
| `quick_short_m`, `quick_moved_m`, `quick_ms` | m, m, ms | the quicker stall, back near the lowest height already found (within `blocked.moved_m` of it): every state of the last `quick_ms` was sent at least `quick_short_m` lower, and the height moved less than `quick_moved_m` | 0.005 m, 0.001 m, 300 ms |
| `descent_mps` | m/s | no stall is told while the height is still falling at least this fast over its window | 0.0005: at about 12 passes a second an arm asked down at the fine speed came down 1.4 to 2.0 mm a second, inside the 2 mm the full stall allows, while an arm that had stopped moved less than 0.1 mm |

What goes wrong when a value is wrong:

- Windows and distances that are too tight for the arm tell "Blocked." while it is still moving; too loose tell
  nothing, and the operator holds against a wall.
- A fresh time shorter than the states' interval makes every state stale, so the rules never judge; an arrival gap
  that is too short makes a network that delivers in bursts hide every stall.
- A descent rate that is too large calls an arm that is still coming down stopped, and tells "Can't go lower." before
  it has landed; one that is too small keeps an arm that has stopped, but still drifts a little, "descending", and tells
  nothing.
- Some numbers are equal on the SO-101 and are separate fields, so that another arm or server can set each apart:
  the three freshness times `robot.wrist.lead.fresh_state_ms`, `response.blocked.fresh_ms` (also the freshness of the
  tool point's measured position for the link controller's lead) and `assist.go_to.pacing.fresh_ms` (all 400 ms), and
  the two still distances `response.blocked.moved_m` and `assist.go_to.pacing.still_m` (both 0.002 m).

### `assist`

Which hands-free aids the robot allows, with their numbers. Each of the five is an object or `null`; `null` means
the robot does not allow that aid. With all five `null` the robot allows none and needs no code path of its own.

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `lock.time_limit_s` | s | lock (a follow nobody holds) is allowed exactly when this is given; the longest a latched follow runs, counted from the latch | 30. What would change it: how long latched runs last in sessions with people; a safety review |
| `go_to.travel_height_m` | m | tap-to-go: the pinch point's height above the table for the level leg | 0.05: a held 2.5 cm object's bottom is then 3.75 cm up, and the pinch point, at 0.09 m in the base frame, is inside the box's 0.152 m top |
| `go_to.speed_mps` | m/s | top speed of the commanded pinch point along the path | 0.04: the pad's coarse speed, near the measured median following speed (0.034 m/s) and under the simulator's own cap on a moving setpoint (about 0.077 m/s) |
| `go_to.arrive_tolerance_m` | m | a fresh measured pinch point this close to the target has arrived | 0.008: under the "Blocked." rule's 10 mm; the grasp window's height |
| `go_to.corrections` | count | how many times a move that settled short may aim again | 2: one may go to holding the travel height, one to the end |
| `go_to.correction_reach_m` | m | the longest remainder a move aims again by | 0.03 |
| `go_to.settle_s` | s | how long fresh positions must stay within `pacing.still_m`, with the command at its leg's end, to count as settled | 0.6 |
| `go_to.time_factor`, `go_to.allowance_s` | factor, s | the deadline: the path's length over the speed, times the factor, plus the allowance | 1.5 and 3.0: at least 3 s, and room for one re-sent start on the longest path in the box (a test pins both) |
| `go_to.arm_data_timeout_s` | s | no measured position younger than this ends the move ("No arm data.") | 2.0: the listening connection reports about every 0.2 s, and an ordinary wireless network was measured holding messages back for up to 1.8 s |
| `go_to.start_grace_s` | s | no stall is judged from positions measured this soon after the start, or after the end of the hold's last pause, unless the arm has already moved `pacing.still_m` | 1.5: a start the server takes late, or an arm that lags at first, is not a stall |
| `go_to.pacing.follow_share` | share | each fresh reading moves the link command this share of the way to the offset it measured (pinch point less gripper link). The whole way overshoots where the jaws swing more than the link moves, since a reading shows a command's effect one or two readings later | 0.5 |
| `go_to.pacing.pace_gain`, `slowest_share`, `start_share` | factor, share, share | the command moves at the speed times min(1, `pace_gain` over the swing), swing being the measured offset's change per unit of gripper-link travel; never under `slowest_share` of the speed, and at `start_share` until the first swing is measured | 0.25, 0.15 and 0.5: tuned on the simulator's arm; no measurement is recorded for them |
| `go_to.pacing.path_watch_tolerances` | factor | a fresh reading this many `arrive_tolerance_m` from the leg ahead ends the move stopped short | 2.5, so 20 mm for the SO-101 |
| `go_to.pacing.fresh_ms` | ms | a measured position older than this says nothing about now: the command waits for a fresher one | 400 |
| `go_to.pacing.still_m` | m | fresh points within this of one another count as standing still, an arm this far from where it started has been seen to move, and a pace is measured over this much link travel or more | 0.002 |
| `go_to.pacing.pace_change_share` | share | the pace is set again only when the share it would move at changes by more than this share of the present one | 0.05 |
| `guide` | yes/no each | which of the guide's additions run: `work_area_words`, `lowest_cue`, `shadow`, `direction_labels`, `wider_on_target` | all true |
| `explain.slow_link_let_go` | yes/no | a hold the operator holds that a slow link stops lets go with "Slow link."; a robot that gives `explain` also gives `guide` | true |
| `views.behind_top_above_table_m` | m | the fixed aiming views: how high above the table the rear view's top lies; at least the travel height | 0.09: keeps the heights used for positioning visible without spending space on the upper workspace |
| `views.max_retargeted_move_s` | s, or null | how long a retargeted move may run | 30 |

How to measure on a new arm: the SO-101's numbers are a safe start; nearly all of them are tuned, and few were measured.
Measure these, and tune the rest while watching tap-to-go reach a point:

- `go_to.travel_height_m`: the height of the pinch point over the table for the level leg, at least the held object's
  height plus a clearance, and inside the work box.
- `go_to.speed_mps`: hold a button on Coarse for 5 s and divide the change of the arm's position by 5; write the speed
  the arm follows, or less.
- `go_to.arrive_tolerance_m`: no more than the grasp tolerance's height, so that arriving counts as on target.
- `go_to.arm_data_timeout_s`: more than the longest the server goes without a state on the network used (about 0.2 s
  between states on the SO-101's, and up to 1.8 s measured on an ordinary wireless network).
- `guide`, `explain`, `views`, `lock`: choices, not measurements; give `null` for an aid the robot should not allow.

What goes wrong in `assist` when a value is wrong: a speed above what the arm follows makes the move stall and end
short; an arrival tolerance under what the arm settles to never arrives; a timeout under the network's longest quiet
ends a move for nothing; a travel height under the object's height drags it across the table.

What goes wrong when a pacing value is wrong: a follow share near 1 overshoots on an arm whose jaws swing, and one
near 0 follows nothing; a pace gain that is too large lets the command outrun the readings; a start share that is too
low makes every move start slowly and a deadline that is too long; path watch tolerances that are too tight end moves
that were fine.

`ARCHITECTURE.md` ("The hands-free aids" and "The guide's additions") says how each aid uses these numbers.

## Worked example: the SO-101's file, top to bottom

`App/Resources/Profiles/so101-s4-sim.json`, read as one person would read it to write another arm's.

1. `profile_version` is 1 and `name` is a label the app shows.
2. `robot.directions`: forward is base −y, left is base +x, up is base +z. The base's +x runs toward the operator's
   left and its −y away from the base; the table is in front of the arm, so away from the base is forward.
3. `robot.wrist`: both signs are 1 (a positive roll turns right; a positive flex tips the jaws toward the table). The
   roll may go 150 degrees either way and 55 per hold, the tilt 25 either way of where the wrist stood after the reset
   (`tilt_centre_deg` null) and 20 per hold. The wrist buttons turn at 20 degrees a second and tilt at 10. `lead`
   says the command may be 2 degrees ahead of the measured angle, plus 10 degrees for each second of the state's age,
   with 0.5 degrees of memory and states over 400 ms old not counted.
4. `robot.gripper`: a hinged jaw in degrees, reading 0 shut and 97 fully open, any reading between −360 and 360
   believed, fully open at 97 and closed on nothing at 2, and a second close while gripping is refused.
5. `robot.motion`: buttons move the target 1 cm a second on Fine and 4 on Coarse; a command may run 8 cm ahead of
   where the server's hold began on the gripper link's path and 5 mm on the tool point's.
6. `server`: the link's z is mirrored (`[1, 1, -1]`), the server stops the arm for good at 10 cm, a hold is ended and
   started again from where the arm is after 1.5 s (0.5 s on the tool point's path), waiting at most 1.5 s for the old
   hold to end; a gripped object is carried on the gripper link's path; the server runs a simulation loop that can stop.
7. `scene`: the base is 5 cm above the world's origin and its axes lie along the world's. The table is 4 cm above
   the base origin. The work box is 16 cm on a side; the cube is 2.5 cm and the goal 5 cm across; the jaws must be within
   6 mm across and 8 mm in height of the cube's centre to take hold; `on_target_window_m` is null, so the same window
   serves for "On target". `tool_offset` says the jaws pinch 7 mm to base +x, 36 mm to −y and 88 mm below the point the
   server reports, as measured with the wrist at flex 40.24 and roll 90, and `error_bound` says how fast that grows
   away from there.
8. `response`: "Blocked." is told by the direction asked; its numbers say the arm is blocked when the command is
   at least 1 cm ahead, the arm has moved under 2 mm in a second of fresh states (under 400 ms old, none more than
   400 ms apart); "Can't go lower." has its own numbers. They suit a server that sends about 12 to 17 states a second.
9. `assist`: all five aids are on, with the numbers `assist` lists above: a latched follow runs for at most 30 s; a tap
   moves the pinch point at 0.04 m/s at 5 cm above the table.

## The whole file

`App/Resources/Profiles/so101-s4-sim.json`, exactly as it is, so that every key name and its place in the nesting can be
seen. Write another arm's file in this shape: every key, none added. A check (`scripts/check-profile-doc.py`) fails when
this copy and the file differ.

```json
{
  "profile_version": 1,
  "name": "SO-101 (S4 simulator)",
  "robot": {
    "directions": {
      "forward": "-y",
      "left": "+x",
      "up": "+z"
    },
    "wrist": {
      "roll_sign": 1,
      "tilt_sign": 1,
      "roll_window_deg": 150,
      "tilt_window_deg": 25,
      "roll_clamp_deg": 55,
      "tilt_clamp_deg": 20,
      "tilt_centre_deg": null,
      "turn_rate_deg_s": 20,
      "tilt_rate_deg_s": 10,
      "lead": {
        "lead_deg": 2,
        "rate_max_deg_s": 10,
        "memory_deg": 0.5,
        "fresh_state_ms": 400
      }
    },
    "gripper": {
      "unit": "deg",
      "closed_reading": 0,
      "open_reading": 97,
      "valid_min": -360,
      "valid_max": 360,
      "fully_open_at": 97,
      "empty_at": 2,
      "reclose_loosens_grip": true
    },
    "motion": {
      "fine_mps": 0.01,
      "coarse_mps": 0.04,
      "max_lead_m": 0.08,
      "tool_max_lead_m": 0.005
    }
  },
  "server": {
    "link_signs": [1, 1, -1],
    "stop_distance_m": 0.1,
    "resync": {
      "after_ms": 1500,
      "tool_after_ms": 500,
      "timeout_ms": 1500
    },
    "held_object_point": "gripper_link",
    "stall_detection": "simulation"
  },
  "scene": {
    "base_in_world_m": [0, 0, 0.05],
    "base_axes_in_world": {
      "x": "+x",
      "y": "+y",
      "z": "+z"
    },
    "table_height_m": 0.04,
    "workspace_min_m": [-0.052383, -0.257418, -0.008015],
    "workspace_max_m": [0.107617, -0.097418, 0.151985],
    "target_size_m": 0.025,
    "goal_size_m": 0.05,
    "grasp_tolerance_m": [0.006, 0.008],
    "on_target_window_m": null,
    "tool_offset": {
      "offset_m": [0.007, -0.036, -0.088],
      "measured_at_m": [-0.002, -0.164, 0.1405],
      "measured_flex_deg": 40.24,
      "measured_roll_deg": 90,
      "error_bound": {
        "x_mm_per_cm": 2.56,
        "plus_y_mm_per_cm": 11.12,
        "minus_y_mm_per_cm": 1.8,
        "z_mm_per_cm": 8.43,
        "flex_mm_per_deg": 1.65,
        "roll_mm_per_deg": 0.23
      }
    }
  },
  "response": {
    "directional_blocked_feedback": true,
    "blocked": {
      "short_m": 0.01,
      "moved_m": 0.002,
      "window_ms": 1000,
      "fresh_ms": 400,
      "arrival_gap_ms": 400,
      "lead_progress_share": 0.1,
      "exclusion_m": 0.04,
      "following_share": 0.5,
      "same_way_deg": 45
    },
    "lowest": {
      "sustain_m": 0.005,
      "quick_short_m": 0.005,
      "quick_moved_m": 0.001,
      "quick_ms": 300,
      "descent_mps": 0.0005
    }
  },
  "assist": {
    "lock": {
      "time_limit_s": 30
    },
    "go_to": {
      "travel_height_m": 0.05,
      "speed_mps": 0.04,
      "arrive_tolerance_m": 0.008,
      "corrections": 2,
      "correction_reach_m": 0.03,
      "settle_s": 0.6,
      "time_factor": 1.5,
      "allowance_s": 3.0,
      "arm_data_timeout_s": 2.0,
      "start_grace_s": 1.5,
      "pacing": {
        "follow_share": 0.5,
        "pace_gain": 0.25,
        "slowest_share": 0.15,
        "start_share": 0.5,
        "path_watch_tolerances": 2.5,
        "fresh_ms": 400,
        "still_m": 0.002,
        "pace_change_share": 0.05
      }
    },
    "guide": {
      "work_area_words": true,
      "lowest_cue": true,
      "shadow": true,
      "direction_labels": true,
      "wider_on_target": true
    },
    "explain": {
      "slow_link_let_go": true
    },
    "views": {
      "behind_top_above_table_m": 0.09,
      "max_retargeted_move_s": 30
    }
  }
}
```
