// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TeleopCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TeleopCore", targets: ["TeleopCore"]),
        .library(name: "TeleopServerModel", targets: ["TeleopServerModel"]),
        .library(name: "TeleopServerHost", targets: ["TeleopServerHost"]),
    ],
    targets: [
        .target(name: "TeleopCore"),
        // A model of the simulator server for tests. Foundation only, so the app could link it later.
        .target(name: "TeleopServerModel"),
        // The model behind a WebSocket on 127.0.0.1 (Network.framework), for app and UI tests.
        .target(name: "TeleopServerHost", dependencies: ["TeleopServerModel"]),
        .testTarget(name: "TeleopCoreTests", dependencies: ["TeleopCore"]),
        .testTarget(
            name: "TeleopServerModelTests",
            dependencies: ["TeleopServerModel", "TeleopServerHost", "TeleopCore"],
            resources: [.copy("Recordings")]
        ),
    ]
)
