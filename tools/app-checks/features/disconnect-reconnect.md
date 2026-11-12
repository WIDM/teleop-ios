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
- The link counts as lost when the socket closes, when the server says nothing for 2 s (1.2 s on both connections
  once the listening connection is up), or when no welcome and first state come within 5 s of opening. A hold in
  progress ends, and the app opens Connect with the lost-connection line (`connect.connection_lost`). With the stop
  latched it stays on the stopped screen instead: the stop is never hidden.

## How to check it

- UI: `ConnectFlowTests.testConnectShowsWhyItFailedAndOffersPractice`,
  `ConnectFlowTests.testTheNotConnectedWordOpensConnect`,
  `LocalServerUITests.testLaunchWithASavedAddressReachesTheLocalServer`, and `PracticeTests` for Settings in
  practice.
- App, on a fake socket and a test clock: `LiveLinkTests.testUserDisconnectClosesTheSocketQuietly`,
  `testSocketCloseDuringAHoldStopsAndReturnsToConnect`, `testSilentServerCountsAsLost`,
  `testWithTheListeningConnectionUpTheLinkIsLostAfter1point2sOfSilence`, `testNoWelcomeWithinTheTimeoutFails`,
  `testConnectingToAnEstoppedServerOpensS4`.
- Core: `S1ConnectFlowTests` and `LiveLinkSessionTests` (`swift test` in `Packages/TeleopCore`).
- By hand, on a phone and a real server: switch Wi-Fi off during a hold; the hold ends and Connect shows the
  lost-connection line.
