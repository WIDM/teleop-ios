# Figma parity

The app's screens at version 1.0.0 are drawn in the Figma file (key `inLwADDDptRo8qIw34DRqP`) on two pages.
"Mockup v3" (page `312:2`) holds every screen as an iPhone frame and an Android frame, the operating screen also
as a Traditional Chinese frame, with the app's own pictures beside them. "Mockup v3 · reference" (page `312:3`)
holds the rules a frame cannot show: the states, the words, the cues, the timings and the strings.
[`figma/mockup-v3-frames.tsv`](figma/mockup-v3-frames.tsv) lists every frame with its node. Open a node by
replacing the colon in its id with a hyphen:
`https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=314-2`.

The pages were drawn from the app's code at 1.0.0, and each of the 125 drawn frames was compared with the rule
and with the app's picture of that screen: the zone edges (top band, control surface, gap, STOP band and the
strip under it), the fill colours, and the two views of the guide. What differs, and why:

- The frames use Noto Sans TC and the app uses the system font. Word widths differ a little, some lines break one
  word earlier, and a Chinese read-out box is wider than in the app.
- The caption over each guide view is 18 pt high in the frames against about 16.5 pt in the app, so the view from
  behind sits up to 2 pt lower and is up to 2.7 pt less high than in the app.
- The status bar and the home indicator are not drawn, and the gear is drawn as an outline.
- The Android frames use 36 pt and 24 pt as stand-ins for the system's top and bottom insets.

## Not drawn yet: what version 1.1.0 adds

Version 1.1.0 adds the hands-free aids (`docs/ARCHITECTURE.md`, "The hands-free aids"). None of what they put on
the screen is drawn in the Figma file yet: the frames show the operating screen and the tutorial as they are with
the master switch off, and Settings without the Aids button in its header. The Settings form itself is unchanged.
Until frames are drawn, these screens and states differ from the file:

- Settings: the Aids button in the header, beside Done, and the aids' page it opens in the form's place, under the
  same header and above the same STOP band: the master switch with what Off turns off under it, a section headed
  Lock with one row per choice and where lock works under it, and the way back to the form in the title's place. No
  frame has them.
- The operating screen's two new states, "Locked on" and "Going", each with "Any key or touch stops it" and no
  scheme hint.
- The amber "Stopped here" with the reason on the line under it, shown for a second after a follow or a move ended
  for a reason the operator did not give, and the two new refusals of a tap ("Outside the work area", "No arm
  data").
- The guide's additions: the Forward and Up arrows on the two views, the shadow under the jaws, the dashed lowest
  line from behind with "lowest" on the height read-out, the line that names the side the commanded place is
  outside the work area on, and the white cross where a move to a tapped point is headed.
- The tutorial's last page: the line for the lock chosen, the line for the tap, and the sentence about the guide's
  arrows.
- The reference page: its states, words, cues and strings are those of 1.0.0, without the latch's pattern, the
  spoken endings and the new strings.

`docs/figma-map.md` maps the file's older Mockup v2 frames, which show the screens the app had before 1.0.0.
