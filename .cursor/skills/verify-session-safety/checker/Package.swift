// swift-tools-version:5.9
import Foundation
import PackageDescription

// TELEOP_CORE_PATH lets scripts/mutants.py point the checker at a broken copy of TeleopCore.
let corePath = ProcessInfo.processInfo.environment["TELEOP_CORE_PATH"] ?? "../../../../Packages/TeleopCore"

let package = Package(
    name: "SafetyCheck",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "TeleopCore", path: corePath)],
    targets: [
        .executableTarget(
            name: "SafetyCheck",
            dependencies: [.product(name: "TeleopCore", package: "TeleopCore")]
        ),
    ]
)
