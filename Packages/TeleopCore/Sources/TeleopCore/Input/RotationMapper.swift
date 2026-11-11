import Foundation
import simd

public enum WristAxis: Equatable, Sendable {
    /// Wrist roll; send with `TeleopLink.orientUpdate(rollDegrees:)`.
    case turn
    /// Wrist flex; send with `TeleopLink.orientUpdate(pitchDegrees:)`.
    case tilt
}

/// What a wrist hold asks for now.
public struct WristTarget: Equatable, Sendable {
    /// Nil until the hold commits to an axis; the target is then the anchor (identity `q_rel`).
    public var axis: WristAxis?
    /// Server degrees on `axis` from where the hold began, with the profile's signs applied.
    public var degrees: Double

    public init(axis: WristAxis?, degrees: Double) {
        self.axis = axis
        self.degrees = degrees
    }

    public static let identity = WristTarget(axis: nil, degrees: 0)
}

/// Measured wrist angles from the newest `state`, all nil on an unknown server.
public struct WristReadings: Equatable, Sendable {
    /// `wrist_roll_deg`.
    public var rollDeg: Double?
    /// `wrist_flex_deg`.
    public var flexDeg: Double?
    /// `wrist_flex_deg` in the first state after the last reset.
    public var flexAtResetDeg: Double?

    public init(rollDeg: Double? = nil, flexDeg: Double? = nil, flexAtResetDeg: Double? = nil) {
        self.rollDeg = rollDeg
        self.flexDeg = flexDeg
        self.flexAtResetDeg = flexAtResetDeg
    }

    public static let unknown = WristReadings()
}

/// Phone attitude to a wrist command for one hold (I-8.1 to I-8.4): anchored where the hold's input began, committed
/// to one axis, gain 1:1, clamped per hold and to the windows, lightly smoothed, with END once per limit.
/// The I-8.6 lead bound is not applied here; it belongs after this, on the value sent.
public struct RotationMapper: Equatable, Sendable {
    public private(set) var anchor: simd_quatd?
    public private(set) var axis: WristAxis?
    /// The server angles this hold may command on `axis`.
    public private(set) var range: ClosedRange<Double> = 0...0
    /// Scheme A: the hold starts at its commit, and the committing angle counts (I-10). Scheme B: the hold starts
    /// at the key press and sends the identity until it commits.
    public let startsAtCommit: Bool
    private let constants: InputConstants
    /// The server angle at commit (scheme A), kept for a start that goes out late (I-8.1).
    private var commitAngle = 0.0
    /// Added to the axis angle once a late start has moved the anchor.
    private var offset = 0.0
    private var smoothed = 0.0
    private var smoothedAt: TimeInterval = 0
    /// The edge END last played at, until the angle backs off from it.
    private var endedAt: Edge?

    private enum Edge: Equatable, Sendable { case lower, upper }

    public init(anchor: simd_quatd?, startsAtCommit: Bool, constants: InputConstants = .appendixA) {
        self.anchor = anchor
        self.startsAtCommit = startsAtCommit
        self.constants = constants
    }

    /// Turn and tilt from the anchor; zero while there is none.
    public func angles(_ attitude: simd_quatd) -> WristAngles {
        guard let anchor else { return .zero }
        return WristAngles(from: anchor, to: attitude)
    }

    /// I-8.2: the axis that has reached `axisLockDeg` while the other is below `axisLockRatio` of it, if any.
    public func dominantAxis(_ angles: WristAngles) -> WristAxis? {
        let turn = abs(angles.turn), tilt = abs(angles.tilt)
        if turn >= constants.axisLockDeg, tilt < constants.axisLockRatio * turn { return .turn }
        if tilt >= constants.axisLockDeg, turn < constants.axisLockRatio * tilt { return .tilt }
        return nil
    }

    /// True once turn or tilt has reached `axisLockDeg`, whether or not one dominates.
    public func reachedLockAngle(_ angles: WristAngles) -> Bool {
        max(abs(angles.turn), abs(angles.tilt)) >= constants.axisLockDeg
    }

    /// The first attitude seen anchors a hold that began before tracking delivered one.
    public mutating func anchorIfNeeded(_ attitude: simd_quatd) {
        if anchor == nil { anchor = attitude }
    }

    /// Commits the hold to `axis` and returns the first target. `range` comes from `limits(for:readings:...)`.
    public mutating func lock(
        _ axis: WristAxis, range: ClosedRange<Double>, attitude: simd_quatd, at time: TimeInterval
    ) -> (target: WristTarget, limitReached: Bool) {
        anchorIfNeeded(attitude)
        self.axis = axis
        self.range = range
        offset = 0
        endedAt = nil
        let raw = serverAngle(attitude)
        commitAngle = clamped(raw)
        smoothed = startsAtCommit ? commitAngle : 0
        smoothedAt = time
        let limit = judgeLimit(raw)
        return (WristTarget(axis: axis, degrees: smoothed), limit)
    }

    /// The target for a new attitude sample, and whether a limit was reached with it (END plays once per limit and
    /// again only after backing off `limitRearmDeg`). Turning back from a limit moves the target back at once.
    public mutating func target(for attitude: simd_quatd, at time: TimeInterval) -> (target: WristTarget, limitReached: Bool) {
        anchorIfNeeded(attitude)
        guard let axis else { return (.identity, false) }
        let raw = serverAngle(attitude)
        // EMA at 30 Hz whatever the sample rate.
        let keep = pow(constants.angleSmoothing, max(0, time - smoothedAt) * 30)
        smoothed = keep * smoothed + (1 - keep) * clamped(raw)
        smoothedAt = time
        let limit = judgeLimit(raw)
        return (WristTarget(axis: axis, degrees: smoothed), limit)
    }

    /// I-8.1: the start went on the wire only now, after waiting behind a finishing hold. Rotation made while it
    /// waited is dropped: the anchor moves so that the angle sent equals the angle at commit (scheme A) or zero
    /// (scheme B, which also commits afresh).
    public mutating func startSent(attitude: simd_quatd, at time: TimeInterval) {
        anchor = attitude
        endedAt = nil
        smoothedAt = time
        if startsAtCommit, axis != nil {
            offset = commitAngle
            smoothed = commitAngle
        } else {
            axis = nil
            offset = 0
            smoothed = 0
        }
    }

    /// The server angles a hold on `axis` may command (I-8.3): the per-hold clamp, narrowed by the roll window
    /// around the measured roll or the tilt window around the flex measured after the last reset. On an unknown
    /// server the roll has only the clamp and the tilt window counts the commanded tilts since the last reset.
    /// The range always contains 0: a wrist already past a window may still turn back.
    public static func limits(
        for axis: WristAxis, readings: WristReadings, commandedTiltSinceResetDeg: Double,
        constants: InputConstants = .appendixA
    ) -> ClosedRange<Double> {
        var lower: Double, upper: Double
        switch axis {
        case .turn:
            lower = -constants.rollClampDeg
            upper = constants.rollClampDeg
            if let roll = readings.rollDeg {
                lower = max(lower, -constants.rollWindowDeg - roll)
                upper = min(upper, constants.rollWindowDeg - roll)
            }
        case .tilt:
            lower = -constants.tiltClampDeg
            upper = constants.tiltClampDeg
            let fromReset: Double
            if let flex = readings.flexDeg, let atReset = readings.flexAtResetDeg {
                fromReset = flex - atReset
            } else {
                fromReset = commandedTiltSinceResetDeg
            }
            lower = max(lower, -constants.tiltWindowDeg - fromReset)
            upper = min(upper, constants.tiltWindowDeg - fromReset)
        }
        return min(lower, 0)...max(upper, 0)
    }

    private func serverAngle(_ attitude: simd_quatd) -> Double {
        let angles = self.angles(attitude)
        switch axis {
        case .turn?: return offset + constants.rollSign * angles.turn
        case .tilt?: return offset + constants.tiltSign * angles.tilt
        case nil: return 0
        }
    }

    private func clamped(_ angle: Double) -> Double { min(max(angle, range.lowerBound), range.upperBound) }

    private mutating func judgeLimit(_ raw: Double) -> Bool {
        switch endedAt {
        case .upper? where raw <= range.upperBound - constants.limitRearmDeg: endedAt = nil
        case .lower? where raw >= range.lowerBound + constants.limitRearmDeg: endedAt = nil
        default: break
        }
        guard endedAt == nil else { return false }
        if raw >= range.upperBound {
            endedAt = .upper
            return true
        }
        if raw <= range.lowerBound {
            endedAt = .lower
            return true
        }
        return false
    }
}
