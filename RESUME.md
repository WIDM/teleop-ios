# Manual MVP handoff

Work stopped at 2026-11-19 16:47:27 Asia/Taipei. No owned test, replay, isolated simulator, preview, or tunnel remains running. Read [the build 28 handoff](docs/HANDOFF-BUILD28.md) before resuming.

App checkout: `/Users/luchienlin/Developer/teleop-ios-wt/aim-local`, branch `mvp-manual-2026-11-19`, HEAD `22cb87e`.
Server checkout: `/Users/luchienlin/Developer/teleop-ios-wt/server-mvp-local`, branch `mvp-height`, HEAD `9c7f803`.
Build 28 corrections remain uncommitted. Preserve them and the earlier experimental checkpoints. No new commit, push, or shared deployment occurred in this finish-and-handoff round.

Completed verification: 100 UI tests, 554 AssistOff unit tests, 33 focused App regressions, 864 core tests, and 137 Python tests passed. The safety checker passed 23 conditions with seven existing model-sync review warnings. Source review found no remaining concrete issues. Full logs and limitations are in the handoff.

The phone remains on build 27. Build 28 has not been signed, installed, or accepted on the phone. Scored phone acceptance remains 0/10. The next step is to verify stopped processes and preserved changes, integrate this candidate, then build/install and perform the frozen manual MVP acceptance. Do not add features.

Evidence: `/Users/luchienlin/teleop-ios-evidence/2026-11-19-build28-handoff/`.
