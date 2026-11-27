import simd

@testable import TeleopCore

/// The two sets of frames the rule tests run with. A test names a set here, never a literal of its own.
enum TestFrames {
    /// The SO-101 in the S4 simulator, the numbers of `so101-s4-sim.json`: forward is base -y, left base +x, up base
    /// +z; the link is x, y, minus z; the world is the base shifted 5 cm up.
    static let so101 = Frames(
        forward: SignedAxis(.y, -1), left: SignedAxis(.x, 1), up: SignedAxis(.z, 1), linkSigns: SIMD3(1, 1, -1),
        baseInWorld: SIMD3(0, 0, 0.05),
        worldTurn: WorldTurn(x: SignedAxis(.x, 1), y: SignedAxis(.y, 1), z: SignedAxis(.z, 1)))

    /// A bench arm that differs wherever the SO-101's frames can: forward is base +x, base z points down, the link
    /// has no flip, and the world is turned a quarter turn against the base (base x along world +y, base y along
    /// world +x, base z along world -z), the base hanging 40 cm over the origin.
    static let benchB = Frames(
        forward: SignedAxis(.x, 1), left: SignedAxis(.y, -1), up: SignedAxis(.z, -1), linkSigns: SIMD3(1, 1, 1),
        baseInWorld: SIMD3(0.10, -0.20, 0.40),
        worldTurn: WorldTurn(x: SignedAxis(.y, 1), y: SignedAxis(.x, 1), z: SignedAxis(.z, -1)))

    /// An arm mounted on its side, so that up is not along base z at all: up is base +y, forward base +z, the link
    /// mirrors x, and the world's up (z) lies along base y. It exists to catch a rule that assumes up is the base's
    /// z whichever way that points.
    static let onItsSide = Frames(
        forward: SignedAxis(.z, 1), left: SignedAxis(.x, 1), up: SignedAxis(.y, 1), linkSigns: SIMD3(-1, 1, 1),
        baseInWorld: SIMD3(-0.05, 0.30, 0.15),
        worldTurn: WorldTurn(x: SignedAxis(.x, 1), y: SignedAxis(.z, 1), z: SignedAxis(.y, -1)))

    static let all: [(name: String, frames: Frames)] = [
        ("SO-101", so101), ("bench arm B", benchB), ("arm on its side", onItsSide),
    ]

    /// A vector of one set's base frame as the other set's base frame has it: the same place, direction or offset,
    /// seen by the same operator. This is how a rule's expected values for B come from the SO-101's.
    static func carry(_ p: SIMD3<Double>, from: Frames, to: Frames) -> SIMD3<Double> {
        to.base(fromOperator: from.operatorPoint(p))
    }

    static func carry(_ p: SIMD3<Float>, from: Frames, to: Frames) -> SIMD3<Float> {
        SIMD3<Float>(carry(SIMD3<Double>(p), from: from, to: to))
    }

    /// A link offset of one set as the other set sends it, for the same move of the arm.
    static func carryLink(_ p: SIMD3<Double>, from: Frames, to: Frames) -> SIMD3<Double> {
        to.link(fromBase: carry(from.base(fromLink: p), from: from, to: to))
    }

    /// A box of one set's base frame as the other's, corners sorted.
    static func carry(_ box: (low: SIMD3<Double>, high: SIMD3<Double>), from: Frames, to: Frames) -> (
        low: SIMD3<Double>, high: SIMD3<Double>
    ) {
        let a = carry(box.low, from: from, to: to), b = carry(box.high, from: from, to: to)
        return (simd_min(a, b), simd_max(a, b))
    }
}
