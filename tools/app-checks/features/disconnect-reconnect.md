# Disconnect, connect again, and a link that drops

A person leaves the server on purpose from Settings, connects again from the Connect screen, and is told plainly
when the link drops by itself.

## What the app does

- Settings, Server, **Disconnect** closes the socket with no error and opens Connect. In practice the section says
  practice uses no server instead, and offers neither button.
- On Connect, **Connect** opens the socket; the operating screen comes up once the server has answered hello with
  its welcome and a first state. An address that does not answer leaves Connect with the reason
  (`connect.failure`) and **Practice without a robot** still offered.
- A later launch with a saved address connects at once. If that server does not answer, the operating screen says
  Not connected, and tapping the word opens Connect.
- The link counts as lost when the socket closes, when the server says nothing for 3 s while the app runs (on the
  control connection, or on both once the listening connection is up), or when no welcome and first state come
  within 5 s of opening. A hold in progress ends. A stall of the network of up to about 2.5 s keeps the link (during
  a hold the control connection hears only the probe echoes, twice a second); one longer than 0.75 s ends the hold
  in progress, by the server's watchdog, with "Link hiccup.". From standby (`p4_standby`) or the slow-link state (`p6_high_latency`) the app
  opens Connect with the lost-connection line (`connect.connection_lost`); elsewhere the operating screen says Link
  lost with "Connect again in Settings", and the operator connects again from Settings, Server. With the stop latched the app stays on the stopped
  screen: the stop is never hidden.

## How to check it

- UI: `ConnectFlowTests.testConnectShowsWhyItFailedAndOffersPractice`,
  `ConnectFlowTests.testTheNotConnectedWordOpensConnect`,
  `LocalServerUITests.testLaunchWithASavedAddressReachesTheLocalServer`, and `PracticeTests` for Settings in
  practice.
- App, on a fake socket and a test clock: `LiveLinkTests.testUserDisconnectClosesTheSocketQuietly`,
  `testSocketCloseDuringAHoldStopsAndReturnsToConnect`, `testSilentServerCountsAsLost`,
  `testWithTheListeningConnectionUpTheLinkIsLostAfter3sOfSilence`, `testNoWelcomeWithinTheTimeoutFails`,
  `testConnectingToAnEstoppedServerOpensS4`.
- App, over a stalling network path to the local server: `LinkStallTests`.
- Core: `S1ConnectFlowTests` and `LiveLinkSessionTests` (`swift test` in `Packages/TeleopCore`).
- By hand, on a phone and a real server: switch Wi-Fi off during a hold; the hold ends and Connect shows the
  lost-connection line.
