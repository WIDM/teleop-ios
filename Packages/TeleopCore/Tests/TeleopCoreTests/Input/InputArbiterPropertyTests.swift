import simd
import XCTest
@testable import TeleopCore

/// C-I2: generated interleavings of keys and touches pressed within 0 to 100 ms of each other and released in every
/// order, with the phone turning, under both platform deliveries of a second key. Whatever happens:
/// never two engaged holds (the reset countdown counts), a dead input never wakes, every start has exactly one stop,
/// and nothing starts with no input down. And nothing ever comes of a touch that begins in the bottom safe area, even
/// one that slides up into the band, the gap or the control surface: a twin arbiter that gets a tick in place of
/// each of its samples answers every step the same way and holds the same inputs.
final class InputArbiterPropertyTests: XCTestCase {
    static let cases = 12_000

    func testGeneratedInterleavingsKeepTheFirstPressWinsPromises() {
        var rng = SplitMix64(seed: 0x7E1E_0B5)
        var totals = Totals()
        for index in 0..<Self.cases {
            let scenario = Scenario.generate(&rng, index: index)
            if let failure = run(scenario, totals: &totals) {
                XCTFail("case \(index) (\(scenario.summary)): \(failure)")
                return
            }
        }
        // The generator must actually reach the situations the promises are about.
        XCTAssertGreaterThan(totals.starts, Self.cases / 2)
        XCTAssertGreaterThan(totals.deadInputs, Self.cases / 4)
        XCTAssertGreaterThan(totals.wristStarts, 200)
        XCTAssertGreaterThan(totals.gripperTouchStarts, 200)
        XCTAssertGreaterThan(totals.countdowns, 50)
        XCTAssertGreaterThan(totals.refusals, 100)
        XCTAssertGreaterThan(totals.palmSamples, 1000)
        XCTAssertGreaterThan(totals.safeAreaTouches, 400)
        XCTAssertGreaterThan(totals.safeAreaTouchesLeavingIt, 100)
        XCTAssertGreaterThan(totals.safeAreaTouchesDuringAHold, 50)
    }

    struct Totals {
        var starts = 0, wristStarts = 0, gripperTouchStarts = 0, deadInputs = 0, countdowns = 0, refusals = 0
        /// Touch samples as wide as a palm.
        var palmSamples = 0
        /// Touches that began in the bottom safe area; of them, those that slid out of it, and those that began while
        /// a hold was engaged.
        var safeAreaTouches = 0, safeAreaTouchesLeavingIt = 0, safeAreaTouchesDuringAHold = 0
    }

    private func run(_ scenario: Scenario, totals: inout Totals) -> String? {
        var arbiter = InputArbiter(scheme: scenario.scheme, hand: scenario.hand, layout: ArbiterRig.layout)
        var twin = arbiter
        var safeAreaTouches = Set<Int>()
        var leftTheSafeArea = Set<Int>()
        var open: HoldKind?
        var countdown = false
        var down = Set<HeldInput>()
        var everDead = Set<HeldInput>()
        var touchKinds: [Int: Bool] = [:]

        for step in scenario.timeline {
            let downBefore = down
            if case .touch(let s) = step.event, s.majorRadius >= arbiter.constants.palmRadiusPt {
                totals.palmSamples += 1
            }
            switch step.event {
            case .keyDown(let key): down.insert(.key(key))
            case .keyUp(let key): down.remove(.key(key))
            case .touch(let s) where s.phase == .began: down.insert(.touch(s.id))
            case .touch(let s) where s.phase == .ended || s.phase == .cancelled: down.remove(.touch(s.id))
            default: break
            }
            var twinEvent = step.event
            if case .touch(let s) = step.event {
                let zone = ArbiterRig.layout.zone(x: s.x, y: s.y)
                if s.phase == .began, zone == .bottomSafeArea {
                    safeAreaTouches.insert(s.id)
                    totals.safeAreaTouches += 1
                    if open != nil { totals.safeAreaTouchesDuringAHold += 1 }
                }
                if safeAreaTouches.contains(s.id) {
                    twinEvent = .tick
                    if zone != .bottomSafeArea, leftTheSafeArea.insert(s.id).inserted {
                        totals.safeAreaTouchesLeavingIt += 1
                    }
                }
            }
            let facts = scenario.facts(at: step.time)
            let commands = arbiter.handle(step.event, at: step.time, facts: facts)
            let twinCommands = twin.handle(twinEvent, at: step.time, facts: facts)
            if commands != twinCommands {
                return "\(step.event) at \(step.time) gave \(commands); without the strip's touches, \(twinCommands)"
            }
            if arbiter.held != twin.held { return "a touch from the bottom safe area is held at \(step.time)" }
            var startedHere: HoldKind?
            var stoppedAfterStart = false
            for command in commands {
                switch command {
                case .startTranslation, .startGripper, .startWrist:
                    let kind = Self.kind(of: command)
                    if let open { return "\(command) while \(open) is engaged at \(step.time)" }
                    if countdown { return "\(command) during the reset countdown at \(step.time)" }
                    if downBefore.isEmpty, down.isEmpty { return "\(command) with no input down at \(step.time)" }
                    open = kind
                    startedHere = kind
                    totals.starts += 1
                    if kind == .wrist { totals.wristStarts += 1 }
                case .stopTranslation, .stopGripper, .stopWrist:
                    guard let current = open else { return "\(command) with nothing engaged at \(step.time)" }
                    if !Self.stop(command, ends: current) { return "\(command) ends \(current)" }
                    if startedHere != nil { stoppedAfterStart = true }
                    open = nil
                case .wristUpdate:
                    if open != .wrist { return "wrist update with \(String(describing: open)) engaged" }
                case .resetCountdownStarted:
                    if open != nil || countdown { return "countdown while engaged" }
                    countdown = true
                    totals.countdowns += 1
                case .resetCountdownCancelled, .fireReset:
                    if !countdown { return "\(command) without a countdown" }
                    countdown = false
                case .cue(.refused), .cue(.alreadyGripping):
                    totals.refusals += 1
                case .cue, .emergencyStop, .openSettings:
                    break
                }
            }

            let held = arbiter.held
            // The engaged input is one that is down, unless the same event let it go.
            if let started = startedHere, !stoppedAfterStart {
                let engaged = held.filter { $0.value == .engaged(started) }
                guard engaged.count == 1, let input = engaged.first?.key else {
                    return "\(started) started but \(engaged.count) inputs report it at \(step.time)"
                }
                if !down.contains(input) { return "\(input) engaged but not down" }
                if everDead.contains(input) { return "dead \(input) woke as \(started) at \(step.time)" }
                if case .touch(let id) = input, case .gripper = started, touchKinds[id] == nil {
                    touchKinds[id] = true
                    totals.gripperTouchStarts += 1
                }
            }
            let engagedCount = held.values.filter {
                if case .engaged = $0 { return true } else { return $0 == .countingDown }
            }.count
            if engagedCount > 1 { return "\(engagedCount) inputs engaged at \(step.time)" }
            for input in everDead where held[input] != nil && held[input] != .dead {
                return "dead \(input) is \(held[input]!) at \(step.time)"
            }
            for (input, phase) in held where phase == .dead && !everDead.contains(input) {
                everDead.insert(input)
                totals.deadInputs += 1
            }
            everDead = everDead.filter { down.contains($0) }
            if held.keys.contains(where: { !down.contains($0) }) { return "a released input is still held" }
        }
        if let open { return "\(open) never stopped" }
        if countdown { return "countdown never ended" }
        if !arbiter.held.isEmpty { return "inputs still held after every release: \(arbiter.held)" }
        return nil
    }

    private static func kind(of command: InputCommand) -> HoldKind {
        switch command {
        case .startTranslation: return .translation
        case .startGripper(let action): return .gripper(action)
        default: return .wrist
        }
    }

    private static func stop(_ command: InputCommand, ends kind: HoldKind) -> Bool {
        switch (command, kind) {
        case (.stopTranslation, .translation), (.stopGripper, .gripper), (.stopWrist, .wrist): return true
        default: return false
        }
    }
}

/// One generated case: what is pressed where and when, how the phone turns, what the facts say.
struct Scenario {
    struct Step { var time: TimeInterval; var order: Int; var event: InputEvent }

    enum KeyDelivery: CaseIterable { case every, secondDropped, secondReplayedAtRelease }

    var scheme: InputScheme
    var hand: Hand
    var delivery: KeyDelivery
    var timeline: [Step]
    var baseFacts: InputFacts
    var factChangeAt: TimeInterval
    var changedFacts: InputFacts

    func facts(at time: TimeInterval) -> InputFacts { time < factChangeAt ? baseFacts : changedFacts }

    var summary: String { "\(scheme) \(hand) \(delivery), \(timeline.count) steps" }

    static func generate(_ rng: inout SplitMix64, index: Int) -> Scenario {
        let scheme: InputScheme = rng.chance(0.5) ? .screenTurns : .keyTurns
        let hand: Hand = rng.chance(0.8) ? .right : .left
        let delivery = KeyDelivery.allCases[Int(rng.next() % 3)]
        var steps: [Step] = []
        var order = 0
        func add(_ time: TimeInterval, _ event: InputEvent) {
            steps.append(Step(time: time, order: order, event: event))
            order += 1
        }
        let long = rng.chance(0.15)
        let span = long ? 2.6 : 0.6

        // Keys: physical presses, then what the platform delivers.
        var keyPresses: [(key: InputKey, down: Double, up: Double)] = []
        for key in [InputKey.upper, .lower] where rng.chance(0.55) {
            let down = rng.uniform(0, 0.1)
            keyPresses.append((key, down, down + rng.uniform(0, long ? 2.4 : 0.45)))
        }
        keyPresses.sort { $0.down < $1.down }
        if keyPresses.count == 2, keyPresses[1].down < keyPresses[0].up, delivery != .every {
            let first = keyPresses[0], second = keyPresses[1]
            add(first.down, .keyDown(first.key))
            add(first.up, .keyUp(first.key))
            if delivery == .secondReplayedAtRelease, second.up > first.up {
                add(first.up, .keyDown(second.key))
                add(second.up, .keyUp(second.key))
            }
        } else {
            for press in keyPresses {
                add(press.down, .keyDown(press.key))
                add(press.up, .keyUp(press.key))
            }
        }

        // Touches: anywhere on the screen, some still, some sliding in 1 mm steps, some growing into a palm.
        let touchCount = Int(rng.next() % 4)
        for n in 0..<touchCount {
            let id = index * 10 + n + 1
            let point = randomPoint(&rng)
            let down = rng.uniform(0, 0.1)
            let up = down + rng.uniform(0, long ? 2.5 : 0.5)
            var radius = rng.chance(0.1) ? rng.uniform(91, 130) : rng.uniform(4, 85)
            add(down, .touch(TouchSample(id: id, phase: .began, x: point.x, y: point.y, majorRadius: radius)))
            var at = point
            var t = down
            if rng.chance(0.6) {
                let degrees = rng.chance(0.4) ? 90 + rng.uniform(-30, 30) : rng.uniform(0, 360)
                let step = SIMD2(cos(degrees * .pi / 180), -sin(degrees * .pi / 180)) * ArbiterRig.pointsPerMm
                let start = down + rng.uniform(0, 0.25)
                let interval = rng.uniform(0.002, 0.015)
                t = start
                for _ in 0..<Int(rng.next() % 20) {
                    t += interval
                    guard t < up else { break }
                    at += step
                    if rng.chance(0.03) { radius = rng.uniform(85, 130) }
                    add(t, .touch(TouchSample(id: id, phase: .moved, x: at.x, y: at.y, majorRadius: radius)))
                }
            }
            let phase: TouchSample.Phase = rng.chance(0.1) ? .cancelled : .ended
            add(up, .touch(TouchSample(id: id, phase: phase, x: at.x, y: at.y, majorRadius: radius)))
        }

        // The phone turns and tilts toward a few random targets, at 60 Hz.
        var turn = 0.0, tilt = 0.0
        var targetTurn = rng.uniform(-15, 15), targetTilt = rng.uniform(-15, 15)
        var time = 0.0
        while time < span {
            if rng.chance(0.05) {
                targetTurn = rng.uniform(-60, 60)
                targetTilt = rng.uniform(-25, 25)
            }
            turn += (targetTurn - turn) * 0.1
            tilt += (targetTilt - tilt) * 0.1
            add(time, .attitude(Phone.attitude(turn: turn, tilt: tilt)))
            time += 1.0 / 60
        }
        for tick in stride(from: 0.0, through: span + 0.6, by: 1.0 / 30) { add(tick, .tick) }
        if rng.chance(0.08) { add(rng.uniform(0, span), .endAllHolds) }
        if rng.chance(0.04) { add(rng.uniform(0, span), .becameActive) }
        if rng.chance(0.03) {
            add(rng.uniform(0, span), .modeChanged(scheme == .screenTurns ? .keyTurns : .screenTurns, hand))
        }
        if rng.chance(0.05) { add(rng.uniform(0, span), .wristStartSent) }
        if rng.chance(0.03) { add(rng.uniform(0, span), .sceneReset) }

        steps.sort { ($0.time, $0.order) < ($1.time, $1.order) }
        return Scenario(
            scheme: scheme, hand: hand, delivery: delivery, timeline: steps,
            baseFacts: randomFacts(&rng), factChangeAt: rng.uniform(0, span), changedFacts: randomFacts(&rng)
        )
    }

    private static func randomPoint(_ rng: inout SplitMix64) -> SIMD2<Double> {
        let layout = ArbiterRig.layout
        let roll = rng.uniform(0, 1)
        let y: Double
        switch roll {
        case ..<0.1: y = rng.uniform(0, layout.topBand.maxY - 0.01)
        case ..<0.15: y = rng.uniform(layout.bottomBand.y, layout.bottomBand.maxY - 0.01)
        case ..<0.18: y = rng.uniform(layout.gap.y, layout.gap.maxY - 0.01)
        case ..<0.22: y = rng.uniform(layout.bottomSafeArea.y, layout.height - 0.01)
        default: y = rng.uniform(layout.controlSurface.y, layout.controlSurface.maxY - 0.01)
        }
        let x = roll < 0.04 ? rng.uniform(0, 56) : rng.uniform(0, layout.width)
        return SIMD2(x, y)
    }

    private static func randomFacts(_ rng: inout SplitMix64) -> InputFacts {
        let refusals: [InputRefusal] = [.noLink, .stopped, .wait, .slowLink, .settingsOpen, .tooHot, .resetFirst]
        return InputFacts(
            refusal: rng.chance(0.12) ? refusals[Int(rng.next() % UInt64(refusals.count))] : nil,
            trackingRefusal: rng.chance(0.06) ? .notTracking : nil,
            translationRefusal: rng.chance(0.04) ? .posture : nil,
            resetRefusal: rng.chance(0.1) ? .wait : nil,
            gripping: rng.chance(0.3),
            wrist: rng.chance(0.5)
                ? WristReadings(rollDeg: rng.uniform(-170, 170), flexDeg: rng.uniform(-40, 40), flexAtResetDeg: 0)
                : .unknown,
            connectionUp: rng.chance(0.9)
        )
    }
}
