# F2 Status chip to P5

The status chip at the top of every screen that shows it opens P5 Connection details.

## Sub-features

- F2.a Chip on P4 Standby -> P5.
- F2.b Chip on S2, S4, S5, S1 -> P5.
- F2.c P5 Close returns to the screen it came from.

## How to get to it (user POV)

- Tap the "Connected"/"Not connected" chip on any screen that shows it.

## Driving it with XCUITest / swift test

Preconditions: baseline.

- Logic: `swift test --filter TeleopNavigatorTests` -> `.openConnection` from each route asserts `.p5`; `.closeConnection` pops back.
- UI: tap `status.chip`, expect `connection.change_server`; tap `connection.close`, expect the origin screen's identifier. Shot `04-P5-connection`.

## Gotchas

- The current UI test only exercises the chip on P4. Other entry points are unverified in UI until tests are added; report them as not covered, not PASS.
