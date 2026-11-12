/// The wrist lead bound (specification I-8.6). The server anchors a wrist hold at its own kept target and moves that
/// target toward anchor + command whatever the wrist does, so a blocked wrist lets the target run ahead, and the
/// wrist moves by that lead once the obstacle gives way, even after the hold has ended. The app bounds the lead on
/// the value it sends: the commanded angle (measured angle at the hold's start + remembered lead + the hold's
/// relative angle) never leads the newest fresh measured angle by more than `leadDeg` plus `rateMaxDegS` times that
/// state's age. Without a fresh state the command does not move further from the wrist.
///
/// All angles are server degrees: roll as `wrist_roll_deg`, flex as `wrist_flex_deg`, the same signs as
/// `WristTarget.degrees`. On an unknown server, which reports no wrist angles, the value passes unchanged.
/// Time comes in as the measured angles' age.
public struct WristLeadBound: Equatable, Sendable {
    /// Appendix A `wristLeadDeg`, `wristRateMaxDegS`, `leadMemoryDeg`, `freshStateMs`.
    public var leadDeg = 2.0
    public var rateMaxDegS = 10.0
    public var memoryDeg = 0.5
    public var freshStateMs = 400

    private struct Memory: Equatable, Sendable {
        var lead: Double
        var measuredAtEnd: Double
    }

    private struct Hold: Equatable, Sendable {
        /// Measured roll and flex when the start went on the wire.
        var start: [WristAxis: Double]
        /// The remembered lead this hold starts from, per axis.
        var carried: [WristAxis: Double]
        var lastSent: WristTarget?
    }

    private var memory: [WristAxis: Memory] = [:]
    private var hold: Hold?

    public init() {}

    /// The lead remembered for `axis` from the last wrist hold, while it still applies.
    public func rememberedLead(_ axis: WristAxis) -> Double? { memory[axis]?.lead }

    /// A wrist hold's `orient_start` went on the wire. `measured`: the newest measured angles.
    public mutating func holdStarted(measured: WristReadings) {
        var start: [WristAxis: Double] = [:]
        var carried: [WristAxis: Double] = [:]
        for axis in [WristAxis.turn, .tilt] {
            guard let now = Self.angle(axis, measured) else { continue }
            start[axis] = now
            // The kept lead is still the server's only while the wrist has not moved since that hold ended.
            if let kept = memory[axis], abs(now - kept.measuredAtEnd) <= memoryDeg {
                carried[axis] = kept.lead
            } else {
                memory[axis] = nil
            }
        }
        hold = Hold(start: start, carried: carried, lastSent: nil)
    }

    /// The value to send for `target`. `measured`: the newest measured angles; `ageMs`: how long ago they arrived,
    /// nil when none has.
    public mutating func bounded(_ target: WristTarget, measured: WristReadings, ageMs: Int?) -> WristTarget {
        guard var current = hold, let axis = target.axis, let start = current.start[axis],
            let now = Self.angle(axis, measured)
        else {
            hold?.lastSent = target
            return target
        }
        let base = start + (current.carried[axis] ?? 0)
        let allowance: Double
        if let ageMs, ageMs <= freshStateMs {
            allowance = leadDeg + rateMaxDegS * Double(max(0, ageMs)) / 1000
        } else {
            // No fresh state: the command may come back toward the wrist, never move further from it.
            let last = current.lastSent.flatMap { $0.axis == axis ? $0.degrees : nil } ?? 0
            allowance = abs(base + last - now)
        }
        let commanded = min(max(base + target.degrees, now - allowance), now + allowance)
        let sent = WristTarget(axis: axis, degrees: commanded - base)
        current.lastSent = sent
        hold = current
        return sent
    }

    /// The hold's stop went out. The lead left on its axis is remembered for the next hold.
    public mutating func holdEnded(measured: WristReadings) {
        defer { hold = nil }
        guard let current = hold, let sent = current.lastSent, let axis = sent.axis,
            let start = current.start[axis], let now = Self.angle(axis, measured)
        else { return }
        let commanded = start + (current.carried[axis] ?? 0) + sent.degrees
        memory[axis] = Memory(lead: commanded - now, measuredAtEnd: now)
    }

    /// A reset writes the default pose into every wrist target, so no lead is left.
    public mutating func sceneReset() {
        memory = [:]
    }

    private static func angle(_ axis: WristAxis, _ readings: WristReadings) -> Double? {
        axis == .turn ? readings.rollDeg : readings.flexDeg
    }
}
