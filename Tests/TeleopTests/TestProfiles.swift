import Foundation
import TeleopCore
@testable import Teleop

/// The profiles the app tests run with, read through `ProfileLoader` from the files the app bundles. The one place a
/// test names a profile; tests use these instead of building their own copy.
enum TestProfiles {
    /// The SO-101 in the S4 pick-and-place simulator: `App/Resources/Profiles/so101-s4-sim.json`.
    static let so101: RobotProfile = {
        do {
            return try ProfileLoader.load(id: "so101-s4-sim", bundle: Bundle(for: AppModel.self))
        } catch {
            fatalError("\(error)")
        }
    }()
}
