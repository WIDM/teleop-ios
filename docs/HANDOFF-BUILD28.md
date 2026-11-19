# Build 28 handoff

Work stopped at **2026-11-19 16:47:27 Asia/Taipei**, before this handoff was finalized. All tests and replays owned by this work are finished. The dedicated iOS simulator, isolated Isaac Sim container, SSH forwarding, and preview tab are stopped. No new feature work remains active.

The phone remains on **1.1.1 (27)**. Candidate 28 passed the checks below but has not been signed, installed, or tested on the phone. Scored phone acceptance remains **0/10**. Keep the scope in [MVP-1.1.1.md](MVP-1.1.1.md) and the record in [MVP-PHONE-ACCEPTANCE.md](MVP-PHONE-ACCEPTANCE.md).

## Preserved decisions

Finish the manual MVP only. Preserve the existing experiments and checkpoints. Do not add voice functions, automatic alignment, tracking, new WebRTC features, or a UI redesign. Do not change server behavior beyond the existing candidate without direct owner approval. Do not weaken tests, widen safety limits, push, or deploy to a shared server.

This round ended after verification. Integration, a local checkpoint, device signing/install, and operator acceptance are for the next maintainer under the owner's existing decisions. No new commit was made during this round.

## Repositories and uncommitted changes

App checkout: `/Users/luchienlin/Developer/teleop-ios-wt/aim-local`.
Branch: `mvp-manual-2026-11-19`.
Last commit: `22cb87e72116093a87650a05499d0e811bf317f6`.

| File | Uncommitted change |
| --- | --- |
| `App/Sources/Link/LiveLinkController.swift` | Bind resync to the original start sequence and handle its final rejection immediately. |
| `Tests/TeleopTests/ManualToolControlTests.swift` | Four additional regressions for ACK ordering, stale/released holds, and the real entry guard. |
| `project.yml` | Build 27 to 28; version remains 1.1.1. Generated project was refreshed. |
| `CHANGELOG.md` | Build 28 refusal feedback entry. |
| `docs/MVP-PHONE-ACCEPTANCE.md` | Failed build 27 smoke and pending build 28 acceptance. |
| `RESUME.md` | New resumption entry point. |
| `docs/HANDOFF-BUILD28.md` | This new handoff. |

Local-only server checkout: `/Users/luchienlin/Developer/teleop-ios-wt/server-mvp-local`.
Branch: `mvp-height`. No remote is configured.
Last commit: `9c7f803e03fb822540dec792b806c15ee3424d63`.

| File | Uncommitted change |
| --- | --- |
| `s4_sim_pick_place.py` | Current-pose gravity support, pre-write freshness check, and stop rebasing before controller cleanup. |
| `tool_control.py` | Validate gravity torque, stiffness, shape, finite values, and the existing support bound. |
| `test_coordinated_integration.py` | Stop ordering and freshness coverage. |
| `test_tool_gravity_support.py` | New gravity support and stop regressions. |
| `LOCAL-CANDIDATE.md` | Current candidate status and evidence pointer. |

Nothing is staged in either checkout. `f11a` remains clean at `7b894f3`; `f11b` remains clean at `0d5508d`. They were not edited. A separate actor changed the main checkout to branch `ci/git-hygiene-check`, HEAD `aa6fb57`, during this work. It was observed clean and left untouched. Do not apply this handoff to that checkout.

For any authorized checkpoint, verify both author and committer are `Thomas Lu <luchienlin1994@gmail.com>`. The server repository currently resolves `user.name` to `luchienlin`; no commit was made with that identity here.

## What changed for the operator

Ordinary XYZ tool motion used a gravity support offset measured only at startup. The reproduced arm sagged as its pose changed and correctly exceeded the existing 1 mm corridor. The correction derives bounded support from current PhysX gravity compensation torque divided by actuator stiffness. Stops remove pending motion lead and retain validated support. Explicit coordinated height remains unchanged.

The App could receive the final movement rejection while resynchronizing and report no response later. It now associates that final rejection with the original start sequence and reports refusal immediately. Replies for released or older holds remain inert.

The 1 mm corridor, 100 ms state freshness, four-degree support bound, workspace limits, and joint limits remain enforced. No production source or test assertion was changed during the final test run.

## Completed verification

Evidence root: `/Users/luchienlin/teleop-ios-evidence/2026-11-19-build28-handoff/`.
The original working evidence remains at `/private/tmp/teleop-build27-user-trial/`.

| Check | Result | Evidence filename |
| --- | --- | --- |
| Complete UI target, Default plan | 100 passed, 0 failed | `ui-final.log`, `ui-final.xcresult` |
| Complete configured AssistOff plan | 554 passed, 0 failed | `assist-off-final.log`, `assist-off-final.xcresult` |
| Focused App control tests | 33 passed, 0 failed | `resync-review-guard-final.log`, matching `.xcresult` |
| TeleopCore | 864 passed, 0 failed | `core-final.log` |
| Server Python | 137 passed, 0 failed | `server-tests-final.log` |
| Safety checker | 23 PASS, 0 FAIL, 7 REVIEW warnings | `safety-final.log` |
| Swift formatting, strings, dead buttons, diff whitespace | Passed | `format-handoff.log`, `strings-handoff.log`, `buttons-handoff.log`, `app-diff-handoff.log` |
| Test console check | Passed | `console-handoff.log` |
| Source and original-log hashes | 227 App files, 4 server files, 4 original evidence files match | `handoff-source-verification.json` |

The final sequential Xcode job exited 0. AssistOff retains its pre-existing live-server exclusions for `OperatorLiveTests` and `ServerMotionTests`; no exclusions were added. The seven safety warnings concern files changed since checker sync commit `e64e8e7`. They remain visible and require model-to-source reconciliation; do not update the sync marker merely to hide them. The checker does not prove transport timing or physical motion.

A source reviewer independent of the implementation found no remaining concrete issues after follow-up. The proposed held-back-start defect was unreachable through both public tool entrypoints, which reject a start while the previous stop is unanswered. A new regression exercises those public guards without changing production code. Reviewer transcripts are preserved in the evidence archive. Earlier internal reviews are self-checks only.

### Isolated physical simulation

- App-faithful replay preserves command values, order, and within-hold timing, while waiting for the previous final stop ACK and fresh idle state. Baseline rejects at 1.016 mm cross-axis excursion. Candidate completes all four recorded holds without rejected ACKs, maximum excursion 0.130 mm.
- Final 40-request directional matrix contains 38 reached motions and two expected path-qualification refusals. Both refused requests recover with a fresh reverse. Maximum reached endpoint error is 0.11745 mm; maximum stopped observation drift is 0.14498 mm.
- XYZ and height emergency-stop, disconnect, late-packet, boundary, and reversal probes passed. The final height log audit covers 972 coordinated steps, maximum XY deviation 0.124308 mm and orientation deviation 0.056894 degrees.
- Final runtime/source hashes match. P1 was restored to a fresh idle state before shutdown.

See `HORIZONTAL-INVESTIGATION.md`, `causal-comparison.json`, `final-server-operator.audit.json`, and `final-runtime-source-match.json`. Read the investigation's old container/review status together with this final handoff; those status lines predate shutdown and final external review.

### Preserved failures and limits

The original build 27 phone smoke failed. The operator reported that gripper and explicit height responded, but ordinary XYZ movement frequently stopped. That is not a scored acceptance result.

The original red App regression failed with six assertions. The first full Default test job was interrupted for review triage after 552 unit and 49 UI passes; its exit code was 75. It is not a completed suite. Its artifacts remain separate from the final complete UI and AssistOff runs.

The first open-loop replay sent a new start before the previous stop completed and correctly received busy. The initial +Y 10 mm request failed the unchanged calibrated fixed-wrist path qualification; +Y 3/5 mm requests were feasible. This proves a limitation of the current planner/control policy, not that no alternative global arm posture could reach the target. Neither refusal is counted as reached, and neither justifies weakening protection.

The initial matrix expected only `ik=ok` after a valid refusal. Its failure is retained. The final matrix accepts `no_solution` only for independently qualified boundary cases and retains the 1 mm stopped-drift check. The final matrix was rerun after the last stop-race correction.

Camera preview video is illustrative, not a stop-latency measurement or a recording of phone interaction. No new UI layout or Figma work was performed. Device usability, physical phone controls, and scored pick/place acceptance remain unverified for build 28.

## Stopped environment

`handoff-stop-status.json` records shutdown evidence.

- Dedicated iOS simulator `C5EC2FCC-610D-4777-9F7C-3F0B9A323313` is Shutdown.
- Owned isolated container `teleop-b24-phone-test` on `luchienlin@140.115.54.62` stopped at 16:35:29 Asia/Taipei. It was created with `--rm`, so Docker removed the container automatically. The remote `/tmp/teleop-b24-phone-test/` directory and its data remain present.
- SSH master PID 39781 and its control socket forwarding are stopped. Former socket path was `/private/tmp/teleop-b24-install/tunnel.sock`.
- The owned preview tab is closed. No owned replay, Xcode test, review job, or background movement remains active.
- Shared `thomas-s4` and real hardware were not changed or stopped.

Pre-existing processes were left untouched: PID 43824 (`scripts/dev_tunnel.sh`), PID 43862 (`scripts/dev_relay.py`), and PID 78720 (the tunnel's SSH child forwarding port 8766). Their ages and parentage identify them as outside this round. Do not kill them as handoff cleanup. The current task board was unavailable on this host because its database was missing; no database or lock was recreated.

## Next actions

1. Verify the source hashes, Git status, and stopped processes against this handoff before writing. Preserve both worktrees and the failed/interrupted evidence. Resolve any mismatch before editing.
2. Reconcile the existing safety-checker model-sync warnings with the implementation. Review the candidate and create the authorized local checkpoint with the required identity. Keep push and shared deployment prohibited.
3. When resuming the owner's phone trial, recreate only the isolated environment from the preserved trial folder. Verify the final source/runtime hashes, normal P1 fixture, `coordinated_height` capability, fresh idle state, and camera preview. The old container no longer exists, so `docker start` alone cannot restore it. Do not run a joint-limit fixture for phone use.
4. Build/sign/install 1.1.1 (28) from `aim-local` and verify the installed version. Existing build 27 signed output is not a build 28 binary. Preserve any newer phone log before installation or relaunch.
5. Run the unscored phone smoke for ordinary front/back/left/right, explicit up/down, gripper, release, emergency stop, and reverse after refusal, including diagrams off. If it fails, preserve phone and isolated-server logs and diagnose within the frozen scope.
6. Only after that smoke passes, perform the scored acceptance in `MVP-PHONE-ACCEPTANCE.md`. Do not infer acceptance from automated replay. Any scope expansion requires the owner's decision.

## Re-run commands

Run these from `aim-local` when a later change requires revalidation. They are reference commands, not background jobs.

```sh
xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan Default -only-testing:TeleopUITests -destination 'platform=iOS Simulator,id=C5EC2FCC-610D-4777-9F7C-3F0B9A323313' -derivedDataPath /private/tmp/teleop-b25-manual CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan AssistOff -destination 'platform=iOS Simulator,id=C5EC2FCC-610D-4777-9F7C-3F0B9A323313' -derivedDataPath /private/tmp/teleop-b25-manual CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Teleop.xcodeproj -scheme Teleop -testPlan Default -only-testing:TeleopTests/ManualToolControlTests -destination 'platform=iOS Simulator,id=C5EC2FCC-610D-4777-9F7C-3F0B9A323313' -derivedDataPath /private/tmp/teleop-b25-manual CODE_SIGNING_ALLOWED=NO
swift test --package-path Packages/TeleopCore
bash tools/session-safety/scripts/check.sh
bash scripts/check-format.sh
python3 scripts/check-strings.py
python3 scripts/check-dead-buttons.py
python3 scripts/check-test-console.py <completed-xcodebuild-logs>
git diff --check
```

In `server-mvp-local`, run `/opt/anaconda3/bin/python3 -m unittest discover`. Isolated replay scripts and their logs are preserved in the evidence root. They contain original temporary paths; review the paths and target endpoint before replay. Do not run them against the shared server.
