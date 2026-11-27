import simd
import XCTest
@testable import TeleopCore

extension ArbiterRig {
    /// A rig whose arbiter has these aids. With `.off` it is exactly `ArbiterRig(scheme)`.
    init(_ scheme: InputScheme, hand: Hand = .right, assist: Assist) {
        self.init(scheme, hand: hand)
        arbiter = InputArbiter(scheme: scheme, hand: hand, layout: Self.layout, assist: assist)
        send(.attitude(Phone.rest))
    }

    /// Lock, variant 1, with the SO-101's 30 s limit unless another is given.
    static func lockPressPress(limit: Double = 30) -> Assist {
        Assist(lock: LockRule(variant: .pressPress, timeLimitS: limit))
    }

    /// Lock, variant 2, with the SO-101's 30 s limit unless another is given.
    static func lockHoldSlide(limit: Double = 30) -> Assist {
        Assist(lock: LockRule(variant: .holdThenSlide, timeLimitS: limit))
    }

    /// Variant 1: a press of the upper key latches; it is released at once.
    @discardableResult
    mutating func latchByPress(after dt: TimeInterval = 0) -> [InputCommand] {
        press(.upper, after: dt) + release(.upper)
    }

    /// The drive cues among `commands`.
    static func drives(_ commands: [InputCommand]) -> [DriveCue] {
        commands.cues.compactMap { if case .drive(let cue) = $0 { return cue } else { return nil } }
    }

    var isLatched: Bool {
        if case .latched? = arbiter.engagement { return true }
        return false
    }

    // MARK: Tap-to-go

    /// The SO-101 simulator's go numbers (the core tests cannot reach `RobotProfile`).
    static let goLimits = GoToLimits(
        travelHeightM: 0.05, speedMps: 0.04, arriveToleranceM: 0.008, corrections: 2, correctionReachM: 0.03,
        settleS: 0.6, timeFactor: 1.5, allowanceS: 3, armDataTimeoutS: 2, startGraceS: 1.5)

    /// Tap-to-go with these numbers, and lock when it is given.
    static func goTo(_ limits: GoToLimits = goLimits, lock: LockRule? = nil) -> Assist {
        Assist(lock: lock, goTo: limits)
    }

    /// The SO-101 simulator's work box, robot base frame, pinch point, and its table height, metres.
    static let boxLow = SIMD3(-0.052383, -0.257418, -0.008015)
    static let boxHigh = SIMD3(0.107617, -0.097418, 0.151985)
    static let table = 0.04
    /// Where a tap sends the pinch point's height: the table plus the travel height.
    static let travelZ = table + goLimits.travelHeightM

    /// About where the reference phone draws the SO-101 guide's view from above. Its centre is on the middle line, so
    /// scheme B's centre band (x 177 to 225) runs through it; `middle` and the two halves lie below it.
    static let panelRect = SurfaceLayout.Rect(x: 118, y: 262, width: 166, height: 166)

    /// The view from above drawn in `rect`, of the SO-101 box moved by `shift`, as the app builds it from the guide.
    static func panel(_ rect: SurfaceLayout.Rect = panelRect, shift: SIMD3<Double> = .zero) -> GoPanel {
        let low = boxLow + shift, high = boxHigh + shift
        let a = TestFrames.so101.operatorPoint(low), b = TestFrames.so101.operatorPoint(high)
        let projection = GuideProjection(
            frames: TestFrames.so101, boxLow: simd_min(a, b), boxHigh: simd_max(a, b), table: table)
        return GoPanel(
            rect: rect, projection: projection, boxLow: simd_min(low, high), boxHigh: simd_max(low, high),
            tableHeight: table)
    }

    /// A point of the panel's rectangle, by its shares across and down.
    static func inPanel(_ across: Double, _ down: Double, _ rect: SurfaceLayout.Rect = panelRect) -> SIMD2<Double> {
        SIMD2(rect.x + across * rect.width, rect.y + down * rect.height)
    }

    /// Where a tap at `p` sends the pinch point.
    static func target(of p: SIMD2<Double>, on panel: GoPanel = panel()) -> SIMD3<Double> {
        panel.target(x: p.x, y: p.y, travelHeight: goLimits.travelHeightM)
    }

    /// The facts with a panel drawn and the arm measured at `pinch`, `ageS` ago.
    static func goFacts(
        panel: GoPanel? = panel(), arm pinch: SIMD3<Double>?, ageS: Double = 0.1, paused: Bool = false
    ) -> InputFacts {
        InputFacts(arm: pinch.map { ArmFix(pinch: $0, ageS: ageS, holdPaused: paused) }, goPanel: panel)
    }

    /// A tap: down at `p`, lifted `dt` later where it went down. Returns what the lift did.
    @discardableResult
    mutating func tap(_ id: Int, at p: SIMD2<Double>, lastingS dt: TimeInterval = 0.08, after: TimeInterval = 0)
        -> [InputCommand]
    {
        touchDown(id, at: p, after: after)
        return lift(id, after: dt)
    }

    var isGoing: Bool {
        if case .going? = arbiter.engagement { return true }
        return false
    }

    /// The pinch point the going move commands now, robot base frame: where it began plus the offset it streams.
    func commanded(from start: SIMD3<Double>) -> SIMD3<Double>? {
        arbiter.goOffset(at: time).map { start + TestFrames.so101.base(fromLink: $0) }
    }
}
