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
    }

    static func look(_ display: OperatingDisplay) -> Look {
        var look = stateLook(display)
        if display.practice, look.details.isEmpty { look.details = [L10n.string("detail.no_robot")] }
        return look
    }

    private static func stateLook(_ display: OperatingDisplay) -> Look {
        switch display.state {
        case .notConnected(let reason):
            return Look(word: L10n.string("state.not_connected"), details: reason.map { [$0] } ?? [], colour: TeleopColors.stateGrey)
        case .connecting(let address):
            return Look(word: L10n.string("state.connecting"), details: address.isEmpty ? [] : [address], colour: TeleopColors.stateGrey)
        case .ready:
            return Look(word: L10n.string("state.ready"), details: [], colour: TeleopColors.stateGreen)
        case .moving(let catchingUp):
            let detail = catchingUp ? "detail.catching_up" : (display.arm == nil && !display.practice ? "detail.no_arm_data" : nil)
            return Look(word: L10n.string("state.moving"), details: detail.map { [L10n.string($0)] } ?? [], colour: TeleopColors.stateBlue)
        case .turning(let degrees, let limit, let estimated):
            return Look(word: L10n.string("state.turning"), details: [progress(degrees, limit, estimated)], colour: TeleopColors.stateBlue)
        case .tilting(let degrees, let limit, let estimated):
            return Look(word: L10n.string("state.tilting"), details: [progress(degrees, limit, estimated)], colour: TeleopColors.stateBlue)
        case .opening:
            return Look(word: L10n.string("state.opening"), details: [], colour: TeleopColors.stateBlue)
        case .closing(let gripped):
            return Look(word: L10n.string("state.closing"), details: gripped ? [L10n.string("detail.gripped")] : [], colour: TeleopColors.stateBlue)
        case .wait(let reason):
            let detail: String
            switch reason {
            case .saving: detail = L10n.string("detail.saving")
            case .resetting: detail = L10n.string("detail.resetting")
            case .notReady: detail = L10n.string("detail.not_ready")
            }
            return Look(word: L10n.string("state.wait"), details: [detail], colour: TeleopColors.stateAmber)
        case .trackingLost:
            return Look(word: L10n.string("state.camera_stopped"), details: [L10n.string("detail.camera_stopped")], colour: TeleopColors.stateAmber)
        case .refused(let refusal):
            return Look(word: reason(refusal), details: [], colour: TeleopColors.stateAmber)
        case .slowLink(let ms):
            return Look(word: L10n.string("state.slow_link"), details: [String(format: L10n.string("detail.latency"), ms)], colour: TeleopColors.stateAmber)
        case .stopped(let cause):
            var details = cause.map { [self.cause($0)] } ?? []
            details.append(L10n.string("detail.reset_prompt"))
            if display.stopExits.recordingMayStayOff, offersRelease(display) {
                details.append(L10n.string("detail.release_warning"))
            }
            return Look(word: L10n.string("state.stopped"), details: details, colour: TeleopColors.stateRed)
        case .linkLost:
            return Look(word: L10n.string("state.link_lost"), details: [L10n.string("detail.reconnecting")], colour: TeleopColors.stateDarkGrey)
        case .saved(let count):
            return Look(word: String(format: L10n.string("state.saved"), count), details: [], colour: TeleopColors.stateGold, darkText: true)
        }
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
        }
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
