import TeleopCore
import XCTest
@testable import Teleop

/// Counts the ON TARGET cues the operator felt during a scripted pick and place: on the approach to the grasp, while
/// the jaws hold the object, and after letting go. The SO-101's and bench arm B's whole-task tests both use it, so the
/// two are held to the same cue rules.
struct OnTargetCueTally {
    private var seen = 0
    private var grasped = false
    private(set) var beforeTheGrasp: [CueLogEntry] = []
    private(set) var whileHolding = 0
    private(set) var afterTheRelease = 0

    /// Call it on every step of the script.
    mutating func update(_ model: AppModel) {
        let cues = model.cueLog.filter { $0.event == .onTarget }
        let new = cues.dropFirst(seen)
        seen = cues.count
        if model.gripping { grasped = true }
        if !grasped {
            beforeTheGrasp += new
        } else if model.gripping {
            whileHolding += new.count
        } else {
            afterTheRelease += new.count
        }
    }

    /// ON TARGET is felt exactly once on the approach to the grasp, never while the jaws hold the object, and not when
    /// letting go on the goal leaves the open jaws on the object they carried there.
    func assertOnceOnTheApproach(
        _ model: AppModel, mode: ControlMode, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertLessThan(model.cueLog.count, 200, "the cue log still holds the whole script", file: file, line: line)
        XCTAssertEqual(
            beforeTheGrasp.count, 1, "\(mode): ON TARGET once on the approach, \(beforeTheGrasp)", file: file, line: line)
        XCTAssertEqual(beforeTheGrasp.first?.dropped, false, "\(mode): and felt", file: file, line: line)
        XCTAssertEqual(whileHolding, 0, "\(mode)", file: file, line: line)
        XCTAssertEqual(
            afterTheRelease, 0, "\(mode): letting go of the carried object is no new approach", file: file, line: line)
    }
}
