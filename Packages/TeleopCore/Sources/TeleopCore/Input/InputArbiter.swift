import Foundation
import simd

/// Decides what every key press, touch and phone turn means under scheme A or B (INTERACTION Part 2), with the time
/// passed in. Feed it events with the facts of the moment; it returns the commands to carry out, in order. It owns
/// everything that moves the arm on the operator's behalf: a hold tied to an input that is down, a follow latched with
/// no input down, and a move to a point tapped on the guide. Each of those starts and ends here.
///
/// It does not wait for the server: a start it issues is engaged until it issues the stop. Holding a start back
/// behind a finishing hold is `TeleopLink`'s job.
public struct InputArbiter: Sendable {
    public let constants: InputConstants
    /// Touches are judged against the layout current at their touch-down.
    public var layout: SurfaceLayout
    public private(set) var scheme: InputScheme
    public private(set) var hand: Hand
    /// The aids allowed now. Changed only by `.assistChanged`, which ends every hold first.
    public private(set) var assist: Assist

    private var keys: [InputKey: KeyState] = [:]
    private var keyBeganAt: [InputKey: TimeInterval] = [:]
    private var keyEndedAt: [InputKey: TimeInterval] = [:]
    /// Keys that were down when the app left the active state; whether they still are is unknown (I-11).
    private var staleKeys: Set<InputKey> = []
    private var touches: [Int: TouchRole] = [:]
    private var engaged: Engagement?
    /// The going move's path. Set exactly while `engaged` is `.going`: by a tap that starts one, cleared by its ending.
    private var move: GoMove?
    /// The engaged wrist hold's mapper.
    private var wrist: RotationMapper?
    private var lastWristTarget = WristTarget.identity
    private var attitude: simd_quatd?
    private var commandedTiltSinceReset = 0.0
    /// The engaged wrist hold's commanded tilt when the last reset came during it; only what it commands after that
    /// counts toward the window.
    private var tiltAtReset = 0.0
    private var now: TimeInterval = -.infinity
    private var facts = InputFacts()
    private var out: [InputCommand] = []
    /// An accepted STOP touch-down came earlier in this call: nothing later in it starts a move nobody holds or a
    /// latch attempt.
    private var stoppedInCall = false

    /// What each `.startTranslation` the last call emitted was, in order: `.phone` for a held or latched start (the
    /// link follows the phone), `.going` for a move to a tapped point (the link streams `goOffset(at:)`). Emptied at
    /// the top of every call, so it is readable until the next one. Its owner carries each start by this, never by
    /// `engagement` after the call: a STOP later in the same call has already emptied the slot. Never `.pad`.
    public private(set) var startsThisCall: [ArmSource] = []

    private enum KeyState: Equatable, Sendable { case engaged, dead }

    private enum TouchRole: Equatable, Sendable {
        /// Filtered out, in the gap or in the bottom safe area: never acts, never cues.
        case ignored
        /// Bottom band: acted on at touch-down.
        case stop
        case band(BandTouch)
        case surface(SurfaceTouch)
    }

    private struct BandTouch: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            /// Inside the palm window.
            case pending
            /// A gear touch past the palm window, waiting for its lift.
            case live
            case counting
            /// Dead; owes NO with this reason once the palm window is over, unless it turns out to be a palm.
            case dead(owes: InputRefusal?)
        }

        var downAt: TimeInterval
        var onGear: Bool
        var phase: Phase
    }

    private struct SurfaceTouch: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            /// Scheme A undecided, scheme B in its dwell.
            case waiting
            /// Dead until lifted. `owesNO`: began while something was engaged, so it plays NO if it ever would have
            /// acted (A-3d, B-6).
            case dead(owesNO: Bool)
            case engaged
            /// Scheme B's centre band inside the guide's view from above, with tap-to-go allowed. Without the guide
            /// this touch is dead and silent; here it can also be a tap at its lift, and nothing else. `held` reports
            /// it `.dead`.
            case tapOnly
        }

        var downAt: TimeInterval
        var down: SIMD2<Double>
        var at: SIMD2<Double>
        var side: SurfaceLayout.Side
        /// Scheme A: turn and tilt from the attitude at touch-down.
        var mapper: RotationMapper
        var phase: Phase
        var windowEnded = false
        /// Variant 2: it began during the upper key's translation hold, and may latch that hold by sliding up.
        var latch: LatchAttempt?
        /// The guide's view from above as it was at touch-down, when the touch began inside it with nothing engaged and
        /// tap-to-go allowed. A tap is judged against this one rectangle and projection. Nil: it is never a tap.
        var panel: GoPanel?
        /// The farthest it has been from its touch-down point over every sample, the lift sample included,
        /// millimetres. Kept only while `panel` is set.
        var farthestMm = 0.0
        /// Its lift sample was at least `palmRadiusPt` wide: a palm at the lift is never a tap, whether or not its
        /// palm window was over.
        var liftWide = false
    }

    /// A thumb that may latch the upper key's hold by sliding up the glass (variant 2).
    private struct LatchAttempt: Equatable, Sendable {
        /// It has gone `slideUnderWayMm` up the glass while mostly up, and stayed mostly up since.
        var underWay = false
        /// A NO the 1.0.1 rules owed it fell due while it was under way. It plays when the attempt ends without a
        /// latch; a latch drops it.
        var withheldNO = false
    }

    public init(
        scheme: InputScheme, hand: Hand = .right, layout: SurfaceLayout, constants: InputConstants = .appendixA,
        assist: Assist = .off
    ) {
        self.scheme = scheme
        self.hand = hand
        self.layout = layout
        self.constants = constants
        self.assist = assist
    }

    // MARK: Reading the state

    /// Every key and every touch that passed the filters, while it is down, and what it is doing.
    public var held: [HeldInput: InputPhase] {
        var result: [HeldInput: InputPhase] = [:]
        for (key, state) in keys {
            if state == .engaged, case .held(.key(key), let kind)? = engaged {
                result[.key(key)] = .engaged(kind)
            } else {
                result[.key(key)] = .dead
            }
        }
        for (id, role) in touches {
            switch role {
            case .ignored, .stop:
                continue
            case .band(let band):
                switch band.phase {
                case .pending, .live: result[.touch(id)] = .waiting
                case .counting: result[.touch(id)] = .countingDown
                case .dead: result[.touch(id)] = .dead
                }
            case .surface(let touch):
                switch touch.phase {
                case .waiting: result[.touch(id)] = .waiting
                case .dead, .tapOnly: result[.touch(id)] = .dead
                case .engaged:
                    if case .held(.touch(id), let kind)? = engaged { result[.touch(id)] = .engaged(kind) }
                }
            }
        }
        return result
    }

    /// The hold engaged now, if any.
    /// The touch whose countdown started last. Kept after the countdown ends, so its owner can still tell which touch
    /// a `resetCountdownStarted` and `fireReset` read in the same step came from.
    public private(set) var countdownTouchID: Int?

    /// What is engaged now: a hold and the input it is tied to, a follow nobody holds, or the countdown.
    public var engagement: Engagement? { engaged }

    /// A follow nobody holds reports `.translation`, the hold the session runs for it.
    public var engagedHold: HoldKind? { engaged?.holdKind }

    /// A volume key or a control-surface touch is down, whatever it is doing (§0.2; the voice gate V-2).
    public var isHoldingAnInput: Bool {
        !keys.isEmpty || touches.values.contains { if case .surface = $0 { return true } else { return false } }
    }

    /// When the next timer runs out, or a move nobody holds reaches its time limit, so the owner can tick then instead
    /// of waiting for its next 30 Hz tick. The limit itself is judged after the events of a call, not fired as a timer.
    public var nextDeadline: TimeInterval? {
        let timer = earliestDeadline()?.at
        guard let limit = looseDeadline else { return timer }
        return min(timer ?? limit, limit)
    }

    /// When the move nobody holds must end at the latest.
    private var looseDeadline: TimeInterval? {
        switch engaged {
        case .latched(let since)?: return since + (assist.lock?.timeLimitS ?? 0)
        case .going?: return move?.deadline
        default: return nil
        }
    }

    /// The going move's offset at `time`, metres, in the frame `TeleopLink.poseUpdate(positionMeters:)` takes: the
    /// whole way asked for since the move began. Nil when no move to a tapped point is going. On this arbiter's clock:
    /// a time before the newest call's counts as that call's, so the owner never does arithmetic on the rules' times.
    public func goOffset(at time: TimeInterval) -> SIMD3<Double>? {
        guard case .going? = engaged, let move else { return nil }
        return move.linkOffset(at: max(time, now))
    }

    // MARK: Handling events

    public mutating func handle(_ event: InputEvent, at time: TimeInterval, facts: InputFacts) -> [InputCommand] {
        handle([event], at: time, facts: facts)
    }

    /// Events that happened at the same instant, applied in the order given, except that an attitude sample is judged
    /// before the touch moves given ahead of it (A-6t). Timers that ran out before this instant fire first; a timer
    /// that runs out at this very instant fires after the events, so a lift, a palm, a swipe or `holdsEnded` at the
    /// deadline still counts.
    ///
    /// Between the events and the timers of this instant, a move nobody holds is checked once (`gate`). No aid has a
    /// timer, so nothing before the events can start or end one, and a STOP among the events always comes ahead of
    /// the checks' endings. The events keep their order under every configuration: a STOP ends the move that exists
    /// when it is applied, one started earlier in the same call included, and nothing after it in the call starts one.
    public mutating func handle(_ events: [InputEvent], at time: TimeInterval, facts: InputFacts) -> [InputCommand] {
        out = []
        self.facts = facts
        stoppedInCall = false
        startsThisCall = []
        let time = max(time, now)
        advance(to: time, firingTies: false)
        for event in ordered(events) {
            apply(event)
        }
        gate()
        advance(to: time, firingTies: true)
        return out
    }

    /// Moves each attitude sample ahead of the touch moves just before it, and of the ticks and the key-ups of keys
    /// that are not down, which do nothing.
    private func ordered(_ events: [InputEvent]) -> [InputEvent] {
        var result: [InputEvent] = []
        var yields: [Bool] = []
        // Keys a key-up would act on, as of each event in turn.
        var down = Set(keys.keys).union(staleKeys)
        for event in events {
            guard case .attitude = event else {
                yields.append(Self.yieldsToAttitude(event, down: &down))
                result.append(event)
                continue
            }
            var index = result.endIndex
            while index > result.startIndex, yields[index - 1] { index -= 1 }
            result.insert(event, at: index)
            yields.insert(false, at: index)
        }
        return result
    }

    private static func yieldsToAttitude(_ event: InputEvent, down: inout Set<InputKey>) -> Bool {
        switch event {
        case .touch(let sample): return sample.phase == .moved
        case .tick: return true
        // Only a key-up whose key is not down: one that ends a hold must still come first.
        case .keyUp(let key): return down.remove(key) == nil
        case .keyDown(let key):
            down.insert(key)
            return false
        default: return false
        }
    }

    private mutating func apply(_ event: InputEvent) {
        switch event {
        case .keyDown(let key): keyDown(key)
        case .keyUp(let key): keyUp(key)
        case .touch(let sample): touch(sample)
        case .attitude(let q): attitudeSample(q)
        case .tick: break
        case .holdsEnded(let reason): holdsEnded(reason)
        case .becameActive:
            // The app left without saying so first: a move nobody holds ran while it was away.
            endLoose(.ended(.appLeft))
            becameActive()
        case .modeChanged(let newScheme, let newHand):
            // Sent only from Settings, where nothing is engaged; a move nobody holds still never ends in silence.
            endLoose(.ended(.unnamed))
            endAllHolds()
            scheme = newScheme
            hand = newHand
        case .assistChanged(let newAssist):
            endLoose(.ended(.unnamed))
            endAllHolds()
            assist = newAssist
        case .sceneReset:
            commandedTiltSinceReset = 0
            tiltAtReset = lastWristTarget.axis == .tilt ? lastWristTarget.degrees : 0
            // Without measured flex, the engaged tilt hold's window now counts from where the hold stood at the reset.
            if lastWristTarget.axis == .tilt, facts.wrist.flexDeg == nil || facts.wrist.flexAtResetDeg == nil {
                wrist?.setRange(
                    RotationMapper.limits(
                        for: .tilt, readings: .unknown, commandedTiltSinceResetDeg: -tiltAtReset, constants: constants
                    ))
            }
        case .wristStartSent:
            guard case .held(_, .wrist)? = engaged, let q = attitude, var mapper = wrist else { return }
            // The target streamed from now on drops the rotation made while the start waited.
            let target = mapper.startSent(attitude: q, at: now)
            wrist = mapper
            emitWrist((target, false))
        }
    }

    // MARK: Keys (I-2, A-1, A-2, B-1, B-2)

    private mutating func keyDown(_ key: InputKey) {
        guard keys[key] == nil else { return }
        if engaged?.isLoose == true {
            // Any press ends a move nobody holds, ahead of every check below, a stale key's included. The key is dead
            // and silent until released, so it starts nothing of its own.
            staleKeys.remove(key)
            keyBeganAt[key] = now
            keys[key] = .dead
            endLoose(.byYou)
            return
        }
        if staleKeys.remove(key) != nil {
            // Still held from before the app left, or pressed again after a release that never arrived: dead either
            // way, and the NO says to press again.
            keyBeganAt[key] = now
            keys[key] = .dead
            cue(.dead)
            return
        }
        let other = key.other
        let previousBegan = keyBeganAt[other]
        keyBeganAt[key] = now
        // One key at a time (I-2.4), then first press wins (I-2.1).
        let chord = previousBegan.map { now - $0 <= constants.keyChordMs / 1000 + Self.slack } ?? false
        let replay =
            constants.keyReplayGuard
            && (keyEndedAt[other].map { now - $0 <= constants.keyReplayMs / 1000 + Self.slack } ?? false)
        if keys[other] != nil || chord || replay || engaged != nil {
            keys[key] = .dead
            cue(.dead)
            return
        }
        // A key wins over an undecided touch, which dies silently (I-2.2, A-8, B-4); so does a touch that could only
        // have been a tap.
        for (id, role) in touches {
            if case .surface(var touch) = role, touch.phase == .waiting || touch.phase == .tapOnly {
                touch.phase = .dead(owesNO: false)
                touches[id] = .surface(touch)
            }
        }
        if key == .upper, assist.lock?.variant == .pressPress {
            // The press itself starts the follow. The key is dead from now on, so its release stops nothing and the
            // next press ends the follow.
            keys[key] = .dead
            startLatched()
            return
        }
        let kind: HoldKind
        switch (key, scheme) {
        case (.upper, _): kind = .translation
        case (.lower, .screenTurns): kind = .gripper(.closed)
        case (.lower, .keyTurns): kind = .wrist
        }
        keys[key] = start(kind, by: .key(key)) ? .engaged : .dead
    }

    private mutating func keyUp(_ key: InputKey) {
        if staleKeys.remove(key) != nil {
            keyEndedAt[key] = now
            return
        }
        guard let state = keys.removeValue(forKey: key) else { return }
        keyEndedAt[key] = now
        if state == .engaged, case .held(.key(key), _)? = engaged { stopEngaged() }
    }

    // MARK: Touches (§2.2)

    private mutating func touch(_ sample: TouchSample) {
        switch sample.phase {
        case .began:
            if touches[sample.id] != nil { touchEnded(sample.id, cancelled: true) }
            touchBegan(sample)
        case .moved:
            touchMoved(sample)
        case .ended, .cancelled:
            // The sample that lifts a contact counts like any other: a palm by it, still inside its window, was a palm
            // all along, so it neither opens Settings nor plays the NO it owed.
            _ = ignoredAsPalm(sample)
            // A possible tap is judged on the whole touch: where the lift lands, and how wide it is.
            if case .surface(var touch)? = touches[sample.id], touch.panel != nil {
                let lift = SIMD2(sample.x, sample.y)
                touch.farthestMm = max(touch.farthestMm, layout.millimetres(simd_length(lift - touch.down)))
                touch.liftWide = sample.majorRadius >= constants.palmRadiusPt
                touches[sample.id] = .surface(touch)
            }
            touchEnded(sample.id, cancelled: sample.phase == .cancelled)
        }
    }

    private mutating func touchBegan(_ s: TouchSample) {
        let zone = layout.zone(x: s.x, y: s.y)
        let palm = s.majorRadius >= constants.palmRadiusPt
        switch zone {
        case .bottomSafeArea:
            // The system's swipe home begins here; it must not stop the robot, nor count as the thumb.
            touches[s.id] = .ignored
        case .bottomBand:
            // No filter applies: a palm here stops the robot too (I-3).
            touches[s.id] = .stop
            // A reset counting down, or a top band touch that would start one, began before this STOP: it must not
            // fire after it and release the stop. Those fingers stay dead until lifted; a new hold, begun after the
            // STOP, may reset from it.
            if case .countdown? = engaged {
                engaged = nil
                out.append(.resetCountdownCancelled)
            }
            for (id, role) in touches {
                if case .band(var band) = role, !band.onGear, band.phase == .pending || band.phase == .counting {
                    band.phase = .dead(owes: nil)
                    touches[id] = .band(band)
                }
            }
            out.append(.emergencyStop)
            stoppedInCall = true
            // The stop goes first; then a move nobody holds ends, one started earlier in this call included. The
            // session's ALARM is its cue.
            endLoose(.stop)
            if !facts.connectionUp { cue(.refused(.notStopped)) }
            // It also ends every latch attempt, so a slide begun before it never latches the hold, in this call or a
            // later one. A NO an attempt withheld plays after the stop's own cues.
            endAttempts()
        case .gap:
            touches[s.id] = .ignored
        case .gear, .topBand:
            if palm || layout.isAtSideEdge(x: s.x) {
                touches[s.id] = .ignored
                return
            }
            if engaged?.isLoose == true {
                // It ends the move nobody holds and does nothing else until lifted: no countdown, no Settings and no
                // "Let go first.".
                touches[s.id] = .band(BandTouch(downAt: now, onGear: zone == .gear, phase: .dead(owes: nil)))
                endLoose(.byYou)
                return
            }
            let phase: BandTouch.Phase
            if engaged != nil {
                phase = .dead(owes: .letGoFirst)
            } else if zone == .topBand, let refusal = facts.resetRefusal {
                phase = .dead(owes: refusal)
            } else {
                phase = .pending
            }
            touches[s.id] = .band(BandTouch(downAt: now, onGear: zone == .gear, phase: phase))
        case .controlSurface:
            if palm || layout.isAtSideEdge(x: s.x) {
                touches[s.id] = .ignored
                return
            }
            let side = layout.side(x: s.x, hand: hand)
            let point = SIMD2(s.x, s.y)
            let mapper = RotationMapper(anchor: attitude, startsAtCommit: true, constants: constants)
            if engaged?.isLoose == true {
                // Anywhere on the surface, scheme B's centre band included, and even with another thumb tracked: one
                // thumb at a time protects the gestures, never a move nobody holds. Dead and silent until lifted.
                touches[s.id] = .surface(
                    SurfaceTouch(
                        downAt: now, down: point, at: point, side: side, mapper: mapper, phase: .dead(owesNO: false)))
                endLoose(.byYou)
                return
            }
            let tracked = touches.values.contains { if case .surface = $0 { return true } else { return false } }
            if tracked {
                touches[s.id] = .ignored
                return
            }
            // With tap-to-go allowed and nothing engaged, a touch that begins inside the guide's view from above may be
            // a tap. It keeps the view as it is now, so its tap is judged against what was drawn under it.
            var panel: GoPanel?
            if assist.goTo != nil, engaged == nil, let view = facts.goPanel, view.contains(x: s.x, y: s.y) {
                panel = view
            }
            let phase: SurfaceTouch.Phase
            switch scheme {
            case .screenTurns:
                phase = engaged != nil ? .dead(owesNO: true) : .waiting
            case .keyTurns:
                // The centre band never acts, so it never owes NO either; inside the guide's view it can still be a
                // tap.
                if side == .centre {
                    phase = panel != nil ? .tapOnly : .dead(owesNO: false)
                } else {
                    phase = engaged != nil ? .dead(owesNO: true) : .waiting
                }
            }
            var touch = SurfaceTouch(downAt: now, down: point, at: point, side: side, mapper: mapper, phase: phase)
            touch.panel = panel
            if assist.lock?.variant == .holdThenSlide, engaged == .held(.key(.upper), .translation), !stoppedInCall {
                // Anywhere on the surface, scheme B's centre band included, a thumb may latch the upper key's hold,
                // unless a STOP came earlier in this call. Its phase stays as 1.0.1 has it.
                touch.latch = LatchAttempt()
            }
            touches[s.id] = .surface(touch)
        }
    }

    /// Marks a contact that is a palm by this sample, and still inside its palm window, as ignored. True when it did.
    private mutating func ignoredAsPalm(_ s: TouchSample) -> Bool {
        guard s.majorRadius >= constants.palmRadiusPt, let role = touches[s.id] else { return false }
        switch role {
        case .ignored, .stop:
            return false
        case .band(let band):
            // A band whose window timer already fired at this instant is past its window.
            guard band.phase != .counting, band.phase != .live, insidePalmWindow(band.downAt) else { return false }
        case .surface(let touch):
            guard !touch.windowEnded else { return false }
        }
        touches[s.id] = .ignored
        return true
    }

    private mutating func touchMoved(_ s: TouchSample) {
        if ignoredAsPalm(s) { return }
        guard case .surface(var touch)? = touches[s.id] else { return }
        touch.at = SIMD2(s.x, s.y)
        if touch.panel != nil {
            touch.farthestMm = max(touch.farthestMm, layout.millimetres(simd_length(touch.at - touch.down)))
        }
        touches[s.id] = .surface(touch)
        // The attempt is followed first, so a NO that falls due now is withheld if the slide is under way.
        if touch.latch != nil { followAttempt(s.id) }
        if touch.windowEnded { judge(s.id) }
    }

    private mutating func touchEnded(_ id: Int, cancelled: Bool) {
        guard let role = touches.removeValue(forKey: id) else { return }
        switch role {
        case .ignored, .stop:
            break
        case .surface(let touch):
            if touch.phase == .engaged, case .held(.touch(id), _)? = engaged { stopEngaged() }
            // Lifted without a latch: the NO it withheld plays now.
            if touch.latch?.withheldNO == true { cue(.dead) }
            if !cancelled, let panel = touch.panel, isTap(touch) { tap(at: touch.down, on: panel) }
        case .band(let band):
            switch band.phase {
            case .pending, .live:
                // A tap on the gear opens Settings when nothing is engaged, and is dead (NO + "Let go first.")
                // otherwise.
                if band.onGear, !cancelled, now - band.downAt < constants.gearTapS {
                    if engaged == nil {
                        out.append(.openSettings)
                    } else {
                        cue(.refused(.letGoFirst))
                    }
                }
            case .counting:
                engaged = nil
                out.append(.resetCountdownCancelled)
            case .dead(let owes):
                // Lifted inside the palm window without growing: not a palm, so the NO it owes plays now.
                if let owes { cue(.refused(owes)) }
            }
        }
    }

    /// Inclusive at its end, as on the control surface, where the window's timer fires after the events of its instant.
    private func insidePalmWindow(_ downAt: TimeInterval) -> Bool {
        now <= downAt + constants.palmWindowMs / 1000 + Self.slack
    }

    // MARK: Phone attitude (I-8, A-6, B-2)

    private mutating func attitudeSample(_ q: simd_quatd) {
        // A sample that is not a rotation (NaN, infinite or zero) would poison every later target of the hold.
        let length = simd_length(q.vector)
        guard length.isFinite, length > 0.5 else { return }
        attitude = q
        for (id, role) in touches {
            if case .surface(var touch) = role, touch.mapper.anchor == nil {
                touch.mapper.anchorIfNeeded(q)
                touches[id] = .surface(touch)
            }
        }
        if case .held(_, .wrist)? = engaged, var mapper = wrist {
            let result: (target: WristTarget, limitReached: Bool)
            if mapper.axis == nil, let axis = mapper.dominantAxis(mapper.angles(q)) {
                result = mapper.lock(axis, range: limits(axis), attitude: q, at: now)
            } else {
                result = mapper.target(for: q, at: now)
            }
            wrist = mapper
            emitWrist(result)
        }
        if scheme == .screenTurns {
            for id in touches.keys.sorted() {
                if case .surface(let touch)? = touches[id], touch.windowEnded { judge(id) }
            }
        }
    }

    // MARK: Judging a control-surface touch

    private mutating func judge(_ id: Int) {
        switch scheme {
        case .screenTurns: judgeScreenTurns(id)
        case .keyTurns: judgeKeyTurnsMove(id)
        }
    }

    private enum ScreenTurnsOutcome { case wrist(WristAxis), open, unclear, sideways }

    /// A-4, A-4b, A-5, A-6 for the touch as it is now; nil while it has not decided. The attitude is judged first.
    private func screenTurnsOutcome(_ touch: SurfaceTouch) -> ScreenTurnsOutcome? {
        let angles = attitude.map { touch.mapper.angles($0) } ?? .zero
        if let axis = touch.mapper.dominantAxis(angles) { return .wrist(axis) }
        switch ThumbSlide.judge(from: touch.down, to: touch.at, layout: layout, constants: constants) {
        case .short: return nil
        case .sideways: return .sideways
        case .up: return touch.mapper.reachedLockAngle(angles) ? .unclear : .open
        }
    }

    private mutating func judgeScreenTurns(_ id: Int) {
        guard case .surface(var touch)? = touches[id], let outcome = screenTurnsOutcome(touch) else { return }
        switch touch.phase {
        case .waiting:
            switch outcome {
            case .wrist(let axis):
                touch.phase = .engaged
                touches[id] = .surface(touch)
                if !start(.wrist, by: .touch(id), mapper: touch.mapper, axis: axis) { markDead(id) }
            case .open:
                touch.phase = .engaged
                touches[id] = .surface(touch)
                if !start(.gripper(.open), by: .touch(id)) { markDead(id) }
            case .unclear, .sideways:
                markDead(id)
                cue(.dead)
            }
        case .dead(owesNO: true):
            switch outcome {
            case .wrist, .open: oweNO(id)
            case .unclear, .sideways: break
            }
            markDead(id)
        case .dead(owesNO: false), .engaged, .tapOnly:
            break
        }
    }

    /// B-3m: moving 10 mm within the dwell makes the touch a swipe. Unlike A-4, the rule names no measure, so it is
    /// the straight distance from touch-down: a diagonal swipe counts as soon as it has gone 10 mm.
    private mutating func judgeKeyTurnsMove(_ id: Int) {
        guard case .surface(let touch)? = touches[id] else { return }
        guard layout.millimetres(simd_length(touch.at - touch.down)) >= constants.openSlideMm - 1e-9 else { return }
        switch touch.phase {
        case .waiting:
            markDead(id)
            cue(.dead)
        case .dead(owesNO: true):
            markDead(id)
        case .tapOnly:
            // Moved too far to be a tap, the only thing it could have been: dead and silent, as without the guide.
            markDead(id)
        case .dead(owesNO: false), .engaged:
            break
        }
    }

    /// B-3, B-3g, B-3c, B-6: the dwell completed with the touch still down.
    private mutating func completeDwell(_ id: Int) {
        guard case .surface(var touch)? = touches[id] else { return }
        switch touch.phase {
        case .waiting:
            let action: GripperState = touch.side == .near ? .closed : .open
            touch.phase = .engaged
            touches[id] = .surface(touch)
            if !start(.gripper(action), by: .touch(id)) { markDead(id) }
        case .dead(owesNO: true):
            oweNO(id)
            markDead(id)
        case .dead(owesNO: false), .engaged, .tapOnly:
            break
        }
    }

    /// A NO the 1.0.1 rules owe this touch falls due. It plays now, unless the touch is a latch attempt under way: then
    /// it waits until the attempt ends, and a latch drops it. An attempt that played its NO is spent.
    private mutating func oweNO(_ id: Int) {
        guard case .surface(var touch)? = touches[id], var attempt = touch.latch, attempt.underWay else {
            cue(.dead)
            endAttempt(id)
            return
        }
        attempt.withheldNO = true
        touch.latch = attempt
        touches[id] = .surface(touch)
    }

    private mutating func markDead(_ id: Int) {
        guard case .surface(var touch)? = touches[id] else { return }
        touch.phase = .dead(owesNO: false)
        touches[id] = .surface(touch)
    }

    // MARK: Timers

    private enum Timer { case surfaceWindow, dwell, bandWindow, countdown }

    /// Times are sums of seconds in floating point; a timer due within a nanosecond is due.
    private static let slack: TimeInterval = 1e-9

    private func deadline(_ role: TouchRole) -> (at: TimeInterval, timer: Timer)? {
        let window = constants.palmWindowMs / 1000
        switch role {
        case .ignored, .stop:
            return nil
        case .band(let band):
            switch band.phase {
            case .pending, .dead(owes: _?): return (band.downAt + window, .bandWindow)
            case .counting: return (band.downAt + constants.resetHoldS, .countdown)
            case .live, .dead(owes: nil): return nil
            }
        case .surface(let touch):
            if !touch.windowEnded { return (touch.downAt + window, .surfaceWindow) }
            guard scheme == .keyTurns else { return nil }
            switch touch.phase {
            case .waiting, .dead(owesNO: true):
                let long = touch.side == .far && facts.gripping
                let dwell = (long ? constants.openWhileGrippingMs : constants.gripDwellMs) / 1000
                // Nothing completes a dwell before the palm window ends.
                return (touch.downAt + max(dwell, window), .dwell)
            case .dead(owesNO: false), .engaged, .tapOnly:
                return nil
            }
        }
    }

    private func earliestDeadline() -> (id: Int, at: TimeInterval, timer: Timer)? {
        var best: (id: Int, at: TimeInterval, timer: Timer)?
        for id in touches.keys.sorted() {
            guard let role = touches[id], let d = deadline(role) else { continue }
            if best == nil || d.at < best!.at { best = (id, d.at, d.timer) }
        }
        return best
    }

    /// Runs every timer that has run out before `time` (and, with `firingTies`, at `time`), each at its own moment.
    private mutating func advance(to time: TimeInterval, firingTies: Bool) {
        let limit = firingTies ? time + Self.slack : time - Self.slack
        while let next = earliestDeadline(), firingTies ? next.at <= limit : next.at < limit {
            now = max(now, next.at)
            fire(next.timer, for: next.id)
        }
        now = time
    }

    private mutating func fire(_ timer: Timer, for id: Int) {
        switch (timer, touches[id]) {
        case (.surfaceWindow, .surface(var touch)?):
            touch.windowEnded = true
            touches[id] = .surface(touch)
            // A threshold crossed inside the window is judged now, if it still holds.
            judge(id)
        case (.dwell, .surface?):
            completeDwell(id)
        case (.bandWindow, .band(var band)?):
            switch band.phase {
            case .dead(let owes):
                if let owes { cue(.refused(owes)) }
                band.phase = .dead(owes: nil)
            case .pending:
                if engaged != nil {
                    band.phase = .dead(owes: nil)
                    cue(.refused(.letGoFirst))
                } else if band.onGear {
                    band.phase = .live
                } else if let refusal = facts.resetRefusal {
                    band.phase = .dead(owes: nil)
                    cue(.refused(refusal))
                } else {
                    band.phase = .counting
                    engaged = .countdown(touch: id)
                    countdownTouchID = id
                    out.append(.resetCountdownStarted)
                    // A control-surface touch still undecided was down when the countdown began, so it is dead
                    // until lifted, even after the reset; it plays NO if it would commit (I-2.1, I-2.3, I-3).
                    for (other, role) in touches {
                        if case .surface(var touch) = role, touch.phase == .waiting {
                            touch.phase = .dead(owesNO: true)
                            touches[other] = .surface(touch)
                        }
                        // One that could only have been a tap is dead and silent, as it is without the guide.
                        if case .surface(var touch) = role, touch.phase == .tapOnly {
                            touch.phase = .dead(owesNO: false)
                            touches[other] = .surface(touch)
                        }
                        // So is another top band touch still in its palm window, which owes "Let go first." (I-3).
                        if other != id, case .band(var otherBand) = role, !otherBand.onGear, otherBand.phase == .pending
                        {
                            otherBand.phase = .dead(owes: .letGoFirst)
                            touches[other] = .band(otherBand)
                        }
                    }
                }
            case .live, .counting:
                break
            }
            touches[id] = .band(band)
        case (.countdown, .band(var band)?):
            band.phase = .dead(owes: nil)
            touches[id] = .band(band)
            engaged = nil
            if let refusal = facts.resetRefusal {
                out.append(.resetCountdownCancelled)
                cue(.refused(refusal))
            } else {
                out.append(.fireReset)
            }
        default:
            break
        }
    }

    // MARK: Starting and stopping

    /// Starts `kind` for `input` unless something is engaged, a fact refuses it, or the jaws already grip (A-2g,
    /// B-3c). Returns whether it started.
    private mutating func start(
        _ kind: HoldKind, by input: HeldInput, mapper: RotationMapper? = nil, axis: WristAxis? = nil
    ) -> Bool {
        if engaged != nil {
            cue(.dead)
            return false
        }
        if let refusal = refusal(for: kind) {
            cue(.refused(refusal))
            return false
        }
        if kind == .gripper(.closed), facts.gripping {
            cue(.alreadyGripping)
            return false
        }
        engaged = .held(input, kind)
        // A top band touch still in its palm window was down when this hold began: it never starts the countdown,
        // and plays NO + "Let go first." when its window ends, as it would with the hold still engaged then.
        for (id, role) in touches {
            if case .band(var band) = role, !band.onGear, band.phase == .pending {
                band.phase = .dead(owes: .letGoFirst)
                touches[id] = .band(band)
            }
        }
        switch kind {
        case .translation:
            out.append(.startTranslation)
            startsThisCall.append(.phone)
        case .gripper(let action):
            out.append(.startGripper(action))
        case .wrist:
            out.append(.startWrist)
            var wristMapper = mapper ?? RotationMapper(anchor: attitude, startsAtCommit: false, constants: constants)
            if let axis, let q = attitude {
                emitWrist(wristMapper.lock(axis, range: limits(axis), attitude: q, at: now))
            } else {
                emitWrist((.identity, false))
            }
            wrist = wristMapper
        }
        return true
    }

    private func refusal(for kind: HoldKind) -> InputRefusal? {
        if let refusal = facts.refusal { return refusal }
        switch kind {
        case .translation: return facts.trackingRefusal ?? facts.translationRefusal
        case .wrist: return facts.trackingRefusal
        case .gripper: return nil
        }
    }

    private func limits(_ axis: WristAxis) -> ClosedRange<Double> {
        RotationMapper.limits(
            for: axis, readings: facts.wrist, commandedTiltSinceResetDeg: commandedTiltSinceReset, constants: constants
        )
    }

    private mutating func emitWrist(_ result: (target: WristTarget, limitReached: Bool)) {
        lastWristTarget = result.target
        out.append(.wristUpdate(result.target))
        if result.limitReached { cue(.limit) }
    }

    /// Sends the stop for the engaged hold (I-1).
    private mutating func stopEngaged() {
        guard case .held(let input, let kind)? = engaged else { return }
        engaged = nil
        switch kind {
        case .translation:
            out.append(.stopTranslation)
            // Variant 2: with the upper key's hold over, nothing is left to latch; a NO an attempt withheld plays
            // after the stop.
            if input == .key(.upper) { endAttempts() }
        case .gripper:
            out.append(.stopGripper)
        case .wrist:
            if lastWristTarget.axis == .tilt { commandedTiltSinceReset += lastWristTarget.degrees - tiltAtReset }
            tiltAtReset = 0
            wrist = nil
            lastWristTarget = .identity
            out.append(.stopWrist)
        }
    }

    /// I-11: every hold ends and every input held now stays dead until released.
    private mutating func endAllHolds() {
        if case .countdown? = engaged {
            engaged = nil
            out.append(.resetCountdownCancelled)
        }
        stopEngaged()
        endAttempts()
        for key in keys.keys { keys[key] = .dead }
        for (id, role) in touches {
            switch role {
            case .surface(var touch):
                touch.phase = .dead(owesNO: false)
                touch.panel = nil
                touches[id] = .surface(touch)
            case .band(var band):
                band.phase = .dead(owes: nil)
                touches[id] = .band(band)
            case .ignored, .stop:
                break
            }
        }
    }

    /// I-11 on return: releases made while the app was away were never delivered. UIKit does not carry a touch across
    /// leaving the active state, so every touch is forgotten; a key may still be held, so it becomes stale.
    private mutating func becameActive() {
        endAllHolds()
        touches.removeAll()
        staleKeys.formUnion(keys.keys)
        keys.removeAll()
    }

    private mutating func cue(_ cue: InputCue) { out.append(.cue(cue)) }

    // MARK: A move nobody holds (lock, tap-to-go)

    /// How a move nobody holds ended, as the rules know it.
    private enum LooseEnd: Equatable {
        /// A key press, or a new touch the filters pass on the control surface, the top band or the gear.
        case byYou
        /// The STOP band. The session's ALARM is the cue.
        case stop
        /// Someone else has told it (`.announced`), or nothing moved (`.startRefused`).
        case silent
        /// A move to a tapped point reached it, by a measured position.
        case arrived
        case ended(DriveEnd)
    }

    /// Variant 1: the accepted press of the upper key starts a follow nobody holds. A press the facts refuse gets the
    /// refusal a held start would get. After a STOP earlier in this call it is refused as the robot being stopped: the
    /// facts are from before that STOP.
    private mutating func startLatched() {
        if let refusal = refusal(for: .translation) {
            cue(.refused(refusal))
            return
        }
        if stoppedInCall {
            cue(.refused(.stopped))
            return
        }
        engaged = .latched(since: now)
        deadenInputsDown()
        out.append(.startTranslation)
        startsThisCall.append(.phone)
        cue(.drive(.latched))
    }

    /// Runs once per call, after the call's events. A variant 2 thumb latches here, never in a call that held a STOP;
    /// then a move nobody holds is checked, which an input in this call has already ended if it was going to. Posture,
    /// tracking and the time limit cover a latched follow from its first moment. A move to a tapped point does not
    /// watch the phone: it ends on measured positions (arrived, stopped short, no arm data) and then on its deadline.
    ///
    /// The refusal backstop ends either for a refusal that means the session cannot run a hold (no link, stopped, slow
    /// link, settings open); the session's own ending for those arrives in the same turn, so this is a last resort,
    /// heard as the unnamed ending. It never ends one on `.wait`: the server shows a success or is resetting, ends the
    /// hold itself, and the link reports it; a success is told by its sound and narration.
    private mutating func gate() {
        if assist.lock?.variant == .holdThenSlide, engaged == .held(.key(.upper), .translation), !stoppedInCall {
            latchBySlide()
        }
        let backstop = facts.refusal.map { $0 != .wait } ?? false
        switch engaged {
        case .latched(let since)?:
            if backstop {
                endLoose(.ended(.unnamed))
            } else if facts.trackingRefusal != nil {
                endLoose(.ended(.tracking))
            } else if facts.translationRefusal != nil {
                endLoose(.ended(.posture))
            } else if now >= since + (assist.lock?.timeLimitS ?? 0) - Self.slack {
                endLoose(.ended(.timeLimit))
            }
        case .going?:
            guard !backstop else { return endLoose(.ended(.unnamed)) }
            guard var current = move else { return }
            let verdict = current.observe(facts.arm, at: now)
            move = current
            switch verdict {
            case .arrived?: endLoose(.arrived)
            case .stoppedShort?: endLoose(.ended(.stoppedShort))
            case .noArmData?: endLoose(.ended(.noArmData))
            case nil: if now >= current.deadline - Self.slack { endLoose(.ended(.timeLimit)) }
            }
        default:
            break
        }
    }

    /// Variant 2: a thumb whose palm window is over and whose slide from touch-down is a deliberate one up the glass
    /// (`ThumbSlide`) latches the upper key's hold. The session's hold goes on, so nothing is sent; the key, still
    /// down, and the thumb are dead from now on. When a fact refuses translation the thumb is spent instead, and a NO
    /// it withheld plays, as 1.0.1 owed it.
    private mutating func latchBySlide() {
        for id in touches.keys.sorted() {
            guard case .surface(let touch)? = touches[id], touch.latch != nil, touch.windowEnded,
                ThumbSlide.judge(from: touch.down, to: touch.at, layout: layout, constants: constants) == .up
            else { continue }
            if refusal(for: .translation) != nil {
                endAttempt(id)
            } else {
                engaged = .latched(since: now)
                deadenInputsDown()
                cue(.drive(.latched))
            }
            return
        }
    }

    /// Variant 2: where a latch attempt's slide has got to. Once it has gone `slideUnderWayMm` up the glass while
    /// mostly up it is under way, and a NO it owes waits; it ends, playing a NO it withheld, when it stops being
    /// mostly up after that, or when the slide turns out sideways.
    private mutating func followAttempt(_ id: Int) {
        guard case .surface(var touch)? = touches[id], var attempt = touch.latch else { return }
        let mostlyUp = ThumbSlide.mostlyUp(from: touch.down, to: touch.at)
        let up = ThumbSlide.upMillimetres(from: touch.down, to: touch.at, layout: layout)
        if mostlyUp, up >= constants.slideUnderWayMm - 1e-9 {
            attempt.underWay = true
        } else if attempt.underWay, !mostlyUp {
            return endAttempt(id)
        }
        if ThumbSlide.judge(from: touch.down, to: touch.at, layout: layout, constants: constants) == .sideways {
            return endAttempt(id)
        }
        touch.latch = attempt
        touches[id] = .surface(touch)
    }

    /// Ends a latch attempt without a latch: a NO it withheld plays now.
    private mutating func endAttempt(_ id: Int) {
        guard case .surface(var touch)? = touches[id], let attempt = touch.latch else { return }
        touch.latch = nil
        touches[id] = .surface(touch)
        if attempt.withheldNO { cue(.dead) }
    }

    /// Every latch attempt ends without a latch, in a fixed order.
    private mutating func endAttempts() {
        for id in touches.keys.sorted() { endAttempt(id) }
    }

    /// A move nobody holds begins: every input already down becomes dead and silent, as `endAllHolds` marks them but
    /// without a stop. Each surface touch, undecided or dead but still owing a NO, becomes dead owing nothing, and a
    /// latch attempt's withheld NO is dropped, as is a possible tap; each top band or gear touch becomes dead owing
    /// nothing, so no countdown, no Settings and no "Let go first."; each key down becomes dead. Their later moves,
    /// timers, lifts and releases emit nothing. Only an input that goes down after the start can end the move.
    private mutating func deadenInputsDown() {
        for key in keys.keys { keys[key] = .dead }
        for (id, role) in touches {
            switch role {
            case .surface(var touch):
                touch.phase = .dead(owesNO: false)
                touch.latch = nil
                touch.panel = nil
                touches[id] = .surface(touch)
            case .band(var band):
                band.phase = .dead(owes: nil)
                touches[id] = .band(band)
            case .ignored, .stop:
                break
            }
        }
    }

    /// Ends the move nobody holds: the stop first, then the cue its ending plays. Does nothing when there is none, so
    /// two endings in one call stop once and cue once.
    private mutating func endLoose(_ how: LooseEnd) {
        guard engaged?.isLoose == true else { return }
        engaged = nil
        move = nil
        out.append(.stopTranslation)
        switch how {
        case .byYou: cue(.drive(.stoppedByYou))
        case .arrived: cue(.drive(.arrived))
        case .ended(let end): cue(.drive(.ended(end)))
        case .stop, .silent: break
        }
    }

    /// I-11 with its reason. For a hold tied to an input and for the countdown it is `endAllHolds` whatever the reason;
    /// a move nobody holds ends with the cue the reason names, or none when its cue has played elsewhere.
    private mutating func holdsEnded(_ reason: Interruption) {
        switch reason {
        case .announced, .startRefused: endLoose(.silent)
        case .unnamed: endLoose(.ended(.unnamed))
        case .appLeft: endLoose(.ended(.appLeft))
        case .cameraStopped: endLoose(.ended(.cameraStopped))
        case .leftScreen: endLoose(.ended(.leftScreen))
        case .slowLink: endLoose(.ended(.slowLink))
        }
        endAllHolds()
    }

    // MARK: A move to a tapped point (tap-to-go)

    /// A tap: still undecided at its lift (scheme A `.waiting`; scheme B `.waiting` before its dwell completed, or
    /// `.tapOnly`), nothing engaged now, its lift sample narrower than a palm, lifted at most `tapMaxS` after its
    /// touch-down and never farther than `tapSlopMm` from it. A dwell that completed before the lift fired ahead of
    /// the lift's events, so a lift past the dwell is a jaw move, as in 1.0.1. A palm inside its window was ignored
    /// before it got here.
    private func isTap(_ touch: SurfaceTouch) -> Bool {
        (touch.phase == .waiting || touch.phase == .tapOnly) && engaged == nil && !touch.liftWide
            && now - touch.downAt <= constants.tapMaxS + Self.slack
            && touch.farthestMm <= constants.tapSlopMm + 1e-9
    }

    /// A tap at `point` on `panel`: refused with a cue, "Arrived." when the arm is there already, or a move that goes
    /// there at the travel height. Neither the phone's tracking or posture nor where the arm stands refuses a tap: the
    /// phone does not steer the move, and the move starts from wherever the arm is. A tap after a STOP earlier in this
    /// call is refused as the robot being stopped, unless the facts, which are from before that STOP, already refuse
    /// it.
    private mutating func tap(at point: SIMD2<Double>, on panel: GoPanel) {
        guard let rule = assist.goTo, engaged == nil else { return }
        if let refusal = facts.refusal {
            cue(.refused(refusal))
            return
        }
        if stoppedInCall {
            cue(.refused(.stopped))
            return
        }
        // No slack: a place the arm is sent to must lie in the box itself, which also refuses a travel height outside
        // it.
        let target = panel.target(x: point.x, y: point.y, travelHeight: rule.travelHeightM)
        guard panel.inBox(target) else {
            cue(.refused(.outsideWorkArea))
            return
        }
        guard let fix = facts.arm, fix.ageS <= GoMove.freshS else {
            cue(.refused(.noArmData))
            return
        }
        if simd_distance(fix.pinch, target) <= rule.arriveToleranceM {
            cue(.drive(.arrived))
            return
        }
        // The box the target was judged against also bounds every correction of the move.
        move = GoMove(
            start: fix.pinch, target: target, limits: rule, at: now, boxLow: panel.boxLow, boxHigh: panel.boxHigh)
        engaged = .going(target: target, since: now)
        deadenInputsDown()
        out.append(.startTranslation)
        startsThisCall.append(.going)
    }
}
