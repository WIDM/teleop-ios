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

    /// Bench arm B, a deliberately different arm given only as a file: `Tests/TeleopTests/Profiles/bench-arm-b.json`,
    /// in the test bundle and not in the app. Read the same way the app reads the SO-101's.
    static let benchB: RobotProfile = {
        do {
            return try ProfileLoader.load(id: "bench-arm-b", bundle: Bundle(for: TestBundleMarker.self))
        } catch {
            fatalError("\(error)")
        }
    }()

    /// B's wrist, jaw, motion and server, as the file gives them: a wrist unlike the SO-101's in every number (a narrower
    /// turn, a wider tilt on a fixed centre, a turn sign the other way and a tilt sign the same as the SO-101's, so a
    /// rule that reads one axis's sign for the other gives a different answer, buttons twice as fast); a parallel jaw
    /// read in millimetres between the pads, 0 shut and 40 open; buttons twice as fast with a lead cap under its 6 cm
    /// stop distance; a server with its own resync times, a held object lifted through the tool point and no
    /// simulation loop to watch. The package tests' `TestWrist.benchB`, `TestJaw.benchB`, `TestMotion.benchB` and
    /// `TestServer.benchB` carry the same numbers, and `BenchArmBTests` checks it.
    static var benchBWrist: WristProfile { benchB.wrist }
    static var benchBGripper: GripperProfile { benchB.gripper }
    static var benchBMotion: MotionProfile { benchB.motion }
    static var benchBServer: ServerProfile { benchB.server }

    /// The SO-101's profile, and the SO-101's with bench arm B's motion and server facts: what a rule that reads them
    /// is run through.
    static let motions: [(name: String, profile: RobotProfile)] = {
        var b = so101
        b.motion = benchBMotion
        b.server = benchBServer
        return [("SO-101", so101), ("bench arm B", b)]
    }()

    /// The jaws the app tests run a jaw rule through.
    static let grippers: [(name: String, gripper: GripperProfile)] = [
        ("SO-101", so101.gripper), ("bench arm B", benchBGripper),
    ]

    /// The wrists the app tests run a wrist rule through.
    static let wrists: [(name: String, wrist: WristProfile)] = [
        ("SO-101", so101.wrist), ("bench arm B", benchBWrist),
    ]
}

/// Names the test bundle, which holds the test-only profile files.
private final class TestBundleMarker {}

extension SurfaceLayout {
    /// The operating screen's zones with the SO-101's input numbers, as the app tests draw it.
    init(width: Double, height: Double, safeTop: Double, safeBottom: Double) {
        self.init(
            width: width, height: height, safeTop: safeTop, safeBottom: safeBottom,
            constants: TestProfiles.so101.inputConstants)
    }
}

extension OperatingFacts {
    /// Facts with the SO-101's wrist, as the rule tests start from.
    init() { self.init(wrist: TestProfiles.so101.wrist) }
}

extension ServerState {
    /// A state read with the SO-101's jaw readings, as the rule tests build one.
    init(payload: [String: Any]) {
        self.init(payload: payload, jawReadings: TestProfiles.so101.gripper.validReadings)
    }
}

extension FeedbackMonitor {
    /// A monitor with the SO-101's blocked and lowest numbers, as the rule tests build one.
    init(limits: GripperLimits, frames: Frames) {
        self.init(
            limits: limits, frames: frames, blocked: TestProfiles.so101.blocked, lowest: TestProfiles.so101.lowest)
    }
}
