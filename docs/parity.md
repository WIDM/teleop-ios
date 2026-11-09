# Figma parity (Mockup v2 iOS, 402x874)

Source: Figma `inLwADDDptRo8qIw34DRqP`, page Mockup v2 `121:134`, exports `figma-v2-ios/*.png` and `metadata.xml`.
Rule: where Figma and visual spec v1.14 disagree, the spec wins and the row says so.
Method: every non-hidden text node of each frame was compared with the string catalog (text, order). Layout, size and colour were compared by reading metadata and PNG against the SwiftUI source. No simulator render was available on this Linux box, so pixel diffs are not done; they are the Mac-only step in the verify-teleop-ios skill.

| Screen | Status | Notes |
|---|---|---|
| P1 Mode select | matched | text and order match; no connection chip (Planner confirmed none in Figma) |
| P2 Cloud check pass | matched | text matches; no connection chip. "Simulate fail" is not in Figma, so it moved off the main layout: hold the title for 1 second |
| P3 Cloud check failed | matched | text matches; no connection chip |
| P4 Standby | matched (layout not pixel-checked) | Bottom row is three equal outline buttons (Record with empty circle, Reset, Settings) as in Figma; gripper card uses the slate fill. Demo shortcuts ("Simulate high latency", "On-screen controls") are removed from the main layout and live in a debug sheet opened by holding the mode pill for 1 second; they are not in Figma |
| P5 Connection details | matched | text matches; latency shown (allowed on P5) |
| P6 High latency | matched (layout not pixel-checked) | Same layout as P4; amber banner is full width under the gripper card as in Figma. "Simulate normal latency" is in the same debug sheet |
| P7 Keyboard open | matched | text matches; latency shown (allowed on P7) |
| T1 / T2 / T3 Tutorial | matched | "Step N of 3" is a format string. The dimmed P4 backdrop still draws its chip because Figma does (see T1 export); it is not tappable (`allowsHitTesting(false)`) and there is no chip on the tip card. T3 has Back and Start only |
| S1 Connect | matched (spacing not pixel-checked) | Recent rows (lab Wi-Fi, Personal hotspot) have history icons; status chip sits in a white card as in Figma. Navigation per spec (Back/Connect -> P5, Disconnect -> S7), and the hint now says so: "Returns to connection details after connecting" |
| S2 Permissions | matched | text matches |
| S3a Recording | matched | Dark "Recording" pill with dot, full-width gripper card, dot beside the timer, Figma hint text (`recording.volume_hint`: "Hold vol+: move arm with the phone, release to stop / Press vol−: toggle gripper (after releasing vol+)"). Bottom row is the dark Recording button plus Reset and Settings outlines. S5a keeps the fallback hint and is now a hold pad |
| S3b Record end | matched | Dark camera panel with gripper card, timer and hint box. Save and Discard (hold 1s) with a trash icon. Discard keeps the amber border because red is reserved for STOP, E-stop and S7; Figma shows red |
| S3m Teleop with base | matched | Standby pill, same dark base handle as P4, crosshair. Hint uses the Figma text (`base.volume_hint`: "Hold vol+: move the arm / Press vol−: toggle gripper / Hold right edge: move the base"). Bottom row is Record / Reset / Settings as in Figma. Figma has no Back, so tapping the handle releases it; Reset has no action yet, same as P4 |
| S4 E-stopped | matched | Rewritten this pass: pill, red card, "Hold 1s to release" white button with progress, caption, STOP solid red + yellow border. Release button is white as in Figma, not red (red only for STOP / E-stop) |
| S5 Screen fallback | matched | Hold pad now holds: press sends `holdArmStart`, release sends `holdArmEnd` (same path as vol+). The entry button is in the P4 debug sheet. Caption "Shown only when volume keys are unavailable" added |
| S5a Recording fallback | matched | Same pale hold pad as S5 with the timer on top and the "Stop recording" caption. Bottom row is Recording / Gripper / Settings as in Figma |
| S6 Settings | matched | Gain, deadband (2 deg) and smoothing (0.3) values live in `FakeTeleopState`, not in view state, so they survive leaving S6. In memory only (no disk persistence yet) |
| S7 Errors | matched | text matches, status chip reads "Disconnected"; amber/red use per spec |

"Matched" covers content and controls. A visual pass against the live Figma on 2026-11-09 still lists style differences: base handle, volume hint box, button fills, card borders and tints, and missing icons on S2, S4, S6, S7. Not yet checked against visual spec v1.14.

Behaviour rows (not screens)
- Blocked gripper toggle or arm hold (latency block, or gripper while the arm is held): `.commandBlocked`, 3 short (haptics-v1 H3, H8).
- E-stop release: long buzz cancelled, then 1 short (haptics-v1 H15).

Figma-vs-spec notes
- Figma frames mark "Volume key status" and "Keep awake" as hidden; they are not rendered, matching the app.
- Icons in Figma are Material Symbols; the app uses SF Symbols equivalents (no font bundled).
- Figma "Android ..." frames in the same file are out of scope for this repo.
