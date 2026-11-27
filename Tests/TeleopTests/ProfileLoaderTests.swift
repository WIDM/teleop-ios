import Foundation
import TeleopCore
import XCTest
@testable import Teleop

/// The build names the profile it drives, a launch argument may name another, and a profile that is missing or wrong
/// stops the load with a sentence that says why.
final class ProfileLoaderTests: XCTestCase {
    private let app = Bundle(for: AppModel.self)
    private let tests = Bundle(for: ProfileLoaderTests.self)

    func testTheBuildNamesTheSO101File() throws {
        XCTAssertEqual(app.object(forInfoDictionaryKey: ProfileLoader.infoKey) as? String, "so101-s4-sim")
        XCTAssertEqual(try ProfileLoader.chosen(arguments: [:], bundle: app), TestProfiles.so101)
    }

    func testTheLaunchArgumentOverridesTheBuild() throws {
        let info: [String: Any] = [ProfileLoader.infoKey: "so101-s4-sim"]
        XCTAssertEqual(try ProfileLoader.chosenID(arguments: [:], info: info), "so101-s4-sim")
        XCTAssertEqual(
            try ProfileLoader.chosenID(arguments: [ProfileLoader.argumentKey: "bench-arm"], info: info), "bench-arm")
        XCTAssertEqual(
            try ProfileLoader.chosenID(arguments: [ProfileLoader.argumentKey: ""], info: info), "so101-s4-sim")
    }

    func testNoChoiceAtAllIsAnError() {
        XCTAssertThrowsError(try ProfileLoader.chosenID(arguments: [:], info: [:])) { error in
            XCTAssertEqual(error as? ProfileLoader.Failure, .noneChosen)
            XCTAssertTrue("\(error)".contains("TeleopRobotProfile"), "\(error)")
        }
    }

    func testAProfileThatIsNotBundledIsAnError() {
        XCTAssertThrowsError(
            try ProfileLoader.chosen(arguments: [ProfileLoader.argumentKey: "no-such-arm"], bundle: app)
        ) { error in
            XCTAssertEqual(error as? ProfileLoader.Failure, .notBundled(id: "no-such-arm"))
            XCTAssertEqual(
                "\(error)", "The robot profile no-such-arm.json is not in the app. Add it to App/Resources/Profiles.")
        }
    }

    func testAnInvalidProfileIsAnErrorWithEveryFault() {
        XCTAssertThrowsError(try ProfileLoader.load(id: "test-invalid-profile", bundle: tests)) { error in
            guard case .unreadable(let id, let reason)? = error as? ProfileLoader.Failure else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(id, "test-invalid-profile")
            XCTAssertTrue(reason.contains("robot.gripper.empty_deg must be below robot.gripper.open_deg."), reason)
            XCTAssertTrue(reason.contains("scene.target_size_m must be above zero."), reason)
        }
    }

    func testAMisspeltFieldIsAnErrorNamingIt() {
        XCTAssertThrowsError(try ProfileLoader.load(id: "test-misspelt-profile", bundle: tests)) { error in
            XCTAssertEqual(
                error as? ProfileLoader.Failure,
                .unreadable(
                    id: "test-misspelt-profile",
                    reason: "The profile has robot.gripper.open_degs, which is not a field of this format."))
        }
    }
}
