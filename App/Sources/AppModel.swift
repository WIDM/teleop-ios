import Observation
import simd
import SwiftUI
import TeleopCore

@Observable
final class AppModel {
    var session: TeleopSession
    @ObservationIgnored private let haptics: HapticsPlaying
    @ObservationIgnored private let pose: () -> simd_float4x4?
    @ObservationIgnored private var holdStartPose: simd_float4x4?
    /// UI tests only: `-recordHaptics YES` shows requested haptics to XCUITest, which cannot feel them.
    private(set) var hapticLog: [String]? = UserDefaults.standard.bool(forKey: "recordHaptics") ? [] : nil
    var language: AppLanguage = L10n.language {
        didSet {
            L10n.language = language
            language.save()
        }
    }
    /// Developer mode log: actions and haptics with times, newest last.
    private(set) var debugLog: [String] = []

    init(
        start: Route = .p1,
        haptics: HapticsPlaying = HapticsController(),
        pose: @escaping () -> simd_float4x4? = { PoseTracker.shared.current }
    ) {
        session = TeleopSession(start: start)
        self.haptics = haptics
        self.pose = pose
        // UI tests only: `-startConnected YES` marks the link live without navigating,
        // so the launch route stays put and control input is accepted.
        if UserDefaults.standard.bool(forKey: "startConnected") { session.state.markConnected() }
    }

    func send(_ action: TeleopAction) {
        let wasMoving = session.state.armMoving
        session.perform(action)
        // The recording clock ticks every second; logging it would bury everything else.
        if action != .recordingTick { log("→ \(action)") }
        logPose(wasMoving: wasMoving)
        for command in session.drainHaptics() {
            haptics.run(command)
            hapticLog?.append(Self.logName(command))
            log("~ \(Self.logName(command))")
        }
    }

    func log(_ line: String) {
        debugLog.append(Self.clock.string(from: Date()) + " " + line)
        if debugLog.count > 40 { debugLog.removeFirst(debugLog.count - 40) }
    }

    func clearLog() { debugLog = [] }

    private func logPose(wasMoving: Bool) {
        let moving = session.state.armMoving
        if !wasMoving, moving {
            holdStartPose = pose()
            if holdStartPose == nil { log("pose: no tracking") }
        } else if wasMoving, !moving {
            if let start = holdStartPose, let end = pose() { log(PoseDelta(from: start, to: end).logLine) }
            holdStartPose = nil
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func logName(_ command: HapticCommand) -> String {
        switch command {
        case .play(let cue): return "\(cue)"
        case .cancel: return "cancel"
        }
    }

    static func startRoute(from defaults: UserDefaults = .standard) -> Route {
        defaults.string(forKey: "startRoute").flatMap(Route.init(rawValue:)) ?? .p1
    }
}
