import simd

@testable import TeleopCore

/// The wrists the rule tests run with. A test names one here, never a literal of its own.
enum TestWrist {
    /// The SO-101 in the S4 simulator, the numbers of `so101-s4-sim.json`.
    static let so101 = WristProfile(
        rollSign: 1, tiltSign: 1, rollWindowDeg: 150, tiltWindowDeg: 25, rollClampDeg: 55, tiltClampDeg: 20,
        tiltCentre: .measuredAfterReset, turnRateDegS: 20, tiltRateDegS: 10,
        lead: WristLeadLimits(leadDeg: 2, rateMaxDegS: 10, memoryDeg: 0.5, freshStateMs: 400))

    /// The wrist of bench arm B: a narrower turn, a wider tilt centred on a fixed flex, a turn sign the other way
    /// and a tilt sign the same as the SO-101's (so a rule that reads one axis's sign for the other gives a
    /// different answer), buttons twice as fast, and its own lead numbers.
    static let benchB = WristProfile(
        rollSign: -1, tiltSign: 1, rollWindowDeg: 90, tiltWindowDeg: 45, rollClampDeg: 40, tiltClampDeg: 30,
        tiltCentre: .fixed(15), turnRateDegS: 40, tiltRateDegS: 20,
        lead: WristLeadLimits(leadDeg: 3, rateMaxDegS: 20, memoryDeg: 1, freshStateMs: 300))

    static let all: [(name: String, wrist: WristProfile)] = [("SO-101", so101), ("bench arm B", benchB)]
}

// What the rule tests built with the arm's defaults before the wrist came from the profile: the SO-101's wrist, named
// here once so that a test that is not about the wrist reads as it did.
extension InputConstants {
    /// The SO-101's wrist with the touch and key numbers as the app has them.
    public static let appendixA = InputConstants(wrist: TestWrist.so101)

    init(rollSign: Double = 1, tiltSign: Double = 1, keyReplayGuard: Bool = true) {
        var wrist = TestWrist.so101
        wrist.rollSign = rollSign
        wrist.tiltSign = tiltSign
        self.init(wrist: wrist, keyReplayGuard: keyReplayGuard)
    }
}

extension RotationMapper {
    init(anchor: simd_quatd?, startsAtCommit: Bool) {
        self.init(anchor: anchor, startsAtCommit: startsAtCommit, constants: .appendixA)
    }

    static func limits(for axis: WristAxis, readings: WristReadings, commandedTiltSinceResetDeg: Double)
        -> ClosedRange<Double>
    {
        limits(
            for: axis, readings: readings, commandedTiltSinceResetDeg: commandedTiltSinceResetDeg,
            constants: .appendixA)
    }
}

extension InputArbiter {
    init(scheme: InputScheme, hand: Hand = .right, layout: SurfaceLayout, assist: Assist = .off) {
        self.init(scheme: scheme, hand: hand, layout: layout, constants: .appendixA, assist: assist)
    }
}

extension SurfaceLayout {
    init(width: Double, height: Double, safeTop: Double, safeBottom: Double, pointsPerMm: Double? = nil) {
        self.init(
            width: width, height: height, safeTop: safeTop, safeBottom: safeBottom, pointsPerMm: pointsPerMm,
            constants: .appendixA)
    }
}

extension WristLeadBound {
    init() { self.init(limits: TestWrist.so101.lead) }
}

extension WristButton {
    var degreesPerSecond: Double { degreesPerSecond(in: TestWrist.so101) }
}

extension WristButtonRamp {
    init(button: WristButton, range: ClosedRange<Double>) {
        self.init(button: button, range: range, wrist: TestWrist.so101)
    }
}
