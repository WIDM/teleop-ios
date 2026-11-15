import simd
import XCTest
@testable import TeleopCore

/// Generated interleavings with the aids. `InputArbiterPropertyTests` keeps asserting the 1.0.1 promises on `.off`
/// from its own unchanged file; this one generates the aided configurations (one case in five is `.off`, so every new
/// statement also holds on 1.0.1), restates the 1.0.1 promises where they still hold, checks the new ones after every
/// step, and compares every case with an `.off` twin up to the first new gesture. A failure says which rule broke, in
/// plain words, then what happened and where.
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
        XCTAssertGreaterThan(totals.slideLatches, 300)
        XCTAssertGreaterThan(totals.centreBandSlideLatches, 50)
        XCTAssertGreaterThan(totals.withheldNOs, 100)
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
        var slideLatches = 0
        /// Latches by a slide that began in scheme B's centre band, dead and silent in 1.0.1.
        var centreBandSlideLatches = 0
        var withheldNOs = 0
    }

    /// A control-surface touch as the generator moved it.
    struct Thumb {
        var downAt: TimeInterval
        var down: SIMD2<Double>
        var at: SIMD2<Double>
        /// It went down while the upper key held the arm.
        var inHeldUp: Bool
        /// Some sample of it was a sideways slide by `ThumbSlide`.
        var sideways = false
        /// A NO was played for it.
        var playedNO = false
    }

    // MARK: One case

    /// The first broken promise of one case, or nil.
    private func run(_ scenario: AssistScenario, totals: inout Totals) -> String? {
        let base = scenario.base
        var arbiter = InputArbiter(
            scheme: base.scheme, hand: base.hand, layout: ArbiterRig.layout, assist: scenario.assist)
        let variant = scenario.assist.lock?.variant
        // An aid changes nothing until it acts: the same events on 1.0.1, until the first new gesture. After a NO
        // withheld by a slide (variant 2) it goes on until the latch, the two then differing only in when NOs play:
        // `withheld` counts the NOs owed.
        var twin: InputArbiter? = InputArbiter(scheme: base.scheme, hand: base.hand, layout: ArbiterRig.layout)
        var withheld: Int?
        // Every control-surface touch down, as the generator moved it, for the latch by a slide and withheld NOs.
        var thumbs: [Int: Thumb] = [:]
        // When the upper key's translation hold began, while it runs.
        var heldUpSince: TimeInterval?
        // A touch from the bottom safe area does nothing: the same events with every sample of a touch that began
        // there turned into a tick.
        var strip: InputArbiter? = scenario.safeAreaTouches.isEmpty ? nil : arbiter
        if scenario.assist == .off { totals.offCases += 1 }

        var open: HoldKind?
        var countdown = false
        var down = Set<HeldInput>()
        var everDead = Set<HeldInput>()
        // Inputs that ended a move nobody holds, or were down when one began, until released: dead and silent.
        var silenced = Set<HeldInput>()
        var lastHeld: [HeldInput: InputPhase] = [:]
        var sawWaitWhileLoose = false

        for step in scenario.steps {
            func at() -> String { "at \(step.time), \(step.events)" }
            let facts = scenario.facts(at: step.time)
            let engagementBefore = arbiter.engagement
            let limitBefore = arbiter.assist.lock?.timeLimitS ?? 0
            let downBefore = down
            // The arbiter as it was, kept only for the steps replayed another way: without the events of dead and
            // silent inputs, or with every hold ending for no named reason.
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
                guard case .touch(let s) = event else { continue }
                let point = SIMD2(s.x, s.y)
                switch s.phase {
                case .began where ArbiterRig.layout.zone(x: s.x, y: s.y) == .controlSurface:
                    let inHeldUp = engagementBefore == .held(.key(.upper), .translation)
                    thumbs[s.id] = Thumb(downAt: step.time, down: point, at: point, inHeldUp: inHeldUp)
                case .moved:
                    guard var thumb = thumbs[s.id] else { break }
                    thumb.at = point
                    let slide = ThumbSlide.judge(
                        from: thumb.down, to: point, layout: ArbiterRig.layout, constants: .appendixA)
                    if slide == .sideways { thumb.sideways = true }
                    thumbs[s.id] = thumb
                default:
                    break
                }
            }
            let commands = arbiter.handle(step.events, at: step.time, facts: facts)
            let held = arbiter.held
            let engagement = arbiter.engagement
            let drives = commands.isEmpty ? [] : ArbiterRig.drives(commands)
            let latchedHere = drives.contains(.latched)
            let heldUpBefore = heldUpSince
            if engagement == .held(.key(.upper), .translation) {
                if engagementBefore != engagement { heldUpSince = step.time }
            } else {
                heldUpSince = nil
            }

            // A touch from the bottom safe area does nothing.
            // The twins are run in place: the arbiter is a large value, and copying it every step costs more than the
            // checks.
            if strip != nil {
                let events = step.events.map { event -> InputEvent in
                    if case .touch(let s) = event, scenario.safeAreaTouches.contains(s.id) { return .tick }
                    return event
                }
                let otherCommands = strip!.handle(events, at: step.time, facts: facts)
                if otherCommands != commands {
                    return "a touch from the bottom safe area does nothing: \(commands), without it "
                        + "\(otherCommands) \(at())"
                }
                if strip!.held != held {
                    return "a touch from the bottom safe area does nothing: it is held \(at())"
                }
            }

            // An aid changes nothing until it acts; while the twin lasts, also when a withheld NO plays
            if twin != nil {
                var events = step.events
                for (i, event) in events.enumerated() {
                    if case .assistChanged = event { events[i] = .assistChanged(.off) }
                }
                let offCommands = twin!.handle(events, at: step.time, facts: facts)
                let offHeld = twin!.held
                let onNOs = Self.noCount(commands), offNOs = Self.noCount(offCommands)
                let sameButNOs =
                    !latchedHere && held == offHeld && Self.withoutNOs(commands) == Self.withoutNOs(offCommands)
                if withheld == nil, offCommands == commands, offHeld == held {
                    // Still 1.0.1.
                } else if scenario.assist == .off {
                    return "an aid changes nothing until it acts: .off gave \(commands), 1.0.1 \(offCommands) \(at())"
                } else if variant == .holdThenSlide, sameButNOs {
                    // A withheld NO: the two differ only in when a NO plays. Each withheld NO plays exactly once
                    // later, and never while its thumb still slides mostly up.
                    if withheld == nil, offNOs - onNOs > 1 {
                        return "an aid changes nothing until it acts: \(offNOs - onNOs) NOs withheld \(at())"
                    }
                    let owed = (withheld ?? 0) + offNOs - onNOs
                    if owed < 0 {
                        return "a withheld NO plays once, later: a NO played that was never withheld: \(commands) "
                            + "\(at())"
                    }
                    if onNOs > offNOs, !Self.mayPlayAWithheldNO(step.events, facts: facts, thumbs: thumbs) {
                        return "a withheld NO plays once, later: it played while its thumb still slides up \(at())"
                    }
                    if offNOs > onNOs { totals.withheldNOs += offNOs - onNOs }
                    withheld = owed
                } else {
                    // The first new gesture, which must be one of the few an aid may make.
                    var fits = false
                    switch variant {
                    case .pressPress?:
                        fits = withheld == nil && Self.isPressGesture(on: commands, off: offCommands)
                    case .holdThenSlide?:
                        // A latch by a slide: the latch cue, and the latching thumb's NO, if it was owed one,
                        // dropped, never played.
                        let others = commands.filter { $0 != .cue(.drive(.latched)) }
                        fits =
                            commands.count - others.count == 1 && onNOs == 0 && (withheld ?? 0) + offNOs <= 1
                            && Self.withoutNOs(others) == Self.withoutNOs(offCommands)
                    case nil:
                        break
                    }
                    if !fits {
                        return "an aid changes nothing until it acts: first difference \(commands), off \(offCommands) "
                            + "\(at())"
                    }
                    for input in Set(held.keys).union(offHeld.keys) where held[input] != offHeld[input] {
                        let upper = input == .key(.upper) && offHeld[input] == .engaged(.translation)
                        let downAtTheStart = latchedHere && downBefore.contains(input)
                        if held[input] != .dead || !(upper || downAtTheStart) {
                            return "an aid changes nothing until it acts: \(input) is "
                                + "\(String(describing: held[input])), off \(String(describing: offHeld[input])) "
                                + "\(at())"
                        }
                    }
                    twin = nil
                    withheld = nil
                }
            }

            // No start during the countdown or with nothing down; a start engages one live input that is down; wrist
            // updates and countdown events in order; and every start has one stop, to the end
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
                    if let open { return "one hold at a time: \(command) while \(open) is engaged \(at())" }
                    if countdown { return "no start during the reset countdown: \(command) \(at())" }
                    if downBefore.isEmpty, down.isEmpty { return "no start with no input down: \(command) \(at())" }
                    open = kind
                    startedHere = kind
                case .stopTranslation, .stopGripper, .stopWrist:
                    guard let current = open else {
                        return "every start has one stop: \(command) with nothing engaged \(at())"
                    }
                    if !Self.stop(command, ends: current) {
                        return "every start has one stop: \(command) ends \(current) \(at())"
                    }
                    if startedHere != nil { stoppedAfterStart = true }
                    open = nil
                case .wristUpdate:
                    if open != .wrist {
                        return "wrist updates only during a wrist hold: \(String(describing: open)) engaged \(at())"
                    }
                case .resetCountdownStarted:
                    if open != nil || countdown {
                        return "countdown events in order: a countdown while engaged \(at())"
                    }
                    countdown = true
                case .resetCountdownCancelled, .fireReset:
                    if !countdown { return "countdown events in order: \(command) without a countdown \(at())" }
                    countdown = false
                case .cue, .emergencyStop, .openSettings:
                    break
                }
            }
            if let started = startedHere, !stoppedAfterStart, case .held(let input, _)? = engagement {
                let engaged = held.filter { $0.value == .engaged(started) }
                if engaged.count != 1 || engaged.first?.key != input {
                    return "a start engages one live input that is down: \(started) started but \(engaged.count) "
                        + "inputs report it \(at())"
                }
                if !down.contains(input) {
                    return "a start engages one live input that is down: \(input) engaged but not down \(at())"
                }
                if everDead.contains(input) {
                    return "a start engages one live input that is down: dead \(input) woke as \(started) \(at())"
                }
            }

            // One thing engaged at a time, the engagement and its input agree, and no input is engaged while loose
            var engagedInputs: [(input: HeldInput, phase: InputPhase)] = []
            for (input, phase) in held {
                switch phase {
                case .engaged, .countingDown: engagedInputs.append((input, phase))
                case .waiting, .dead: break
                }
            }
            let loose = engagement?.isLoose == true
            let count = engagedInputs.count + (loose ? 1 : 0)
            if count > 1 { return "one thing engaged at a time: \(count) things engaged \(at())" }
            if (engagement == nil) != (count == 0) {
                return "one thing engaged at a time: engagement \(String(describing: engagement)) \(at())"
            }
            switch engagement {
            case .held(let input, let kind)?:
                if held[input] != .engaged(kind) || !down.contains(input) {
                    return "the engagement and its input agree: \(input) is \(String(describing: held[input])) for "
                        + "\(kind) \(at())"
                }
            case .countdown(let touch)?:
                if held[.touch(touch)] != .countingDown {
                    return "the engagement and its input agree: the countdown's touch is not counting \(at())"
                }
            case .latched?:
                if !engagedInputs.isEmpty {
                    return "no input engaged during a move nobody holds: \(engagedInputs) while latched \(at())"
                }
            case nil:
                break
            }
            for (input, phase) in engagedInputs {
                if case .engaged(let kind) = phase, engagement != .held(input, kind) {
                    return "the engagement and its input agree: \(input) reports \(kind), engagement "
                        + "\(String(describing: engagement)) \(at())"
                }
            }

            // An aid acts only when it is on
            if arbiter.assist.lock == nil, scenario.assist.lock == nil {
                if loose {
                    return "an aid acts only when it is on: \(String(describing: engagement)) without lock \(at())"
                }
                if !drives.isEmpty { return "an aid acts only when it is on: \(drives) without lock \(at())" }
            }
            if commands.contains(.cue(.refused(.outsideWorkArea))) || commands.contains(.cue(.refused(.noArmData))) {
                return "an aid acts only when it is on: a tap's refusal without tap-to-go \(at())"
            }

            // A follow latches only by a press or by a slide
            if case .latched(let since)? = engagement, engagementBefore?.isLoose != true {
                var idle = engagementBefore == nil
                if case .countdown? = engagementBefore { idle = true }
                let latches = drives.filter { $0 == .latched }.count
                let start = commands.firstIndex(of: .startTranslation)
                let byPress =
                    idle && step.events.contains(.keyDown(.upper)) && arbiter.assist.lock?.variant == .pressPress
                    && translationStarts == 1 && latches == 1 && start.map { $0 + 1 < commands.count } == true
                    && commands[start! + 1] == .cue(.drive(.latched))
                let bySlide =
                    engagementBefore == .held(.key(.upper), .translation)
                    && arbiter.assist.lock?.variant == .holdThenSlide && translationStarts == 0
                    && translationStops == 0 && latches == 1
                guard byPress || bySlide, since == step.time else {
                    return "a follow latches only by a press or by a slide: latched from "
                        + "\(String(describing: engagementBefore)) with \(commands) \(at())"
                }
                // A latch by a slide needs a thumb new to the hold that slid deliberately up and played no NO
                if bySlide {
                    let latching = thumbs.filter { held[.touch($0.key)] != nil }
                    guard latching.count == 1, let (id, thumb) = latching.first else {
                        return "a latch by a slide needs a deliberate slide up: \(latching.count) thumbs down at it "
                            + "\(at())"
                    }
                    let slide = ThumbSlide.judge(
                        from: thumb.down, to: thumb.at, layout: ArbiterRig.layout, constants: .appendixA)
                    let began = heldUpBefore.map { thumb.inHeldUp && thumb.downAt >= $0 } ?? false
                    let windowOver = step.time >= thumb.downAt + arbiter.constants.palmWindowMs / 1000 - 1e-9
                    if !began || !windowOver || slide != .up || thumb.sideways || thumb.playedNO {
                        return "a latch by a slide needs a deliberate slide up: touch \(id) latched: \(thumb), "
                            + "\(slide) \(at())"
                    }
                    totals.slideLatches += 1
                    if arbiter.scheme == .keyTurns,
                        ArbiterRig.layout.side(x: thumb.down.x, hand: arbiter.hand) == .centre
                    {
                        totals.centreBandSlideLatches += 1
                    }
                }
            }
            if !(engagementBefore?.isLoose == true), drives.contains(where: { $0 != .latched }) || drives.count > 1 {
                return "with nothing loose before, the only drive cue is one latch: \(drives) \(at())"
            }

            // A move nobody holds ends once, with the cue of what ended it (its door)
            if case .latched(let since)? = engagementBefore {
                let door =
                    Self.eventDoor(step.events[...])
                    ?? Self.gateDoor(facts: facts, since: since, limit: limitBefore, time: step.time)
                if loose {
                    if let door { return "a move nobody holds ends once, with its cue: \(door) did not end it \(at())" }
                    if engagement != engagementBefore {
                        return "a move nobody holds ends once, with its cue: became \(String(describing: engagement)) "
                            + "\(at())"
                    }
                    if commands.contains(.stopTranslation) || !drives.isEmpty {
                        return "a move nobody holds ends once, with its cue: \(commands) and still loose \(at())"
                    }
                    if facts.refusal == .wait { sawWaitWhileLoose = true }
                } else {
                    guard let door else {
                        return "a move nobody holds ends once, with its cue: it ended with no door: \(commands) \(at())"
                    }
                    if translationStops != 1 {
                        return "a move nobody holds ends once, with its cue: \(translationStops) stops \(at())"
                    }
                    if drives != door {
                        return "a move nobody holds ends once, with its cue: \(drives), its door gives \(door) \(at())"
                    }
                    let stopAt = commands.firstIndex(of: .stopTranslation)!
                    if let cue = door.first, commands.dropFirst(stopAt + 1).first != .cue(.drive(cue)) {
                        return "a move nobody holds ends once, with its cue: \(cue) does not follow the stop: "
                            + "\(commands) \(at())"
                    }
                }
                for case .holdsEnded(let reason) in step.events {
                    if let i = AssistScenario.reasons.firstIndex(of: reason) { totals.reasonsWhileLoose[i] += 1 }
                }
            }
            for drive in drives {
                if drive == .latched, translationStarts > 0 { totals.pressLatches += 1 }
                if drive == .ended(.timeLimit) { totals.lockLimits += 1 }
            }

            // A STOP ends what exists
            if let stopEvent = step.events.firstIndex(where: Self.isStop) {
                if loose { return "a STOP ends what exists: still loose after it \(at())" }
                guard let e = commands.firstIndex(of: .emergencyStop) else {
                    return "a STOP ends what exists: no STOP sent \(at())"
                }
                let after = commands[(e + 1)...]
                if after.contains(where: { if case .cue(.drive) = $0 { return true } else { return false } }) {
                    return "a STOP ends what exists: a drive cue after the STOP: \(commands) \(at())"
                }
                let beforeStop = ArbiterRig.drives(Array(commands[..<e]))
                if beforeStop.contains(where: { if case .ended = $0 { return true } else { return false } }) {
                    return "a STOP ends what exists: an ending ahead of the STOP: \(commands) \(at())"
                }
                let endedBefore = Self.eventDoor(step.events[..<stopEvent]) != nil
                let latchedBefore = beforeStop.contains(.latched)
                let looseAtStop = (engagementBefore?.isLoose == true && !endedBefore) || latchedBefore
                if looseAtStop != after.contains(.stopTranslation) {
                    return "a STOP ends what exists: loose at the STOP \(looseAtStop), \(commands) \(at())"
                }
                if looseAtStop { totals.stopsWhileLoose += 1 }
                if latchedBefore { totals.stopsAfterALatchInTheStep += 1 }
            }

            // A follow ends at its time limit, and when a fact refuses it
            if case .latched(let since)? = engagement {
                let limit = arbiter.assist.lock?.timeLimitS ?? 0
                if step.time >= since + limit - 1e-9 {
                    return "a follow ends at its time limit: latched past it \(at())"
                }
                if facts.trackingRefusal != nil || facts.translationRefusal != nil
                    || (facts.refusal != nil && facts.refusal != .wait)
                {
                    return "a follow ends when a fact refuses it: latched with \(facts) \(at())"
                }
            }

            // Every reason ends a held hold or the countdown the same way
            if replaysUnnamed, var unnamed = before {
                let expected = unnamed.handle([.endAllHolds], at: step.time, facts: facts)
                if expected != commands || unnamed.held != held || unnamed.engagement != engagement {
                    return "every reason ends a held hold the same way: \(step.events) gave \(commands), unnamed "
                        + "\(expected) \(at())"
                }
            }

            // Each start is recorded once
            let recorded = arbiter.startsThisCall
            if recorded.count != translationStarts || recorded.contains(where: { $0 != .phone }) {
                return "each start is recorded once: \(recorded) for \(commands) \(at())"
            }

            // Dead and silent inputs stay so: what they may not do. First by the events of those inputs, against the
            // same step with those events taken out; then, in a step with only silenced inputs held, by their timers
            // too.
            if !silencedEvents.isEmpty, var without = before {
                var events = step.events
                for i in silencedEvents { events[i] = .tick }
                let expected = Self.forbidden(without.handle(events, at: step.time, facts: facts))
                for (kind, n) in Self.forbidden(commands) where n > expected[kind, default: 0] {
                    return "dead and silent inputs stay so: one gave \(kind) \(at())"
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
                    return "dead and silent inputs stay so: \(kind) with only those held \(at())"
                }
            }
            if engagementBefore?.isLoose == true, !loose, let ender = Self.inputDoor(step.events) {
                if startedHere != nil {
                    return "the input that ends a move nobody holds starts nothing: \(commands) \(at())"
                }
                if down.contains(ender) { silenced.insert(ender) }
            }
            if latchedHere {
                for (input, phase) in held {
                    if phase != .dead {
                        return "inputs down when a follow begins are dead: \(input) is \(phase) \(at())"
                    }
                    silenced.insert(input)
                    if input != .key(.upper) { totals.inputsHeldAcrossALooseStart += 1 }
                }
            }
            for input in silenced where held[input] != nil && held[input] != .dead {
                return "dead and silent inputs stay so: \(input) is \(held[input]!) \(at())"
            }

            // Who played a NO, for the latch by a slide: with no new input in the step and one thumb held, the NO is
            // that thumb's.
            if !commands.isEmpty, commands.contains(.cue(.dead)) {
                let fresh = step.events.contains {
                    switch $0 {
                    case .keyDown: return true
                    case .touch(let s): return s.phase == .began
                    default: return false
                    }
                }
                let heldThumbs = thumbs.keys.filter { lastHeld[.touch($0)] != nil }
                if !fresh, heldThumbs.count == 1, let id = heldThumbs.first { thumbs[id]?.playedNO = true }
            }
            if thumbs.keys.contains(where: { !down.contains(.touch($0)) }) {
                thumbs = thumbs.filter { down.contains(.touch($0.key)) }
            }

            // A dead input stays dead; a released input is not held
            for input in everDead where held[input] != nil && held[input] != .dead {
                return "a dead input stays dead: \(input) is \(held[input]!) \(at())"
            }
            for (input, phase) in held where phase == .dead { everDead.insert(input) }
            // Released inputs leave both sets.
            if !everDead.isEmpty { everDead = everDead.filter { down.contains($0) } }
            if !silenced.isEmpty { silenced = silenced.filter { down.contains($0) } }
            if held.keys.contains(where: { !down.contains($0) }) {
                return "a released input is not held: one still is \(at())"
            }
            lastHeld = held
        }
        if sawWaitWhileLoose { totals.casesWithWaitWhileLoose += 1 }
        // Every NO withheld has played by the end.
        if let withheld, withheld != 0 { return "a withheld NO plays once, later: \(withheld) never played" }
        // Every start stopped, and nothing held after every release
        if let open { return "every start has one stop: \(open) never stopped" }
        if countdown { return "countdown events in order: the countdown never ended" }
        if !arbiter.held.isEmpty {
            return "nothing held after every release: inputs still held: \(arbiter.held)"
        }
        return nil
    }

    // MARK: The statements' helpers

    private static func noCount(_ commands: [InputCommand]) -> Int {
        commands.isEmpty ? 0 : commands.filter { $0 == .cue(.dead) }.count
    }

    private static func withoutNOs(_ commands: [InputCommand]) -> [InputCommand] {
        commands.filter { $0 != .cue(.dead) }
    }

    /// A step in which a withheld NO may play. The thumb lifts, or its slide stops being mostly up or turns out
    /// sideways; the upper key's hold ends; a STOP ends every latch attempt; or a fact refuses translation, so the
    /// thumb's slide cannot latch.
    private static func mayPlayAWithheldNO(_ events: [InputEvent], facts: InputFacts, thumbs: [Int: Thumb]) -> Bool {
        if facts.refusal != nil || facts.trackingRefusal != nil || facts.translationRefusal != nil { return true }
        for event in events {
            if isStop(event) { return true }
            switch event {
            case .keyUp(.upper), .holdsEnded, .becameActive, .modeChanged, .assistChanged:
                return true
            case .touch(let s) where s.phase == .ended || s.phase == .cancelled:
                return true
            case .touch(let s) where s.phase == .moved:
                guard let thumb = thumbs[s.id] else { continue }
                let slide = ThumbSlide.judge(
                    from: thumb.down, to: thumb.at, layout: ArbiterRig.layout, constants: .appendixA)
                if !ThumbSlide.mostlyUp(from: thumb.down, to: thumb.at) || slide == .sideways { return true }
            default:
                continue
            }
        }
        return false
    }

    /// The first differences variant 1 may make: at the first step where the aided arbiter and its `.off` twin differ,
    /// the aided commands are the twin's with exactly one new gesture.
    private static func isPressGesture(on: [InputCommand], off: [InputCommand]) -> Bool {
        guard let start = off.firstIndex(of: .startTranslation) else { return false }
        // A variant 1 latch: the latch cue right after its start, and, when a STOP comes later in the step, the
        // stop of what it latched right after the STOP.
        var latch = off
        latch.insert(.cue(.drive(.latched)), at: start + 1)
        if latch == on { return true }
        if let stop = latch[(start + 2)...].firstIndex(of: .emergencyStop) {
            latch.insert(.stopTranslation, at: stop + 1)
            if latch == on { return true }
        }
        // A variant 1 press after a STOP in the same step: refused as the robot being stopped.
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
/// a STOP in the same step before or after the press; with variant 2, thumbs landing during the hold on a half or in
/// the centre band and sliding up, and the top band or the gear touched during it; inputs already down when a press
/// comes; touches anywhere, filtered or not; every reason every hold ends for; the app coming back, the aids and the
/// mode changing; scene resets and wrist starts; spells of facts that refuse, `.wait` among them; and a final
/// every-hold-ends after every release.
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
        let roll = rng.uniform(0, 1)
        let assist =
            roll < 0.2
            ? Assist.off
            : Assist(
                lock: LockRule(variant: roll < 0.6 ? .pressPress : .holdThenSlide, timeLimitS: rng.uniform(0.3, 3)))
        let slides = assist.lock?.variant == .holdThenSlide
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

        // The phone at rest again, so a turn of a few degrees below is one.
        add(start - 0.01, [.attitude(Phone.rest)])
        // Presses, each perhaps with inputs already down when it comes, or with a STOP in its step; with variant 2, a
        // thumb landing during the hold, and the top band or the gear touched during it.
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
            let length = slides && key == .upper ? rng.uniform(0.2, 2) : rng.uniform(0.03, 0.6)
            if slides, key == .upper, rng.chance(0.7) {
                // A thumb lands on a half or in the centre band, and slides 6 to 14 mm at angles around up, at 1 to
                // 40 ms a millimetre, some pausing, some after the phone turned 5 degrees.
                let id = newID()
                let surface = layout.controlSurface
                let x =
                    rng.chance(0.4)
                    ? rng.uniform(185, 217) : rng.chance(0.5) ? rng.uniform(40, 170) : rng.uniform(232, 362)
                var p = SIMD2(x, rng.uniform(surface.y + 120, surface.maxY - 10))
                var when = t + rng.uniform(0.02, 0.3)
                add(when, [touch(id, .began, p, rng.uniform(6, 60))])
                if rng.chance(0.2) {
                    for i in 1...6 {
                        when += 1.0 / 60
                        add(when, [.attitude(Phone.attitude(turn: Double(i)))])
                    }
                }
                when += rng.uniform(0, 0.08)
                let mm = rng.uniform(6, 14)
                let degrees = 90 + rng.uniform(-35, 35)
                let perMm = rng.uniform(0.001, 0.04)
                let pauseAfter = rng.chance(0.25) ? 1 + Int(rng.next() % 8) : -1
                let step = SIMD2(cos(degrees * .pi / 180), -sin(degrees * .pi / 180)) * ArbiterRig.pointsPerMm
                var travelled = 0.0
                var moves = 0
                while travelled < mm - 1e-9 {
                    let d = min(1, mm - travelled)
                    travelled += d
                    when += perMm * d
                    p += step * d
                    add(when, [touch(id, .moved, p, 20)])
                    moves += 1
                    if moves == pauseAfter { when += rng.uniform(0.2, 0.5) }
                }
                add(when + rng.uniform(0.02, 0.5), [touch(id, rng.chance(0.1) ? .cancelled : .ended, p, 20)])
            }
            if slides, key == .upper, rng.chance(0.3) {
                let id = newID()
                let p =
                    rng.chance(0.5)
                    ? SIMD2(rng.uniform(80, 380), rng.uniform(70, layout.topBand.maxY - 1))
                    : SIMD2(rng.uniform(layout.gear.x + 13, layout.gear.maxX - 1), layout.gear.y + 20)
                let when = t + rng.uniform(0.02, 0.3)
                add(when, [touch(id, .began, p, 10)])
                add(when + rng.uniform(0.05, 1), [touch(id, .ended, p, 10)])
            }
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
