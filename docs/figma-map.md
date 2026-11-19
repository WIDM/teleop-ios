# Mockup v2: iOS acceptance map

Target: `WIDM/teleop-ios`. Figma file key: `inLwADDDptRo8qIw34DRqP`. Page: `121:134` (Mockup v2). iOS frame size: **402 × 874 pt**. Flow start: **P1, `121:135`**.

Open a node by replacing the colon in its ID with a hyphen: [P1](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-135). Screen links below use this format.

Sources: [prototype links](ios-links.json), [layer metadata](mockup-v2-metadata.xml), [visual rules through v1.14](../design/visual-spec-v1.md), and [event feedback](../design/haptics-v1.md). Only the 20 top-level 402 × 874 frames are mapped; 412-wide Android frames are excluded. Metadata gives layer names and geometry, not rendered colors or actual string values. Reference text below comes from visible text-layer names; hidden layers are excluded. Sample addresses, timers, and readings are screenshot fixtures, not fixed runtime values.

## Global rules

### Navigation

- [ ] Every visible Connection chip opens P5, including chips on S1, S4, and S7.
- [ ] P5 Change server opens S1; S1 Connect and Back open P5; S1 Disconnect opens S7.
- [ ] S7 Reconnect and Back to connect both open S1.
- [ ] Every screen after connection (all screens except P1, P2, P3 and S4) exposes an E-stop button: tap E-stop button -> S4. P1–P3 run before any robot connection and have no STOP by design.
- [ ] S4 Release (hold 1s) -> P4 only after a full 1-second hold; early release cancels.

Navigation lists retain every distinct exported element/destination pair. Identical duplicates are collapsed; different labels on the same control are retained as aliases. `tap X -> Y` identifies prototype behavior, not authorization to replace a required hold with a tap. Unresolved source conflicts are explicitly noted and cannot be marked passed by guessing a route.

### Appearance and copy

- [ ] Red `#DC2626` appears only on STOP, S4 emergency-stop state, or S7 error/disconnection state; recording, failed preflight checks, and latency warnings are not red.
- [ ] STOP is solid `#DC2626`, white text, with a `#FACC15` border; its button remains 72 pt high and spans the available content width, visible above sheets and keyboards.
- [ ] Primary actions use `#2563EB`; normal connection and Pass use `#16A34A`; warnings and Fail use `#D97706` (Fail has white text).
- [ ] Backgrounds use `#F8FAFC`, cards `#FFFFFF`, primary text `#0F172A`, and secondary/disabled text `#475569`; the camera area uses the specified dark-blue treatment.
- [ ] Inactive Record uses a blue outline and white fill. Active Record uses solid `#0F172A`, white "Recording 0:12" in the reference state, a blinking white dot, and a 2 px white border; the status bar does not turn red.
- [ ] The idle Base sidebar uses `#0F172A` at 80% opacity, white 17 pt text, and the existing 72 pt width/hit area; it remains solid-styled rather than glass.
- [ ] iOS text uses SF Pro, monospaced numeric telemetry, body 16 pt, labels 14 pt, and no text below 12 pt; glass-layer text is solid dark text at least 14 pt, with a scrim when needed for contrast.
- [ ] Touch targets are at least 48 pt; standard spacing follows an 8 pt grid, corner radius 12 pt, and side margins 16 pt. Metadata geometry exceptions are reported against this rule rather than silently treated as compliant.
- [ ] Icons render as Material Symbols Rounded outlines, not literal icon identifier strings; no emoji appear.
- [ ] UI copy is English, with no screen codes, H-codes, node IDs, filenames, or implementation identifiers. Buttons use title case except STOP; labels fit without reducing the required font size.
- [ ] Normal status shows a dot and Connected, without latency numbers, always-on status, or volume-key-ready status; latency numbers appear in P5. Developer telemetry is hidden in normal mode.
- [ ] In cloud mode, the blue Cloud mode banner remains visible, including during emergency stop; it is absent in on-site mode.

Current v1.14 visual rules override older red recording-dot and red Discard descriptions. Haptic/audio events still follow the haptics source. No left/right-arm switch is present in these 20 frames, so H7/H8 are not assigned; H16 is outside the requested scope.

### Feedback verification

Use a UI-test-instrumented feedback sink to assert vibration/audio requests; a simulator screenshot cannot prove physical vibration. Short pulses are provisionally 60 ms with 120 ms gaps; long pulses provisionally repeat 400 ms on / 200 ms off. H12–H15 and the latency/speed thresholds remain provisional in the source. Apply feedback only when the named event occurs, not merely on navigating to a screen. H1/H2 refer to gripper transitions, including the fallback Gripper control; they do not require working volume keys in fallback mode.

## P1 Mode select

Node: [`121:135`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-135). Purpose: Choose on-site or cloud operation.

**Layout checks**

- [ ] The reference view contains "Choose a mode"; "Pick once per launch. You can change it in Settings."; "On-site mode"; "● Selected"; "Phone and robot share the lab Wi-Fi."; "Cloud mode"; "Connect remotely. Two safety checks must pass first: robot heartbeat and physical e-stop."; "Next".

**Navigation checks**

- [ ] tap On-site mode button -> P2.
- [ ] tap Cloud mode button -> P3.
- [ ] tap Next button -> P2.

**Haptics checks**

- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.

**State/color checks**

- [ ] The primary Next action is blue; the initial On-site mode selection is visible.

Note: pre-connection screen; no STOP by design.

## P2 Cloud checks pass

Node: [`121:153`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-153). Purpose: Show passing cloud safety checks.

**Layout checks**

- [ ] The reference view contains "Cloud safety check"; "Both checks must pass before standby."; "Robot heartbeat"; "Received just now"; "Pass"; "Physical e-stop"; "Connected and not pressed"; "Enter standby"; "Back".

**Navigation checks**

- [ ] tap Enter standby button -> S2.
- [ ] tap Back button -> P1.

**Haptics checks**

- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.

**State/color checks**

- [ ] Both Pass results are green; Enter standby is blue.

Note: pre-connection screen; no STOP by design.

## P3 Cloud check failed

Node: [`121:175`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-175). Purpose: Explain the failed cloud safety check.

**Layout checks**

- [ ] The reference view contains "Cloud safety check"; "One check failed. Standby is locked."; "Robot heartbeat"; "No heartbeat from the robot"; "Fail"; "Physical e-stop"; "Connected and not pressed"; "Pass"; "Check the robot power and network, or ask someone on site to check the e-stop."; "Recheck"; "Use on-site mode".

**Navigation checks**

- [ ] tap Recheck button -> P2.
- [ ] tap Use on-site mode button -> P1.

**Haptics checks**

- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.
- [ ] H14: a failed cloud safety check emits no vibration and 1 notification tone.

**State/color checks**

- [ ] Fail is amber with white text; Pass is green; Recheck is blue; no Connected status is shown and standby remains locked.

Note: pre-connection screen; no STOP by design.

## S1 Connect

Node: [`121:1126`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-1126). Purpose: Enter a server address and connect or disconnect.

**Layout checks**

- [ ] The reference view contains "Not connected"; "Teleop"; "Connect to the robot"; "Server address"; "192.168.x.x:8765"; "Connect"; "Disconnect"; "Recent"; "lab Wi-Fi"; "Personal hotspot"; "Back"; "STOP".

**Navigation checks**

- [ ] tap Connection chip -> P5.
- [ ] tap Connect -> P5.
- [ ] tap Disconnect -> S7.
- [ ] tap Back -> P5.
- [ ] tap E-stop button -> S4.

**Haptics checks**

- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.
- [ ] H9: successful pairing or pose_start/base_start emits no vibration or sound.

**State/color checks**

- [ ] The chip reads Not connected in the supplied initial state; Connect is a blue primary action.

Note: helper text now reads "Returns to connection details after connecting" (Figma fixed 2026-11-05).

## S2 Permissions

Node: [`121:1162`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-1162). Purpose: Explain camera and motion permissions.

**Layout checks**

- [ ] The reference view contains "Setup"; "Connected"; "Two permissions are required"; "Camera"; "Tracks phone pose for AR. On iOS the camera must stay on so volume-key hold and release are detected."; "Motion sensors"; "Reads phone rotation and maps it to wrist orientation."; "Continue opens the system permission prompts."; "Continue"; "STOP".

**Navigation checks**

- [ ] tap Connection chip -> P5.
- [ ] tap Continue -> T1.
- [ ] tap E-stop button -> S4.

**Haptics checks**

- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.

**State/color checks**

- [ ] The chip reads Connected and the mode label reads Setup; Continue is blue.

## T1 Tutorial 1 of 3

Node: [`121:387`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-387). Purpose: Teach hold-to-move arm control.

**Layout checks**

- [ ] The reference view contains "Standby"; "Connected"; "Gripper: open"; "Close: 1 pulse. Open: 2 pulses."; "Gripper aim"; "Hold vol+: move arm Press vol−: gripper Hold right edge: move base"; "Base"; "Record"; "Reset"; "Settings"; "Step 1 of 3"; "Hold volume up to move the arm"; "The arm follows your phone only while the button is held. Release to stop."; "Skip"; "Next"; "STOP".

**Navigation checks**

- [ ] tap Connection chip -> P5.
- [ ] tap Record -> S3a.
- [ ] tap Settings -> S6.
- [ ] tap Skip -> P4.
- [ ] tap Next -> T2.
- [ ] tap E-stop button -> S4.

**Haptics checks**

- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.
- [ ] H10: starting recording emits no vibration and 1 notification tone.

**State/color checks**

- [ ] The tutorial card overlays the dimmed standby view; STOP remains unobscured.

## T2 Tutorial 2 of 3

Node: [`121:435`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-435). Purpose: Teach gripper control and feedback.

**Layout checks**

- [ ] The reference view contains "Standby"; "Connected"; "Gripper: open"; "Close: 1 pulse. Open: 2 pulses."; "Gripper aim"; "Hold vol+: move arm Press vol−: gripper Hold right edge: move base"; "Base"; "Record"; "Reset"; "Settings"; "Step 2 of 3"; "Press volume down for the gripper"; "One short pulse means closed. Two short pulses mean opened."; "Skip"; "Next"; "STOP".

**Navigation checks**

- [ ] tap Connection chip -> P5.
- [ ] tap Record -> S3a.
- [ ] tap Settings -> S6.
- [ ] tap Skip -> P4.
- [ ] tap Next -> T3.
- [ ] tap E-stop button -> S4.

**Haptics checks**

- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.
- [ ] H10: starting recording emits no vibration and 1 notification tone.

**State/color checks**

- [ ] The tutorial card overlays the dimmed standby view; STOP remains unobscured.

## T3 Tutorial 3 of 3

Node: [`121:483`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-483). Purpose: Teach emergency stopping.

**Layout checks**

- [ ] The reference view contains "Standby"; "Connected"; "Gripper: open"; "Close: 1 pulse. Open: 2 pulses."; "Gripper aim"; "Hold vol+: move arm Press vol−: gripper Hold right edge: move base"; "Base"; "Record"; "Reset"; "Settings"; "Step 3 of 3"; "The red STOP button is always here"; "Tap it at any time to stop the robot at once."; "Back"; "Start"; "STOP".

**Navigation checks**

- [ ] tap Connection chip -> P5.
- [ ] tap Record -> S3a.
- [ ] tap Settings -> S6.
- [ ] tap Skip -> P4 (layer displays Back).
- [ ] tap Next -> P4 (layer displays Start).
- [ ] tap Start -> P4.
- [ ] tap E-stop button -> S4.

**Haptics checks**

- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.
- [ ] H10: starting recording emits no vibration and 1 notification tone.

**State/color checks**

- [ ] The tutorial card overlays the dimmed standby view; STOP remains unobscured.

Source note: Layer mapping: Skip (121:523) displays Back; Next (121:525) displays Start. Both target P4; no T2 destination is supplied.

## P4 Standby

Node: [`121:198`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-198). Purpose: Provide the idle teleoperation controls.

**Layout checks**

- [ ] The reference view contains "Standby"; "Connected"; "Gripper: open"; "Close: 1 pulse. Open: 2 pulses."; "Gripper aim"; "Hold vol+: move arm Press vol−: gripper Hold right edge: move base"; "Base"; "Record"; "Reset"; "Settings"; "STOP".
- [ ] The Base handle is 72 pt wide at the right edge of the camera area and does not extend into the bottom action row.

**Navigation checks**

- [ ] tap Connection chip -> P5.
- [ ] tap Volume key hint -> S5.
- [ ] tap Base handle (right edge) -> S3m.
- [ ] tap Record -> S3a.
- [ ] tap Settings -> S6.
- [ ] tap E-stop button -> S4.

**Haptics checks**

- [ ] H1: closing the gripper emits 1 short pulse.
- [ ] H2: opening the gripper emits 2 short pulses.
- [ ] H3: a rejected command emits 3 short pulses.
- [ ] H4: a clamped command emits 3 short pulses plus an amber flash, at most once per hold.
- [ ] H5: a ForcedStop event (vol− during held vol+, competing arm/base control, or excessive phone speed) emits 3 short pulses.
- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.
- [ ] H9: successful pairing or pose_start/base_start emits no vibration or sound.
- [ ] H10: starting recording emits no vibration and 1 notification tone.

**State/color checks**

- [ ] The mode reads Standby; the normal connection dot is green; Record has a blue border and white fill.

## P5 Connection details

Node: [`121:236`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-236). Purpose: Inspect connection health and server details.

**Layout checks**

- [ ] The reference view contains "Standby"; "Connected"; "Gripper: open"; "Close: 1 pulse. Open: 2 pulses."; "Gripper aim"; "Hold vol+: move arm Press vol−: gripper Hold right edge: move base"; "Base"; "Record"; "Reset"; "Settings"; "Connection"; "Latency"; "80 ms, normal"; "Robot heartbeat"; "Received just now"; "Server address"; "192.168.x.x:8765"; "Change server"; "Close"; "STOP".
- [ ] The Connection sheet overlays a dimmed standby view; STOP sits below the sheet.

**Navigation checks**

- [ ] tap Record -> S3a.
- [ ] tap Settings -> S6.
- [ ] tap Row Latency -> P6.
- [ ] tap Latency -> P6.
- [ ] tap Input -> P7.
- [ ] tap Row Change server -> S1.
- [ ] tap Close -> the screen that opened P5 (return to origin). If E-stop is latched, Close always returns to S4. Fallback when there is no origin: P4.
- [ ] tap E-stop button -> S4.
- [ ] tap Connection chip -> P5 (global requirement; absent from export).

**Haptics checks**

- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.
- [ ] H10: starting recording emits no vibration and 1 notification tone.

**State/color checks**

- [ ] The normal latency dot is green; Change server uses neutral text with a right chevron, not blue text.

Source note: Source gap: the visible Connection chip has no exported link; apply the global chip -> P5 invariant.
Decision N1 (2026-11-05): Figma links Close to P4 only because a static prototype cannot return to origin. The app must remember the origin screen. While E-stop is latched, closing P5 must never hide S4.

## P6 High latency

Node: [`121:291`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-291). Purpose: Show that high latency blocks new commands.

**Layout checks**

- [ ] The reference view contains "Standby"; "Connected"; "Gripper: open"; "Close: 1 pulse. Open: 2 pulses."; "Gripper aim"; "Hold vol+: move arm Press vol−: gripper Hold right edge: move base"; "Base"; "Record"; "Reset"; "Settings"; "STOP"; "New commands blocked. Latency is high.".

**Navigation checks**

- [ ] tap Connection chip -> P5.
- [ ] tap Record -> S3a.
- [ ] tap Reset scene -> P4.
- [ ] tap Settings -> S6.
- [ ] tap E-stop button -> S4.

**Haptics checks**

- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.
- [ ] H10: starting recording emits no vibration and 1 notification tone.
- [ ] H12: the cloud latency dot turning amber at 150–400 ms emits no vibration or sound.
- [ ] H13: a new start rejected above 400 ms emits 3 short pulses only at the rejected attempt.

**State/color checks**

- [ ] The latency dot is amber, never red; a rejected new start above 400 ms leaves the screen showing New commands blocked. Latency is high.

## P7 Keyboard open

Node: [`121:331`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-331). Purpose: Edit the server address with the keyboard open.

**Layout checks**

- [ ] The reference view contains "Standby"; "Connected"; "Gripper: open"; "Close: 1 pulse. Open: 2 pulses."; "Gripper aim"; "Hold vol+: move arm Press vol−: gripper Hold right edge: move base"; "Base"; "Record"; "Reset"; "Settings"; "Connection"; "Latency"; "80 ms, normal"; "Robot heartbeat"; "Received just now"; "Server address"; "192.168.x.x:8765"; "Close"; "STOP".
- [ ] The shared keyboard starts at y=632; the STOP container occupies y=548–632, with its 72 pt button fully above the keyboard. The server field remains fully visible above it.

**Navigation checks**

- [ ] tap Connection chip -> P5.
- [ ] tap Record -> S3a.
- [ ] tap Settings -> S6.
- [ ] tap Close -> P5.
- [ ] tap Key -> P5.
- [ ] tap Done -> P5.
- [ ] tap E-stop button -> S4.

**Haptics checks**

- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.
- [ ] H10: starting recording emits no vibration and 1 notification tone.

**State/color checks**

- [ ] The connection details retain their normal colors; the keyboard contains no red styling.

Note: Close goes to P5 only (Figma fixed 2026-11-05). The keyboard instance has no expanded key metadata.

## S3a Recording

Node: [`121:1190`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-1190). Purpose: Show an active recording during teleoperation.

**Layout checks**

- [ ] The reference view contains "Recording"; "Connected"; "Gripper: open"; "Close: 1 pulse. Open: 2 pulses."; "00:12"; "Hold vol+: move arm with the phone, release to stop Press vol−: toggle gripper (after releasing vol+)"; "Recording 0:12"; "Reset"; "Settings"; "STOP".
- [ ] The central timer shows 00:12 in the reference state; the action row shows Recording 0:12.

**Navigation checks**

- [ ] tap Connection chip -> P5.
- [ ] tap Record -> S3b.
- [ ] tap Settings -> S6.
- [ ] tap E-stop button -> S4.

**Haptics checks**

- [ ] H1: closing the gripper emits 1 short pulse.
- [ ] H2: opening the gripper emits 2 short pulses.
- [ ] H3: a rejected command emits 3 short pulses.
- [ ] H4: a clamped command emits 3 short pulses plus an amber flash, at most once per hold.
- [ ] H5: a ForcedStop event (vol− during held vol+, competing arm/base control, or excessive phone speed) emits 3 short pulses.
- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.
- [ ] H9: successful pairing or pose_start/base_start emits no vibration or sound.
- [ ] H11: ending recording or successfully saving emits no vibration and 2 notification tones; the recording indicator disappears.

**State/color checks**

- [ ] Recording styling follows the global recording rule; the timer uses monospaced digits and the status bar does not turn red.

## S3b Record end

Node: [`121:1237`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-1237). Purpose: Save or discard the completed take.

**Layout checks**

- [ ] The reference view contains "Standby"; "Connected"; "Gripper: open"; "Close: 1 pulse. Open: 2 pulses."; "00:42"; "Save or discard this take? The arm stays still until you choose."; "Discard (hold 1s)"; "Save"; "STOP".
- [ ] The reference timer shows 00:42; Discard (hold 1s) and Save are both present.

**Navigation checks**

- [ ] tap Connection chip -> P5.
- [ ] hold Discard -> P4 (1 second; exported as ON_CLICK).
- [ ] hold Discard (hold 1s) -> P4 (1 second; exported as ON_CLICK).
- [ ] tap Save -> P4.
- [ ] tap E-stop button -> S4.

**Haptics checks**

- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.
- [ ] H11: ending recording or successfully saving emits no vibration and 2 notification tones; the recording indicator disappears.

**State/color checks**

- [ ] The arm stays still until a choice is made; Save is solid green with white text. Discard is not red under the current red-only rule; its replacement color is unspecified.

Source note: Source conflict: the export marks Discard as ON_CLICK; the layer label and visual spec require a 1-second hold. Older red Discard styling is superseded by the current red-only rule. Metadata shows no frame count or separate summary label.

## S3m Teleop with base

Node: [`121:1279`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-1279). Purpose: Expose the right-edge base control.

**Layout checks**

- [ ] The reference view contains "Standby"; "Connected"; "Gripper: open"; "Close: 1 pulse. Open: 2 pulses."; "Hold vol+: move the arm Press vol−: toggle gripper Hold right edge: move the base"; "Base"; "Record"; "Reset"; "Settings"; "STOP".
- [ ] The Base handle stays on the right edge within the camera area.

**Navigation checks**

- [ ] tap Connection chip -> P5.
- [ ] tap Base handle (right edge) -> P4.
- [ ] tap Record -> S3a.
- [ ] tap Settings -> S6.
- [ ] tap E-stop button -> S4.

**Haptics checks**

- [ ] H1: closing the gripper emits 1 short pulse.
- [ ] H2: opening the gripper emits 2 short pulses.
- [ ] H3: a rejected command emits 3 short pulses.
- [ ] H4: a clamped command emits 3 short pulses plus an amber flash, at most once per hold.
- [ ] H5: a ForcedStop event (vol− during held vol+, competing arm/base control, or excessive phone speed) emits 3 short pulses.
- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.
- [ ] H9: successful pairing or pose_start/base_start emits no vibration or sound.
- [ ] H10: starting recording emits no vibration and 1 notification tone.

**State/color checks**

- [ ] The idle Base handle follows the global dark translucent rule; while held, it is blue with white text and the mode reads Base; holding vol+ changes the mode to Arm.

## S4 E-stopped

Node: [`121:1327`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-1327). Purpose: Show the emergency-stop lock and deliberate release.

**Layout checks**

- [ ] The reference view contains "E-stopped"; "Connected"; "Arm stopped. All inputs are locked."; "Volume keys and on-screen controls are ignored."; "Hold 1s to release"; "Release early to cancel. A short buzz confirms release."; "STOP".
- [ ] A hold-progress ring accompanies Hold 1s to release.

**Navigation checks**

- [ ] tap Connection chip -> P5.
- [ ] hold Release (hold 1s) -> P4 (1 second; exported as ON_CLICK).

**Haptics checks**

- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.
- [ ] H15: the release hold emits no vibration during the hold and 1 short pulse on completion at 1 second.

**State/color checks**

- [ ] The status bar is red with a yellow border; motion inputs are locked. A release shorter than 1 second leaves the stop latched; a completed hold returns to Standby.

Source note: The export marks Release as ON_CLICK; the required native gesture is a 1-second hold. STOP remains drawn on S4, but no STOP self-link is supplied. The Connection chip remains navigable; movement must stay locked until release.

## S5 Screen fallback

Node: [`121:1358`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-1358). Purpose: Provide touch controls when volume keys are unavailable.

**Layout checks**

- [ ] The reference view contains "Standby"; "Connected"; "Hold here"; "Hold here: phone motion moves the arm. Release to stop."; "Gripper: open"; "Record"; "Gripper"; "Settings"; "STOP".
- [ ] The large Hold here pad sits above Record, Gripper, and Settings.

**Navigation checks**

- [ ] tap Connection chip -> P5.
- [ ] tap Record -> S5a.
- [ ] tap Settings -> S6.
- [ ] tap E-stop button -> S4.

**Haptics checks**

- [ ] H1: closing the gripper emits 1 short pulse.
- [ ] H2: opening the gripper emits 2 short pulses.
- [ ] H3: a rejected command emits 3 short pulses.
- [ ] H4: a clamped command emits 3 short pulses plus an amber flash, at most once per hold.
- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.
- [ ] H9: successful pairing or pose_start/base_start emits no vibration or sound.
- [ ] H10: starting recording emits no vibration and 1 notification tone.

**State/color checks**

- [ ] Record has a blue border and white fill; holding the pad enables arm motion and releasing it stops motion.

## S5a Recording fallback

Node: [`121:1394`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-1394). Purpose: Record while using touch controls.

**Layout checks**

- [ ] The reference view contains "Recording"; "Connected"; "00:12"; "Hold here"; "Hold here: phone motion moves the arm. Release to stop."; "Recording 0:12"; "Gripper"; "Settings"; "STOP".
- [ ] The Hold here pad contains the 00:12 timer above the action row.

**Navigation checks**

- [ ] tap Connection chip -> P5.
- [ ] tap Record -> S3b.
- [ ] tap Settings -> S6.
- [ ] tap E-stop button -> S4.

**Haptics checks**

- [ ] H1: closing the gripper emits 1 short pulse.
- [ ] H2: opening the gripper emits 2 short pulses.
- [ ] H3: a rejected command emits 3 short pulses.
- [ ] H4: a clamped command emits 3 short pulses plus an amber flash, at most once per hold.
- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.
- [ ] H9: successful pairing or pose_start/base_start emits no vibration or sound.
- [ ] H11: ending recording or successfully saving emits no vibration and 2 notification tones; the recording indicator disappears.

**State/color checks**

- [ ] Recording styling follows the global recording rule; holding and releasing the pad retains the fallback motion behavior.

Source note: Source ambiguity: "Gripper: open / Stop recording hint" is a text-layer name, not independently verified rendered copy. Do not invent replacement wording or expose an authoring hint as final UI text.

## S6 Settings

Node: [`121:1434`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-1434). Purpose: Adjust controls and access diagnostics and tutorial replay.

**Layout checks**

- [ ] The reference view contains "Back"; "Settings"; "Done"; "Sensitivity"; "1.0"; "Deadband"; "2°"; "Smoothing"; "0.3"; "Debug log"; "Send hello"; "Clear log"; "Replay tutorial"; "Developer mode"; "Off"; "STOP".

**Navigation checks**

- [ ] tap Back -> P4.
- [ ] tap Done -> P4.
- [ ] tap Replay tutorial -> T1.
- [ ] tap E-stop button -> S4.

**Haptics checks**

- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.

**State/color checks**

- [ ] Developer mode initially reads Off; normal UI copy contains no raw protocol identifiers or duplicated implementation labels.

Source note: Source conflict: metadata includes gain, deadband, smoothing and raw pose_* debug lines despite Developer mode Off. Preserve the controls, but these implementation strings cannot pass the no-internal-codes rule in normal UI.

## S7 Errors

Node: [`121:1493`](https://www.figma.com/design/inLwADDDptRo8qIw34DRqP/?node-id=121-1493). Purpose: Show connection loss, timeout, or command rejection.

**Layout checks**

- [ ] The reference view contains "Disconnected"; "Connection lost"; "Arm stopped by heartbeat timeout. Reconnecting…"; "No update for 750 ms. This command stopped. Release and try again."; "Command rejected: busy"; "Another device is controlling the robot"; "Reconnect"; "Back to connect"; "STOP".

**Navigation checks**

- [ ] tap Connection chip -> P5.
- [ ] tap Reconnect -> S1.
- [ ] tap Back to connect -> S1.
- [ ] tap E-stop button -> S4.

**Haptics checks**

- [ ] H3: a rejected command emits 3 short pulses.
- [ ] H6: STOP, disconnection, or a 750 ms watchdog timeout emits repeating long pulses plus an alarm until cleared or acknowledged.

**State/color checks**

- [ ] The connection chip reads Disconnected; connection-loss styling may be red, while a busy rejection uses warning styling rather than emergency-stop feedback.

## Reachability from P1

Each row is a yes/no UI-test check: starting at P1, the listed route reaches the target using the exported links above. P1–P3 have no STOP by design. Reachability is proven for the supplied prototype graph, not yet executed against the native app.

| Target | Route from P1 | Reached in native UI test? |
| --- | --- | --- |
| P1 | P1 | [ ] |
| P2 | P1 -> P2 | [ ] |
| P3 | P1 -> P3 | [ ] |
| S1 | P1 -> P2 -> S2 -> P5 -> S1 | [ ] |
| S2 | P1 -> P2 -> S2 | [ ] |
| T1 | P1 -> P2 -> S2 -> T1 | [ ] |
| T2 | P1 -> P2 -> S2 -> T1 -> T2 | [ ] |
| T3 | P1 -> P2 -> S2 -> T1 -> T2 -> T3 | [ ] |
| P4 | P1 -> P2 -> S2 -> P5 -> P4 | [ ] |
| P5 | P1 -> P2 -> S2 -> P5 | [ ] |
| P6 | P1 -> P2 -> S2 -> P5 -> P6 | [ ] |
| P7 | P1 -> P2 -> S2 -> P5 -> P7 | [ ] |
| S3a | P1 -> P2 -> S2 -> P5 -> S3a | [ ] |
| S3b | P1 -> P2 -> S2 -> P5 -> S3a -> S3b | [ ] |
| S3m | P1 -> P2 -> S2 -> P5 -> P4 -> S3m | [ ] |
| S4 | P1 -> P2 -> S2 -> S4 | [ ] |
| S5 | P1 -> P2 -> S2 -> P5 -> P4 -> S5 | [ ] |
| S5a | P1 -> P2 -> S2 -> P5 -> P4 -> S5 -> S5a | [ ] |
| S6 | P1 -> P2 -> S2 -> P5 -> S6 | [ ] |
| S7 | P1 -> P2 -> S2 -> P5 -> S1 -> S7 | [ ] |
