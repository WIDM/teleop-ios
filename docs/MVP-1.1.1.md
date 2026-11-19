# Manual teleoperation MVP 1.1.1

Status: scope approved on 2026-11-19; phone acceptance is pending.

## Goal

Complete move, height adjustment, grasp, and placement reliably with the phone. Operation must remain available when assistance diagrams are off. Looking at the phone is permitted for this MVP.

## Frozen scope

- Existing buttons and IMU/ARKit movement, plus existing precision adjustment for final alignment.
- Explicit up/down controls move the calibrated pinch point vertically with coordinated wrist flex and unchanged gripper world orientation.
- Existing open/close controls and hold-to-move, release-to-stop interaction.
- Release, emergency stop, disconnection, workspace and joint-limit handling; a fresh opposite-direction hold can recover from a recoverable limit.
- Accurate distinction between available, moving, blocked, and disconnected states; no expired speech/state prompts.
- Controls work without assistance diagrams and do not depend on a particular target object. A separate move-to-position task uses the same controls.

Height acceptance uses the existing up/down buttons, including the precision panel. General phone XYZ input retains its current control policy. An already selected experimental phone height axis may use the same explicit mode; no new selector or speech work is included.

## Explicitly deferred

No new voice actions, voice-axis recognition improvements, automatic target alignment, target tracking, completely eyes-free operation, multi-view camera work, or additional interface redesign. Preserve existing experiments and their tests. Do not enable unfinished experiments as a release feature.

Only defects that prevent the acceptance criteria below belong to this version. Record other improvements for a later version without implementing them. Acceptance criteria and trial positions must not be changed after a scored run begins to make a failure pass.

## Acceptance

### Pick and place

Use one fixed object and three named reachable starting positions, P1/P2/P3, frozen with simulator coordinates before scored testing. Use the same placement region and starting arm pose. Run ten scored attempts in this fixed order:

| Trial | Position | Assistance diagrams |
| --- | --- | --- |
| 1 | P1 | On |
| 2 | P2 | Off |
| 3 | P3 | On |
| 4 | P1 | Off |
| 5 | P2 | On |
| 6 | P3 | Off |
| 7 | P1 | On |
| 8 | P2 | Off |
| 9 | P3 | On |
| 10 | P1 | Off |

Pass: at least eight successes; each successful attempt finishes within two minutes. A success requires grasping, lifting clear of the support, placing in the predefined region and releasing the object stably. Record every attempt, including failures. Starting/resetting the trial scene is allowed between attempts; App restart or engineering intervention during an attempt makes that attempt a failure. Timing begins at the first movement command and ends at stable placement/release. At least five attempts use diagrams off as specified above.

### Safety and recovery

Ten trials each for release, emergency stop, disconnection, and blocked-direction reversal. Each trial must stop accepting the old movement command. Reconnection or delayed packets must not resume old motion. A deliberate fresh opposite-direction action must recover after a recoverable geometric limit; emergency-stop reset remains explicit. Any unsafe continuation fails the safety gate. Record command, acknowledgement and measured-state timing separately; do not infer physical stopping from an acknowledgement alone.

Keep existing freshness, timeout, workspace, joint, corridor and orientation thresholds. Never loosen assertions, skip failing tests or reset the measurement reference to hide drift.

### Reusability

Complete the separate move-to-position task with the same controls and assistance diagrams off. No object-specific UI or automatic grasp alignment is required.

### Engineering delivery

Relevant unit/integration/UI tests, formatter/static checks and safety checks pass. Preserve failures and their reproductions. Obtain independent review. Identify the exact App build, source commit, simulator candidate and trial records. Phone acceptance is complete only after the operator trials and log review; simulated wire replay alone is not phone acceptance.

## Delivery boundaries

1. Local checkpoint of existing modifications and unfinished experiments. A checkpoint is a recovery snapshot, not a release approval.
2. Integrate explicit per-hold height control and required state/stop fixes; validate locally and in the isolated simulator.
3. Install the test build, perform the frozen phone trials, inspect phone/server records, and prepare the verified local delivery.

Local commits are authorized. No push, shared/production deployment or merge is authorized. Temporary isolated simulation and test-build installation remain part of validation. No real robot actuation is authorized.
