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

    /// A wrist unlike the SO-101's in every number, as bench arm B will have it (the same numbers as the package
    /// tests' `TestWrist.benchB`): a narrower turn, a wider tilt on a fixed centre, a turn sign the other way and a
    /// tilt sign the same as the SO-101's (so a rule that reads one axis's sign for the other gives a different
    /// answer), buttons twice as fast.
    static let benchBWrist = WristProfile(
        rollSign: -1, tiltSign: 1, rollWindowDeg: 90, tiltWindowDeg: 45, rollClampDeg: 40, tiltClampDeg: 30,
        tiltCentre: .fixed(15), turnRateDegS: 40, tiltRateDegS: 20,
        lead: WristLeadLimits(leadDeg: 3, rateMaxDegS: 20, memoryDeg: 1, freshStateMs: 300))

    /// A jaw unlike the SO-101's: parallel, read in millimetres between the pads, 0 shut and 40 open (the same numbers
    /// as the package tests' `TestJaw.benchB`).
    static let benchBGripper = GripperProfile(
        unit: .mm, closedReading: 0, openReading: 40, validMin: 0, validMax: 45, fullyOpenAt: 39, emptyAt: 1)

    /// The jaws the app tests run a jaw rule through.
    static let grippers: [(name: String, gripper: GripperProfile)] = [
        ("SO-101", so101.gripper), ("bench arm B", benchBGripper),
    ]

    /// The wrists the app tests run a wrist rule through.
    static let wrists: [(name: String, wrist: WristProfile)] = [
        ("SO-101", so101.wrist), ("bench arm B", benchBWrist),
    ]
}

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
