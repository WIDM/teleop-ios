import TeleopCore
import XCTest
@testable import Teleop

final class LocalizationTests: XCTestCase {
    func testKeysResolveToEnglish() {
        let bundle = Bundle(for: AppModel.self)
        XCTAssertEqual(bundle.localizedString(forKey: "connect.connect", value: nil, table: nil), "Connect")
        XCTAssertEqual(bundle.localizedString(forKey: "stop.label", value: nil, table: nil), "STOP")
        XCTAssertEqual(bundle.localizedString(forKey: "connection.change_server", value: nil, table: nil), "Change server")
    }

    func testLatencyShowsANumberOnlyWhenMeasured() {
        let language = L10n.language
        L10n.language = .en
        defer { L10n.language = language }
        var state = FakeTeleopState()
        XCTAssertEqual(ConnectionDetailsScreen.latencyText(state), "Not measured", "not connected")
        state.markConnected()
        XCTAssertEqual(ConnectionDetailsScreen.latencyText(state), "Not measured", "connected, no round trip yet")
        state.latencyMs = 95
        XCTAssertEqual(ConnectionDetailsScreen.latencyText(state), "95 ms, normal")
        state.latencyMs = 450
        XCTAssertEqual(ConnectionDetailsScreen.latencyText(state), "450 ms, high")
        state.markDisconnected()
        XCTAssertEqual(ConnectionDetailsScreen.latencyText(state), "Not measured", "a dropped link's last sample is not current")
    }
}
