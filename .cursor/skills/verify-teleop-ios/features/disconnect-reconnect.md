# F3 S1 Disconnect to S7 to Reconnect

Disconnecting from S1 shows S7 Errors (red banner, arm stopped safely, long-buzz haptic); Reconnect returns to S1.

## Sub-features

- F3.a S1 Disconnect -> S7.
- F3.b S7 Reconnect -> S1.
- F3.c S7 Back to Connect -> S1.
- F3.d Disconnect plays the long buzz (400 on / 200 off) and it is cancelled on reconnect.

## How to get to it (user POV)

- P5 Change server -> S1 -> Disconnect.

## Driving it with XCUITest / swift test

Preconditions: baseline, connected (S1 Connect done once).

- Logic: `swift test --filter TeleopSessionTests` -> `.disconnect` asserts `.s7`; `.reconnect` asserts `.s1`; check drained haptics.
- UI: tap `connect.disconnect`, expect `errors.reconnect` (shot `09-S7-errors`); tap `errors.reconnect`, expect `connect.connect` (shot `10-S1-after-reconnect`).

## Gotchas

- haptics-v1 requires the long buzz on disconnect; if `TeleopSession` emits no haptic on `.disconnect`, report FAIL against H-spec, do not relax the check.
- S7 is one of only three places red is allowed.
