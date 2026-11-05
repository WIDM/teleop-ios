# F1 S1 Connect to P5

From S1 Connect the user taps Connect (or Back) and lands on P5 Connection details showing the server and heartbeat.

## Sub-features

- F1.a S1 Connect -> P5, status becomes Connected.
- F1.b S1 Back -> P5 without changing connection state.
- F1.c P5 Change server -> S1.

## How to get to it (user POV)

- P1 Next -> S2 Continue -> T1 Skip -> P4 -> status chip -> P5 -> Change server -> S1.

## Driving it with XCUITest / swift test

Preconditions: baseline; fake state Not connected.

- Logic: `swift test --filter S1ConnectFlowTests` -> perform `.changeServer`, `.connect` asserts route `.p5`; `.s1Back` asserts `.p5`.
- UI: `ConnectFlowScreenshotTests.testS1ThroughP5` taps `connection.change_server`, `connect.connect`; expects `connection.change_server` (P5). Shots `06-S1-connect`, `07-P5-after-connect`, `08-P5-after-back`.
- Page compare: `figma-compare.py ... --only S1,P5`.

## Gotchas

- P5 must show latency text only on P5/P7; a latency row elsewhere is a FAIL.
- Back from S1 must not go to P4 (old v1.12 rule).
