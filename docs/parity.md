# Figma parity

The app's screens at version 1.0.0 are drawn in the Figma file (key `inLwADDDptRo8qIw34DRqP`) on two pages.
"Mockup v3" (page `312:2`) holds every screen as an iPhone frame and an Android frame, the operating screen also
as a Traditional Chinese frame, with the app's own pictures beside them. "Mockup v3 · reference" (page `312:3`)
holds the rules a frame cannot show: the states, the words, the cues, the timings and the strings.
[`figma/mockup-v3-frames.tsv`](figma/mockup-v3-frames.tsv) lists every frame with its node. Open a node by
replacing the colon in its id with a hyphen:
`https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=314-2`.

The pages were drawn from the app's code at 1.0.0, and the app's screens did not change in 1.0.1. Each of the 125
frames was checked against the layout rule: the zone edges (top band, control surface, gap, STOP band and the strip
under it) and the fill colours, measured on the frame. The 58 operating screen frames (iPhone and Chinese) were also
paired with the app's picture of the same state: on the picture the strip under the STOP band is measured, and for
the 40 with a guide the two views of the guide are measured against the frame's. Ten other iPhone frames were
looked at beside the nearest picture the tests take; the other 9 iPhone frames and the 48 Android frames have no
picture of the same state and were checked against the rule only. Text and icons are looked at, not measured. What
differs, and why:

- The frames use Noto Sans TC and the app uses the system font. Word widths differ a little, some lines break one
  word earlier, and a Chinese read-out box is wider than in the app.
- The caption over each guide view is 18 pt high in the frames against about 16.5 pt in the app, so the view from
  behind sits up to 2 pt lower and is up to 2.7 pt less high than in the app.
- Settings: the frames draw the section headers in title case where the app uses small capitals, with taller rows
  and inset cards, so the Settings frames hold fewer rows above the STOP band ("Show the guide" is cut at the band
  in the first Settings frame, whole in the app). The rows, their order and their words are the same.
- The status bar and the home indicator are not drawn, and the gear is drawn as an outline.
- The Android frames use 36 pt and 24 pt as stand-ins for the system's top and bottom insets.

`docs/figma-map.md` maps the file's older Mockup v2 frames, which show the screens the app had before 1.0.0.
