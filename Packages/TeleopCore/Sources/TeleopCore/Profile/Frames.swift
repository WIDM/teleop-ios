import simd

/// One of the three coordinate axes of a frame: the robot base frame, the link frame or the world frame.
public enum BaseAxis: String, CaseIterable, Sendable, Codable {
    case x, y, z

    /// 0, 1 or 2: the place of this axis in a vector.
    public var index: Int {
        switch self {
        case .x: return 0
        case .y: return 1
        case .z: return 2
        }
    }
}

/// A direction along one coordinate axis, one way or the other: `+x`, `-y` and so on. Only quarter turns can be said
/// this way; a direction at another angle has no value of this type.
public struct SignedAxis: Equatable, Sendable, Codable {
    public var axis: BaseAxis
    /// 1 or -1.
    public var sign: Double

    public init(_ axis: BaseAxis, _ sign: Double) {
        self.axis = axis
        self.sign = sign
    }

    /// The same axis the other way.
    public var reversed: SignedAxis { SignedAxis(axis, -sign) }

    /// One unit this way.
    public var vector: SIMD3<Double> {
        var v = SIMD3<Double>.zero
        v[axis.index] = sign
        return v
    }

    /// How far `point` lies this way, taken along its own axis.
    public func component(of point: SIMD3<Double>) -> Double { sign * point[axis.index] }

    /// `point` with its part along this axis set so that `component(of:)` gives `value`.
    public func setting(_ value: Double, in point: SIMD3<Double>) -> SIMD3<Double> {
        var result = point
        result[axis.index] = sign * value
        return result
    }

    /// As the profile file writes it: `+x`, `-x`, `+y`, `-y`, `+z` or `-z`.
    public var text: String { (sign < 0 ? "-" : "+") + axis.rawValue }

    /// Reads `text` back; nil for anything that is not one of the six.
    public init?(text: String) {
        guard text.count == 2, let first = text.first, first == "+" || first == "-",
            let axis = BaseAxis(rawValue: String(text.dropFirst()))
        else { return nil }
        self.init(axis, first == "-" ? -1 : 1)
    }

    /// The six values the profile file accepts, for the sentences that refuse anything else.
    public static let allowedText = "+x, -x, +y, -y, +z or -z"

    /// Written and read as its text (`"-y"`), so that a sign other than 1 or -1 cannot be stored.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = SignedAxis(text: text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "\(text) is not one of \(Self.allowedText)."))
        }
        self = value
    }

    /// True when the sign is exactly 1 or -1, as a value read from a file always is.
    var hasUnitSign: Bool { sign == 1 || sign == -1 }
}

/// Which world axis each axis of the robot base lies along: the quarter turn from base to world. The base axes and
/// the world axes are both right-handed, so a valid turn takes x cross y to z.
public struct WorldTurn: Equatable, Sendable, Codable {
    public var x: SignedAxis
    public var y: SignedAxis
    public var z: SignedAxis

    public init(x: SignedAxis, y: SignedAxis, z: SignedAxis) {
        self.x = x
        self.y = y
        self.z = z
    }

    var axes: [SignedAxis] { [x, y, z] }
}

/// How the places the app talks about are related to one another, for one robot setup.
///
/// Three relations, each a quarter turn or a shift and nothing in between:
/// - operator to base: which base axis, and which way along it, is forward, left and up as the operator at the table
///   sees them (right is the opposite of left);
/// - base to link: the frame the server takes a translation hold's offset in is the base frame with some axes
///   mirrored, one sign per axis;
/// - world to base: where the base sits in the world frame, and which world axis each base axis lies along.
///
/// A pure value that travels inside the values that carry the profile's numbers. There is no default and no global:
/// an arm that is mounted, wired or calibrated differently gives different frames, and the rules ask these.
public struct Frames: Equatable, Sendable, Codable {
    public var forward: SignedAxis
    public var left: SignedAxis
    public var up: SignedAxis
    /// Each 1 or -1: the link's x, y and z against the base's.
    public var linkSigns: SIMD3<Double>
    /// The base origin in the world frame, metres.
    public var baseInWorld: SIMD3<Double>
    public var worldTurn: WorldTurn

    public init(
        forward: SignedAxis, left: SignedAxis, up: SignedAxis, linkSigns: SIMD3<Double>,
        baseInWorld: SIMD3<Double>, worldTurn: WorldTurn
    ) {
        self.forward = forward
        self.left = left
        self.up = up
        self.linkSigns = linkSigns
        self.baseInWorld = baseInWorld
        self.worldTurn = worldTurn
    }

    // MARK: Operator and base

    /// The base axis, and the way along it, that `direction` moves the arm.
    public func axis(for direction: OperatorDirection) -> SignedAxis {
        switch direction {
        case .forward: return forward
        case .back: return forward.reversed
        case .left: return left
        case .right: return left.reversed
        case .up: return up
        case .down: return up.reversed
        }
    }

    /// One metre this way, in the robot base frame.
    public func baseVector(_ direction: OperatorDirection) -> SIMD3<Double> { axis(for: direction).vector }

    /// One metre this way, in the frame `TeleopLink.poseUpdate(positionMeters:)` takes.
    public func linkVector(_ direction: OperatorDirection) -> SIMD3<Double> {
        link(fromBase: baseVector(direction))
    }

    /// Right, forward and up as the operator sees them, metres, from a point in the robot base frame.
    public func operatorPoint(_ base: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            left.reversed.component(of: base), forward.component(of: base), up.component(of: base))
    }

    /// The robot base frame point of an operator-frame point: the inverse of `operatorPoint`.
    public func base(fromOperator point: SIMD3<Double>) -> SIMD3<Double> {
        var base = SIMD3<Double>.zero
        base[left.axis.index] = -left.sign * point.x
        base[forward.axis.index] = forward.sign * point.y
        base[up.axis.index] = up.sign * point.z
        return base
    }

    /// How high `base` is, metres: its part along up.
    public func height(of base: SIMD3<Double>) -> Double { up.component(of: base) }

    /// `base` moved straight up or down until its height is `height`.
    public func settingHeight(_ height: Double, of base: SIMD3<Double>) -> SIMD3<Double> {
        up.setting(height, in: base)
    }

    /// `offset` without its height: the part that lies across the table.
    public func level(_ offset: SIMD3<Double>) -> SIMD3<Double> { settingHeight(0, of: offset) }

    /// One metre up, in the robot base frame.
    public var upVector: SIMD3<Double> { up.vector }

    // MARK: Base and link

    /// The server moves the base by the offset it is sent with each axis signed by `linkSigns`; this is what to send
    /// for a move of `b` in the base frame.
    public func link(fromBase b: SIMD3<Double>) -> SIMD3<Double> { b * linkSigns }

    /// What a link offset `p` moves the base by.
    public func base(fromLink p: SIMD3<Double>) -> SIMD3<Double> { p * linkSigns }

    /// Single-precision forms, for the offsets the link controller holds as floats.
    public func link(fromBase b: SIMD3<Float>) -> SIMD3<Float> { b * SIMD3<Float>(linkSigns) }

    public func base(fromLink p: SIMD3<Float>) -> SIMD3<Float> { p * SIMD3<Float>(linkSigns) }

    /// How the log names the link's frame, such as `base_x,base_y,negative_base_z`.
    public var linkFrameName: String {
        zip(BaseAxis.allCases, [linkSigns.x, linkSigns.y, linkSigns.z])
            .map { ($1 < 0 ? "negative_base_" : "base_") + $0.rawValue }.joined(separator: ",")
    }

    /// Metres right, forward and up as the operator sees them, as an offset for the link's translation hold. For
    /// input that comes in the operator's frame, such as the phone's motion, so that it moves the arm the way the
    /// buttons do.
    public func linkOffset(right: Double, forward: Double, up: Double) -> SIMD3<Double> {
        link(fromBase: base(fromOperator: SIMD3(right, forward, up)))
    }

    // MARK: World and base

    /// A world-frame position in the robot base frame.
    public func base(fromWorld world: SIMD3<Double>) -> SIMD3<Double> {
        let shifted = world - baseInWorld
        return SIMD3(
            worldTurn.x.component(of: shifted), worldTurn.y.component(of: shifted),
            worldTurn.z.component(of: shifted))
    }

    /// Single-precision form, for the positions the app holds as floats.
    public func base(fromWorld world: SIMD3<Float>) -> SIMD3<Float> {
        let shifted = world - SIMD3<Float>(baseInWorld)
        func part(_ axis: SignedAxis) -> Float { Float(axis.sign) * shifted[axis.axis.index] }
        return SIMD3(part(worldTurn.x), part(worldTurn.y), part(worldTurn.z))
    }

    /// A robot base frame position in the world frame.
    public func world(fromBase base: SIMD3<Double>) -> SIMD3<Double> {
        var world = SIMD3<Double>.zero
        for (value, axis) in zip([base.x, base.y, base.z], worldTurn.axes) {
            world[axis.axis.index] = axis.sign * value
        }
        return world + baseInWorld
    }

    /// A world-frame direction in the base frame: no shift.
    public func base(fromWorldDirection world: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            worldTurn.x.component(of: world), worldTurn.y.component(of: world), worldTurn.z.component(of: world))
    }

    /// A base-frame direction in the world frame: no shift.
    public func worldDirection(fromBase base: SIMD3<Double>) -> SIMD3<Double> {
        var world = SIMD3<Double>.zero
        for (value, axis) in zip([base.x, base.y, base.z], worldTurn.axes) {
            world[axis.axis.index] = axis.sign * value
        }
        return world
    }

    // MARK: Validation

    /// Every fault in these frames, one plain sentence each, naming the profile file's fields. Empty: they can be used.
    public func faults() -> [String] {
        var faults: [String] = []
        let directions = [("forward", forward), ("left", left), ("up", up)]
        var directionSigns = true
        var directionsAreATurn = false
        for (name, direction) in directions where !direction.hasUnitSign {
            directionSigns = false
            faults.append(
                "robot.directions.\(name) must point one way along its axis: a sign of 1 or -1, not "
                    + "\(direction.sign).")
        }
        if directionSigns {
            if Set(directions.map(\.1.axis)).count != 3 {
                let said = directions.map { "\($0.0) \($0.1.text)" }.joined(separator: ", ")
                faults.append(
                    "robot.directions: forward, left and up must lie along three different base axes, one each; "
                        + "they are \(said).")
            } else if !Self.isTurn(right: left.reversed, forward: forward, up: up) {
                faults.append(
                    "robot.directions: forward, left and up make a mirror image of the operator's view, not a turn "
                        + "of the base. Flip the sign of one of the three.")
            } else {
                directionsAreATurn = true
            }
        }
        if !(0..<3).allSatisfy({ linkSigns[$0] == 1 || linkSigns[$0] == -1 }) {
            faults.append("server.link_signs must each be 1 or -1; only a mirrored axis is supported.")
        }
        if !(baseInWorld.x.isFinite && baseInWorld.y.isFinite && baseInWorld.z.isFinite) {
            faults.append("scene.base_in_world_m must be finite numbers.")
        }
        var turnSigns = true
        for (name, axis) in zip(["x", "y", "z"], worldTurn.axes) where !axis.hasUnitSign {
            turnSigns = false
            faults.append(
                "scene.base_axes_in_world.\(name) must point one way along its axis: a sign of 1 or -1, not "
                    + "\(axis.sign).")
        }
        var turnIsValid = false
        if turnSigns {
            if Set(worldTurn.axes.map(\.axis)).count != 3 {
                let said = zip(["x", "y", "z"], worldTurn.axes).map { "\($0.0) \($0.1.text)" }.joined(separator: ", ")
                faults.append(
                    "scene.base_axes_in_world: x, y and z must lie along three different world axes, one each; "
                        + "they are \(said).")
            } else if !Self.isTurn(right: worldTurn.x, forward: worldTurn.y, up: worldTurn.z) {
                faults.append(
                    "scene.base_axes_in_world is a mirror image, not a turn: the base's x cross y must be its z. "
                        + "Flip the sign of one of the three.")
            } else {
                turnIsValid = true
            }
        }
        if directionsAreATurn, turnIsValid {
            let worldUp = base(fromWorldDirection: SIMD3(0, 0, 1))
            if worldUp != up.vector {
                let along =
                    zip(BaseAxis.allCases, [worldUp.x, worldUp.y, worldUp.z])
                    .first { $1 != 0 }.map { SignedAxis($0.0, $0.1).text } ?? "?"
                faults.append(
                    "robot.directions.up is \(up.text), but scene.base_axes_in_world puts base \(along) along world "
                        + "+z. They must name the same base axis, the same way.")
            }
        }
        return faults
    }

    /// Three axes along three different axes form a turn, not a mirror image, when the first cross the second is the
    /// third.
    private static func isTurn(right: SignedAxis, forward: SignedAxis, up: SignedAxis) -> Bool {
        simd_cross(right.vector, forward.vector) == up.vector
    }
}
