# Session safety checker

The checker proves the app's safety promises (the E-stop latch, when the arm may move, the gripper and wrist rules, the stop always shown, the E-stop buzz) by running the real `TeleopCore` code through every reachable state. Tests check the sequences someone wrote down. This check tries every action in every reachable state of the real `TeleopSession`, so it also finds orders of taps nobody thought of. There is no separate model to keep in sync: the checker imports `TeleopCore` and calls `perform`.

Run it whenever a change touches `TeleopSession`, `FakeTeleopState`, the navigator, a screen's `model.send` calls or the hold handling in `OperatingController`, and before calling such a change safe.

## Run it

From the repo root:

    tools/session-safety/scripts/check.sh

Needs `swift` and `python3`. Exit 0 means only known findings. Exit 1 means a new violation, a stale finding or drift. Exit 2 means `swift` is missing, which is a skip and not a pass.

After changing the checker or a guarded code path, also prove the check can still fail:

    tools/session-safety/scripts/mutants.py

It breaks a throwaway copy of `TeleopCore`, never the repo's files. Every line must say `CAUGHT`.

Last mutation run: 2026-11-13, on commit `605bf87`. 48 variants, 48 `CAUGHT`, none `MISSED`: 39 changes to
`TeleopCore`, of which 37 must make a property fail and 2 harmless ones must leave it passing; 1 change to
`ui-map.tsv`; 8 changes to the screens' source that `drift.py` must report.

## Read the result

Each property prints one status:

- `PASS`: no explored state breaks it.
- `KNOWN`: broken and listed in `known-findings.txt`. Report it, but it does not fail the run.
- `FAIL`: newly broken. The numbered steps are a shortest path of real actions from launch.
- `STALE`: listed as known but no longer broken. Remove its line from `known-findings.txt`.
- `DRIFT`: the checker's tables or `ui-map.tsv` no longer match the code.
- `REVIEW`: a covered file changed after the sync commit. See "Keep it in step".

Two groups of properties:

- **S properties, every action in every state.** The session rules on their own. They guard paths that do not go through today's screens, such as volume keys and a real link.
- **U properties, shipped screens only.** Only the actions each screen can send, from `ui-map.tsv`, plus, from any route, the end action of whatever is held: the release of that input, or the hold ending because the app left the active state (`AppModel.activeChanged`) or the camera stopped. Leaving the operating screen (its routes, `operatingScreen` in `main.swift`: P4, P5, P6, P7, S4) ends an arm hold, a gripper hold and a wrist hold, as `OperatingController` does for the keys, the touches and the pad; moving between them keeps those holds. `drift.py` holds `operatingScreen` to `RootView.operatingRoutes`, which `OperatingController.operatingRoutes` must be. A U failure is reachable by a user tapping today.

## Real bug or checker error

Replay the printed steps as `perform` calls in a `TeleopSessionTests` case.

- If the state in the test matches the `Found:` line, it is a real finding. For a U property, also confirm each step's button on that screen. Report it in the words of the steps.
- If a U path uses a button the screen does not have, `ui-map.tsv` is wrong. Fix the map from the screen source.
- If a promise itself is wrong because the product intent changed, get that decision from the project owner first. Then change the property and say so in the change description.

Never weaken a property, shrink the action list, or add to `known-findings.txt` just to get a pass. A finding is a report first: fixing the product code is a change of its own, with its own review.

## Promises checked

| Id | Promise | Harm if broken |
| --- | --- | --- |
| S1 | E-stop stays latched until `releaseStop`, or until the server confirms (`sceneResetDone`) a reset asked for in the stop state (`resetScene` while E-stopped and connected, which sets `resetClearsStop`) with no `stop` since (§6.5: a reset clears the stop and arms the recorder again). `resetClearsStop` is set only that way, only while E-stopped, and every `stop` clears it. | Commands accepted after STOP with no deliberate release, or a STOP pressed during a reset lost when the reset's answer arrives. |
| S2 | The arm starts only on `holdArmStart` while connected, not E-stopped, not latency-blocked. | Motion when the operator was told it cannot move. |
| S3 | The arm is never moving while E-stopped. | STOP does not stop the arm. |
| S4 | The gripper changes only on `gripperStart` while connected, not E-stopped, not blocked, arm not moving; or opens on `resetScene` while connected and not E-stopped (the scene reset puts objects back too); or takes the server's value when a live link comes up. | The gripper drops or grabs unexpectedly. |
| S5 | `holdArmEnd` always leaves the arm stopped. | Releasing the control does not stop the arm. |
| S6 | The arm is moving only while connected and not latency-blocked. | Motion reported or commanded over a lost or slow link. |
| S10, U7 | The gripper starts moving only on `gripperStart`, and is moving only while connected, not E-stopped, not latency-blocked and the arm is not moving. | The gripper squeezes or drops something when the operator was told it cannot move. |
| S11 | `gripperEnd` always leaves the gripper still. | Releasing the control does not stop the gripper. |
| S12, U8 | At most one of the arm hold, the gripper hold and the wrist hold is active. | The server runs one held control at a time; the phone would show two working while one is. |
| S13, U8 | A wrist hold (`wristMoving`) is active only while connected and not E-stopped. | The wrist keeps turning after STOP or over a lost link. |
| S15 | `wristEnd` always ends the wrist hold. | Releasing the input does not stop the wrist. |
| S16 | A wrist hold starts only on `wristStart` while connected, not E-stopped, not latency-blocked and the arm not moving. | The wrist turns when the operator was told it cannot. |
| S7 | `stop` from any state ends E-stopped on S4 with the arm stopped. | STOP fails in some state. |
| S8, U6 | The E-stop long buzz never starts while already playing. | `HapticsController.play` overwrites `loopPlayer` without stopping it, so an older buzz may survive release. |
| S9 | The long buzz plays exactly while E-stop is latched. | The haptic signal disagrees with the safety state. |
| U1 | While E-stop is latched, every screen the user can be on shows that it is stopped (the operating screen's routes P4, P5, P6, P7, S4, and Settings, S6, with its STOPPED band), or is a connection screen that leads straight back to one that does (S1: one of its own actions other than STOP opens such a screen, checked in every stopped state). `drift.py` holds the list to `RootView.operatingRoutes` and to Settings' `settings.stopped` band. One exception is on purpose (J7): a STOP that has reached no robot leaves the robot not stopped. That is a STOP pressed before the control connection's `welcome` with the listening connection not up, or one whose `estop` went out but the link was lost before a `state` the server wrote after reading it said stopped, or before the answer to a reset asked for from the stop, which clears the server's stop as soon as the server reads it. Until it goes out after the next welcome, no screen shows STOPPED: the operating screen says Connecting, Not connected or Link lost (also while Connect replaces a link that is up), Settings shows no band, Connect and Settings say the STOP is waiting when they refuse practice, and every press is answered with "No link." The checker does not model it (see "Left out"). | The stop is hidden and input is silently ignored. |
| U2 | S4 shows only while E-stop is latched. | The app claims an E-stop that is not active. |
| U3 | A latched E-stop can always be released. | The operator is stuck. |
| U4 | The arm is moving only while connected and not latency-blocked. | Same as S6, reachable by tapping. |
| U5 | Every teleop screen (all but S4) offers STOP. | No STOP on a teleop screen. |

U5 reads `ui-map.tsv`, and `drift.py` holds that table to each screen's own struct in the source. It does not check whether the button is visible or hittable, or where on the glass a touch reaches it; the UI tests cover that (`docs/TESTING.md`; `StopBandTests` for where each screen's band ends, and the input rules' `HomeSwipeTests` for a touch under it, which does nothing).

`drift.py` compares by struct, so it cannot tell routes apart when one struct draws several: p4, p5, p6, p7 and s4 (`OperatingScreen`, whose rows are the same), t1 to t3 (`TutorialScreen`). A control that lives only in one branch of those structs is read by hand. Recheck those rows when those structs change.

## Scope and assumptions

Verified: every reachable combination of the `FakeTeleopState` fields in `StateKey`, current route, `connectionOrigin` and whether the long buzz is playing, from every way the app opens: a fresh install on S2 and every later launch on P4, each on a real server or in practice (`launches` in `main.swift`). Practice starts and ends only from Connect and Settings (`toggleLiveLink`). Settings offers Replay tutorial only while the stop is not latched, as `SettingsScreen` does (`shippedActions` in `main.swift`): the tutorial pages do not show the stop, so offering it then would break U1. On shipped screens every launch is tried with a server that records and one that does not: with a recorder, `AppModel` refuses Release, keep scene while stopped on the real server (§6.5), so `shippedActions` does not offer `releaseStop` there and U3 must find the way out through the reset (`resetScene`, then `sceneResetDone`).

Bounds:

- The back stack is left out of state identity (see below).

Left out:

- Settings sliders (`setSmoothing`), `serverAddress` and `sensitivity`. No action changes them and no guard reads them.
- SwiftUI behavior, gesture timing and real haptics. The hold-end on leaving a screen is modelled from `OperatingController`, not run. The simulator has no haptic engine, so the effect of a second loop needs a real iPhone.
- What the screens draw. U1 counts the operating screen's routes and Settings as showing a latched stop. They show it from `AppModel.operating`, which says connecting, not connected or link lost instead while a pressed STOP is owed (`AppModel.pressedStop`, J7: the robot is not stopped), also while Connect replaces a link that is up. A pressed STOP is sent, confirmed or owed: owed when it was pressed before the control connection's `welcome` with the listening connection not up (`LiveLinkController.estop`), or when the link went before a `state` the server wrote after reading its `estop` said stopped (`LiveLinkController.estopConfirmed`), or before the answer to a reset asked for from the stop (`FakeTeleopState.resetClearsStop`), which puts a confirmed STOP back to sent. Settings draws its band only for the stopped state. The session's latch is the same either way, so the checker cannot tell the two apart; U1 states the exception, `AppModel.robotStopped` makes every press say "No link." then, also while Connect replaces a link that is up, and `OperatingLinkTests`, `LiveLinkTests` and `LinkStallTests` cover it.
- Which release ends which hold. A release ends a hold only while the control it belongs to still owns it (`FakeTeleopState.isHolding`; the input rules send a stop only for the hold they started). The checker offers the end actions in every state where something is held, which covers every release that does end a hold; a release that no longer owns the hold does nothing, and nothing here models that.
- The rule for a pressed STOP and for a welcome. A pressed STOP is, until it is released, confirmed by the server, owed, or sent and waiting; it is never dropped without the operator being told; and whenever the stop is latched at the control connection's `welcome`, `estop` goes out first. This lives in `AppModel` (`pressedStop`, `welcomed`), outside the session, and turns on the server's own `state`, which the checker does not model. The session's latch is the same in all three, so no property can state it. `LinkStallTests` (against the server model, with a stalled network path), `LiveLinkTests` and `OperatingLinkTests` cover it.
- The wire itself: sockets, timers, message contents and the server's 750 ms watchdog. The checker covers what the session does when the link reports `linkUp`, `linkLost`, `linkLatency`, a server E-stop (`stop`), a refused hold (`holdArmEnd`, `wristEnd`) or a confirmed scene reset (`sceneResetDone`) from any route on a live link. `sceneResetDone` is offered in every state, more often than a server can send it; S1 checks that the session lets only the answer to a reset asked for in the stop state release it. That the app sends `pose_stop` or `estop` whenever the session stops the arm is covered by `LiveLinkTests`, not here.
- Launch arguments for UI tests (`-startRoute`, `-startConnected`, `-startBlocked`, `-startConnectionLost`, `-firstRunDone`, `-operatingFixture`).

A pass covers the session rules under these limits, not the robot.

## Why the stack is left out

Comparing whole stacks would make the state space unbounded, because `navigate` keeps pushing. Leaving the stack out is sound here for two reasons, and a reviewer should recheck both if the covered code changes:

- `TeleopSession.perform` never reads the stack to change `state`, so S properties do not depend on it. S7 reads only the route that `stop` itself sets.
- On shipped screens, `back` is sent only from routes with a `BackStackRules.previous`, and then the new route is that rule's target whatever the stack holds. The checker stops with an error if `ui-map.tsv` ever sends `back` from a route without a rule.

## Change something on purpose

- New `TeleopAction`: add it to `actionTable` in `checker/Sources/SafetyCheck/main.swift`, and to `ui-map.tsv` if a screen sends it. `drift.py` fails until both are done.
- New stored field in `FakeTeleopState`: add it to `StateKey`, or to the "Not in key" comment if no action changes it. `drift.py` fails until you do.
- New or changed screen: update its row in `ui-map.tsv`.
- Fixed finding: remove its line from `known-findings.txt`. The check reports `STALE` until you do.
- New promise: add it to `properties`, add its check, add a breaking variant to `scripts/mutants.py`, and add it to the table above.

## Keep it in step

Sync commit: `e550233`

`check.sh` prints `REVIEW` for each covered file changed since that commit. Read the change, confirm that the checker, `ui-map.tsv` and the two stack arguments still describe the code, run `mutants.py`, and only then move the sync commit above to the commit you confirmed.

## Coverage

- `Packages/TeleopCore/Sources/TeleopCore/TeleopSession.swift`: `perform`, `acceptsControl`, `canControl`, `go`.
- `Packages/TeleopCore/Sources/TeleopCore/FakeTeleopState.swift`: connection, latency, E-stop, the reset that may release it, gripper and wrist state.
- `Packages/TeleopCore/Sources/TeleopCore/TeleopNavigator.swift`: `navigate`, `back`.
- `Packages/TeleopCore/Sources/TeleopCore/BackStackRules.swift`: `previous`, `controlRoutes`.
- `App/Sources/Operating/OperatingController.swift`: the input rules' and the pad's commands (`allowed_outside` in `drift.py`), STOP, the gear (`openSettings`) and the top band's reset (through `AppModel.runReset`) included. It ends every hold, with its stop, when the operating screen's routes go away, which `perform` in `main.swift` models, and when the app leaves the active state or the camera stops, which the end actions offered while a control is held cover.
- `App/Sources/Operating/Views/OperatingScreen.swift`: draws every operating route (`RootView.operatingRoutes`) from `model.operating`, the stopped state included. Its touch surface and pad reach `OperatingController`; Release, keep scene and the not-connected word send their own actions (`OWN_ACTIONS` in `drift.py`).
- `App/Sources/Screens`: every `model.send` call, mapped in `ui-map.tsv`; `RootView.operatingRoutes` and Settings' STOPPED band, which U1 counts on (`showsTheStop` in `main.swift`, held to the source by `drift.py`).
- `App/Sources/VolumeKeys`: `VolumeKeyModifier` hands the keys' raw events to the model and sends no actions itself; the operating screen, which attaches it, is credited with what the keys can do (`KEY_ACTIONS` in `drift.py`). `App/Sources/Pose` only reads the camera pose and sends no actions.
- `App/Sources/AppModel.swift`, `App/Sources/Link/LiveLinkController.swift`: the actions they send without a screen (`allowed_outside` in `drift.py`, `linkEvents` and `toggleLiveLink` in `main.swift`).
- `App/Sources/Haptics/HapticsController.swift`: basis for the S8 and U6 harm only.
