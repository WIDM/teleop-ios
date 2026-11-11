import Foundation
import simd

/// Decides what every key press, touch and phone turn means under scheme A or B (INTERACTION Part 2), with the time
/// passed in. Feed it events with the facts of the moment; it returns the commands to carry out, in order.
///
/// It does not wait for the server: a start it issues is engaged until it issues the stop. Holding a start back
/// behind a finishing hold is `TeleopLink`'s job.
public struct InputArbiter: Sendable {
    public let constants: InputConstants
    /// Touches are judged against the layout current at their touch-down.
    public var layout: SurfaceLayout
    public private(set) var scheme: InputScheme
    public private(set) var hand: Hand

    private var keys: [InputKey: KeyState] = [:]
    private var keyBeganAt: [InputKey: TimeInterval] = [:]
    private var keyEndedAt: [InputKey: TimeInterval] = [:]
    /// Keys that were down when the app left the active state; whether they still are is unknown (I-11).
    private var staleKeys: Set<InputKey> = []
    private var touches: [Int: TouchRole] = [:]
    private var engaged: Engaged?
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

    private enum KeyState: Equatable, Sendable { case engaged, dead }

    private enum Engaged: Equatable, Sendable {
        case hold(HeldInput, HoldKind)
        /// The reset countdown of this top band touch.
        case countdown(Int)
    }

    private enum TouchRole: Equatable, Sendable {
        /// Filtered out or in the gap: never acts, never cues.
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
        }

        var downAt: TimeInterval
        var down: SIMD2<Double>
        var at: SIMD2<Double>
        var side: SurfaceLayout.Side
        /// Scheme A: turn and tilt from the attitude at touch-down.
        var mapper: RotationMapper
        var phase: Phase
        var windowEnded = false
    }

    public init(scheme: InputScheme, hand: Hand = .right, layout: SurfaceLayout, constants: InputConstants = .appendixA) {
        self.scheme = scheme
        self.hand = hand
        self.layout = layout
        self.constants = constants
    }

    // MARK: Reading the state

    /// Every key and every touch that passed the filters, while it is down, and what it is doing.
    public var held: [HeldInput: InputPhase] {
        var result: [HeldInput: InputPhase] = [:]
        for (key, state) in keys {
            if state == .engaged, case .hold(.key(key), let kind)? = engaged {
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
                case .dead: result[.touch(id)] = .dead
                case .engaged:
                    if case .hold(.touch(id), let kind)? = engaged { result[.touch(id)] = .engaged(kind) }
                }
            }
        }
        return result
    }

    /// The hold engaged now, if any.
    public var engagedHold: HoldKind? {
        if case .hold(_, let kind)? = engaged { return kind }
        return nil
    }

    /// A volume key or a control-surface touch is down, whatever it is doing (§0.2; the voice gate V-2).
    public var isHoldingAnInput: Bool {
        !keys.isEmpty || touches.values.contains { if case .surface = $0 { return true } else { return false } }
    }

    /// When the next timer runs out, so the owner can tick then instead of waiting for its next 30 Hz tick.
    public var nextDeadline: TimeInterval? { earliestDeadline()?.at }

    // MARK: Handling events

    public mutating func handle(_ event: InputEvent, at time: TimeInterval, facts: InputFacts) -> [InputCommand] {
        handle([event], at: time, facts: facts)
    }

    /// Events that happened at the same instant, applied in the order given, except that an attitude sample is judged
    /// before the touch moves given ahead of it (A-6t). Timers that ran out before this instant fire first; a timer
    /// that runs out at this very instant fires after the events, so a lift, a palm, a swipe or `endAllHolds` at the
    /// deadline still counts.
    public mutating func handle(_ events: [InputEvent], at time: TimeInterval, facts: InputFacts) -> [InputCommand] {
        out = []
        self.facts = facts
        let time = max(time, now)
        advance(to: time, firingTies: false)
        for event in Self.ordered(events) {
            apply(event)
        }
        advance(to: time, firingTies: true)
        return out
    }

    /// Moves each attitude sample ahead of the touch moves (and ticks, which do nothing) just before it.
    private static func ordered(_ events: [InputEvent]) -> [InputEvent] {
        var result: [InputEvent] = []
        for event in events {
            guard case .attitude = event else {
                result.append(event)
                continue
            }
            var index = result.endIndex
            while index > result.startIndex, Self.yieldsToAttitude(result[index - 1]) { index -= 1 }
            result.insert(event, at: index)
        }
        return result
    }

    private static func yieldsToAttitude(_ event: InputEvent) -> Bool {
        switch event {
        case .touch(let sample): return sample.phase == .moved
        case .tick: return true
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
        case .endAllHolds: endAllHolds()
        case .becameActive: becameActive()
        case .modeChanged(let newScheme, let newHand):
            endAllHolds()
            scheme = newScheme
            hand = newHand
        case .sceneReset:
            commandedTiltSinceReset = 0
            tiltAtReset = lastWristTarget.axis == .tilt ? lastWristTarget.degrees : 0
        case .wristStartSent:
            guard case .hold(_, .wrist)? = engaged, let q = attitude, var mapper = wrist else { return }
            // The target streamed from now on drops the rotation made while the start waited.
            let target = mapper.startSent(attitude: q, at: now)
            wrist = mapper
            emitWrist((target, false))
        }
    }

    // MARK: Keys (I-2, A-1, A-2, B-1, B-2)

    private mutating func keyDown(_ key: InputKey) {
        guard keys[key] == nil else { return }
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
        let replay = constants.keyReplayGuard
            && (keyEndedAt[other].map { now - $0 <= constants.keyReplayMs / 1000 + Self.slack } ?? false)
        if keys[other] != nil || chord || replay || engaged != nil {
            keys[key] = .dead
            cue(.dead)
            return
        }
        // A key wins over an undecided touch, which dies silently (I-2.2, A-8, B-4).
        for (id, role) in touches {
            if case .surface(var touch) = role, touch.phase == .waiting {
                touch.phase = .dead(owesNO: false)
                touches[id] = .surface(touch)
            }
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
        if state == .engaged, case .hold(.key(key), _)? = engaged { stopEngaged() }
    }

    // MARK: Touches (§2.2)

    private mutating func touch(_ sample: TouchSample) {
        switch sample.phase {
        case .began:
            if touches[sample.id] != nil { touchEnded(sample.id, cancelled: true) }
            touchBegan(sample)
        case .moved:
            touchMoved(sample)
        case .ended:
            touchEnded(sample.id, cancelled: false)
        case .cancelled:
            touchEnded(sample.id, cancelled: true)
        }
    }

    private mutating func touchBegan(_ s: TouchSample) {
        let zone = layout.zone(x: s.x, y: s.y)
        let palm = s.majorRadius >= constants.palmRadiusPt
        switch zone {
        case .bottomBand:
            // No filter applies: a palm here stops the robot too (I-3).
            touches[s.id] = .stop
            out.append(.emergencyStop)
            if !facts.connectionUp { cue(.refused(.notStopped)) }
        case .gap:
            touches[s.id] = .ignored
        case .gear, .topBand:
            if palm || layout.isAtSideEdge(x: s.x) {
                touches[s.id] = .ignored
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
            let tracked = touches.values.contains { if case .surface = $0 { return true } else { return false } }
            if palm || layout.isAtSideEdge(x: s.x) || tracked {
                touches[s.id] = .ignored
                return
            }
            let side = layout.side(x: s.x, hand: hand)
            let phase: SurfaceTouch.Phase
            switch scheme {
            case .screenTurns:
                phase = engaged != nil ? .dead(owesNO: true) : .waiting
            case .keyTurns:
                // The centre band never acts, so it never owes NO either.
                if side == .centre {
                    phase = .dead(owesNO: false)
                } else {
                    phase = engaged != nil ? .dead(owesNO: true) : .waiting
                }
            }
            let point = SIMD2(s.x, s.y)
            touches[s.id] = .surface(SurfaceTouch(
                downAt: now, down: point, at: point, side: side,
                mapper: RotationMapper(anchor: attitude, startsAtCommit: true, constants: constants), phase: phase
            ))
        }
    }

    private mutating func touchMoved(_ s: TouchSample) {
        guard let role = touches[s.id] else { return }
        let palm = s.majorRadius >= constants.palmRadiusPt
        switch role {
        case .ignored, .stop:
            return
        case .band(let band):
            if palm, insidePalmWindow(band.downAt) { touches[s.id] = .ignored }
        case .surface(var touch):
            if palm, !touch.windowEnded {
                touches[s.id] = .ignored
                return
            }
            touch.at = SIMD2(s.x, s.y)
            touches[s.id] = .surface(touch)
            if touch.windowEnded { judge(s.id) }
        }
    }

    private mutating func touchEnded(_ id: Int, cancelled: Bool) {
        guard let role = touches.removeValue(forKey: id) else { return }
        switch role {
        case .ignored, .stop:
            break
        case .surface(let touch):
            if touch.phase == .engaged, case .hold(.touch(id), _)? = engaged { stopEngaged() }
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

    private func insidePalmWindow(_ downAt: TimeInterval) -> Bool {
        now < downAt + constants.palmWindowMs / 1000 - Self.slack
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
        if case .hold(_, .wrist)? = engaged, var mapper = wrist {
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
        let d = touch.at - touch.down
        let dx = layout.millimetres(d.x), dy = layout.millimetres(d.y)
        guard reachedSlide(dx, dy) else { return nil }
        // Screen y grows downward, so up the glass is negative.
        guard dy < 0, abs(dy) > abs(dx) else { return .sideways }
        return touch.mapper.reachedLockAngle(angles) ? .unclear : .open
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
            case .wrist, .open: cue(.dead)
            case .unclear, .sideways: break
            }
            markDead(id)
        case .dead(owesNO: false), .engaged:
            break
        }
    }

    /// Travel from touch-down, measured as in A-4: the larger of the two components, in millimetres.
    private func reachedSlide(_ dx: Double, _ dy: Double) -> Bool {
        max(abs(dx), abs(dy)) >= constants.openSlideMm - 1e-9
    }

    /// B-3m: moving 10 mm within the dwell makes the touch a swipe.
    private mutating func judgeKeyTurnsMove(_ id: Int) {
        guard case .surface(let touch)? = touches[id] else { return }
        let d = touch.at - touch.down
        guard reachedSlide(layout.millimetres(d.x), layout.millimetres(d.y)) else { return }
        switch touch.phase {
        case .waiting:
            markDead(id)
            cue(.dead)
        case .dead(owesNO: true):
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
            cue(.dead)
            markDead(id)
        case .dead(owesNO: false), .engaged:
            break
        }
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
            case .dead(owesNO: false), .engaged:
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
                    engaged = .countdown(id)
                    out.append(.resetCountdownStarted)
                    // A control-surface touch still undecided was down when the countdown began, so it is dead
                    // until lifted, even after the reset; it plays NO if it would commit (I-2.1, I-2.3, I-3).
                    for (other, role) in touches {
                        if case .surface(var touch) = role, touch.phase == .waiting {
                            touch.phase = .dead(owesNO: true)
                            touches[other] = .surface(touch)
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
        engaged = .hold(input, kind)
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
        guard case .hold(_, let kind)? = engaged else { return }
        engaged = nil
        switch kind {
        case .translation:
            out.append(.stopTranslation)
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
        for key in keys.keys { keys[key] = .dead }
        for (id, role) in touches {
            switch role {
            case .surface(var touch):
                touch.phase = .dead(owesNO: false)
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
}
