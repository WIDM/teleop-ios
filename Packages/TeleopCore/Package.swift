// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TeleopCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TeleopCore", targets: ["TeleopCore"]),
        .library(name: "TeleopServerModel", targets: ["TeleopServerModel"]),
    ],
    targets: [
        .target(name: "TeleopCore"),
        // A model of the simulator server for tests. Foundation only, so the app could link it later.
        .target(name: "TeleopServerModel"),
        .testTarget(name: "TeleopCoreTests", dependencies: ["TeleopCore"]),
        .testTarget(
            name: "TeleopServerModelTests",
            dependencies: ["TeleopServerModel", "TeleopCore"],
            resources: [.copy("Recordings")]
        ),
    ]
)
