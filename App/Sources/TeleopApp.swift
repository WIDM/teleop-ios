import SwiftUI
import TeleopCore

@main
struct TeleopApp: App {
    @State private var model = AppModel(start: AppModel.startRoute())

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
