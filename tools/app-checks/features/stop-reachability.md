# STOP on every screen, and the way out

STOP can always be reached, a stop is always shown while it is latched, and there is always a way out of it.

## What the app does

- The operating screen's bottom band is STOP 急停 (`operating.stop`). Settings, Connect, the permissions screen and
  the tutorial pages pin a STOP band to their bottom edge (`stop`).
- STOP sends `estop` on both connections and the long buzz starts. The operating screen turns red and says
  STOPPED, with the cause; Settings shows a STOPPED band above everything. A STOP pressed with no link up has
  reached no robot: the screen then says Not connected, every press is answered "No link.", and the STOP goes out
  after the next welcome unless it was released first.
- Two ways out. Holding the top edge for 2 s resets the scene, which also releases the stop once the server confirms
  the reset. **Release, keep scene** (`stop.release`, a one-second hold) releases the stop and leaves the scene as
  it is; it is not offered when the server reports a recorder, which only a reset arms again.
- While the stop is latched Settings does not offer Replay tutorial, and practice cannot start or end.

## How to check it

- Safety checker: `tools/session-safety/scripts/check.sh` proves STOP from every state, the latch, the stop always
  shown (U1), a way out (U3) and STOP on every screen (U5) for the real session code.
- UI: `OperatingTouchTests` (the band, Release, keep scene, Settings while stopped, the band on Settings),
  `SettingsTests.testTheTutorialIsNotOfferedWhileStopped`, `PracticeTests.testPracticeIsRefusedWhileStoppedAndSaysWhy`.
- App: `LiveLinkTests` (`testStopSendsEstopAndNothingMovesAfter`, `testStopGoesOutOnBothConnections`,
  `testStopWithNoLinkIsNotPretendedAndIsSentAfterTheNextWelcome`), `ObserverTests.testStopReachesTheServerOnBothConnections`,
  `LocalOperatorTests` (STOP during a hold and both ways out against the local server), `OperatingLinkTests`
  (the reset that releases the stop).
- By hand, on a phone: the long buzz itself.
