import SwiftUI
import TeleopCore

struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TestFrame {
            ZStack {
                TeleopColors.background.ignoresSafeArea()
                screen(for: model.session.route)
            }
        }
        .environment(\.locale, model.language.locale)
        // Rebuild every screen on a language change, so format strings looked up at runtime follow too.
        .id(model.language)
        .foregroundStyle(TeleopColors.textPrimary)
        // The colours are fixed, so system parts (Settings' form, text fields) must not turn dark with the phone. The
        // operating screen's dark top band needs the light status bar, which iOS 17 and 18 give only to a dark scheme.
        .preferredColorScheme(Self.operatingRoutes.contains(model.session.route) ? .dark : .light)
        .overlay(alignment: .topLeading) {
            if let log = model.hapticLog {
                Text(verbatim: "log:" + log.joined(separator: ","))
                    .font(.system(size: 1))
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("test.haptics")
            }
        }
        .onAppear {
            PoseTracker.shared.setActive(tracksPose)
            if AppModel.opensSavedServerAtLaunch() { model.trySavedServer() }
        }
        .onChange(of: tracksPose) { _, tracks in PoseTracker.shared.setActive(tracks) }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the foreground (home, call, Control Center) must never leave the arm moving.
            if phase != .active, model.session.state.armMoving { model.send(.holdArmEnd) }
            model.foregroundChanged()
            // Camera access granted in the Settings app only shows up on return.
            if phase == .active { PoseTracker.shared.setActive(tracksPose) }
        }
        .task(id: tracksPose) {
            // ARKit is not something SwiftUI observes, so the posture is polled while the operating screen is up.
            guard tracksPose else { return }
            while !Task.isCancelled {
                model.refreshPosture()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// The operating screen tracks the phone in the phone modes. That also keeps the camera in use for the volume
    /// keys. In buttons mode the camera is off and the volume keys change the volume (§3.1).
    private var tracksPose: Bool {
        Self.operatingRoutes.contains(model.session.route) && model.controlMode != .buttons
    }

    /// The routes the operating screen draws. One view for all of them, so a route change (STOP, a slow link) does
    /// not rebuild the touch surface under a finger.
    static let operatingRoutes: Set<Route> = [.p4, .p5, .p6, .p7, .s4, .s5]

    @ViewBuilder
    private func screen(for route: Route) -> some View {
        switch route {
        case .p4, .p5, .p6, .p7, .s4, .s5: OperatingScreen(model: model)
        case .t1: TutorialScreen(model: model, step: 1)
        case .t2: TutorialScreen(model: model, step: 2)
        case .t3: TutorialScreen(model: model, step: 3)
        case .s1: ConnectScreen(model: model)
        case .s2: PermissionsScreen(model: model)
        case .s6: SettingsScreen(model: model)
        }
    }
}

/// UI tests only: `-screenFrame 375x667x20x0` draws the app in a frame of that width and height, at the top left,
/// with those top and bottom safe-area insets, so a smaller phone's layout can be checked on the test device.
private struct TestFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if let frame = testScreenFrame {
            content
                .environment(\.surfaceInsets, frame.insets)
                .frame(width: frame.width, height: frame.height)
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea()
                // The test device's status bar is taller than the frame's top inset and would cover the top band.
                .statusBarHidden(true)
        } else {
            content
        }
    }
}

private let testScreenFrame: (width: Double, height: Double, insets: SurfaceInsets)? = {
    guard let text = UserDefaults.standard.string(forKey: "screenFrame") else { return nil }
    let parts = text.split(separator: "x").compactMap { Double($0) }
    guard parts.count == 4 else { return nil }
    return (parts[0], parts[1], SurfaceInsets(top: parts[2], bottom: parts[3]))
}()
