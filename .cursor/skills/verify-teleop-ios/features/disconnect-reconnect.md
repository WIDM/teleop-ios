# F3 S1 Disconnect, then connect again

Disconnect on S1 ends the link and stays on S1, with no lost-connection line; Connect then returns to P5.

## Sub-features

- F3.a S1 Disconnect -> S1, status Not connected, no `connect.connection_lost`.
- F3.b S1 Connect after Disconnect -> P5, status Connected.
- F3.c A live link that drops on P4, P6 or S5 opens S1 with `connect.connection_lost`; E-stop keeps S4.
- F3.d Disconnect plays the long buzz (400 on / 200 off) and it is cancelled on reconnect.

## How to get to it (user POV)

- P5 Change server -> S1 -> Disconnect.

## Driving it with XCUITest / swift test

Preconditions: baseline, connected (S1 Connect done once).

- Logic: `swift test --filter S1ConnectFlowTests` -> `.disconnect` keeps `.s1`; `LiveLinkSessionTests` -> `.linkLost` opens `.s1` with `connectionLost`; check drained haptics.
- UI: tap `connect.disconnect`, expect `connect.connect` and no `connect.connection_lost` (shot `08-S1-after-disconnect`); tap `connect.connect`, expect `connection.change_server`. F3.c needs a live link; the UI tests run on the demo link.

## Gotchas

- haptics-v1 requires the long buzz on disconnect; if `TeleopSession` emits no haptic on `.disconnect`, report FAIL against H-spec, do not relax the check.
- The lost-connection line on S1 is one of only three places red is allowed.
