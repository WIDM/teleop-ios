# STOP on every screen, and the way out

STOP can always be reached, a stop is always shown while it is latched, and there is always a way out of it.

## What the app does

- The operating screen's bottom band is STOP 急停 (`operating.stop`). Settings, Connect, the permissions screen and
  the tutorial pages pin a STOP band to their bottom (`stop`). On every screen the band ends where the bottom safe
  area begins: a touch in the strip under it, where the system's swipe home begins, does not stop.
- STOP sends `estop` on both connections and the long buzz starts. The operating screen turns red and says
  STOPPED, with the cause; Settings shows a STOPPED band above everything. A STOP that has reached no server is
  owed: one pressed before the server's welcome, or one the server had not confirmed when the link was lost. The
  screen then shows the link's state (Not connected, Connecting or Link lost), the app says "No link. Not
  stopped.", every press is answered "No link.", and `estop` goes out first after the next welcome, with the
  alarm, unless the stop was released first. While the stop is latched, `estop` goes out first at every welcome
  of the control connection.
- Two ways out. Holding the top edge for 2 s resets the scene, which also releases the stop once the server confirms
  the reset. **Release, keep scene** (`stop.release`, a one-second hold) releases the stop and leaves the scene as
  it is; it is not offered when the server reports a recorder, which only a reset arms again.
- While the stop is latched Settings does not offer Replay tutorial, and practice cannot start or end.

## How to check it

- Safety checker: `tools/session-safety/scripts/check.sh` proves STOP from every state, the latch, the stop always
  shown (U1), a way out (U3) and STOP on every screen (U5) for the real session code.
- UI: `OperatingTouchTests` (the band, Release, keep scene, Settings while stopped, the band on Settings),
  `StopBandTests` (where the band ends on every screen, and a press or a swipe under it doing nothing),
  `SettingsTests.testTheTutorialIsNotOfferedWhileStopped`, `PracticeTests.testPracticeIsRefusedWhileStoppedAndSaysWhy`.
- Core: `HomeSwipeTests` (the swipes home of a person's phone log do nothing; a press on the band stops at
  touch-down).
- App: `LiveLinkTests` (`testStopSendsEstopAndNothingMovesAfter`, `testStopGoesOutOnBothConnections`,
  `testStopWithNoLinkIsNotPretendedAndIsSentAfterTheNextWelcome`), `LinkStallTests` (a STOP lost with the link
  before the server confirmed it is owed and goes out first after the next welcome; one pressed after the welcome
  has reached the server), `ObserverTests.testStopReachesTheServerOnBothConnections`,
  `LocalOperatorTests` (STOP during a hold and both ways out against the local server), `OperatingLinkTests`
  (the reset that releases the stop).
- By hand, on a phone: the long buzz itself.
