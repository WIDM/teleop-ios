import SwiftUI
import TeleopCore

/// What the operating screen says and which colour it takes (§7.2), from `OperatingDisplay`, in the app's language.
enum OperatingWords {
    struct Look: Equatable {
        var word: String
        var details: [String]
        var colour: Color
        /// Gold is light: its words are drawn dark.
        var darkText = false
        /// One more line under the details, kept apart from them: that the hands-free aids are off.
        var note: String? = nil
    }

    static func look(_ display: OperatingDisplay) -> Look {
        var look = stateLook(display)
        // Only a translation's state carries it (`OperatingRules.showsOpenJawsFirst`); last, under its own lines.
        if display.openJawsFirst { look.details.append(L10n.string("detail.open_jaws_first")) }
        if display.practice, look.details.isEmpty { look.details = [L10n.string("detail.no_robot")] }
        look.note = aidsOffNote(display)
        return look
    }

    /// In a phone mode, where a tap on the guide could go, in every state but a stop: a line that came and went would
    /// move the guide at every hold, and a stop already says why and what to do next, and takes no tap.
    private static func aidsOffNote(_ display: OperatingDisplay) -> String? {
        guard display.aidsOff, !display.practice, display.mode != .buttons else { return nil }
        if case .stopped = display.state { return nil }
        if case .simulatorStalled = display.state { return nil }
        if case .simulatorPaused(stopped: true) = display.state { return nil }
        return L10n.string("detail.aids_off")
    }

    private static func stateLook(_ display: OperatingDisplay) -> Look {
        switch display.state {
        case .notConnected(let reason):
            // The word opens Connect (§7.2), and says so.
            let details = (reason.map { [$0] } ?? []) + [L10n.string("detail.tap_to_connect")]
            return Look(word: L10n.string("state.not_connected"), details: details, colour: TeleopColors.stateGrey)
        case .connecting(let address):
            return Look(
                word: L10n.string("state.connecting"), details: address.isEmpty ? [] : [address],
                colour: TeleopColors.stateGrey)
        case .ready:
            return Look(word: L10n.string("state.ready"), details: [], colour: TeleopColors.stateGreen)
        case .moving(let catchingUp):
            let detail =
                catchingUp
                ? "detail.catching_up" : (display.arm == nil && !display.practice ? "detail.no_arm_data" : nil)
            return Look(
                word: L10n.string("state.moving"), details: detail.map { [L10n.string($0)] } ?? [],
                colour: TeleopColors.stateBlue)
        case .locked(let catchingUp):
            // In the moving colour, since the arm moves; no key is held to let go of, so the detail says how it stops.
            let details = [L10n.string("detail.stop_any")] + (catchingUp ? [L10n.string("detail.catching_up")] : [])
            return Look(word: L10n.string("state.locked"), details: details, colour: TeleopColors.stateBlue)
        case .going(let catchingUp):
            // As for a follow nobody holds: the arm moves, and nothing is held to let go of.
            let details = [L10n.string("detail.stop_any")] + (catchingUp ? [L10n.string("detail.catching_up")] : [])
            return Look(word: L10n.string("state.going"), details: details, colour: TeleopColors.stateBlue)
        case .turning(let degrees, let limit, let estimated):
            return Look(
                word: L10n.string("state.turning"), details: [progress(degrees, limit, estimated)],
                colour: TeleopColors.stateBlue)
        case .tilting(let degrees, let limit, let estimated):
            return Look(
                word: L10n.string("state.tilting"), details: [progress(degrees, limit, estimated)],
                colour: TeleopColors.stateBlue)
        case .opening:
            return Look(word: L10n.string("state.opening"), details: [], colour: TeleopColors.stateBlue)
        case .closing(let gripped):
            return Look(
                word: L10n.string("state.closing"), details: gripped ? [L10n.string("detail.gripped")] : [],
                colour: TeleopColors.stateBlue)
        case .wait(let reason):
            let detail: String
            switch reason {
            case .saving: detail = L10n.string("detail.saving")
            case .resetting: detail = L10n.string("detail.resetting")
            case .notReady: detail = L10n.string("detail.not_ready")
            }
            return Look(word: L10n.string("state.wait"), details: [detail], colour: TeleopColors.stateAmber)
        case .trackingLost:
            return Look(
                word: L10n.string("state.camera_stopped"), details: [L10n.string("detail.camera_stopped")],
                colour: TeleopColors.stateAmber)
        case .refused(let refusal):
            return Look(word: reason(refusal), details: [], colour: TeleopColors.stateAmber)
        case .serverRefused(let refusalClass, moveEnded: false):
            return Look(word: reason(refusalClass), details: [], colour: TeleopColors.stateAmber)
        case .serverRefused(let refusalClass, moveEnded: true):
            return endedLook(.endedByServer(refusalClass))
        case .ended(let end):
            return endedLook(.ended(end))
        case .slowLink(let ms):
            return Look(
                word: L10n.string("state.slow_link"), details: [String(format: L10n.string("detail.latency"), ms)],
                colour: TeleopColors.stateAmber)
        case .stopped(let cause):
            var details = cause.map { [self.cause($0)] } ?? []
            if let dismissal = display.dismissal { details.insert(Self.dismissal(dismissal), at: 0) }
            details.append(L10n.string("detail.reset_prompt"))
            if display.stopExits.recordingMayStayOff, offersRelease(display) {
                details.append(L10n.string("detail.release_warning"))
            }
            return Look(word: L10n.string("state.stopped"), details: details, colour: TeleopColors.stateRed)
        case .simulatorStalled(let stopped):
            // Each line true as it stands: with no stop on yet, what Reconnect will do instead.
            return Look(
                word: L10n.string("state.sim_stalled"),
                details: [L10n.string(stopped ? "detail.sim_stalled" : "detail.sim_stalled_unstopped")],
                colour: TeleopColors.stateRed)
        case .simulatorPaused(let stopped):
            // Quiet: the stop or the wait, and one line why. It often passes in seconds.
            return Look(
                word: L10n.string(stopped ? "state.stopped" : "state.wait"),
                details: [L10n.string("detail.sim_paused")],
                colour: stopped ? TeleopColors.stateRed : TeleopColors.stateAmber)
        case .linkLost:
            // Nothing reconnects by itself: the way back is Connect in Settings, behind the gear on this screen.
            return Look(
                word: L10n.string("state.link_lost"),
                details: (display.dismissal.map { [Self.dismissal($0)] } ?? []) + [
                    L10n.string("detail.connect_in_settings")
                ],
                colour: TeleopColors.stateDarkGrey)
        case .saved(let count):
            return Look(
                word: String(format: L10n.string("state.saved"), count), details: [], colour: TeleopColors.stateGold,
                darkText: true)
        }
    }

    /// Why the server refused this phone or let it go, in the words S1 uses too.
    static func dismissal(_ reason: SessionDismissal) -> String {
        switch reason {
        case .inUse: return L10n.string("connect.dismissed_in_use")
        case .taken: return L10n.string("connect.dismissed_taken")
        case .idle: return L10n.string("connect.dismissed_idle")
        }
    }

    /// A simulator that is not responding offers **Reconnect** in the release's place: it leaves the server stopped,
    /// latching the stop first when none is on, drops the connection and opens Connect. Practice has no server to
    /// stall.
    static func offersReconnect(_ display: OperatingDisplay) -> Bool {
        guard case .simulatorStalled = display.state else { return false }
        return !display.practice
    }

    /// The stopped state shows **Release, keep scene** only when the stop exits offer it (§6.5).
    static func offersRelease(_ display: OperatingDisplay) -> Bool {
        guard case .stopped = display.state else { return false }
        return display.stopExits.exits.contains(.releaseKeepScene)
    }

    private static func progress(_ degrees: Double, _ limit: Double, _ estimated: Bool) -> String {
        let text = String(format: L10n.string("detail.angle_progress"), Int(degrees.rounded()), Int(limit.rounded()))
        return estimated ? text + " · " + L10n.string("detail.estimated") : text
    }

    static func reason(_ refusal: Refusal) -> String {
        switch refusal {
        case .noLink: return L10n.string("refusal.no_link")
        case .notStopped: return L10n.string("refusal.not_stopped")
        case .emergencyStop: return L10n.string("refusal.stopped")
        case .notReady, .busy: return L10n.string("refusal.wait")
        case .slowLink: return L10n.string("refusal.slow_link")
        case .notTracking: return L10n.string("refusal.not_tracking")
        case .posture: return L10n.string("refusal.posture")
        case .letGoFirst: return L10n.string("refusal.let_go_first")
        case .deadInput: return L10n.string("refusal.did_nothing")
        case .serverRefused: return L10n.string("refusal.server_refused")
        case .useUpperKey: return L10n.string("refusal.use_upper_key")
        case .outsideWorkArea: return L10n.string("refusal.outside_work_area")
        case .noArmData: return L10n.string("refusal.no_arm_data")
        case .tapStill: return L10n.string("refusal.tap_still")
        case .tapLetGo: return L10n.string("refusal.tap_let_go")
        case .tapViewAbove: return L10n.string("refusal.tap_view_above")
        case .simulatorStalled: return L10n.string("state.sim_stalled")
        }
    }

    /// How a move nobody held ended: the words the operator heard, "Stopped here" and then why, in the place and colour
    /// of a refusal.
    private static func endedLook(_ cue: DriveCue) -> Look {
        let words = CueTable.row(for: .drive(cue)).speech.map(spoken)
        return Look(word: words.first ?? "", details: Array(words.dropFirst()), colour: TeleopColors.stateAmber)
    }

    /// A server's refusal by what the operator can do; the general class says what `.serverRefused` says.
    static func reason(_ refusalClass: ServerRefusalClass) -> String {
        switch refusalClass {
        case .contact: return L10n.string("refusal.contact")
        case .jointLimit: return L10n.string("refusal.joint_limit")
        case .reach: return L10n.string("refusal.reach")
        case .simulatorStalled: return L10n.string("state.sim_stalled")
        case .other: return reason(.serverRefused)
        }
    }

    /// One spoken phrase as the screen writes it: the same words, without the closing full stop.
    private static func spoken(_ key: SpeechKey) -> String {
        var text = SpeechText.string([Phrase(key)])
        if text.hasSuffix(".") || text.hasSuffix("。") { text.removeLast() }
        return text
    }

    static func cause(_ cause: EmergencyCause) -> String {
        switch cause {
        case .button: return L10n.string("cause.button")
        case .behind: return L10n.string("cause.behind")
        case .other: return L10n.string("cause.other")
        case .link: return L10n.string("cause.link")
        case .onConnect: return L10n.string("cause.on_connect")
        }
    }

    /// The REC line in the top band (§6.2, §7.2). Nil while the server has not said whether it records.
    struct RecLine: Equatable {
        enum Dot: Equatable { case capturing, idle }
        var dot: Dot?
        var text: String
        /// The take's length, drawn small after the text.
        var elapsed: String?
        var tail: String?
        var warning = false

        var spoken: String { [text, elapsed, tail].compactMap { $0 }.joined(separator: " ") }
    }

    static func recLine(_ display: OperatingDisplay) -> RecLine? {
        if display.practice { return RecLine(text: L10n.string("rec.practice")) }
        let recorder = display.recorder
        let saved = recorder.saved ?? 0, discarded = recorder.discarded ?? 0
        switch recorder.mode {
        case .unknown:
            return nil
        case .notRecording:
            return RecLine(text: L10n.string("rec.none"))
        case .armed:
            return RecLine(dot: .idle, text: String(format: L10n.string("rec.armed"), saved, discarded))
        case .capturing:
            return RecLine(
                dot: .capturing, text: L10n.string("rec.capturing"), elapsed: recorder.secondsCaptured.map(clock),
                tail: "· " + String(format: L10n.string("rec.saved"), saved)
            )
        case .waiting:
            return RecLine(dot: .idle, text: String(format: L10n.string("rec.waiting"), saved, discarded))
        case .off:
            return RecLine(text: L10n.string("rec.off"), warning: true)
        }
    }

    /// Minutes and seconds, as "0:12".
    static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    static func modeChip(_ mode: ControlMode) -> String {
        switch mode {
        case .screenTurns: return "A"
        case .keyTurns: return "B"
        case .buttons: return L10n.string("mode.buttons")
        }
    }

    static func modeName(_ mode: ControlMode) -> String {
        switch mode {
        case .screenTurns: return L10n.string("mode.scheme_a")
        case .keyTurns: return L10n.string("mode.scheme_b")
        case .buttons: return L10n.string("mode.buttons")
        }
    }

    enum LinkDot: Equatable { case up, slow, down, practice }

    static func linkDot(_ display: OperatingDisplay) -> LinkDot {
        if display.practice { return .practice }
        guard display.linkUp else { return .down }
        if case .slowLink = display.state { return .slow }
        return (display.latencyMs ?? 0) >= FakeTeleopState.blockLatencyMs ? .slow : .up
    }

    static func linkLabel(_ dot: LinkDot) -> String {
        switch dot {
        case .up: return L10n.string("link.up")
        case .slow: return L10n.string("link.slow")
        case .down: return L10n.string("link.down")
        case .practice: return L10n.string("link.practice")
        }
    }
}
