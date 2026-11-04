import Observation
import SwiftUI
import TeleopCore

@Observable
final class AppModel {
    var session: TeleopSession
    @ObservationIgnored private let haptics: HapticsPlaying

    init(start: Route = .p1, haptics: HapticsPlaying = HapticsController()) {
        session = TeleopSession(start: start)
        self.haptics = haptics
    }

    func send(_ action: TeleopAction) {
        session.perform(action)
        for command in session.drainHaptics() {
            haptics.run(command)
        }
    }

    static func startRoute(from defaults: UserDefaults = .standard) -> Route {
        defaults.string(forKey: "startRoute").flatMap(Route.init(rawValue:)) ?? .p1
    }
}
