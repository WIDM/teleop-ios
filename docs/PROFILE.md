# Robot profiles

A **robot profile** is a JSON file that holds what the app must know about one robot setup: the arm, its gripper, the
scene around it and the hands-free aids it allows. The server's messages do not carry these numbers, so each setup
the app drives needs one profile. The app ships one: the SO-101 arm in the S4 pick-and-place simulator,
`App/Resources/Profiles/so101-s4-sim.json`.

Not every number about an arm is in the profile yet. The ones still in code are listed under "Where robot and task
numbers live" in `ARCHITECTURE.md`.

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
code outside the tests brings back a direction table or conversion that the profile's frames replaced
(`OperatorDirection.baseAxis`, `OperatorFrame`, a direction's `baseVector` or `linkVector` property, the static
`GuideProjection` conversions) or holds or builds a `Frames` outside the core's `Profile` folder; and when any code,
tests and the loader included, reads `ProfileLoader.current` outside `AppModel` and `OperatingFixtures`. The
check reads text, not types: it catches accidents, and review catches deliberate workarounds. Tests read profiles
through `TestProfiles` in `Tests/TeleopTests`.

## The file format

```json
{
  "profile_version": 1,
  "name": "SO-101 (S4 simulator)",
  "robot":    { "directions": { ... }, "wrist": { ... }, "gripper": { ... } },
  "server":   { "link_signs": [ ... ] },
  "scene":    { ..., "base_axes_in_world": { ... }, "tool_offset": { ..., "error_bound": { ... } } },
  "response": { ... },
  "assist":   { "lock": ..., "go_to": ..., "guide": ..., "explain": ..., "views": ... }
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
- **Units are in the key's name:** `_m` metres, `_deg` degrees, `_s` seconds, `_mps` metres per second,
  `_mm_per_cm` millimetres per centimetre, `_mm_per_deg` millimetres per degree. A key without a unit is a count,
  a sign, a factor or a yes/no.
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
  valid half turn that only the direction check below catches);
- `server.link_signs` has a value that is not 1 or -1;
- `scene.base_axes_in_world`: x, y and z do not lie along three different world axes, or they make a mirror image (the
  base's x cross y must be its z); `scene.base_in_world_m` is not finite numbers;
- `robot.wrist.roll_sign` or `tilt_sign` is not 1 or -1;
- `robot.gripper.open_deg` is not above zero, `empty_deg` is negative, or `empty_deg` is not below `open_deg`;
- a position is not a finite number, or `scene.workspace_min_m` is not below `scene.workspace_max_m` on every axis;
- a size or tolerance (`target_size_m`, `goal_size_m`, `grasp_tolerance_m`, `on_target_window_m` when given) is not
  above zero, `on_target_window_m` is narrower than `grasp_tolerance_m` on either axis, or a rate of `error_bound` is
  negative;
- `assist.lock.time_limit_s` is not above zero;
- a number of `assist.go_to` is out of range: the travel height, speed, arrival tolerance, settle time, time factor
  and arm-data timeout must be above zero; the correction reach, allowance and start grace zero or more; the
  corrections a whole number zero or more;
- `assist.views` has a height that is not above zero or is below the travel height, a move limit that is not above
  zero, or is given without `assist.go_to`;
- `assist.explain` is given without `assist.guide`.

## Fields

Each table gives the key, its unit, what it does, and the SO-101 value with how it was found.

### `robot.directions`

Which base axis, and which way along it, is forward, left and up as the operator at the table sees them; right, back
and down are the opposites. Buttons, voice and the phone all send these directions, and the guide draws them.

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `forward` | axis | the base axis the arm moves along, away from the operator, when told forward | `-y` |
| `left` | axis | the base axis the arm moves along toward the operator's left | `+x`: toward the goal |
| `up` | axis | the base axis the arm moves along when told up; "height" everywhere in the app (the table, "lowest", the travel height) is the part along this axis | `+z` |

The SO-101's values are the app's former direction table (INTERACTION §3.3), the one source for them before this
file; its comment says base +x is left "toward the goal". A wrong value goes wrong in the loudest way: every direction moves the arm the
wrong way, the guide is mirrored, or, with one sign wrong, the arm moves toward the operator. To find them for a new
arm, with the arm's start pose clear, press each of the six direction buttons once and read the change of `ee_pos` in
the server's state: the axis that changed is the base axis and the sign of the change is the sign. Write the three axes
for forward, left and up; the load refuses a set that makes a mirror image, and the six presses confirm the rest.

### `server`

What the server does to what it is sent, which is a fact about the server, not about the arm.

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `link_signs` | [x, y, z], each 1 or -1 | the server moves the base by a translation hold's offset with each axis multiplied by these: the frame the app sends offsets in is the base frame with some axes mirrored | [1, 1, -1]: the S4 server was calibrated on a WebXR phone (mapping `phone_axes_20261025_v1`, `frame: webxr_local`) and moves the arm by [p0, p1, −p2] of the offset it is sent. A server whose z is up in its own frame would give [1, 1, 1] |

A wrong sign reverses that axis: for the SO-101's z, every vertical move would go the other way. To find them, send a
translation hold of +1 cm along each of the link's axes and read the change of `ee_pos`; the sign of the change is the
sign.

### `robot.wrist`

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `roll_sign` | 1 or -1 | server wrist roll = this × the phone's turn | 1, until a check on the live robot measures it |
| `tilt_sign` | 1 or -1 | server wrist flex = this × the phone's tilt | 1, likewise |

### `robot.gripper`

The jaw reading is the server's `gripper_deg`, in degrees for the SO-101.

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `open_deg` | deg | a jaw reading at or above this while opening counts as fully open | 97; the joint's limit is 100 |
| `empty_deg` | deg | at or below this when a close has ended with no contact, the jaws closed on nothing | 2; an empty close settled at 0.4 degrees on the S4 simulator, and a check on the device may set it later |
| `reclose_loosens_grip` | yes/no | a second close while gripping is refused until the jaws have opened, because a close starts from the measured angle and so loosens the grip | true; a robot that must squeeze harder to hold would set it false |

### `scene`

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `base_in_world_m` | m, [x, y, z] | where the robot base sits in the world frame; the server reports the arm in the base frame and objects in the world frame, and this brings objects into the base frame | [0, 0, 0.05], `ROBOT_BASE_POS_W` in the simulator's source |
| `base_axes_in_world` | axes, `x`, `y`, `z` | which world axis each axis of the robot base lies along: the quarter turn from the base to the world, applied with the shift above | `x`: `+x`, `y`: `+y`, `z`: `+z`: until this field, the app took world to base as a shift only, and the server model does too |
| `table_height_m` | m | the table surface's height over the base origin, along up (`robot.directions.up`), for the guide | 0.04: the simulator's `TABLE_TOP_Z_M` minus the base height. For a base whose up is the other way along its z, the table under it has a negative height |
| `workspace_min_m`, `workspace_max_m` | m, [x, y, z] | the box the server keeps the pinch point inside, for the guide and the "Blocked." rule; moved back by `offset_m` it is the box for the gripper link | the simulator clamps the point it reports to 8 cm either way of where it is after a reset (`WORKSPACE_RADIUS_M` around `initial_ee_pos_b`); this is that box moved by `offset_m`, so it holds while the wrist keeps its start pose. When the server reports a tool point, the guide moves the box by the measured offset instead |
| `target_size_m` | m | the task object's size across, to draw it true to size | 0.025, the cube |
| `goal_size_m` | m | the goal area's size across; the goal is the box the server judges success in | 0.05 |
| `grasp_tolerance_m` | m, [across, height] | how close the pinch point must be to the object's centre for a close to take hold of it; also the level word, the threshold for an approximate estimate, and the server model's grasp window | [0.006, 0.008]: in the simulator the window is a few millimetres either way |
| `on_target_window_m` | m, [across, height], or null | a wider window for the guide's "On target" and its cue, used when the guide's aids ask for it; never narrower than `grasp_tolerance_m` on either axis | null: the grasp tolerance is used |

### `scene.tool_offset`

When the server's state has no `tool_pos`, the app estimates where the jaws pinch as the reported gripper point plus
this offset. The estimate is exact where the offset was measured and grows less certain away from it.

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `offset_m` | m, [x, y, z] | from the point the server reports for the arm (the gripper link origin) to where the jaws pinch, robot base frame; holds while the wrist joints stay put | [0.007, -0.036, -0.088]: measured on the S4 simulator on 2026-11-11 with the jaws turned sideways, where the reported point sat at the cube's centre plus (−0.007, +0.036, +0.088). The front-to-back grasp it replaced lifted the cube 1 time in 16. The scene starts with the jaws sideways (wrist roll 90 degrees), so the offset holds from the start pose |
| `measured_at_m` | m, [x, y, z] | the reported point where the offset was measured (the cube's resting centre minus the offset) | [-0.002, -0.164, 0.1405] |
| `measured_flex_deg`, `measured_roll_deg` | deg | the wrist flex and roll at that measurement | 40.24 and 90 |
| `error_bound` | see below | how far the estimate may be off elsewhere; past half of `grasp_tolerance_m` across, the guide draws the pinch point as approximate | see below |

`error_bound` adds, in millimetres: so many per centimetre the reported point has moved from `measured_at_m` along
each base axis (`x_mm_per_cm` and `z_mm_per_cm` either way, `plus_y_mm_per_cm` toward the base and
`minus_y_mm_per_cm` away from it), plus so many per degree the wrist's flex and roll are from their measured values
(`flex_mm_per_deg`, `roll_mm_per_deg`). Without both wrist angles there is no bound and the estimate is approximate.
For the SO-101 the rates are 2.56, 11.12, 1.80, 8.43, 1.65 and 0.23. They were computed from the SO-101's
description and the server's solver, fitted never to underestimate within 6 cm across and 5 cm above the measured
place, and tested with tilt and turn up to 30 degrees. Below the measured height, where the fit has no places, the
rate for up is used; outside the fitted region the bound is already over 10 mm. The line at half the grasp
tolerance comes from hand trials, where a lift needed the jaws within about 1 cm, and the SO-101's tolerance is
6 mm.

### `response`

| Key | Unit | What it does | SO-101 |
|---|---|---|---|
| `directional_blocked_feedback` | yes/no | with the guide's additions on, "Blocked." is told by the direction asked, using the gripper-link box | true: the box has been checked against the workspace in the server's recordings |

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
| `go_to.settle_s` | s | how long fresh positions must stay within 2 mm, with the command at its leg's end, to count as settled | 0.6 |
| `go_to.time_factor`, `go_to.allowance_s` | factor, s | the deadline: the path's length over the speed, times the factor, plus the allowance | 1.5 and 3.0: at least 3 s, and room for one re-sent start on the longest path in the box (a test pins both) |
| `go_to.arm_data_timeout_s` | s | no measured position younger than this ends the move ("No arm data.") | 2.0: the listening connection reports about every 0.2 s, and an ordinary wireless network was measured holding messages back for up to 1.8 s |
| `go_to.start_grace_s` | s | no stall is judged from positions measured this soon after the start, or after the end of the hold's last pause, unless the arm has already moved 2 mm | 1.5: a start the server takes late, or an arm that lags at first, is not a stall |
| `guide` | yes/no each | which of the guide's additions run: `work_area_words`, `lowest_cue`, `shadow`, `direction_labels`, `wider_on_target` | all true |
| `explain.slow_link_let_go` | yes/no | a hold the operator holds that a slow link stops lets go with "Slow link."; a robot that gives `explain` also gives `guide` | true |
| `views.behind_top_above_table_m` | m | the fixed aiming views: how high above the table the rear view's top lies; at least the travel height | 0.09: keeps the heights used for positioning visible without spending space on the upper workspace |
| `views.max_retargeted_move_s` | s, or null | how long a retargeted move may run | 30 |

`ARCHITECTURE.md` ("The hands-free aids" and "The guide's additions") says how each aid uses these numbers.
