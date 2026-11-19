import XCTest
@testable import Teleop

final class LocalizationTests: XCTestCase {
    func testKeysResolveToEnglish() {
        let bundle = Bundle(for: AppModel.self)
        XCTAssertEqual(bundle.localizedString(forKey: "connect.connect", value: nil, table: nil), "Connect")
        XCTAssertEqual(bundle.localizedString(forKey: "band.stop", value: nil, table: nil), "STOP 急停")
    }
}
