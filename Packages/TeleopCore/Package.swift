// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TeleopCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TeleopCore", targets: ["TeleopCore"]),
    ],
    targets: [
        .target(name: "TeleopCore"),
        .testTarget(name: "TeleopCoreTests", dependencies: ["TeleopCore"]),
    ]
)
