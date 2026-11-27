import TeleopCore

/// The frames the app tests run rules and the scripted hand against, besides the SO-101's own (from its profile file):
/// the same two test-only sets the package tests use (`TestFrames` in `TeleopCoreTests`).
enum TestFrames {
    /// A bench arm whose forward is base +x, whose base z points down, whose link has no flip and whose world is
    /// turned a quarter turn against the base.
    static let benchB = Frames(
        forward: SignedAxis(.x, 1), left: SignedAxis(.y, -1), up: SignedAxis(.z, -1), linkSigns: SIMD3(1, 1, 1),
        baseInWorld: SIMD3(0.10, -0.20, 0.40),
        worldTurn: WorldTurn(x: SignedAxis(.y, 1), y: SignedAxis(.x, 1), z: SignedAxis(.z, -1)))

    /// An arm mounted on its side: up is base +y.
    static let onItsSide = Frames(
        forward: SignedAxis(.z, 1), left: SignedAxis(.x, 1), up: SignedAxis(.y, 1), linkSigns: SIMD3(-1, 1, 1),
        baseInWorld: SIMD3(-0.05, 0.30, 0.15),
        worldTurn: WorldTurn(x: SignedAxis(.x, 1), y: SignedAxis(.z, 1), z: SignedAxis(.y, -1)))

    static var all: [(name: String, frames: Frames)] {
        [("SO-101", TestProfiles.so101.frames), ("bench arm B", benchB), ("arm on its side", onItsSide)]
    }
}
