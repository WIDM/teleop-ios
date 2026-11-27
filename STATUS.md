# Status

What the app does, what is known not to work, and what version 1 leaves out. How each part works is in
`docs/ARCHITECTURE.md`; how it is tested is in `docs/TESTING.md`.

## Works, and the default tests cover it

- The operating screen in all three control modes (screen turns, key turns, buttons), driven through the input
  rules. A scripted pick-and-place in each mode, through raw inputs only, passes against the server model in every
  default run.
- The link: two connections, holds, final acks, resets, the emergency stop and its two ways out, and a STOP pressed
  before the server's welcome or lost with the link before the server confirmed it. The server model it is tested against is
  checked against 18 recordings of the real server.
- The guide, in the phone modes on a real server: the arm from above and from behind, and the target and goal
  when the server reports them. The jaw marker is the server's `tool_pos` when it sends one, otherwise an estimate
  drawn as a hollow ring where it may be off. The phone plays the on-target haptic once per approach.
- Fine controls, in the two phone modes: a button on the operating screen opens a pad of buttons that move the arm,
  open and close the gripper and turn the wrist, the arm at the fine speed (1 cm a second). Its Wrist page turns the
  wrist at 20 degrees a second and tilts it at 10, within the limits of the phone's wrist gesture, and the page
  switches only with no finger on a button. The panel opens only with the arm stopped and the server's word on that stop; with a follow or a move
  nobody holds running, the press stops it first and opens the panel once the stop is confirmed, or plays NO after
  1.5 s.
- Pad, panel and Up and Down holds follow the pinch point (the point between the jaws that is put on an object's
  centre) on a server that offers a calibrated one (one that lists it as a control point and names its calibration when
  the connection opens), with coordinated height for Up and Down on a server that offers that as well: the wrist moves
  with the arm so the jaws rise and fall on a vertical line with their direction kept. Once the server reports that the
  jaws closed on something, these holds go on the gripper link's path (the path of the origin of the arm's last link,
  which carries the jaws, as version 1.1.0 sent every hold), without coordinated height, until the jaws open, the scene
  is reset or the link is made again.
- When a server refuses or ends a manual arm hold, the phone says what to do for three kinds of reason (the arm touched
  something, a joint is at its limit, the arm cannot get there along its path); other reasons keep the general words.
- A simulator that pauses behind the server: no new move, release or reset is sent and the screen says to wait; after
  15 s it says the simulator is not responding; any stop already on stays on, and Reconnect sends a stop first when
  none is on, waits up to 1 s for the server to confirm it, and opens Connect; a stop not yet confirmed is sent again
  on the next connection.
- A server that keeps one phone per simulator: Connect and the stopped and link-lost states say why it refused or let
  go of this phone.
- The connection's name carries an install code, eight random hex digits made when the app first starts, so the
  server's log can tell one install's sessions from another's.
- On the first move of an episode with the jaws shut and nothing held, the operating screen shows a line to open the
  gripper first. It is shown only, for 4 s: nothing is spoken or felt, and the move is not held back.
- A record on the phone, `Documents/session.log`, kept across launches and set aside as
  `session.1.log` at 2 MB, with server addresses written as `<server>`; nothing in the app reads it.
- The recorder: the REC line, Settings → Recording, and the spoken news of each take.
- A vibration, a sound or a spoken phrase for every feedback event (`CueTable`); every string in English and
  Traditional Chinese.
- Practice without a robot, marked on the operating screen, Connect, Settings and the tutorial.
- Every operating state drawn in both languages at two screen heights.
- The hands-free aids, behind one master switch on the aids' page that the Aids button in the Settings header
  opens, on by default; with it off, lock, tap-to-go and the guide's additions are as in version 1.0.1, a hold that a
  slow link stops is shown on the screen only, and the operating screen in a phone mode says "Hands-free aids off:
  taps do nothing". The app's unit tests pass unedited in a test plan that turns it off. The Settings form itself is
  as in version 1.0.1.
  - Lock, chosen on the same page, in the two phone modes: a press of vol+, or a thumb slid up the glass while vol+ is
    held, keeps the arm following the phone with no key held, until any key or touch, STOP, the robot profile's time
    limit, lost tracking or a phone no longer held upright stops it.
  - Tap-to-go: a tap on the guide's view from above sends the jaws there, up or down to a travel height first and
    then level. A tap on the view from behind sets the left-right place and the height and keeps the front-back one;
    inside the narrow column around the jaws it changes only the height. A touch on a view while a move runs holds the
    move, and lifting it promptly aims the move at the new point. A move ends when the arm arrives, when it settles
    short, when no fresh arm position comes, at its time limit (worked out from the path's length and the move's speed, allowing for a slower start, pauses and a
    new aim point, and with the SO-101 profile 30 s from its start at most), or on any key, on STOP,
    on a touch outside the views, or on a contact that is long or slides. A limit the move meets, such as the edge of
    the work area or something in its path, is told by its ending alone. A tap made before the server has answered the
    last stop the phone sent is refused with "Wait." and dropped, until an arm position from after that answer has come
    (or, when the answer is lost, until the first arm position after the link's own 0.8 s wait for it), and no tap is
    taken while the camera is stopped.
  - With a server that reports where the jaws pinch (`tool_pos`), a move follows that point, which turns with the
    arm's posture. For the operator: moves are slower, more so near the robot's base; a move whose jaws leave its
    path, or whose server stops reporting that point, ends "Stopped here. Short of the target."; and a tap on a place
    the jaws cannot reach at the travel height is not refused beforehand: its move ends the same way, near the edge
    of reach. With a server that reports no such point, a move is as before.
  - Every start and ending of a follow or a move nobody holds is told once, and the screen shows "Locked on" or
    "Going", and afterwards why it ended when the operator did not end it and it did not arrive. The words of an
    ending are never dropped; a "Locked on." not yet said when the alarm, "Link lost." or any ending of that follow comes
    is dropped, since the follow is over and the latch was felt.
  - The guide's additions: the commanded place leaving the work area is felt, said with its side and shown under
    the guide; an arm that cannot go lower says "Can't go lower." and the guide marks the lowest height; a shadow
    under the jaws; Forward and Up arrows on the two views.
  - A hold the operator keeps down that a slow link stops lets go with a double long buzz and says "Slow link.".

## Only a person can check

The tests cannot press the volume keys, move a real phone, touch the glass with a real thumb, or feel and hear the
cues. Those, and everything against the real server in Isaac Sim (the `Live` test plan), need a person with a
phone.

Measured with a person's hand on an iPhone 17: the phone reports how wide a touch is in steps of about 12 pt. In its
first 100 ms a thumb pad pressed, held or slid on the glass was at most 85 pt wide, a tap 24 to 61 pt, and the base
of the hand pressed on the glass 97 pt or more. The rule that ignores a palm everywhere but on the STOP band
(`InputConstants.palmRadiusPt`, 91 pt) sits between them. On the same phone every swipe home began in the lowest
34 pt, under the home indicator. The STOP band ends above that strip and a touch that begins in the strip does
nothing, so none of those swipes stops the robot. One press aimed at scheme B's lower left corner landed on the STOP
band; scheme B's words sit halfway up the screen, away from the band. Not yet checked on a phone: other hands, the
12 pt edge rule, a swipe home that begins above the home indicator, and how often a press on scheme B's halves lands
on the STOP band with the words halfway up.

The hands-free aids are not yet checked on a phone with a person's hand: how the latch's pattern feels beside GO
and END; the lock's slide (`InputConstants.slideUnderWayMm`) and the tap's limits (`tapMaxS`, `tapSlopMm`), which
no hand traces have set yet; whether the robot profile's numbers for the lock and for a move to a tapped point
(`RobotProfile.assist`) suit a real arm's lag; and the lowest rule's numbers (`FeedbackMonitor`). How a move follows
the reported pinch point has been run only against the server model, in the tests: not yet in Isaac Sim, and not by
hand.

The Live test plan has no test of the Wrist page or of coordinated height. The app tests that cover them use scripted
fake transports, and the Wrist page's UI tests also use the local server model.

## Known not to work

- The app does not reconnect by itself after a lost link: the operating screen shows "Link lost" with "Connect again
  in Settings", and the operator connects again from Settings → Server. On `p4_standby` and `p6_high_latency` a lost
  link opens Connect instead.
- A failed connection gets no specific reason, except from a server that keeps one phone per simulator and says why
  it refused or let go of this phone. On Connect, a refused connection, a timeout and an unreadable address all read
  "Could not connect to that address."; the operating screen says only "Not connected".
- Practice shows no guide: the practice link has no arm to report.
- A touch 91 pt wide or wider when it lands or in its first 100 ms, about 30 mm across, is taken for a palm and
  ignored without a sound: a thumb laid flat on the glass can be that wide. The STOP band is the exception: any
  touch there stops the robot.
- A press on the strip below the STOP band, where the home indicator sits, does not stop the robot.
- A whole press, move and release that falls inside one stall of the network plays the start's tick, moves the arm
  a few millimetres at most (the held messages reach the server together), and ends without a word: a start gets
  no acknowledgement of its own.
- For a moment after a stall the screen can say Slow link, because the probes sent during the stall come back
  late, and a press in that moment is refused with "Slow link.".
- A server that has gone silent is noticed after 3 s, but only after tens of seconds while the app's own main
  thread stalls on every tick: each late tick counts as the app not running, not as silence.
- Nothing ends the holds when the phone overheats.
- Which way a turn or a tilt of the phone moves the wrist (`rollSign`, `tiltSign` in `RobotProfile`) is +1 for both,
  the value the profile keeps until a check on the live robot sets it.
- An ending of a follow that comes within about 0.36 s of its latch has no vibration of its own, because the
  latch's pattern is still playing; its words still play.
- The ending heard when the app leaves the foreground during a follow or a move ("Stopped here. You left the app.")
  is raised as the app goes, and may not be heard.
- When the server goes quiet during a move to a tapped point, the operator hears "Stopped here. No arm data." and
  about a second later "Link lost.": two cues for one cause.
- "Can't go lower." stays quiet on a link whose states arrive more than 0.4 s apart (`FeedbackMonitor.arrivalGapMs`),
  and a first stall on top of an object leaves the remembered lowest height there until a stall lower down.
- The robot profile gives no wider on-target window yet (`RobotProfile.onTargetWindow` is nil), so "On target" uses
  the grasp tolerance with the aids on as well.
- A turn or a tilt of the wrist, by the Wrist page or by the phone, moves the pinch point too: the jaws' position has to
  be checked after it.
- "Touching something. Open the gripper or lift." may not mean the arm touched anything. The server gives seven
  reasons for an arm pushed, turned or twisted off its path, and the phone says this for all of them; touching
  something is the likeliest cause, not a certain one.
- A simulator that is not responding is not brought back by the phone; the server has to be restarted. Reconnect sends
  a stop first when none is on, waits up to 1 s for the server to confirm it, then opens Connect; a stop not yet
  confirmed is sent again on the next connection.
- From a server that sends no timing in its `state`, the phone learns that the simulator has paused only from the
  server's own `sim_stalled`. The four signs the phone judges itself (three states in a row that were each over 2 s old
  when the server sent them and older each time, moves refused "busy" for over 3 s, a stop with no final answer for
  3 s, and a release refused `estop_not_frozen` while the newest state is over 2 s old, a move was refused "busy"
  since the last stop answer, or a stop has waited over 0.8 s for its answer) count only after a state with its timing
  has come on that connection.
- The install code is kept in the app's settings, so a phone restored from another phone's backup has that phone's
  code, and the server's log cannot tell the two apart.

## Left out of version 1

- Voice commands. Choosing the movement axis by voice is an unfinished experiment, shown only when the app is
  launched with `-voiceEntry YES`.
- Wrist buttons in buttons mode. They exist only on the Wrist page of Fine controls in the phone modes.
- Distribution through TestFlight is handled in App Store Connect, outside the repository. The repository has what an
  upload needs (the privacy manifest `App/PrivacyInfo.xcprivacy`, which declares the install code as a device
  identifier used for analytics, linked to the install and not used for tracking, and the encryption declaration in
  `project.yml`); the steps only the Apple account holder can take are in `docs/RELEASING.md`.
