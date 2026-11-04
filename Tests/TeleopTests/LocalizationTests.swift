import XCTest
@testable import Teleop

final class LocalizationTests: XCTestCase {
    func testKeysResolveToEnglish() {
        let bundle = Bundle(for: AppModel.self)
        XCTAssertEqual(bundle.localizedString(forKey: "connect.connect", value: nil, table: nil), "Connect")
        XCTAssertEqual(bundle.localizedString(forKey: "stop.label", value: nil, table: nil), "STOP")
        XCTAssertEqual(bundle.localizedString(forKey: "connection.change_server", value: nil, table: nil), "Change server")
    }
}
