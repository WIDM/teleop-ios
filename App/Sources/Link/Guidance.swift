import simd
import TeleopCore

/// What the app has to know about one robot setup to put the arm and the things around it in one picture.
/// The server's state does not carry these, so each setup the app drives needs a profile.
struct RobotProfile: Equatable {
    var name: String
    /// From the point the server reports for the arm (the gripper link origin) to where the jaws pinch,
    /// in the robot base frame, metres. Holds while the wrist joints stay put, as in translation mode.
    /// This is the grasp point with the jaws turned sideways, measured on the S4 simulator on 2026-11-11:
    /// the reported point sat at the cube's centre plus (−0.007, +0.036, +0.088) m. The front-to-back grasp it
    /// replaces lifted the cube 1 time in 16.
    var toolOffset: SIMD3<Float>
    /// Where the robot base sits in the world frame, metres. The server reports the arm in the base frame
    /// and objects in the world frame; this brings objects into the base frame.
    var baseInWorld: SIMD3<Float>

    /// The SO-101 in the S4 pick-and-place simulator. The base height is ROBOT_BASE_POS_W in the simulator's source.
    static let so101Simulator = RobotProfile(
        name: "SO-101 (S4 simulator)",
        toolOffset: SIMD3(0.007, -0.036, -0.088),
        baseInWorld: SIMD3(0, 0, 0.05)
    )

    /// How close the pinch point must be to an object's centre, across the table and in height, for closing
    /// the jaws to take hold of it. In the simulator the window is a few millimetres either way.
    var graspTolerance = SIMD2<Float>(0.006, 0.008)
    /// Edge of the task cube, metres.
    var cubeSize: Float = 0.025
    /// The scene's start pose already has the jaws side by side, which is the grasp `toolOffset` was measured
    /// for. True for the development simulator since 2026-11-11 (its start wrist roll is 90 degrees). The server
    /// as published starts them front to back, and there the operator has to turn them first: two full presses.
    var jawsStartSideways = true

    /// Where the jaws pinch, robot base frame.
    func toolPoint(reported arm: SIMD3<Float>) -> SIMD3<Float> { arm + toolOffset }
    /// A world-frame position in the robot base frame.
    func inBase(world: SIMD3<Float>) -> SIMD3<Float> { world - baseInWorld }
}

/// Where the thing to reach is, as the operator sees it, so the task does not have to be done by eye alone.
struct Guidance: Equatable {
    enum Target: Equatable { case cube, goal, done }

    var target: Target
    /// Metres right, forward and up from where the jaws pinch to the target. Zero means: close the gripper.
    var offset: SIMD3<Float>
    /// Where things are, in metres as the operator sees them: x right, y forward, z up. For the map.
    /// `arm` is where the jaws pinch, not the point the server reports.
    var arm = SIMD3<Float>.zero
    var cube = SIMD3<Float>.zero
    var goal = SIMD3<Float>.zero
    /// The arm stopped following in the direction it is being asked to go: it is at the edge of its range.
    var atEdge = false
    /// The jaws are around the cube: closing them now takes hold of it.
    var readyToGrasp = false
    /// The wrist was tilted since the scene was reset or the link came up. `arm` is the pinch point measured at the
    /// start pitch, so it no longer says where the jaw tips are.
    var wristTilted = false
    /// The jaws have to be turned sideways before this grasp point means anything; the guide says so.
    var turnJawsFirst = false
    /// Edge of the cube, metres, for drawing it true to size.
    var cubeSize = RobotProfile.so101Simulator.cubeSize
    /// Jaw tips this close to the target's height, metres, count as level with it.
    var heightTolerance = RobotProfile.so101Simulator.graspTolerance.y

    /// How close, flat on the table, the gripper must be to the cube to count as holding it once closed.
    static let holdingRadius: Float = 0.03
    /// Half-size of the goal area on the table, as the server judges success.
    static let goalHalfExtent: Float = 0.025

    /// Positions as the server reports them, metres: the arm in the robot base frame, cube and goal in the world.
    static func make(
        arm reported: SIMD3<Float>, cube worldCube: SIMD3<Float>, goal worldGoal: SIMD3<Float>,
        gripper: GripperState?, wristTilted: Bool = false, profile: RobotProfile = .so101Simulator
    ) -> Guidance {
        let arm = profile.toolPoint(reported: reported)
        let cube = profile.inBase(world: worldCube), goal = profile.inBase(world: worldGoal)
        let cubeToGoal = goal - cube
        let places = (operatorOffset(arm), operatorOffset(cube), operatorOffset(goal))
        if abs(cubeToGoal.x) <= goalHalfExtent, abs(cubeToGoal.y) <= goalHalfExtent {
            return Guidance(
                target: .done, offset: .zero, arm: places.0, cube: places.1, goal: places.2,
                wristTilted: wristTilted, cubeSize: profile.cubeSize, heightTolerance: profile.graspTolerance.y
            )
        }
        let flat = SIMD2(cube.x - arm.x, cube.y - arm.y)
        let holding = gripper == .closed && simd_length(flat) <= holdingRadius
        // Carrying: steer the cube, which moves with the gripper, to the goal. Otherwise steer the gripper to the cube.
        let base = holding ? cubeToGoal : cube - arm
        let ready = !holding && gripper != .closed && !wristTilted
            && simd_length(flat) <= profile.graspTolerance.x && abs(cube.z - arm.z) <= profile.graspTolerance.y
        return Guidance(
            target: holding ? .goal : .cube, offset: operatorOffset(base),
            arm: places.0, cube: places.1, goal: places.2, readyToGrasp: ready,
            wristTilted: wristTilted, turnJawsFirst: !profile.jawsStartSideways,
            cubeSize: profile.cubeSize, heightTolerance: profile.graspTolerance.y
        )
    }

    /// Robot base to operator directions. The server maps right → −X, forward → −Y, up → +Z.
    static func operatorOffset(_ base: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(-base.x, -base.y, base.z)
    }
}

/// Where to draw the gripper, the cube and the goal in the two guide views: from above, and from behind the robot.
/// Both views are `width` points wide and share one scale (points per metre) and one left-right axis, so a thing
/// sits at the same x in both. Up in the top view is the operator's forward, right is right. In the side view up is up,
/// with the table drawn as a line. The scale zooms out to keep the gripper, the cube and the goal in the top view.
/// Anything that would fall outside a view is pinned to its edge.
struct MiniMapLayout: Equatable {
    /// Edge of the goal area, metres.
    static let goalSize: Float = 0.05
    /// The views never cover less than this across, so small moves do not look huge.
    static let minimumSpan: Float = 0.14
    /// Room kept around the outermost thing.
    static let margin: Float = 0.03
    /// Width of both views, points. The text under them wraps at this width too.
    static let guideWidth: Float = 198
    /// Points kept between a marker pinned to an edge and that edge.
    static let pinInset: Float = 7
    /// Points from the bottom of the side view to the table line.
    static let tableInset: Float = 12
    /// Points the jaw schematic rises above the pinch point in the side view.
    static let jawRise: Float = 28
    /// Height of the ring in the side view, points. The ring lies flat, so it is seen edge on.
    static let ringThickness: Float = 10
    /// The ring is a little wider than the cube, like open jaws around it.
    static let ringToCube: Float = 1.9

    /// How the jaw tips compare with the cube's centre, or with the goal's resting height while carrying.
    struct HeightGap: Equatable {
        enum Kind: Equatable { case above, below, level }
        var kind: Kind
        /// Size of the gap in centimetres, never negative.
        var centimetres: Float
    }

    /// A dimension line in the side view and where its label goes.
    struct GapLine: Equatable {
        /// The line is vertical at this x, from the ring's height to the target's height.
        var x: Float
        var ringY: Float
        var targetY: Float
        /// Where the label's centre goes.
        var label: SIMD2<Float>
    }

    let width: Float
    let topHeight: Float
    let sideHeight: Float
    let cubeSize: Float
    let heightTolerance: Float
    let target: Guidance.Target
    let centre: SIMD2<Float>
    /// Points per metre, in both views and both directions.
    let scale: Float
    /// Height of the table surface.
    let tableZ: Float
    let arm: SIMD3<Float>
    let cube: SIMD3<Float>
    let goal: SIMD3<Float>

    init(_ guidance: Guidance, width: Float = guideWidth, topHeight: Float = 124, sideHeight: Float = 124) {
        self.width = width
        self.topHeight = topHeight
        self.sideHeight = sideHeight
        cubeSize = guidance.cubeSize
        heightTolerance = guidance.heightTolerance
        target = guidance.target
        arm = guidance.arm
        goal = guidance.goal
        // A held cube travels with the gripper; the server's last word on it is from before the hold.
        cube = guidance.target == .goal ? guidance.arm : guidance.cube
        let xs = [arm.x, cube.x, goal.x], ys = [arm.y, cube.y, goal.y]
        centre = SIMD2((xs.min()! + xs.max()!) / 2, (ys.min()! + ys.max()!) / 2)
        let spanX = max(xs.max()! - xs.min()! + 2 * Self.margin, Self.minimumSpan)
        let spanY = ys.max()! - ys.min()! + 2 * Self.margin
        scale = min(width / spanX, topHeight / spanY)
        tableZ = min(guidance.cube.z, guidance.goal.z) - guidance.cubeSize / 2
    }

    var carrying: Bool { target == .goal }

    func length(_ meters: Float) -> Float { meters * scale }

    /// Distance from the left edge, in either view.
    func x(_ meters: Float) -> Float { (meters - centre.x) * scale + width / 2 }

    /// Position in the top view, origin top-left.
    func top(_ place: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2(x(place.x), topHeight / 2 - (place.y - centre.y) * scale)
    }

    /// The robot base (the base frame's origin) in the top view. Off the map it sits on the nearest edge.
    var base: SIMD2<Float> {
        let at = top(.zero), inset = Self.pinInset
        return SIMD2(min(max(at.x, inset), width - inset), min(max(at.y, inset), topHeight - inset))
    }

    // MARK: Side view

    var tableY: Float { sideHeight - Self.tableInset }

    /// Distance from the top of the side view for a height, not pinned.
    func sideY(_ z: Float) -> Float { tableY - (z - tableZ) * scale }

    /// Where the pinch point is drawn. Too high or too low, it stays where the jaw schematic still fits.
    var ring: SIMD2<Float> {
        SIMD2(x(arm.x), min(max(sideY(arm.z), Self.jawRise + Self.pinInset), sideHeight - Self.pinInset))
    }

    /// The cube in the side view: sitting on the table, or in the jaws while carried.
    var sideCube: (centre: SIMD2<Float>, edge: Float) {
        (SIMD2(x(cube.x), carrying ? ring.y : sideY(cube.z)), length(cubeSize))
    }

    /// The goal area as a segment on the table.
    var sideGoal: (minX: Float, maxX: Float, y: Float) {
        (x(goal.x - Self.goalSize / 2), x(goal.x + Self.goalSize / 2), tableY)
    }

    /// Height the jaw tips are measured against: the cube's centre, or the goal's resting height while carrying.
    var targetZ: Float { carrying ? goal.z : cube.z }

    var heightGap: HeightGap? {
        guard target != .done else { return nil }
        let gap = arm.z - targetZ
        let kind: HeightGap.Kind = abs(gap) <= heightTolerance ? .level : (gap > 0 ? .above : .below)
        return HeightGap(kind: kind, centimetres: abs(gap) * 100)
    }

    /// Room the gap label needs beside the line, points.
    static let labelWidth: Float = 74
    static let labelHeight: Float = 16

    var gapLine: GapLine? {
        guard heightGap != nil else { return nil }
        let ring = self.ring
        let reach = length(cubeSize * Self.ringToCube) / 2 + 10
        // Beside the ring, on the side of it with more room, with the label further out so it stays off the ring and the cube.
        let toRight = ring.x < width / 2
        let lineX = min(max(toRight ? ring.x + reach : ring.x - reach, Self.pinInset), width - Self.pinInset)
        let targetY = min(max(sideY(targetZ), Self.pinInset), sideHeight - Self.pinInset)
        let half = Self.labelWidth / 2
        let labelX = min(max(toRight ? lineX + 5 + half : lineX - 5 - half, half), width - half)
        let labelY = min(max((ring.y + targetY) / 2, Self.labelHeight / 2), sideHeight - Self.labelHeight / 2)
        return GapLine(x: lineX, ringY: ring.y, targetY: targetY, label: SIMD2(labelX, labelY))
    }
}

/// The phone's own directions in the world, for a phone held in portrait.
/// ARKit's camera axes are fixed to the sensor, which sits landscape: +x runs along the long edge toward the
/// bottom of a portrait phone, +y toward its right edge, +z out of the screen.
struct PhoneAxes {
    let right: SIMD3<Float>
    let top: SIMD3<Float>
    /// Where the back camera looks.
    let view: SIMD3<Float>

    init(_ camera: simd_float4x4) {
        right = simd_normalize(SIMD3(camera.columns.1.x, camera.columns.1.y, camera.columns.1.z))
        top = -simd_normalize(SIMD3(camera.columns.0.x, camera.columns.0.y, camera.columns.0.z))
        view = -simd_normalize(SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z))
    }
}

/// Whether the phone is held so that right, forward and up mean what the operator expects.
/// Leaning back is fine, all the way to lying flat with the screen up: the direction mapping covers that.
/// What breaks it is holding the phone sideways, or with the screen turned toward the floor.
enum PhonePosture: Equatable {
    case upright
    /// Sideways, screen toward the floor, or upside down.
    case tilted
    /// ARKit has no pose yet.
    case unknown

    /// The side edge may dip this far from level before it counts as sideways.
    static let sidewaysDegrees: Float = 40
    /// The back camera may point this far above level before the screen counts as facing the floor.
    static let faceDownDegrees: Float = 30
    /// Once tilted, the phone must come back this much inside a limit to count as upright again,
    /// so a hand hovering at the limit does not flicker (and buzz) back and forth.
    static let returnMarginDegrees: Float = 10

    static func of(_ camera: simd_float4x4?, previous: PhonePosture = .unknown) -> PhonePosture {
        guard let camera else { return .unknown }
        let axes = PhoneAxes(camera)
        let margin = previous == .tilted ? returnMarginDegrees : 0
        let sideways = abs(axes.right.y) > sin((sidewaysDegrees - margin) * .pi / 180)
        let faceDown = axes.view.y > sin((faceDownDegrees - margin) * .pi / 180)
        let upsideDown = axes.top.y < (previous == .tilted ? -0.15 : -0.3)
        return sideways || faceDown || upsideDown ? .tilted : .upright
    }
}
