# Phone acceptance record

Status: build 27 unscored smoke test failed; scored acceptance has not started. Candidate 28 passed automated verification but is not signed, installed, or phone-tested. The phone remains on build 27. Do not mark this complete from unit tests or simulator wire replay.

The frozen criteria and position order are in `MVP-1.1.1.md`. Checkpoint commits are App `05c8e3e`, earlier worktree `7b894f3`, and isolated server `71aee47`. The validated isolated server integration is `9c7f803`.

## Before scored trials

- Verify installed build and isolated server source, advertised height capability, camera tracking and fresh arm data.
- Keep voice-action prototype and automatic/latched assistance off. No new voice functions are tested.
- Use existing phone movement for coarse positioning and existing precision up/down controls for height.
- Verify one release and emergency-stop smoke check before proceeding to manipulation trials.
- Record simulator world position and robot-base position separately.

## Operator sequence

1. Wait for the trial scene and confirm the specified diagram setting.
2. Open the jaws; position above the cube with phone movement or buttons.
3. Use precision up/down for final height, then close the jaws.
4. Lift, move to the green placement region, lower, and open the jaws.
5. Release all controls and report the result. Preserve a failed or timed-out attempt before resetting.

The operator must physically perform these actions. Automated wire replay cannot establish phone usability or grasp success. Source/build metadata and both phone/server logs are required for acceptance.

## Results

Pick-and-place: 0/10 recorded. Safety categories: 0/10 phone trials recorded in each category. Reusability demonstration: pending. No success rate or completion claim is available yet.

## Build 27 smoke test

On 2026-11-19 the operator confirmed that gripper and explicit up/down controls responded, but ordinary front/back/left/right movement frequently stopped with refusal or blocked feedback. The captured interval contains 15 ordinary-tool holds rejected with `tool_measured_corridor`; three coordinated-height holds ended normally. These observations do not complete the vertical, release or recovery acceptance criteria. One rejection during resynchronization was incorrectly reported as no response. Preserve this failed smoke test and correct the underlying motion and feedback defects before starting scored trials.
