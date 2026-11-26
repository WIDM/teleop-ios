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
        XCTAssertGreaterThan(totals.goStarts, 800)
        for kind in ["the facts", "the work box", "no fresh arm", "a STOP earlier in the step"] {
            XCTAssertGreaterThan(totals.refusedTaps[kind, default: 0], 50, "taps refused by \(kind)")
        }
        for kind in ["arrival", "stopped short", "no arm data", "time limit", "a key", "a touch", "STOP"] {
            XCTAssertGreaterThan(totals.goEndings[kind, default: 0], 50, "moves to a point ended by \(kind)")
        }
        XCTAssertGreaterThan(totals.stopsAfterATapInTheStep, 50)
        XCTAssertGreaterThan(totals.palmWideLifts, 50)
        XCTAssertGreaterThan(totals.lateStarts, 50)
        XCTAssertGreaterThan(totals.casesWithWaitWhileGoing, 50)
    }

    struct Totals {
        /// Moves to a tapped point started.
        var goStarts = 0
        /// Taps refused, by what refused them: the facts, the work box, no fresh arm, a STOP earlier in the step.
        var refusedTaps: [String: Int] = [:]
        /// Moves to a tapped point ended, by what ended them.
        var goEndings: [String: Int] = [:]
        var stopsAfterATapInTheStep = 0
        /// Lifts as wide as a palm, after the palm window, of touches that were taps in every other way.
        var palmWideLifts = 0
        /// Moves begun with an arm that stood still at first.
        var lateStarts = 0
        var casesWithWaitWhileGoing = 0
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
        /// The step it went down in.
        var downStep: Int
        var down: SIMD2<Double>
        var at: SIMD2<Double>
        /// It went down while the upper key held the arm.
        var inHeldUp: Bool
        /// Some sample of it was a sideways slide by `ThumbSlide`.
        var sideways = false
        /// A NO was played for it.
        var playedNO = false
        /// It passed the palm and edge filters at its touch-down.
        var accepted = true
        /// The guide's panel it began inside, with tap-to-go allowed and nothing engaged; nil otherwise.
        var panel: GoPanel?
        /// The farthest it went from its touch-down, millimetres, over every sample, the lift sample included.
        var farthestMm = 0.0
        /// Its lift: when, how wide, and whether it was cancelled.
        var liftAt: TimeInterval?
        var liftRadius = 0.0
        var cancelled = false

        /// Shaped as a tap: accepted, begun inside the panel with nothing engaged, lifted (not cancelled) at most
        /// `tapMaxS` after its touch-down, never farther than `tapSlopMm` from it, and lifted narrower than a palm
        /// (`narrowLift` false leaves the last test out).
        func isTap(narrowLift: Bool = true) -> Bool {
            let constants = InputConstants.appendixA
            guard accepted, panel != nil, !cancelled, let liftAt else { return false }
            return liftAt - downAt <= constants.tapMaxS + 1e-9 && farthestMm <= constants.tapSlopMm + 1e-9
                && (!narrowLift || liftRadius < constants.palmRadiusPt)
        }
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
        // The last step that held an accepted STOP touch-down.
        var lastStopStep: Int?
        // With tap-to-go: the arm the rules are told of, and how each move to a point starts, runs and ends.
        var watch: GoWatch?
        var lastTapPoint: SIMD2<Double>?
        var explainedSecondContact = false
        if let limits = scenario.assist.goTo, let walk = scenario.walk { watch = GoWatch(limits: limits, walk: walk) }

        for (index, step) in scenario.steps.enumerated() {
            func at() -> String { "at \(step.time), \(step.events)" }
            var facts = scenario.facts(at: step.time)
            if watch != nil { facts.arm = watch!.arm.fix(at: step.time) }
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
            // The control-surface touches lifted in this step, as the generator moved them.
            var lifted: [Thumb] = []
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
                    var thumb = Thumb(downAt: step.time, downStep: index, down: point, at: point, inHeldUp: inHeldUp)
                    thumb.accepted = Self.passesTheFilters(s)
                    if scenario.assist.goTo != nil, engagementBefore == nil, let panel = facts.goPanel,
                        panel.contains(x: s.x, y: s.y)
                    {
                        thumb.panel = panel
                    }
                    thumbs[s.id] = thumb
                case .moved:
                    guard var thumb = thumbs[s.id] else { break }
                    thumb.at = point
                    let slide = ThumbSlide.judge(
                        from: thumb.down, to: point, layout: ArbiterRig.layout, constants: .appendixA)
                    if slide == .sideways { thumb.sideways = true }
                    thumb.farthestMm = max(thumb.farthestMm, Self.millimetres(from: thumb.down, to: point))
                    thumbs[s.id] = thumb
                case .ended, .cancelled:
                    guard var thumb = thumbs[s.id] else { break }
                    thumb.farthestMm = max(thumb.farthestMm, Self.millimetres(from: thumb.down, to: point))
                    thumb.liftAt = step.time
                    thumb.liftRadius = s.majorRadius
                    thumb.cancelled = s.phase == .cancelled
                    lifted.append(thumb)
                default:
                    break
                }
            }
            let commands = arbiter.handle(step.events, at: step.time, facts: facts)
            if step.events.contains(where: Self.isStop) { lastStopStep = index }
            let held = arbiter.held
            let engagement = arbiter.engagement
            let drives = commands.isEmpty ? [] : ArbiterRig.drives(commands)
            let latchedHere = drives.contains(.latched)
            let recorded = arbiter.startsThisCall
            // A move nobody holds began in this step: a latch, or a tap that started a move to a point.
            let looseStartedHere = latchedHere || recorded.contains(.going)
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
                    if !fits, scenario.assist.goTo != nil, (withheld ?? 0) == 0 {
                        fits = Self.isTapGesture(on: commands, off: offCommands, facts: facts)
                    }
                    if !fits {
                        return "an aid changes nothing until it acts: first difference \(commands), off \(offCommands) "
                            + "\(at())"
                    }
                    for input in Set(held.keys).union(offHeld.keys) where held[input] != offHeld[input] {
                        let upper = input == .key(.upper) && offHeld[input] == .engaged(.translation)
                        let downAtTheStart = looseStartedHere && downBefore.contains(input)
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
            case .latched?, .going?:
                if !engagedInputs.isEmpty {
                    return "no input engaged during a move nobody holds: \(engagedInputs) while loose \(at())"
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
                if case .latched? = engagement {
                    return "an aid acts only when it is on: \(String(describing: engagement)) without lock \(at())"
                }
                if drives.contains(.latched) { return "an aid acts only when it is on: \(drives) without lock \(at())" }
            }
            if arbiter.assist.goTo == nil, scenario.assist.goTo == nil {
                if case .going? = engagement {
                    return "an aid acts only when it is on: \(String(describing: engagement)) without tap-to-go "
                        + "\(at())"
                }
                let tapRefusals: [InputRefusal] = [.outsideWorkArea, .noArmData, .tapStill, .tapLetGo, .tapViewAbove]
                if tapRefusals.contains(where: { commands.contains(.cue(.refused($0))) }) {
                    return "an aid acts only when it is on: a tap's refusal without tap-to-go \(at())"
                }
                let goOnly: [DriveCue] = [.arrived, .ended(.stoppedShort), .ended(.noArmData), .stoppedByYouTapOnce]
                if drives.contains(where: goOnly.contains) || recorded.contains(.going) {
                    return "an aid acts only when it is on: \(drives), \(recorded) without tap-to-go \(at())"
                }
            }
            if scenario.assist.lock == nil, scenario.assist.goTo == nil {
                if loose { return "an aid acts only when it is on: \(String(describing: engagement)) \(at())" }
                if !drives.isEmpty { return "an aid acts only when it is on: \(drives) \(at())" }
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
                    // A STOP ends every latch attempt, and a thumb that lands after it in the same step makes none.
                    if let lastStopStep, thumb.downStep <= lastStopStep {
                        return "a STOP ends every latch attempt: touch \(id) went down in step \(thumb.downStep), "
                            + "the last STOP was in step \(lastStopStep) \(at())"
                    }
                    totals.slideLatches += 1
                    if arbiter.scheme == .keyTurns,
                        ArbiterRig.layout.side(x: thumb.down.x, hand: arbiter.hand) == .centre
                    {
                        totals.centreBandSlideLatches += 1
                    }
                }
            }
            if recorded.contains(.going), engagementBefore?.isLoose != true {
                lastTapPoint = lifted.first(where: { $0.isTap() })?.down
            }
            if !(engagementBefore?.isLoose == true), !drives.isEmpty, drives != [.latched], drives != [.arrived] {
                return "with nothing loose before, the only drive cue is one latch, or a tap's \"Arrived.\": "
                    + "\(drives) \(at())"
            }

            // A move nobody holds ends once, with the cue of what ended it (its door). A move to a point that the
            // checks after the events ended is judged by `GoWatch`, which knows what its verdicts need.
            if let looseBefore = engagementBefore, looseBefore.isLoose {
                let quickSecondContactPoint: SIMD2<Double>?
                if case .going(_, let since) = looseBefore, step.time - since <= InputConstants.secondContactS + 1e-9,
                    !explainedSecondContact
                {
                    quickSecondContactPoint = lastTapPoint
                } else {
                    quickSecondContactPoint = nil
                }
                let eventDoor = Self.eventDoor(step.events[...], near: quickSecondContactPoint)
                if eventDoor == [.stoppedByYouTapOnce] { explainedSecondContact = true }
                var door = eventDoor
                if case .latched(let since) = looseBefore {
                    door = door ?? Self.gateDoor(facts: facts, since: since, limit: limitBefore, time: step.time)
                }
                if case .going = looseBefore, eventDoor == nil, !loose {
                    if translationStops != 1 || drives.count != 1 {
                        return "a move nobody holds ends once, with its cue: \(commands) \(at())"
                    }
                    let stopAt = commands.firstIndex(of: .stopTranslation)!
                    if commands.dropFirst(stopAt + 1).first != .cue(.drive(drives[0])) {
                        return "a move nobody holds ends once, with its cue: \(drives[0]) does not follow the stop: "
                            + "\(commands) \(at())"
                    }
                } else if loose {
                    if let door { return "a move nobody holds ends once, with its cue: \(door) did not end it \(at())" }
                    if engagement != engagementBefore {
                        return "a move nobody holds ends once, with its cue: became \(String(describing: engagement)) "
                            + "\(at())"
                    }
                    if commands.contains(.stopTranslation) || !drives.isEmpty {
                        return "a move nobody holds ends once, with its cue: \(commands) and still loose \(at())"
                    }
                    if facts.refusal == .wait {
                        if case .going = looseBefore { watch?.sawWait = true } else { sawWaitWhileLoose = true }
                    }
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
                if drive == .ended(.timeLimit), case .latched? = engagementBefore { totals.lockLimits += 1 }
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
                // A tap ahead of the STOP that started a move to a point: the starts before the STOP, as recorded.
                let startsBeforeStop = commands[..<e].filter { $0 == .startTranslation }.count
                let wentBefore = recorded.prefix(startsBeforeStop).contains(.going)
                let looseAtStop = (engagementBefore?.isLoose == true && !endedBefore) || latchedBefore || wentBefore
                if looseAtStop != after.contains(.stopTranslation) {
                    return "a STOP ends what exists: loose at the STOP \(looseAtStop), \(commands) \(at())"
                }
                if looseAtStop { totals.stopsWhileLoose += 1 }
                if latchedBefore { totals.stopsAfterALatchInTheStep += 1 }
                if wentBefore { totals.stopsAfterATapInTheStep += 1 }
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

            // Each start is recorded once, with what the link must follow: the phone for a press of the upper key, a
            // move to a point only for a tap's, and only with tap-to-go
            let phoneStarts = recorded.filter { $0 == .phone }.count
            let goStarts = recorded.filter { $0 == .going }.count
            let upperPresses = step.events.filter { $0 == .keyDown(.upper) }.count
            if recorded.count != translationStarts || phoneStarts + goStarts != recorded.count
                || phoneStarts > upperPresses || goStarts > lifted.filter({ $0.isTap() }).count
                || (goStarts > 0 && scenario.assist.goTo == nil)
            {
                return "each start is recorded once, with what the link follows: \(recorded) for \(commands) \(at())"
            }

            // How each move to a point starts, runs and ends
            if watch != nil {
                let view = GoWatch.Step(
                    time: step.time, events: step.events, facts: facts, commands: commands, recorded: recorded,
                    engagementBefore: engagementBefore, engagement: engagement, nextDeadline: arbiter.nextDeadline,
                    offset: arbiter.goOffset(at: step.time), drives: drives)
                if let failure = watch!.check(view, lifted: lifted, totals: &totals) { return "\(failure) \(at())" }
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
            if looseStartedHere {
                for (input, phase) in held {
                    if phase != .dead {
                        return "inputs down when a move nobody holds begins are dead: \(input) is \(phase) \(at())"
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
        if watch?.sawWait == true { totals.casesWithWaitWhileGoing += 1 }
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

    /// The first differences a tap may make: the twin starts nothing, and the aided commands are the twin's with one
    /// of the tap's outcomes added (its start; a refusal by the facts, the work box, no fresh arm or a STOP earlier in
    /// the step; or "Arrived."), or with its start and, when a STOP comes later in the step, the stop of what it
    /// started right after the STOP.
    private static func isTapGesture(on: [InputCommand], off: [InputCommand], facts: InputFacts) -> Bool {
        guard !off.contains(.startTranslation), on.count > off.count else { return false }
        var outcomes: [InputCommand] = [
            .startTranslation, .cue(.refused(.outsideWorkArea)), .cue(.refused(.noArmData)), .cue(.refused(.stopped)),
            .cue(.drive(.arrived)), .cue(.refused(.tapStill)), .cue(.refused(.tapLetGo)),
            .cue(.refused(.tapViewAbove)),
        ]
        if let refusal = facts.refusal { outcomes.append(.cue(.refused(refusal))) }
        for i in 0...off.count {
            for outcome in outcomes {
                var added = off
                added.insert(outcome, at: i)
                if added == on { return true }
            }
            var stopped = off
            stopped.insert(.startTranslation, at: i)
            if let stop = stopped[(i + 1)...].firstIndex(of: .emergencyStop) {
                stopped.insert(.stopTranslation, at: stop + 1)
                if stopped == on { return true }
            }
        }
        return false
    }

    /// The straight distance between two points of the reference screen, millimetres.
    static func millimetres(from a: SIMD2<Double>, to b: SIMD2<Double>) -> Double {
        ArbiterRig.layout.millimetres(simd_length(b - a))
    }

    /// The cues the first ending among `events` plays for a move nobody holds, or nil when none of them ends one.
    fileprivate static func eventDoor(
        _ events: ArraySlice<InputEvent>, near tap: SIMD2<Double>? = nil
    ) -> [DriveCue]? {
        for event in events {
            switch event {
            case .keyDown:
                return [.stoppedByYou]
            case .touch(let s) where s.phase == .began:
                switch ArbiterRig.layout.zone(x: s.x, y: s.y) {
                case .bottomBand:
                    return []
                case .controlSurface:
                    if Self.passesTheFilters(s) {
                        if let tap,
                            millimetres(from: tap, to: SIMD2(s.x, s.y)) <= InputConstants.appendixA.tapSlopMm + 1e-9
                        {
                            return [.stoppedByYouTapOnce]
                        }
                        return [.stoppedByYou]
                    }
                case .gear, .topBand:
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

    fileprivate static func isStop(_ event: InputEvent) -> Bool {
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
/// mode changing; scene resets and wrist starts; spells of facts that refuse, `.wait` among them; with tap-to-go, the
/// guide's panel, an arm the moves drive, and a stretch of taps after the presses; and a final every-hold-ends after
/// every release.
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
    /// With tap-to-go: the guide's view from above, and from when it is another one or none (the guide not drawn).
    var panel: GoPanel?
    var panelChange: (at: TimeInterval, to: GoPanel?)?
    /// With tap-to-go: how the measured arm behaves.
    var walk: ArmWalk?

    /// The base's facts at `time`, with the spells that hold then laid over them, and the panel drawn then. The arm is
    /// filled in by the run, which knows what the moves commanded.
    func facts(at time: TimeInterval) -> InputFacts {
        var facts = base.facts(at: time)
        for spell in spells where time >= spell.from && time < spell.to {
            if let refusal = spell.refusal { facts.refusal = refusal }
            if spell.tracking { facts.trackingRefusal = .notTracking }
            if spell.posture { facts.translationRefusal = .posture }
        }
        if assist.goTo != nil {
            if let change = panelChange, time >= change.at { facts.goPanel = change.to } else { facts.goPanel = panel }
        }
        return facts
    }

    var summary: String {
        let lock = assist.lock.map { "lock \($0.variant) \($0.timeLimitS) s" } ?? "no lock"
        let go =
            assist.goTo.map { "tap-to-go at \($0.speedMps) m/s, \(String(describing: walk?.way))" } ?? "no tap-to-go"
        return "\(base.summary), \(lock), \(go), \(steps.count) steps"
    }

    static func generate(_ rng: inout SplitMix64, index: Int) -> AssistScenario {
        let base = Scenario.generate(&rng, index: index)
        let roll = rng.uniform(0, 1)
        // One case in five is 1.0.1; the others are lock 1, lock 2, tap-to-go, and tap-to-go with either lock, alike.
        var assist = Assist.off
        if roll >= 0.2 {
            let kind = Int(rng.next() % 5)
            if kind != 2 {
                let variant: LockVariant = kind % 2 == 0 ? .pressPress : .holdThenSlide
                assist.lock = LockRule(variant: variant, timeLimitS: rng.uniform(0.3, 3))
            }
            if kind >= 2 { assist.goTo = goLimits(&rng) }
        }
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

        // With tap-to-go, a stretch of taps after the presses: inside the box's part of the panel, in its margin, just
        // outside it, over the arm where the last move went; some still, some out more than 3 mm and back, some lifted
        // far away or as wide as a palm, some lasting too long, some with a STOP in the step of their lift, some with
        // the gear or the top band down across the lift; each followed now and then by a key, a touch, the top band or
        // the gear, a STOP or every hold ending, with refusals, "wait" and the phone's facts switching meanwhile.
        var panel: GoPanel?
        var panelChange: (at: TimeInterval, to: GoPanel?)?
        var walk: ArmWalk?
        var last = end
        if let goTo = assist.goTo {
            let first = randomPanel(&rng)
            panel = first
            // After the presses' last release, so no key is still down from them.
            let goStart = t + rng.uniform(0.1, 0.3)
            let goEnd = goStart + rng.uniform(2, 5)
            last = goEnd
            if rng.chance(0.1) {
                panelChange = (rng.uniform(goStart, goEnd), rng.chance(0.4) ? nil : randomPanel(&rng))
            }
            walk = randomWalk(&rng, goTo, from: goStart, to: goEnd)
            var tapAt = goStart
            var lastPoint: SIMD2<Double>?
            // When each key is let go of: a key is pressed again only once it is up.
            var keyUpAt: [InputKey: TimeInterval] = [:]
            while tapAt < goEnd {
                let t = tapAt
                var rect = first.rect
                if let change = panelChange, t >= change.at, let other = change.to { rect = other.rect }
                let id = newID()
                let place = rng.uniform(0, 1)
                var p = SIMD2(
                    rect.x + rng.uniform(0.13, 0.87) * rect.width, rect.y + rng.uniform(0.13, 0.87) * rect.height)
                if let lastPoint, place < 0.15 {
                    p = lastPoint
                } else if place >= 0.75, place < 0.9 {
                    let edge = rng.chance(0.5) ? rng.uniform(0.01, 0.1) : rng.uniform(0.9, 0.99)
                    if rng.chance(0.5) { p.x = rect.x + edge * rect.width } else { p.y = rect.y + edge * rect.height }
                } else if place >= 0.9 {
                    p.x = rng.chance(0.5) ? rect.x - rng.uniform(0.5, 8) : rect.maxX + rng.uniform(0, 8)
                }
                lastPoint = p
                let radius = rng.uniform(6, 60)
                var duration = rng.chance(0.85) ? rng.uniform(0.03, 0.28) : rng.uniform(0.31, 0.6)
                var liftPoint = p
                var liftRadius = radius
                add(t, [touch(id, .began, p, radius)])
                let shape = rng.uniform(0, 1)
                let angle = rng.uniform(0, 2 * .pi)
                let unit = SIMD2(cos(angle), sin(angle)) * ArbiterRig.pointsPerMm
                if shape < 0.1 {
                    add(t + duration * 0.3, [touch(id, .moved, p + unit * rng.uniform(3.5, 6), radius)])
                    add(t + duration * 0.6, [touch(id, .moved, p, radius)])
                } else if shape < 0.2 {
                    add(t + duration * 0.5, [touch(id, .moved, p + unit * rng.uniform(0.5, 2.5), radius)])
                } else if shape < 0.25 {
                    liftPoint = p + unit * rng.uniform(4, 8)
                } else if shape < 0.32 {
                    duration = rng.uniform(0.11, 0.28)
                    liftRadius = rng.uniform(95, 130)
                }
                let liftAt = t + duration
                let lift = touch(id, rng.chance(0.03) ? .cancelled : .ended, liftPoint, liftRadius)
                if rng.chance(0.08) {
                    let stopID = newID()
                    let stopPoint = SIMD2(rng.uniform(20, 380), layout.bottomBand.y + 20)
                    let stop = touch(stopID, .began, stopPoint, 8)
                    add(liftAt, rng.chance(0.5) ? [lift, stop] : [stop, lift])
                    add(liftAt + rng.uniform(0.05, 0.3), [touch(stopID, .ended, stopPoint, 8)])
                } else {
                    add(liftAt, [lift])
                }
                if rng.chance(0.1) {
                    let gearID = newID()
                    let gearPoint = SIMD2(rng.uniform(layout.gear.x + 13, layout.gear.maxX - 1), layout.gear.y + 20)
                    add(liftAt - rng.uniform(0.05, 0.3), [touch(gearID, .began, gearPoint, 10)])
                    add(liftAt + rng.uniform(0.02, 0.4), [touch(gearID, .ended, gearPoint, 10)])
                }
                if rng.chance(0.1) {
                    // Still inside its palm window at the lift.
                    let bandID = newID()
                    let bandPoint = SIMD2(rng.uniform(80, 380), rng.uniform(70, layout.topBand.maxY - 1))
                    add(liftAt - rng.uniform(0.01, 0.08), [touch(bandID, .began, bandPoint, 10)])
                    add(liftAt + rng.uniform(0.05, 0.6), [touch(bandID, .ended, bandPoint, 10)])
                }
                let next = liftAt + rng.uniform(0.05, 1)
                let follow = rng.uniform(0, 1)
                if follow < 0.15 {
                    let key: InputKey = rng.chance(0.7) ? .upper : .lower
                    let up = next + rng.uniform(0.05, 0.4)
                    if next > keyUpAt[key, default: -.infinity] {
                        add(next, [.keyDown(key)])
                        add(up, [.keyUp(key)])
                        keyUpAt[key] = up
                    }
                } else if follow < 0.33 {
                    // A touch on the surface, the top band or the gear.
                    let otherID = newID()
                    let surface = layout.controlSurface
                    var q = SIMD2(rng.uniform(30, 372), rng.uniform(surface.y + 10, surface.maxY - 10))
                    if follow >= 0.27 {
                        q = SIMD2(rng.uniform(layout.gear.x + 13, 380), rng.uniform(70, layout.topBand.maxY - 1))
                    }
                    add(next, [touch(otherID, .began, q, rng.uniform(6, 60))])
                    add(next + rng.uniform(0.05, 0.6), [touch(otherID, .ended, q, 20)])
                } else if follow < 0.4 {
                    let stopID = newID()
                    let stopPoint = SIMD2(rng.uniform(20, 380), layout.bottomBand.y + 20)
                    add(next, [touch(stopID, .began, stopPoint, rng.uniform(6, 120))])
                    add(next + rng.uniform(0.03, 0.4), [touch(stopID, .ended, stopPoint, 8)])
                } else if follow < 0.46 {
                    add(next, [.holdsEnded(reasons[Int(rng.next() % 7)])])
                }
                tapAt = next + (rng.chance(0.4) ? rng.uniform(1, 2.5) : rng.uniform(0.05, 1))
            }
            for _ in 0..<Int(rng.next() % 3) {
                let from = rng.uniform(goStart, goEnd)
                var spell = Spell(from: from, to: from + rng.uniform(0.05, 1), refusal: nil)
                let roll = rng.uniform(0, 1)
                if roll < 0.45 {
                    spell.refusal = .wait
                } else if roll < 0.7 {
                    spell.refusal = [InputRefusal.noLink, .stopped, .slowLink, .settingsOpen][Int(rng.next() % 4)]
                } else if roll < 0.85 {
                    spell.tracking = true
                } else {
                    spell.posture = true
                }
                spells.append(spell)
            }
            if rng.chance(0.3) { add(rng.uniform(goStart, goEnd), [.holdsEnded(reasons[Int(rng.next() % 7)])]) }
            if rng.chance(0.04) { add(rng.uniform(goStart, goEnd), [.becameActive]) }
            if rng.chance(0.04) { add(rng.uniform(goStart, goEnd), [.assistChanged(assist)]) }
            if rng.chance(0.03) {
                add(rng.uniform(goStart, goEnd), [.modeChanged(rng.chance(0.5) ? .screenTurns : .keyTurns, base.hand)])
            }
        }

        for tick in stride(from: baseEnd + 1.0 / 30, through: last + 0.8, by: 1.0 / 30) { add(tick, [.tick]) }
        // Every hold ends once everything is let go of.
        add((steps.map(\.time).max() ?? 0) + 0.05, [.endAllHolds])
        steps.sort { ($0.time, $0.order) < ($1.time, $1.order) }
        return AssistScenario(
            base: base, assist: assist, steps: steps, spells: spells, safeAreaTouches: safeArea, panel: panel,
            panelChange: panelChange, walk: walk)
    }

    /// Go numbers scaled so that a move, its corrections and its deadline fit inside a case; now and then a travel
    /// height that puts every target above the box.
    private static func goLimits(_ rng: inout SplitMix64) -> GoToLimits {
        GoToLimits(
            travelHeightM: rng.chance(0.05) ? rng.uniform(0.12, 0.15) : rng.uniform(0.02, 0.1),
            speedMps: rng.uniform(0.15, 0.4), arriveToleranceM: rng.uniform(0.006, 0.012),
            corrections: Int(rng.next() % 3), correctionReachM: rng.uniform(0.005, 0.03),
            settleS: rng.uniform(0.08, 0.3), timeFactor: rng.uniform(1.1, 1.6), allowanceS: rng.uniform(0, 0.5),
            armDataTimeoutS: rng.uniform(0.5, 1.2), startGraceS: rng.chance(0.3) ? 0 : rng.uniform(0.05, 0.5))
    }

    /// The guide's view from above of the SO-101 box, now and then moved by a measured offset: over scheme B's centre
    /// band in half the cases, otherwise on one half.
    private static func randomPanel(_ rng: inout SplitMix64) -> GoPanel {
        let surface = ArbiterRig.layout.controlSurface
        let roll = rng.uniform(0, 1)
        var side = rng.uniform(110, 150)
        var x = rng.uniform(14, 176 - side)
        if roll < 0.5 {
            side = rng.uniform(110, 200)
            x = rng.uniform(231 - side, 171)
        } else if roll >= 0.75 {
            x = rng.uniform(226, 390 - side)
        }
        let y = rng.uniform(surface.y + 10, surface.maxY - side - 10)
        var shift = SIMD3<Double>.zero
        if rng.chance(0.3) {
            shift = SIMD3(rng.uniform(-0.01, 0.01), rng.uniform(-0.01, 0.01), rng.uniform(-0.01, 0.01))
        }
        return ArbiterRig.panel(SurfaceLayout.Rect(x: x, y: y, width: side, height: side), shift: shift)
    }

    /// An arm inside the box, sometimes at the travel height, that reports its position at some age, now and then
    /// not at first, with gaps and pauses; it follows a move late or on time, sagging, blocked, freezing or creeping.
    private static func randomWalk(
        _ rng: inout SplitMix64, _ goTo: GoToLimits, from goStart: TimeInterval, to goEnd: TimeInterval
    ) -> ArmWalk {
        let low = ArbiterRig.boxLow, high = ArbiterRig.boxHigh
        var rest = SIMD3(
            rng.uniform(low.x + 0.01, high.x - 0.01), rng.uniform(low.y + 0.01, high.y - 0.01),
            rng.uniform(ArbiterRig.table + 0.005, high.z - 0.01))
        if rng.chance(0.2) { rest.z = ArbiterRig.table + goTo.travelHeightM }
        let roll = rng.uniform(0, 1)
        var way = ArmWalk.Way.follows
        if roll >= 0.85 {
            way = .creeps(rng.uniform(0.02, 0.08))
        } else if roll >= 0.75 {
            way = .freezes(after: rng.uniform(0.1, 1))
        } else if roll >= 0.55 {
            way = .blocked(rng.uniform(0.01, 0.05))
        } else if roll >= 0.4 {
            way = .sags(rng.uniform(0.004, 0.02))
        }
        var gaps: [ClosedRange<Double>] = []
        for _ in 0..<Int(rng.next() % 3) {
            let from = rng.uniform(goStart, goEnd)
            gaps.append(from...(from + rng.uniform(0.2, 2.5)))
        }
        var pauses: [ClosedRange<Double>] = []
        for _ in 0..<Int(rng.next() % 3) {
            let from = rng.uniform(goStart, goEnd)
            pauses.append(from...(from + rng.uniform(0.1, 0.8)))
        }
        let firstFixAt = rng.chance(0.15) ? goStart + rng.uniform(0, 1.5) : -.infinity
        let latency = rng.uniform(0.02, 0.2)
        let lag = rng.uniform(0, 0.3)
        let lateStart = rng.chance(0.3) ? rng.uniform(0.2, 1.5) : 0
        return ArmWalk(
            rest: rest, firstFixAt: firstFixAt, latency: latency, lag: lag, lateStart: lateStart, way: way, gaps: gaps,
            pauses: pauses)
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

// MARK: Tap-to-go in the generated cases

/// How the measured arm behaves in a generated case with tap-to-go.
struct ArmWalk {
    enum Way {
        /// It goes where the move commands.
        case follows
        /// Its jaws hang this far below the commanded point, metres.
        case sags(Double)
        /// Something holds it this far from the target, metres.
        case blocked(Double)
        /// It stops this long after the move began, wherever it is then, seconds.
        case freezes(after: Double)
        /// It moves toward the command no faster than this, metres per second.
        case creeps(Double)
    }

    /// Where it stands before any move.
    var rest: SIMD3<Double>
    /// No position is reported before this.
    var firstFixAt: TimeInterval
    /// How old a position is when the rules are told it, seconds.
    var latency: Double
    /// How far it trails the command, seconds.
    var lag: Double
    /// How long it stands still after each move begins, seconds.
    var lateStart: Double
    var way: Way
    /// Spells in which no new position arrives, so the last one grows old.
    var gaps: [ClosedRange<Double>]
    /// Spells in which the link pauses the hold.
    var pauses: [ClosedRange<Double>]
}

/// The arm a generated case reports to the input rules: it stands where it is until a move to a point goes, then
/// makes of what the move commanded what its walk says.
struct ArmModel {
    let walk: ArmWalk
    private(set) var position: SIMD3<Double>
    private var measured: (pinch: SIMD3<Double>, at: TimeInterval)?
    /// The move going now: where it began, when, and where to.
    private var move: (start: SIMD3<Double>, since: TimeInterval, target: SIMD3<Double>)?
    /// What that move commanded after each step, robot base frame.
    private var commanded: [(at: TimeInterval, point: SIMD3<Double>)] = []
    private var frozen: SIMD3<Double>?
    private var lastAt: TimeInterval?

    init(_ walk: ArmWalk) {
        self.walk = walk
        position = walk.rest
    }

    /// What the rules are told at `time`: the newest position reported, how old it is, and whether the link pauses
    /// the hold then.
    mutating func fix(at time: TimeInterval) -> ArmFix? {
        if let move { position = place(at: time, move) }
        lastAt = time
        if time >= walk.firstFixAt, !walk.gaps.contains(where: { $0.contains(time) }) {
            measured = (position, time - walk.latency)
        }
        guard let measured else { return nil }
        let paused = walk.pauses.contains { $0.contains(time) }
        return ArmFix(pinch: measured.pinch, ageS: time - measured.at, holdPaused: paused)
    }

    private mutating func place(
        at time: TimeInterval, _ move: (start: SIMD3<Double>, since: TimeInterval, target: SIMD3<Double>)
    ) -> SIMD3<Double> {
        let elapsed = time - move.since
        guard elapsed >= walk.lateStart else { return position }
        let command = commanded.last { $0.at <= time - walk.lag }?.point ?? move.start
        switch walk.way {
        case .follows:
            return command
        case .sags(let depth):
            return command - SIMD3(0, 0, depth)
        case .blocked(let distance):
            let off = command - move.target
            guard simd_length(off) < distance else { return command }
            let away = simd_length(off) > 1e-9 ? off : move.start - move.target
            return move.target + simd_normalize(away) * distance
        case .freezes(let after):
            if elapsed < after { return command }
            if frozen == nil { frozen = position }
            return frozen!
        case .creeps(let speed):
            let gap = command - position
            let reach = speed * max(0, time - (lastAt ?? time))
            return simd_length(gap) > reach ? position + simd_normalize(gap) * reach : command
        }
    }

    /// After a step: the move going now, begun from `startFix` if it began in this step, and what it commands.
    mutating func update(
        going engagement: Engagement?, startFix: ArmFix?, offset: SIMD3<Double>?, at time: TimeInterval
    ) {
        guard case .going(let target, let since)? = engagement, let offset else {
            move = nil
            commanded = []
            frozen = nil
            return
        }
        if move?.since != since {
            move = (startFix?.pinch ?? position, since, target)
            commanded = []
            frozen = nil
        }
        commanded.append((time, move!.start + OperatorFrame.base(fromLink: offset)))
    }
}

/// What the generated test knows of the move to a point going now, to judge its verdicts and its path.
struct GoTrack {
    let start: SIMD3<Double>
    let target: SIMD3<Double>
    let since: TimeInterval
    /// The work box of the panel its tap was judged on, corners sorted.
    let boxLow: SIMD3<Double>
    let boxHigh: SIMD3<Double>
    /// Its deadline when it began. A correction only moves it later.
    let firstDeadline: TimeInterval
    /// The last step whose fix said the link was pausing the hold.
    var lastPausedAt: TimeInterval?
    /// A fresh fix has shown the arm 2 mm or more from where it began.
    var seenMoving = false
    /// A fresh fix was no lower than the travel height less the arrival tolerance.
    var travelHeightSeen = false
    /// The offset after each step the move went on in.
    var offsets: [(at: TimeInterval, offset: SIMD3<Double>)] = []

    init(
        start: SIMD3<Double>, target: SIMD3<Double>, since: TimeInterval, limits: GoToLimits, on panel: GoPanel
    ) {
        self.start = start
        self.target = target
        self.since = since
        boxLow = panel.boxLow
        boxHigh = panel.boxHigh
        let path = abs(target.z - start.z) + simd_length(SIMD2(target.x - start.x, target.y - start.y))
        firstDeadline = since + path / limits.speedMps * limits.timeFactor + limits.allowanceS
    }

    /// What the move's own judgement takes from the fix of a step it judged.
    mutating func saw(_ fix: ArmFix?, at time: TimeInterval, limits: GoToLimits) {
        guard let fix, fix.ageS <= limits.armDataTimeoutS else { return }
        if fix.holdPaused { lastPausedAt = time }
        guard fix.ageS <= GoWatch.freshS else { return }
        if simd_distance(fix.pinch, start) >= FeedbackMonitor.blockedMovedMeters { seenMoving = true }
        if target.z - fix.pinch.z <= limits.arriveToleranceM { travelHeightSeen = true }
    }
}

/// The statements about moves to a tapped point, checked after every step of a case with tap-to-go: how a move
/// starts (only from a tap), how it runs (at its speed, level only once a fresh position has reached the travel
/// height, never outside the work box it was given, never past its deadline, its arm data or a refusal that means the
/// session cannot run a hold), and how it ends in the checks after the events (arrived on a fresh position at the
/// target; stopped short only after the arm settled with the command at its leg's end, after the last pause and after
/// the start's grace; no arm data; time).
struct GoWatch {
    static let freshS = Double(FeedbackMonitor.freshStateMs) / 1000

    /// One step, as `run` saw it.
    struct Step {
        var time: TimeInterval
        var events: [InputEvent]
        var facts: InputFacts
        var commands: [InputCommand]
        var recorded: [ArmSource]
        var engagementBefore: Engagement?
        var engagement: Engagement?
        var nextDeadline: TimeInterval?
        var offset: SIMD3<Double>?
        var drives: [DriveCue]
    }

    let limits: GoToLimits
    var arm: ArmModel
    var track: GoTrack?
    /// A step of a move to a point had the facts say "wait".
    var sawWait = false
    /// The walk stands still at first after each start.
    private let lateStarts: Bool

    init(limits: GoToLimits, walk: ArmWalk) {
        self.limits = limits
        arm = ArmModel(walk)
        lateStarts = walk.lateStart > 0.2
    }

    /// Where `tap` sends the arm: the point drawn under its touch-down on the panel of its touch-down.
    private func target(of tap: AssistPropertyTests.Thumb) -> SIMD3<Double> {
        tap.panel!.target(x: tap.down.x, y: tap.down.y, travelHeight: limits.travelHeightM)
    }

    /// The first broken statement of this step, or nil. Then it follows the arm on.
    mutating func check(
        _ s: Step, lifted: [AssistPropertyTests.Thumb], totals: inout AssistPropertyTests.Totals
    ) -> String? {
        defer { arm.update(going: s.engagement, startFix: s.facts.arm, offset: s.offset, at: s.time) }
        let taps = lifted.filter { $0.isTap() }
        if case .going? = s.engagementBefore, let failure = runOrEnd(s, totals: &totals) { return failure }
        if s.recorded.contains(.going) {
            if let failure = start(s, taps: taps, totals: &totals) { return failure }
        } else if s.drives == [.arrived], s.engagementBefore?.isLoose != true {
            // "Arrived." with nothing going: a tap on the arm, which moves nothing.
            let onTheArm = s.facts.arm.map { fix in
                fix.ageS <= Self.freshS
                    && taps.contains { simd_distance(fix.pinch, target(of: $0)) <= limits.arriveToleranceM }
            }
            if s.facts.refusal != nil || onTheArm != true {
                return "\"Arrived.\" with nothing going is a tap on the arm: \(s.facts), \(lifted)"
            }
        } else if !taps.isEmpty {
            countRefusals(s, totals: &totals)
        }
        let palm = InputConstants.appendixA.palmRadiusPt, window = InputConstants.appendixA.palmWindowMs / 1000
        for thumb in lifted where thumb.isTap(narrowLift: false) && thumb.liftRadius >= palm {
            if thumb.liftAt! - thumb.downAt > window { totals.palmWideLifts += 1 }
        }
        return nil
    }

    /// A move to a point starts only from a tap: the step's `.ended` sample of a touch that began inside the panel of
    /// its touch-down with nothing engaged, lifted at most `tapMaxS` after, never farther than `tapSlopMm` from its
    /// touch-down over every sample, lifted narrower than a palm; with no refusal in the facts, a fix at most 0.4 s
    /// old, and a target inside the panel's box with no slack, at the travel height above the table.
    private mutating func start(_ s: Step, taps: [AssistPropertyTests.Thumb], totals: inout AssistPropertyTests.Totals)
        -> String?
    {
        let label = "a move to a point starts only from a tap"
        if s.recorded.filter({ $0 == .going }).count != 1 || s.engagementBefore != nil {
            return "\(label): \(s.recorded) with \(String(describing: s.engagementBefore)) before"
        }
        if s.facts.refusal != nil { return "\(label): refused by the facts \(s.facts)" }
        guard let fix = s.facts.arm, fix.ageS <= Self.freshS else {
            return "\(label): with no fresh arm \(String(describing: s.facts.arm))"
        }
        let fitting = taps.filter { tap in
            let target = target(of: tap)
            return tap.panel!.inBox(target) && target.z == tap.panel!.tableHeight + limits.travelHeightM
                && simd_distance(fix.pinch, target) > limits.arriveToleranceM
        }
        guard let tap = fitting.first else { return "\(label): no tap in the step could go: \(taps)" }
        totals.goStarts += 1
        if lateStarts { totals.lateStarts += 1 }
        guard case .going(let goal, let since)? = s.engagement else { return nil }
        if goal != target(of: tap) || since != s.time {
            return "\(label): it goes to \(goal) since \(since), the tap asks for \(target(of: tap))"
        }
        var track = GoTrack(start: fix.pinch, target: goal, since: since, limits: limits, on: tap.panel!)
        track.saw(fix, at: s.time, limits: limits)
        if let failure = path(&track, s) { return failure }
        self.track = track
        return nil
    }

    /// The move that was going: either it goes on, keeping every rule a running move keeps, or it ended in this step,
    /// by an event (its cue is checked by `run`) or by the checks after the events, whose verdict must be one its
    /// facts allow.
    private mutating func runOrEnd(_ s: Step, totals: inout AssistPropertyTests.Totals) -> String? {
        guard var track = self.track else { return "a move to a point is followed from its start: none was seen" }
        let fix = s.facts.arm
        let fresh = fix.map { $0.ageS <= Self.freshS } ?? false
        let atTarget = fresh && simd_distance(fix!.pinch, track.target) <= limits.arriveToleranceM
        let noData = fix.map { $0.ageS > limits.armDataTimeoutS } ?? true
        let backstop = s.facts.refusal.map { $0 != .wait } ?? false
        if case .going(_, let since)? = s.engagement, since == track.since {
            track.saw(fix, at: s.time, limits: limits)
            if backstop {
                return "a move nobody holds ends when the session cannot run a hold: going with \(s.facts)"
            }
            if noData {
                return "a move to a point never outlives its arm data: going with \(String(describing: fix))"
            }
            if atTarget { return "a move to a point ends on a fresh position at its target: going at \(fix!)" }
            guard let next = s.nextDeadline, next > s.time else {
                return "a move to a point ends at its deadline: going, next \(String(describing: s.nextDeadline))"
            }
            if s.facts.refusal == .wait { sawWait = true }
            let failure = path(&track, s)
            self.track = track
            return failure
        }
        self.track = nil
        if let kind = Self.doorKind(s.events) {
            totals.goEndings[kind, default: 0] += 1
            return nil
        }
        // Ended by the checks after the events.
        if !backstop { track.saw(fix, at: s.time, limits: limits) }
        let ending = s.drives.first
        let label = "a move to a point ends by its verdicts"
        let kind: String
        if backstop {
            kind = "the backstop"
            if ending != .ended(.unnamed) { return "\(label): \(String(describing: ending)) with \(s.facts)" }
        } else if noData {
            kind = "no arm data"
            if ending != .ended(.noArmData) {
                return "\(label): \(String(describing: ending)) with \(String(describing: fix))"
            }
        } else {
            switch ending {
            case .arrived?:
                kind = "arrival"
                if !atTarget { return "\(label): \"Arrived.\" on \(String(describing: fix)), target \(track.target)" }
            case .ended(.stoppedShort)?:
                kind = "stopped short"
                if let failure = settled(track, fix: fix, at: s.time) { return failure }
            case .ended(.timeLimit)?:
                kind = "time limit"
                if s.time < track.firstDeadline - 1e-9 {
                    return "\(label): time is up at \(s.time), before the deadline \(track.firstDeadline)"
                }
            default:
                return "\(label): \(String(describing: ending)) on \(String(describing: fix)) with \(s.facts)"
            }
        }
        totals.goEndings[kind, default: 0] += 1
        return nil
    }

    /// A move to a point keeps to its speed, goes level only once a fresh position has reached the travel height, and
    /// commands no point outside the work box its tap was judged against. A move that starts outside that box (the arm
    /// stood there, or the panel changed since the last move) commands nothing farther out on any axis than its start.
    private func path(_ track: inout GoTrack, _ s: Step) -> String? {
        guard let offset = s.offset else { return "a move to a point streams its offset while it goes: none" }
        if let last = track.offsets.last,
            simd_distance(offset, last.offset) > limits.speedMps * (s.time - last.at) + 1e-9
        {
            return "a move to a point keeps to its speed: from \(last.offset) at \(last.at) to \(offset)"
        }
        if !track.travelHeightSeen, offset.x != 0 || offset.y != 0 {
            return "a move to a point goes level only once a fresh position reached the travel height: \(offset)"
        }
        let point = track.start + OperatorFrame.base(fromLink: offset)
        let low = simd_min(track.boxLow, track.start) - 1e-9
        let high = simd_max(track.boxHigh, track.start) + 1e-9
        if any(point .< low) || any(point .> high) {
            return "a move to a point commands no point outside the work box it was given: \(point) is outside "
                + "\(track.boxLow) to \(track.boxHigh), the move began at \(track.start)"
        }
        track.offsets.append((s.time, offset))
        return nil
    }

    /// Stopped short only on a fresh fix with the link not pausing, after the arm settled for the settle time on
    /// positions measured after the command reached its leg's end (it stood still all that while), after the last
    /// pause, and after the start's grace, counted from the later of the start and that pause, unless a fix had already
    /// shown the arm moving.
    private func settled(_ track: GoTrack, fix: ArmFix?, at time: TimeInterval) -> String? {
        let label = "a move to a point stops short only once its arm settled"
        guard let fix, fix.ageS <= Self.freshS, !fix.holdPaused else {
            return "\(label): on \(String(describing: fix))"
        }
        let from = time - fix.ageS - limits.settleS
        let window = track.offsets.filter { $0.at >= from + 1e-9 }
        if let first = window.first, window.contains(where: { $0.offset != first.offset }) {
            return "\(label), with the command at its leg's end: it moved after \(from)"
        }
        if let paused = track.lastPausedAt, paused >= from + 1e-9 {
            return "\(label), after the last pause: paused at \(paused), settling from \(from)"
        }
        if !track.seenMoving {
            let graceEnds = max(track.since, track.lastPausedAt ?? -.infinity) + limits.startGraceS
            if graceEnds >= from + 1e-9 { return "\(label), after the start's grace: it ends at \(graceEnds)" }
        }
        return nil
    }

    /// What refused a tap in this step, counted by kind.
    private func countRefusals(_ s: Step, totals: inout AssistPropertyTests.Totals) {
        let stopFirst =
            s.events.firstIndex(where: AssistPropertyTests.isStop).map { stop in
                s.events[..<stop].allSatisfy {
                    if case .touch(let t) = $0, t.phase == .ended { return false } else { return true }
                }
            } ?? false
        for case .cue(.refused(let refusal)) in s.commands {
            let kind: String
            switch refusal {
            case .outsideWorkArea: kind = "the work box"
            case .noArmData: kind = "no fresh arm"
            case .stopped where stopFirst && s.facts.refusal == nil: kind = "a STOP earlier in the step"
            default:
                guard refusal == s.facts.refusal else { continue }
                kind = "the facts"
            }
            totals.refusedTaps[kind, default: 0] += 1
        }
    }

    /// What ended a move nobody holds among `events`, by kind, or nil when none of them did.
    private static func doorKind(_ events: [InputEvent]) -> String? {
        for event in events {
            switch event {
            case .keyDown:
                return "a key"
            case .touch(let s) where s.phase == .began:
                switch ArbiterRig.layout.zone(x: s.x, y: s.y) {
                case .bottomBand:
                    return "STOP"
                case .controlSurface, .gear, .topBand:
                    let palm = InputConstants.appendixA.palmRadiusPt
                    if s.majorRadius < palm, !ArbiterRig.layout.isAtSideEdge(x: s.x) { return "a touch" }
                case .gap, .bottomSafeArea:
                    break
                }
            case .holdsEnded, .becameActive, .modeChanged, .assistChanged:
                return "an interruption"
            default:
                continue
            }
        }
        return nil
    }
}
