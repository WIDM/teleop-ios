# Holding a control to move, and the cues that answer

Nothing moves unless the operator holds a control, and it stops where it is on release. The phone answers every
press with a cue the operator feels and hears, so the screen is rarely needed.

## What the app does

- Three control modes, chosen in Settings: Screen turns (A), Key turns (B) and Buttons. In A and B, holding the
  upper volume key makes the arm follow the phone. In A the lower key closes the jaws, and a thumb on the screen
  opens them (slide up) or turns and tilts the wrist (turn the phone). In B the lower key and a turn of the phone
  turn the wrist, and the two halves of the screen close and open the jaws. Buttons mode draws a pad: arrows,
  Open and Close, Fine and Coarse.
- One thing at a time: after a press is taken, every other press does nothing until it is let go.
- The cues: one tick when the arm starts to follow (go); one long buzz at a limit (end); two heavy thumps when the
  jaws hold something (grip); two long buzzes when the phone ends the hold for the operator, because it moved faster
  than 0.8 m/s or lost tracking (let go); three quick ticks for a press that did nothing, followed by why (no); a
  long rattle for the emergency stop (alarm); and, with a target on the guide, a tick then a soft buzz when the jaws
  are on it. The tutorial teaches them with the same words.
- Opening Settings, leaving the app or losing the camera ends every hold, with its stop sent to the server.

## How to check it

- Core: the input rules (`Input/` tests, `InputArbiterPropertyTests` with 12,000 generated cases), the pad
  (`Buttons/` tests), the cues (`CueTableTests`, `FeedbackMonitorTests`, `OnTargetCueTests`), `HapticPatternTests`.
- App: `OperatingLinkTests` (what each mode streams), `LiveLinkTests.testMovingThePhoneTooFastEndsTheHold` and the
  tests around it, `LocalOperatorTests` (the wrist in each scheme, holds ended by Settings, the background and the
  camera), and `LocalPickAndPlaceTests`, which picks up and places the task object in every mode against the local
  server.
- UI: `OperatingScreenTests` draws every operating state; `-recordHaptics YES` puts the haptics the app asks for in
  a hidden element (`test.haptics`) a UI test can read.
- By hand, on a phone: XCUITest cannot press the volume keys or move the phone, and the iPhone simulator has no
  haptic engine, so how a cue feels and the keys themselves are checked on a real iPhone.
