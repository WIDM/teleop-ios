# Figma parity (Mockup v2 iOS, 402x874)

Source: Figma `inLwADDDptRo8qIw34DRqP`, page Mockup v2 `121:134`, exports `figma-v2-ios/*.png` and `metadata.xml`.
Rule: where Figma and visual spec v1.14 disagree, the spec wins and the row says so.
Method: every non-hidden text node of each frame was compared with the string catalog (text, order). Layout, size and colour were compared by reading metadata and PNG against the SwiftUI source. No simulator render was available on this Linux box, so pixel diffs are not done; they are the Mac-only step in the verify-teleop-ios skill.

| Screen | Status | Notes |
|---|---|---|
| P1 Mode select | matched | text and order match |
| P2 Cloud check pass | matched | text matches |
| P3 Cloud check failed | matched | text matches |
| P4 Standby | gap | Extra demo buttons ("Simulate high latency", "On-screen controls") are not in Figma; kept so the prototype can reach P6 and S5. Layout not pixel-checked |
| P5 Connection details | matched | text matches; latency shown (allowed on P5) |
| P6 High latency | gap | same demo button as P4; amber banner text matches |
| P7 Keyboard open | matched | text matches; latency shown (allowed on P7) |
| T1 / T2 / T3 Tutorial | matched | "Step N of 3" is a format string |
| S1 Connect | gap | Figma has Recent rows with history icons; layout spacing not pixel-checked. Navigation per spec (Back/Connect -> P5, Disconnect -> S7) |
| S2 Permissions | matched | text matches |
| S3a Recording | gap | Hint text in Figma ("Hold vol+: move arm with the phone, release to stop / Press vol-: toggle gripper (after releasing vol+)") differs from the shared `control.volume_hint`; not changed, spec v1.14 wording not confirmed |
| S3b Record end | matched | Save / Discard (hold 1s) present |
| S3m Teleop with base | gap | Figma hint ("Hold vol+: move the arm / Press vol-: toggle gripper / Hold right edge: move the base") differs from P4 hint text used here |
| S4 E-stopped | matched | Rewritten this pass: pill, red card, "Hold 1s to release" white button with progress, caption, STOP solid red + yellow border. Release button is white as in Figma, not red (red only for STOP / E-stop) |
| S5 Screen fallback | matched | Rewritten: hold pad, gripper state, Record / Gripper / Settings row. The entry button on P4 is an extra demo affordance |
| S5a Recording fallback | matched | hold hint text now matches |
| S6 Settings | gap | Sliders now show gain / deadband (2 deg) / smoothing (0.3) tags and values and three log lines as in Figma. Deadband and smoothing are local view state, not persisted |
| S7 Errors | matched | text matches; amber/red use per spec |

Figma-vs-spec notes
- Figma frames mark "Volume key status" and "Keep awake" as hidden; they are not rendered, matching the app.
- Icons in Figma are Material Symbols; the app uses SF Symbols equivalents (no font bundled).
- Figma "Android ..." frames in the same file are out of scope for this repo.
