# Status

What the app does now, what is known not to work, and what version 1 leaves out. How each part works is in
`docs/ARCHITECTURE.md`; how it is tested is in `docs/TESTING.md`.

## Works, and the default tests cover it

- The operating screen in all three control modes (screen turns, key turns, buttons), driven through the input
  rules. A scripted pick-and-place in each mode, through raw inputs only, passes against the server model in every
  default run.
- The link: two connections, holds, final acks, resets, the emergency stop and its two ways out, and a STOP pressed
  with no link. The server model it is tested against is checked against 18 recordings of the real server.
- The guide, in the phone modes on a real server: the arm from above and from behind, and the target and goal
  when the server reports them.
- The recorder: the REC line, Settings → Recording, and the spoken news of each take.
- A vibration, a sound or a spoken phrase for every feedback event (`CueTable`); every string in English and
  Traditional Chinese.
- Practice without a robot, marked on the operating screen, Connect, Settings and the tutorial.
- Every operating state drawn in both languages at two screen heights.

## Only a person can check

The tests cannot press the volume keys, move a real phone, touch the glass with a real thumb, or feel and hear the
cues. Those, and everything against the real simulator (the `Live` test plan), need a person with a phone.

## Known not to work

- After a lost link, the operating screen can show "Link lost" with "Reconnecting…", but the app does not reconnect
  by itself: the operator connects again from Settings → Server. On `p4_standby` and `p6_high_latency` a lost link
  opens Connect instead.
- A failed connection gets no specific reason. On Connect, a refused connection, a timeout and an unreadable
  address all read "Could not connect to that address."; the operating screen says only "Not connected".
- Practice shows no guide: the practice link has no arm to report.
- Nothing ends the holds when the phone overheats.
- Which way a turn or a tilt of the phone moves the wrist (`rollSign`, `tiltSign` in `RobotProfile`) is +1 for both,
  the value the profile keeps until a check on the live robot sets it.

## Left out of version 1

- Voice commands.
- Wrist buttons in buttons mode.
- Distribution through TestFlight, which is not set up yet (`docs/RELEASING.md` says what it needs).
