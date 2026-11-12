import simd
import XCTest
@testable import TeleopCore

/// Drives an `InputArbiter` on the reference device (402 × 874 pt, 6.4 pt per mm) with a clock that only moves
/// when a step says so. Every step returns the commands it produced.
struct ArbiterRig {
    static let layout = SurfaceLayout(width: 402, height: 874, safeTop: 62, safeBottom: 34)
    /// Points on the reference screen.
    static let middle = SIMD2<Double>(201, 440)
    static let rightHalf = SIMD2<Double>(300, 440)
    static let leftHalf = SIMD2<Double>(100, 440)
    static let topBand = SIMD2<Double>(201, 90)
    static let gear = SIMD2<Double>(30, 90)
    static let bottomBand = SIMD2<Double>(201, 820)
    static let gap = SIMD2<Double>(201, 760)
    static let pointsPerMm = 6.4

    var arbiter: InputArbiter
    var time: TimeInterval = 10
    var facts = InputFacts()
    var log: [InputCommand] = []
    var turn = 0.0
    var tilt = 0.0
    private var points: [Int: SIMD2<Double>] = [:]
    private var radii: [Int: Double] = [:]

    init(_ scheme: InputScheme, hand: Hand = .right, constants: InputConstants = .appendixA) {
        arbiter = InputArbiter(scheme: scheme, hand: hand, layout: Self.layout, constants: constants)
        send(.attitude(Phone.rest))
    }

    @discardableResult
    mutating func send(_ event: InputEvent, after dt: TimeInterval = 0) -> [InputCommand] {
        batch([event], after: dt)
    }

    @discardableResult
    mutating func batch(_ events: [InputEvent], after dt: TimeInterval = 0) -> [InputCommand] {
        time += dt
        let commands = arbiter.handle(events, at: time, facts: facts)
        log += commands
        return commands
    }

    @discardableResult
    mutating func press(_ key: InputKey, after dt: TimeInterval = 0) -> [InputCommand] {
        send(.keyDown(key), after: dt)
    }

    @discardableResult
    mutating func release(_ key: InputKey, after dt: TimeInterval = 0) -> [InputCommand] {
        send(.keyUp(key), after: dt)
    }

    @discardableResult
    mutating func wait(_ dt: TimeInterval) -> [InputCommand] { send(.tick, after: dt) }

    func sample(_ id: Int, _ phase: TouchSample.Phase, _ p: SIMD2<Double>, radius: Double) -> InputEvent {
        .touch(TouchSample(id: id, phase: phase, x: p.x, y: p.y, majorRadius: radius))
    }

    @discardableResult
    mutating func touchDown(_ id: Int, at p: SIMD2<Double>, radius: Double = 8, after dt: TimeInterval = 0)
        -> [InputCommand]
    {
        points[id] = p
        radii[id] = radius
        return send(sample(id, .began, p, radius: radius), after: dt)
    }

    /// Moves the touch to `p` in one sample.
    @discardableResult
    mutating func move(_ id: Int, to p: SIMD2<Double>, radius: Double? = nil, after dt: TimeInterval = 0)
        -> [InputCommand]
    {
        points[id] = p
        if let radius { radii[id] = radius }
        return send(sample(id, .moved, p, radius: radii[id] ?? 8), after: dt)
    }

    /// Slides the touch `mm` millimetres at `degrees` (0 = right, 90 = up the glass) as continuous 1 mm moves,
    /// `dt` apart.
    @discardableResult
    mutating func slide(_ id: Int, mm: Double, degrees: Double, dt: TimeInterval = 0.01) -> [InputCommand] {
        let direction = SIMD2(cos(degrees * .pi / 180), -sin(degrees * .pi / 180)) * Self.pointsPerMm
        let start = points[id]!
        var commands: [InputCommand] = []
        var travelled = 0.0
        while travelled < mm - 1e-9 {
            travelled = min(mm, travelled + 1)
            commands += move(id, to: start + direction * travelled, after: dt)
        }
        return commands
    }

    @discardableResult
    mutating func lift(_ id: Int, after dt: TimeInterval = 0) -> [InputCommand] {
        let p = points.removeValue(forKey: id) ?? .zero
        return send(sample(id, .ended, p, radius: radii.removeValue(forKey: id) ?? 8), after: dt)
    }

    /// Sets the phone to this turn and tilt from rest in one sample.
    @discardableResult
    mutating func orient(turn: Double? = nil, tilt: Double? = nil, after dt: TimeInterval = 0) -> [InputCommand] {
        if let turn { self.turn = turn }
        if let tilt { self.tilt = tilt }
        return send(.attitude(attitude), after: dt)
    }

    var attitude: simd_quatd { Phone.attitude(turn: turn, tilt: tilt) }

    /// Turns the phone gradually to the given angles in `steps` samples, `dt` apart.
    @discardableResult
    mutating func rotate(turn: Double? = nil, tilt: Double? = nil, steps: Int = 10, dt: TimeInterval = 1.0 / 60)
        -> [InputCommand]
    {
        let from = (self.turn, self.tilt)
        let to = (turn ?? self.turn, tilt ?? self.tilt)
        var commands: [InputCommand] = []
        for i in 1...steps {
            let f = Double(i) / Double(steps)
            commands += orient(turn: from.0 + (to.0 - from.0) * f, tilt: from.1 + (to.1 - from.1) * f, after: dt)
        }
        return commands
    }

    func phase(_ input: HeldInput) -> InputPhase? { arbiter.held[input] }
}

extension Array where Element == InputCommand {
    /// Everything but wrist targets.
    var withoutUpdates: [InputCommand] { filter { if case .wristUpdate = $0 { return false } else { return true } } }
    var wristTargets: [WristTarget] { compactMap { if case .wristUpdate(let t) = $0 { return t } else { return nil } } }
    var cues: [InputCue] { compactMap { if case .cue(let c) = $0 { return c } else { return nil } } }
}
