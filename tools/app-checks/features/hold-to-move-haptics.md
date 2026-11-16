# Holding a control to move, and the cues that answer

With the hands-free aids off (the master switch on the aids' page, opened from the Settings header), nothing moves
unless the operator holds a control, and it stops where it is on release: version 1.0.1's rule, unchanged. With them
on, lock and tap-to-go add moves that nobody holds, and each of those ends on the next key press or touch. The phone
answers every press, and every start and ending of a move nobody holds, with a cue the operator feels and hears, so
the screen is rarely needed.

## What the app does

- Three control modes, chosen in Settings: Screen turns (A), Key turns (B) and Buttons. In A and B, holding the
  upper volume key makes the arm follow the phone. In A the lower key closes the jaws, and a thumb on the screen
  opens them (slide up) or turns and tilts the wrist (turn the phone). In B the lower key and a turn of the phone
  turn the wrist, and the two halves of the screen close and open the jaws. Buttons mode draws a pad: arrows,
  Open and Close, Fine and Coarse.
- One thing at a time: after a press is taken, every other press does nothing until it is let go. A follow or a
  move nobody holds is ended by the next press or touch instead, and that input then does nothing else until it is
  let go.
- The cues: one tick when the arm starts to follow (go); one long buzz at a limit (end); two heavy thumps when the
  jaws hold something (grip); two long buzzes when the phone ends the hold for the operator, because it moved faster
  than 0.8 m/s or lost tracking (let go); three quick ticks for a press that did nothing, followed by why (no); a
  long rattle for the emergency stop (alarm); and, with a target on the guide, a tick then a soft buzz when the jaws
  are on it. The tutorial teaches them with the same words.
- Opening Settings, leaving the app or losing the camera ends every hold, with its stop sent to the server.
- With the aids on, in the two phone modes: lock (chosen on the aids' page) keeps the arm following the phone with
  no key held, after a press of the upper key or after a thumb slid up the glass while the key is held; a tap on the
  guide's view from above sends the jaws to that point. Latching plays a long buzz then a tick (latch) and "Locked
  on."; a move that arrives plays end and "Arrived."; an ending the operator caused plays end and "Stopped here.".
  A lost link, STOP or a robot that stopped itself, a success and a start that was refused are each told by their
  own cue alone: let go with the lost link's sound and "Link lost."; the alarm; the success's sound and words; the
  refusal. Any other ending plays let go, "Stopped here." and why, once, and the screen shows why for a second. A
  limit that a move to a tapped point meets is told by the move's ending alone. The tutorial's last page teaches the
  lock chosen and the tap.

## How to check it

- Core: the input rules (`Input/` tests, `InputArbiterPropertyTests` with 12,000 generated cases), the pad
  (`Buttons/` tests), the cues (`CueTableTests`, `FeedbackMonitorTests`, `OnTargetCueTests`), `HapticPatternTests`.
- Core, the aids: `OffEqualsVersion101Tests` (with the aids off, the input rules equal version 1.0.1's on the same
  12,000 cases), `AssistPropertyTests` (generated cases with the aids), `LockPressPressTests`, `LockHoldSlideTests`,
  `TapToGoTests`, `GoingTests`, `LooseEndingsTests`, `DriveCueTests`.
- App: `OperatingLinkTests` (what each mode streams), `LiveLinkTests.testMovingThePhoneTooFastEndsTheHold` and the
  tests around it, `LocalOperatorTests` (the wrist in each scheme, holds ended by Settings, the background and the
  camera), and `LocalPickAndPlaceTests`, which picks up and places the task object in every mode against the local
  server. With the aids: `LooseEndingHeardTests` (every ending of a follow or a move nobody holds heard once),
  `AssistControllerTests`, `AssistLinkTests` and `LocalAssistTests` (lock and taps through raw inputs against the
  local server). The AssistOff test plan runs every app test again with the aids off.
- UI: `OperatingScreenTests` draws every operating state, and `AssistOperatingScreenTests` the states of the aids;
  `-recordHaptics YES` puts the haptics the app asks for in a hidden element (`test.haptics`) a UI test can read.
- By hand, on a phone: XCUITest cannot press the volume keys or move the phone, and the iPhone simulator has no
  haptic engine, so how a cue feels, the keys themselves, the lock's slide and the tap are checked on a real iPhone.
