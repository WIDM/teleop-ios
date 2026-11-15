import simd
import XCTest
@testable import TeleopCore

/// Generated interleavings with the aids. `InputArbiterPropertyTests` keeps asserting the 1.0.1 promises on `.off`
/// from its own unchanged file; this one generates the aided configurations (one case in five is `.off`, so every new
/// statement also holds on 1.0.1), restates the 1.0.1 promises where they still hold, checks the new ones after every
/// step, and compares every case with an `.off` twin up to the first new gesture. A failure names the statement by
/// its id.
final class AssistPropertyTests: XCTestCase {
    static let cases = 12_000

    func testGeneratedInterleavingsWithTheAidsKeepEveryPromise() {
        var rng = SplitMix64(seed: 0xA551_57)
        var totals = Totals()
        for index in 0..<Self.cases {
            let scenario = AssistScenario.generate(&rng, index: index)
            if let failure = run(scenario, totals: &totals) {
                XCTFail("case \(index) (\(scenario.summary)): \(failure)")
                return
            }
        }
        // The generator must reach what the statements are about.
        XCTAssertGreaterThan(totals.offCases, Self.cases / 7)
        XCTAssertGreaterThan(totals.pressLatches, 1000)
        XCTAssertGreaterThan(totals.lockLimits, 50)
        for (reason, count) in zip(AssistScenario.reasons, totals.reasonsWhileLoose) {
            XCTAssertGreaterThan(count, 30, "\(reason) on a move nobody holds")
        }
        XCTAssertGreaterThan(totals.stopsWhileLoose, 100)
        XCTAssertGreaterThan(totals.stopsAfterALatchInTheStep, 50)
        XCTAssertGreaterThan(totals.inputsHeldAcrossALooseStart, 100)
        XCTAssertGreaterThan(totals.casesWithWaitWhileLoose, 50)
    }

    struct Totals {
        var offCases = 0
        var pressLatches = 0
        var lockLimits = 0
        /// `.holdsEnded` of each reason, in `AssistScenario.reasons` order, while a move nobody holds ran.
        var reasonsWhileLoose = [Int](repeating: 0, count: AssistScenario.reasons.count)
        var stopsWhileLoose = 0
        var stopsAfterALatchInTheStep = 0
        /// Inputs other than the latching key that were down when a move nobody holds began.
        var inputsHeldAcrossALooseStart = 0
        var casesWithWaitWhileLoose = 0
    }

    // MARK: One case

    /// The first broken promise of one case, or nil. The statements are tests.md (a) and (b), under their ids.
    private func run(_ scenario: AssistScenario, totals: inout Totals) -> String? {
        let base = scenario.base
        var arbiter = InputArbiter(
            scheme: base.scheme, hand: base.hand, layout: ArbiterRig.layout, assist: scenario.assist)
        // P-ON: the same events on 1.0.1, until the first new gesture.
        var twin: InputArbiter? = InputArbiter(scheme: base.scheme, hand: base.hand, layout: ArbiterRig.layout)
        // O9: the same events with every sample of a touch that began in the bottom safe area turned into a tick.
        var strip: InputArbiter? = scenario.safeAreaTouches.isEmpty ? nil : arbiter
        if scenario.assist == .off { totals.offCases += 1 }

        var open: HoldKind?
        var countdown = false
        var down = Set<HeldInput>()
        var everDead = Set<HeldInput>()
        // P9 and P17: inputs that ended a move nobody holds, or were down when one began, until released.
        var silenced = Set<HeldInput>()
        var lastHeld: [HeldInput: InputPhase] = [:]
        var sawWaitWhileLoose = false

        for step in scenario.steps {
            func at() -> String { "at \(step.time), \(step.events)" }
            let facts = scenario.facts(at: step.time)
            let engagementBefore = arbiter.engagement
            let limitBefore = arbiter.assist.lock?.timeLimitS ?? 0
            let downBefore = down
            // The arbiter as it was, kept only for the steps P9, P14 and P17 replay another way.
            let silencedEvents =
                silenced.isEmpty ? [] : step.events.indices.filter { Self.isEvent(step.events[$0], of: silenced) }
            var replaysUnnamed = false
            if step.events.count == 1, case .holdsEnded(let reason) = step.events[0], reason != .unnamed,
                engagementBefore?.isLoose != true
            {
                replaysUnnamed = true
            }
            let before: InputArbiter? = silencedEvents.isEmpty && !replaysUnnamed ? nil : arbiter
            for event in step.events {
                switch event {
                case .keyDown(let key): down.insert(.key(key))
                case .keyUp(let key): down.remove(.key(key))
                case .touch(let s) where s.phase == .began: down.insert(.touch(s.id))
                case .touch(let s) where s.phase == .ended || s.phase == .cancelled: down.remove(.touch(s.id))
                default: break
                }
            }
            let commands = arbiter.handle(step.events, at: step.time, facts: facts)
            let held = arbiter.held
            let engagement = arbiter.engagement
            let drives = commands.isEmpty ? [] : ArbiterRig.drives(commands)
            let latchedHere = drives.contains(.latched)

            // O9
            // The twins are run in place: the arbiter is a large value, and copying it every step costs more than the
            // checks.
            if strip != nil {
                let events = step.events.map { event -> InputEvent in
                    if case .touch(let s) = event, scenario.safeAreaTouches.contains(s.id) { return .tick }
                    return event
                }
                let otherCommands = strip!.handle(events, at: step.time, facts: facts)
                if otherCommands != commands {
                    return "O9: \(commands), without the strip's touches \(otherCommands) \(at())"
                }
                if strip!.held != held { return "O9: a touch from the bottom safe area is held \(at())" }
            }

            // P-ON
            if twin != nil {
                var events = step.events
                for (i, event) in events.enumerated() {
                    if case .assistChanged = event { events[i] = .assistChanged(.off) }
                }
                let offCommands = twin!.handle(events, at: step.time, facts: facts)
                let offHeld = twin!.held
                if offCommands != commands || offHeld != held {
                    if scenario.assist == .off { return "P-ON: .off gave \(commands), 1.0.1 \(offCommands) \(at())" }
                    if !Self.isNewGesture(on: commands, off: offCommands) {
                        return "P-ON: first difference \(commands), off \(offCommands) \(at())"
                    }
                    for input in Set(held.keys).union(offHeld.keys) where held[input] != offHeld[input] {
                        let upper = input == .key(.upper) && offHeld[input] == .engaged(.translation)
                        let downAtTheStart = latchedHere && downBefore.contains(input)
                        if held[input] != .dead || !(upper || downAtTheStart) {
                            return "P-ON: \(input) is \(String(describing: held[input])), off "
                                + "\(String(describing: offHeld[input])) \(at())"
                        }
                    }
                    twin = nil
                }
            }

            // O2, O3, O4, O10, and every start with one stop (O7, to the end)
            var startedHere: HoldKind?
            var stoppedAfterStart = false
            var translationStarts = 0
            var translationStops = 0
            for command in commands {
                if command == .startTranslation { translationStarts += 1 }
                if command == .stopTranslation { translationStops += 1 }
                switch command {
                case .startTranslation, .startGripper, .startWrist:
                    let kind = Self.kind(of: command)
                    if let open { return "\(command) while \(open) is engaged \(at())" }
                    if countdown { return "O2: \(command) during the reset countdown \(at())" }
                    if downBefore.isEmpty, down.isEmpty { return "O3: \(command) with no input down \(at())" }
                    open = kind
                    startedHere = kind
                case .stopTranslation, .stopGripper, .stopWrist:
                    guard let current = open else { return "O7: \(command) with nothing engaged \(at())" }
                    if !Self.stop(command, ends: current) { return "O7: \(command) ends \(current) \(at())" }
                    if startedHere != nil { stoppedAfterStart = true }
                    open = nil
                case .wristUpdate:
                    if open != .wrist { return "O10: wrist update with \(String(describing: open)) engaged \(at())" }
                case .resetCountdownStarted:
                    if open != nil || countdown { return "O10: countdown while engaged \(at())" }
                    countdown = true
                case .resetCountdownCancelled, .fireReset:
                    if !countdown { return "O10: \(command) without a countdown \(at())" }
                    countdown = false
                case .cue, .emergencyStop, .openSettings:
                    break
                }
            }
            if let started = startedHere, !stoppedAfterStart, case .held(let input, _)? = engagement {
                let engaged = held.filter { $0.value == .engaged(started) }
                if engaged.count != 1 || engaged.first?.key != input {
                    return "O4: \(started) started but \(engaged.count) inputs report it \(at())"
                }
                if !down.contains(input) { return "O4: \(input) engaged but not down \(at())" }
                if everDead.contains(input) { return "O4: dead \(input) woke as \(started) \(at())" }
            }

            // P1, P2, P3
            var engagedInputs: [(input: HeldInput, phase: InputPhase)] = []
            for (input, phase) in held {
                switch phase {
                case .engaged, .countingDown: engagedInputs.append((input, phase))
                case .waiting, .dead: break
                }
            }
            let loose = engagement?.isLoose == true
            let count = engagedInputs.count + (loose ? 1 : 0)
            if count > 1 { return "P1: \(count) things engaged \(at())" }
            if (engagement == nil) != (count == 0) { return "P1: engagement \(String(describing: engagement)) \(at())" }
            switch engagement {
            case .held(let input, let kind)?:
                if held[input] != .engaged(kind) || !down.contains(input) {
                    return "P2: \(input) is \(String(describing: held[input])) for \(kind) \(at())"
                }
            case .countdown(let touch)?:
                if held[.touch(touch)] != .countingDown { return "P2: the countdown's touch is not counting \(at())" }
            case .latched?:
                if !engagedInputs.isEmpty { return "P3: \(engagedInputs) while latched \(at())" }
            case nil:
                break
            }
            for (input, phase) in engagedInputs {
                if case .engaged(let kind) = phase, engagement != .held(input, kind) {
                    return "P2: \(input) reports \(kind), engagement \(String(describing: engagement)) \(at())"
                }
            }

            // P4
            if arbiter.assist.lock == nil, scenario.assist.lock == nil {
                if loose { return "P4: \(String(describing: engagement)) without lock \(at())" }
                if !drives.isEmpty { return "P4: \(drives) without lock \(at())" }
            }
            if commands.contains(.cue(.refused(.outsideWorkArea))) || commands.contains(.cue(.refused(.noArmData))) {
                return "P4: a tap's refusal without tap-to-go \(at())"
            }

            // P5
            if case .latched(let since)? = engagement, engagementBefore?.isLoose != true {
                var idle = engagementBefore == nil
                if case .countdown? = engagementBefore { idle = true }
                let latches = drives.filter { $0 == .latched }.count
                let start = commands.firstIndex(of: .startTranslation)
                guard idle, step.events.contains(.keyDown(.upper)), arbiter.assist.lock?.variant == .pressPress,
                    translationStarts == 1, latches == 1, let start, start + 1 < commands.count,
                    commands[start + 1] == .cue(.drive(.latched)), since == step.time
                else { return "P5: latched from \(String(describing: engagementBefore)) with \(commands) \(at())" }
            }
            if !(engagementBefore?.isLoose == true), drives.contains(where: { $0 != .latched }) || drives.count > 1 {
                return "P8: \(drives) with nothing loose before \(at())"
            }

            // P8
            if case .latched(let since)? = engagementBefore {
                let door =
                    Self.eventDoor(step.events[...])
                    ?? Self.gateDoor(facts: facts, since: since, limit: limitBefore, time: step.time)
                if loose {
                    if let door { return "P8: \(door) did not end it \(at())" }
                    if engagement != engagementBefore { return "P8: became \(String(describing: engagement)) \(at())" }
                    if commands.contains(.stopTranslation) || !drives.isEmpty {
                        return "P8: \(commands) and still loose \(at())"
                    }
                    if facts.refusal == .wait { sawWaitWhileLoose = true }
                } else {
                    guard let door else { return "P8: it ended with no door: \(commands) \(at())" }
                    if translationStops != 1 { return "P8: \(translationStops) stops \(at())" }
                    if drives != door { return "P8: \(drives), its door gives \(door) \(at())" }
                    let stopAt = commands.firstIndex(of: .stopTranslation)!
                    if let cue = door.first, commands.dropFirst(stopAt + 1).first != .cue(.drive(cue)) {
                        return "P8: \(cue) does not follow the stop: \(commands) \(at())"
                    }
                }
                for case .holdsEnded(let reason) in step.events {
                    if let i = AssistScenario.reasons.firstIndex(of: reason) { totals.reasonsWhileLoose[i] += 1 }
                }
            }
            for drive in drives {
                if drive == .latched { totals.pressLatches += 1 }
                if drive == .ended(.timeLimit) { totals.lockLimits += 1 }
            }

            // P10
            if let stopEvent = step.events.firstIndex(where: Self.isStop) {
                if loose { return "P10: still loose after a STOP \(at())" }
                guard let e = commands.firstIndex(of: .emergencyStop) else { return "P10: no STOP sent \(at())" }
                let after = commands[(e + 1)...]
                if after.contains(where: { if case .cue(.drive) = $0 { return true } else { return false } }) {
                    return "P10: a drive cue after the STOP: \(commands) \(at())"
                }
                let beforeStop = ArbiterRig.drives(Array(commands[..<e]))
                if beforeStop.contains(where: { if case .ended = $0 { return true } else { return false } }) {
                    return "P10: an ending ahead of the STOP: \(commands) \(at())"
                }
                let endedBefore = Self.eventDoor(step.events[..<stopEvent]) != nil
                let latchedBefore = beforeStop.contains(.latched)
                let looseAtStop = (engagementBefore?.isLoose == true && !endedBefore) || latchedBefore
                if looseAtStop != after.contains(.stopTranslation) {
                    return "P10: loose at the STOP \(looseAtStop), \(commands) \(at())"
                }
                if looseAtStop { totals.stopsWhileLoose += 1 }
                if latchedBefore { totals.stopsAfterALatchInTheStep += 1 }
            }

            // P11, P12
            if case .latched(let since)? = engagement {
                let limit = arbiter.assist.lock?.timeLimitS ?? 0
                if step.time >= since + limit - 1e-9 { return "P11: latched past its limit \(at())" }
                if facts.trackingRefusal != nil || facts.translationRefusal != nil
                    || (facts.refusal != nil && facts.refusal != .wait)
                {
                    return "P12: latched with \(facts) \(at())"
                }
            }

            // P14
            if replaysUnnamed, var unnamed = before {
                let expected = unnamed.handle([.endAllHolds], at: step.time, facts: facts)
                if expected != commands || unnamed.held != held || unnamed.engagement != engagement {
                    return "P14: \(step.events) gave \(commands), unnamed \(expected) \(at())"
                }
            }

            // P18
            let recorded = arbiter.startsThisCall
            if recorded.count != translationStarts || recorded.contains(where: { $0 != .phone }) {
                return "P18: \(recorded) for \(commands) \(at())"
            }

            // P9, P17: what silenced inputs may not do. First by the events of those inputs, against the same step
            // with those events taken out; then, in a step with only silenced inputs held, by their timers too.
            if !silencedEvents.isEmpty, var without = before {
                var events = step.events
                for i in silencedEvents { events[i] = .tick }
                let expected = Self.forbidden(without.handle(events, at: step.time, facts: facts))
                for (kind, n) in Self.forbidden(commands) where n > expected[kind, default: 0] {
                    return "P9/P17: an input dead and silent gave \(kind) \(at())"
                }
            }
            if !silenced.isEmpty, !commands.isEmpty {
                let fresh = step.events.contains {
                    switch $0 {
                    case .keyDown: return true
                    case .touch(let s): return s.phase == .began
                    default: return false
                    }
                }
                let quiet = Set(lastHeld.keys).union(held.keys)
                if !fresh, !quiet.isEmpty, quiet.isSubset(of: silenced),
                    let kind = Self.forbidden(commands).keys.first
                {
                    return "P9/P17: \(kind) with only dead and silent inputs held \(at())"
                }
            }
            if engagementBefore?.isLoose == true, !loose, let ender = Self.inputDoor(step.events) {
                if startedHere != nil { return "P9: the input that ended it started \(commands) \(at())" }
                if down.contains(ender) { silenced.insert(ender) }
            }
            if latchedHere {
                for (input, phase) in held {
                    if phase != .dead { return "P17: \(input) is \(phase) as the follow begins \(at())" }
                    silenced.insert(input)
                    if input != .key(.upper) { totals.inputsHeldAcrossALooseStart += 1 }
                }
            }
            for input in silenced where held[input] != nil && held[input] != .dead {
                return "P9/P17: \(input) is \(held[input]!) \(at())"
            }

            // O5, O6
            for input in everDead where held[input] != nil && held[input] != .dead {
                return "O5: dead \(input) is \(held[input]!) \(at())"
            }
            for (input, phase) in held where phase == .dead { everDead.insert(input) }
            // Released inputs leave both sets.
            if !everDead.isEmpty { everDead = everDead.filter { down.contains($0) } }
            if !silenced.isEmpty { silenced = silenced.filter { down.contains($0) } }
            if held.keys.contains(where: { !down.contains($0) }) { return "O6: a released input is still held \(at())" }
            lastHeld = held
        }
        if sawWaitWhileLoose { totals.casesWithWaitWhileLoose += 1 }
        // O7, O8
        if let open { return "O7: \(open) never stopped" }
        if countdown { return "O7: the countdown never ended" }
        if !arbiter.held.isEmpty { return "O8: inputs still held after every release: \(arbiter.held)" }
        return nil
    }

    // MARK: The statements' helpers

    /// P-ON's closed list: at the first step where the aided arbiter and its `.off` twin differ, the aided commands
    /// are the twin's with exactly one new gesture.
    private static func isNewGesture(on: [InputCommand], off: [InputCommand]) -> Bool {
        guard let start = off.firstIndex(of: .startTranslation) else { return false }
        // (1) A variant 1 latch: the latch cue right after its start, and, when a STOP comes later in the step, the
        // stop of what it latched right after the STOP.
        var latch = off
        latch.insert(.cue(.drive(.latched)), at: start + 1)
        if latch == on { return true }
        if let stop = latch[(start + 2)...].firstIndex(of: .emergencyStop) {
            latch.insert(.stopTranslation, at: stop + 1)
            if latch == on { return true }
        }
        // (5) A variant 1 press after a STOP in the same step: refused as the robot being stopped.
        var refused = off
        refused[start] = .cue(.refused(.stopped))
        return off[..<start].contains(.emergencyStop) && refused == on
    }

    /// The cues the first ending among `events` plays for a move nobody holds, or nil when none of them ends one.
    private static func eventDoor(_ events: ArraySlice<InputEvent>) -> [DriveCue]? {
        for event in events {
            switch event {
            case .keyDown:
                return [.stoppedByYou]
            case .touch(let s) where s.phase == .began:
                switch ArbiterRig.layout.zone(x: s.x, y: s.y) {
                case .bottomBand:
                    return []
                case .controlSurface, .gear, .topBand:
                    if Self.passesTheFilters(s) { return [.stoppedByYou] }
                case .gap, .bottomSafeArea:
                    break
                }
            case .holdsEnded(let reason):
                switch reason {
                case .announced, .startRefused: return []
                case .unnamed: return [.ended(.unnamed)]
                case .appLeft: return [.ended(.appLeft)]
                case .cameraStopped: return [.ended(.cameraStopped)]
                case .leftScreen: return [.ended(.leftScreen)]
                case .slowLink: return [.ended(.slowLink)]
                }
            case .becameActive:
                return [.ended(.appLeft)]
            case .modeChanged, .assistChanged:
                return [.ended(.unnamed)]
            default:
                continue
            }
        }
        return nil
    }

    /// The input whose down event is the first ending among `events`, if the first ending is an input's.
    private static func inputDoor(_ events: [InputEvent]) -> HeldInput? {
        for event in events {
            switch event {
            case .keyDown(let key):
                return .key(key)
            case .touch(let s) where s.phase == .began:
                switch ArbiterRig.layout.zone(x: s.x, y: s.y) {
                case .bottomBand: return nil
                case .controlSurface, .gear, .topBand: if passesTheFilters(s) { return .touch(s.id) }
                case .gap, .bottomSafeArea: break
                }
            case .holdsEnded, .becameActive, .modeChanged, .assistChanged:
                return nil
            default:
                continue
            }
        }
        return nil
    }

    /// What the checks after a call's events give a latched follow: the cues of its ending, or nil when it goes on.
    private static func gateDoor(facts: InputFacts, since: TimeInterval, limit: Double, time: TimeInterval)
        -> [DriveCue]?
    {
        if let refusal = facts.refusal, refusal != .wait { return [.ended(.unnamed)] }
        if facts.trackingRefusal != nil { return [.ended(.tracking)] }
        if facts.translationRefusal != nil { return [.ended(.posture)] }
        if time >= since + limit - 1e-9 { return [.ended(.timeLimit)] }
        return nil
    }

    private static func passesTheFilters(_ s: TouchSample) -> Bool {
        s.majorRadius < InputConstants.appendixA.palmRadiusPt && !ArbiterRig.layout.isAtSideEdge(x: s.x)
    }

    private static func isStop(_ event: InputEvent) -> Bool {
        guard case .touch(let s) = event, s.phase == .began else { return false }
        return ArbiterRig.layout.zone(x: s.x, y: s.y) == .bottomBand
    }

    /// A later event of an input in `inputs`: a move, a lift or a release.
    private static func isEvent(_ event: InputEvent, of inputs: Set<HeldInput>) -> Bool {
        switch event {
        case .keyUp(let key): return inputs.contains(.key(key))
        case .touch(let s): return s.phase != .began && inputs.contains(.touch(s.id))
        default: return false
        }
    }

    /// What a dead and silent input may never cause, counted by kind.
    private static func forbidden(_ commands: [InputCommand]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for command in commands {
            switch command {
            case .cue(.dead): counts["a NO", default: 0] += 1
            case .cue(.refused): counts["a refusal", default: 0] += 1
            case .openSettings: counts["Settings", default: 0] += 1
            case .resetCountdownStarted: counts["a countdown", default: 0] += 1
            case .startTranslation, .startGripper, .startWrist: counts["a start", default: 0] += 1
            default: break
            }
        }
        return counts
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

/// One generated case with the aids: `Scenario.generate`'s keys, touches, turns and ticks, then a longer stretch with
/// the configuration's gestures: presses of the upper key 0.1 to 1.5 s apart (the lower key now and then), some with
/// a STOP in the same step before or after the press; inputs already down when a press comes; touches anywhere,
/// filtered or not; every reason every hold ends for; the app coming back, the aids and the mode changing; scene
/// resets and wrist starts; spells of facts that refuse, `.wait` among them; and a final every-hold-ends after every
/// release.
struct AssistScenario {
    struct Step {
        var time: TimeInterval
        var order: Int
        var events: [InputEvent]
    }

    /// Facts laid over the base's from `from` until `to`.
    struct Spell {
        var from: TimeInterval
        var to: TimeInterval
        var refusal: InputRefusal?
        var tracking = false
        var posture = false
    }

    static let reasons: [Interruption] = [
        .unnamed, .announced, .startRefused, .appLeft, .cameraStopped, .leftScreen, .slowLink,
    ]

    var base: Scenario
    var assist: Assist
    var steps: [Step]
    var spells: [Spell]
    /// Touches that begin in the bottom safe area.
    var safeAreaTouches: Set<Int>

    /// The base's facts at `time`, with the spells that hold then laid over them.
    func facts(at time: TimeInterval) -> InputFacts {
        var facts = base.facts(at: time)
        for spell in spells where time >= spell.from && time < spell.to {
            if let refusal = spell.refusal { facts.refusal = refusal }
            if spell.tracking { facts.trackingRefusal = .notTracking }
            if spell.posture { facts.translationRefusal = .posture }
        }
        return facts
    }

    var summary: String {
        let configuration = assist.lock.map { "lock \($0.variant) \($0.timeLimitS) s" } ?? "off"
        return "\(base.summary), \(configuration), \(steps.count) steps"
    }

    static func generate(_ rng: inout SplitMix64, index: Int) -> AssistScenario {
        let base = Scenario.generate(&rng, index: index)
        let assist =
            rng.chance(0.2) ? Assist.off : Assist(lock: LockRule(variant: .pressPress, timeLimitS: rng.uniform(0.3, 3)))
        let layout = ArbiterRig.layout
        var steps = base.timeline.map { Step(time: $0.time, order: $0.order, events: [$0.event]) }
        var order = steps.count
        var nextID = 1_000
        func add(_ time: TimeInterval, _ events: [InputEvent]) {
            steps.append(Step(time: time, order: order, events: events))
            order += 1
        }
        func newID() -> Int {
            nextID += 1
            return nextID
        }
        func touch(_ id: Int, _ phase: TouchSample.Phase, _ p: SIMD2<Double>, _ radius: Double) -> InputEvent {
            .touch(TouchSample(id: id, phase: phase, x: p.x, y: p.y, majorRadius: radius))
        }
        var safeArea = Set<Int>()
        for step in base.timeline {
            if case .touch(let s) = step.event, s.phase == .began, layout.zone(x: s.x, y: s.y) == .bottomSafeArea {
                safeArea.insert(s.id)
            }
        }
        let baseEnd = base.timeline.map(\.time).max() ?? 0
        let keysFree =
            base.timeline.compactMap { step -> TimeInterval? in
                if case .keyUp = step.event { return step.time }
                return nil
            }.max() ?? 0
        let start = keysFree + rng.uniform(0.05, 0.3)
        let end = start + rng.uniform(1, 4)

        // Presses, each perhaps with inputs already down when it comes, or with a STOP in its step.
        var t = start
        while t < end {
            let key: InputKey = rng.chance(0.8) ? .upper : .lower
            if rng.chance(0.3) {
                let which = 1 + Int(rng.next() % 7)
                if which & 1 != 0 {
                    // A thumb, then slid up the glass after the press.
                    let id = newID()
                    let surface = layout.controlSurface
                    var p = SIMD2(rng.uniform(30, 372), rng.uniform(surface.y + 80, surface.maxY - 10))
                    add(t - rng.uniform(0.01, 0.4), [touch(id, .began, p, rng.uniform(6, 60))])
                    var when = t + rng.uniform(0.01, 0.1)
                    for _ in 0..<Int(rng.next() % 14) {
                        when += rng.uniform(0.003, 0.03)
                        p.y -= ArbiterRig.pointsPerMm
                        add(when, [touch(id, .moved, p, 20)])
                    }
                    add(when + rng.uniform(0.02, 0.5), [touch(id, .ended, p, 20)])
                }
                if which & 2 != 0 {
                    // The top band, inside its palm window when the press comes.
                    let id = newID()
                    let p = SIMD2(rng.uniform(80, 380), rng.uniform(70, layout.topBand.maxY - 1))
                    add(t - rng.uniform(0.01, 0.09), [touch(id, .began, p, 10)])
                    add(t + rng.uniform(0.05, 1), [touch(id, .ended, p, 10)])
                }
                if which & 4 != 0 {
                    let id = newID()
                    let gear = layout.gear
                    let p = SIMD2(rng.uniform(gear.x + 13, gear.maxX - 1), rng.uniform(gear.y + 1, gear.maxY - 1))
                    add(t - rng.uniform(0.01, 0.3), [touch(id, .began, p, 10)])
                    add(t + rng.uniform(0.02, 0.45), [touch(id, .ended, p, 10)])
                }
            }
            let length = rng.uniform(0.03, 0.6)
            if rng.chance(0.1) {
                let id = newID()
                let p = SIMD2(rng.uniform(20, 380), layout.bottomBand.y + 20)
                let stop = touch(id, .began, p, rng.uniform(6, 120))
                add(t, rng.chance(0.5) ? [.keyDown(key), stop] : [stop, .keyDown(key)])
                add(t + rng.uniform(0.03, 0.4), [touch(id, .ended, p, 8)])
            } else {
                add(t, [.keyDown(key)])
            }
            add(t + length, [.keyUp(key)])
            t += length + rng.uniform(0.1, 1.5)
        }

        // Touches anywhere, some sliding; none in a quiet case, so a follow can run to its limit.
        if !rng.chance(0.35) {
            for _ in 0..<Int(rng.next() % 4) {
                let id = newID()
                var p = point(&rng)
                let radius = rng.chance(0.15) ? rng.uniform(91, 130) : rng.uniform(4, 60)
                var when = rng.uniform(start, end)
                add(when, [touch(id, .began, p, radius)])
                if layout.zone(x: p.x, y: p.y) == .bottomSafeArea { safeArea.insert(id) }
                if rng.chance(0.5) {
                    let degrees = rng.uniform(0, 360)
                    let step = SIMD2(cos(degrees * .pi / 180), -sin(degrees * .pi / 180)) * ArbiterRig.pointsPerMm
                    for _ in 0..<Int(rng.next() % 12) {
                        when += rng.uniform(0.005, 0.03)
                        p += step
                        add(when, [touch(id, .moved, p, radius)])
                    }
                }
                add(when + rng.uniform(0.02, 0.6), [touch(id, rng.chance(0.1) ? .cancelled : .ended, p, radius)])
            }
        }

        if rng.chance(0.6) { add(rng.uniform(start, end), [.holdsEnded(reasons[Int(rng.next() % 7)])]) }
        if rng.chance(0.3) { add(rng.uniform(start, end), [.holdsEnded(reasons[Int(rng.next() % 7)])]) }
        if rng.chance(0.08) { add(rng.uniform(start, end), [.becameActive]) }
        if rng.chance(0.08) { add(rng.uniform(start, end), [.assistChanged(assist)]) }
        if rng.chance(0.04) {
            add(rng.uniform(start, end), [.modeChanged(rng.chance(0.5) ? .screenTurns : .keyTurns, base.hand)])
        }
        if rng.chance(0.15) { add(rng.uniform(start, end), [.sceneReset]) }
        if rng.chance(0.15) { add(rng.uniform(start, end), [.wristStartSent]) }
        if rng.chance(0.3) {
            // The phone turns for a moment, at 60 Hz.
            var when = rng.uniform(start, end)
            let turn = rng.uniform(-40, 40), tilt = rng.uniform(-20, 20)
            for i in 1...18 {
                let f = Double(i) / 18
                add(when, [.attitude(Phone.attitude(turn: turn * f, tilt: tilt * f))])
                when += 1.0 / 60
            }
        }

        var spells: [Spell] = []
        for _ in 0..<Int(rng.next() % 3) {
            let from = rng.uniform(start, end)
            var spell = Spell(from: from, to: from + rng.uniform(0.05, 1.2), refusal: nil)
            let roll = rng.uniform(0, 1)
            if roll < 0.4 {
                spell.refusal = .wait
            } else if roll < 0.6 {
                spell.refusal = [InputRefusal.noLink, .stopped, .slowLink, .settingsOpen][Int(rng.next() % 4)]
            } else if roll < 0.8 {
                spell.tracking = true
            } else {
                spell.posture = true
            }
            spells.append(spell)
        }

        for tick in stride(from: baseEnd + 1.0 / 30, through: end + 0.8, by: 1.0 / 30) { add(tick, [.tick]) }
        // Every hold ends once everything is let go of.
        add((steps.map(\.time).max() ?? 0) + 0.05, [.endAllHolds])
        steps.sort { ($0.time, $0.order) < ($1.time, $1.order) }
        return AssistScenario(base: base, assist: assist, steps: steps, spells: spells, safeAreaTouches: safeArea)
    }

    /// Anywhere on the reference screen, the zones weighted toward the ones that end a move nobody holds.
    private static func point(_ rng: inout SplitMix64) -> SIMD2<Double> {
        let layout = ArbiterRig.layout
        let roll = rng.uniform(0, 1)
        switch roll {
        case ..<0.45:
            let surface = layout.controlSurface
            return SIMD2(rng.uniform(0, layout.width), rng.uniform(surface.y, surface.maxY - 0.01))
        case ..<0.6:
            return SIMD2(rng.uniform(layout.gear.maxX, layout.width), rng.uniform(0, layout.topBand.maxY - 0.01))
        case ..<0.7:
            let gear = layout.gear
            return SIMD2(rng.uniform(gear.x, gear.maxX - 0.01), rng.uniform(gear.y, gear.maxY - 0.01))
        case ..<0.8:
            return SIMD2(rng.uniform(0, layout.width), rng.uniform(layout.bottomBand.y, layout.bottomBand.maxY - 0.01))
        case ..<0.87:
            return SIMD2(rng.uniform(0, layout.width), rng.uniform(layout.gap.y, layout.gap.maxY - 0.01))
        default:
            let safe = layout.bottomSafeArea
            return SIMD2(rng.uniform(0, layout.width), rng.uniform(safe.y, safe.maxY - 0.01))
        }
    }
}
