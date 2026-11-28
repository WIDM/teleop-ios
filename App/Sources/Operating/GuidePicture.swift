import simd
import TeleopCore

/// The guide as plain numbers: where each thing goes in its two views and what its read-outs say. Pure, so every case
/// can be tested without drawing.
///
/// The base form uses only what any arm reports: the pinch point inside the workspace box, seen from above and from
/// behind, its height above the table, how far the jaws are open, the wrist's turn and tilt when reported, where the
/// arm is being asked to go during a move, and where a move to a point tapped on the guide is headed. Only when the
/// server reports task objects does it add a target and a goal as plain shapes, the gap from the pinch point to the
/// target, "on target" inside the on-target window, and "holding" while the jaws grip. A pinch point the profile can
/// only estimate roughly is drawn hollow, says so, and is never "on target". The guide's aids, each only when it is on,
/// add: the side the commanded place is outside the work area on, the lowest height a downward stall reached (a line
/// from behind, and "lowest" on the height while the pinch point is back there), a shadow under the pinch point, and
/// which way is forward and which way is up.
///
/// Both views are equally wide and share one left-right axis and one scale, so a thing sits at the same x in both.
/// From above, up is the operator's forward; from behind, up is up. Places are shares of a view's width and height,
/// origin top left, y down. A thing outside a view is drawn on its edge and marked as pinned.
struct GuidePicture: Equatable {
    struct Spot: Equatable {
        var x: Double
        var y: Double
    }

    /// One thing, in both views.
    struct Mark: Equatable {
        var above: Spot
        var behind: Spot
        /// It lies outside at least one view and is drawn on that view's edge.
        var pinned: Bool
    }

    struct Area: Equatable {
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double
    }

    /// How the pinch point's height compares with a thing's, inside the profile's height tolerance or not.
    enum Height: Equatable {
        case above(cm: Double)
        case below(cm: Double)
        case level
    }

    /// One read-out under the views, in the order shown. The view puts each into words.
    enum Line: Equatable {
        /// The pinch point's height above the table.
        case height(cm: Double)
        /// The same, while the pinch point is back at the lowest height a downward stall reached (the guide's aid).
        case heightLowest(cm: Double)
        case jaws(percentOpen: Int)
        case wrist(turnDeg: Int?, tiltDeg: Int?)
        /// The pinch point is an estimate that may be off by more than half the profile's grasp tolerance.
        case approximate
        /// From the pinch point to the target: the distance across the table, and the height.
        case target(acrossCm: Double, height: Height)
        case onTarget
        case holding
        /// While holding: from the pinch point to the goal.
        case goal(acrossCm: Double, height: Height)
        /// The place being commanded is outside the work area on this side, in the operator's words (the guide's aid).
        case commandOutside(OperatorDirection)
        /// The pinch point is outside the workspace box.
        case outside
    }

    /// Room around the workspace box, as a share of its larger side, so a mark on the box's edge is drawn whole.
    static let marginShare = GuideProjection.marginShare
    /// A reading this close outside the box's faces, metres, still counts as inside.
    static let boxSlack = 0.001

    /// Where every spot in both views was placed. A tap on the view from above is read back through this same value,
    /// so it asks for the place drawn under the finger.
    let projection: GuideProjection
    /// The workspace box as drawn, robot base frame, pinch point, metres: the profile's box moved by the reading's
    /// `boxShift`, corners sorted. Two members rather than a pair, so that `Equatable` is still synthesized.
    let workBoxLow: SIMD3<Double>
    let workBoxHigh: SIMD3<Double>
    /// Width over height of the view from above, and of the view from behind.
    var aboveAspect: Double { projection.aboveAspect }
    var behindAspect: Double { projection.behindAspect }
    /// The workspace box in each view. From behind, it stops at the table.
    let boxAbove: Area
    let boxBehind: Area
    /// The table's surface in the view from behind.
    let tableY: Double
    let pinch: Mark
    let commanded: Mark?
    /// Where a move to a point tapped on the guide is headed, drawn as a cross in both views; nil when none runs.
    let goTarget: Mark?
    /// 0 closed … 1 open; nil when not reported.
    let jawOpening: Double?
    let target: Mark?
    let goal: Mark?
    /// Edges as shares of the views' width, which both views share.
    let targetEdge: Double
    let goalEdge: Double
    let outside: Bool
    /// The pinch point is drawn hollow: an estimate that may be off by more than half the profile's grasp tolerance.
    let approximate: Bool
    /// Never while `approximate`.
    let onTarget: Bool
    let holding: Bool
    /// From the target to the pinch point, metres: across the table, and the pinch point's height above it. Nil
    /// without a target.
    let targetGap: SIMD2<Double>?
    let lines: [Line]
    /// The guide's aids, each nil or false without its aid. The lowest pinch height a downward stall reached, as a
    /// share of the view from behind's height, drawn as a dashed line across the box; "lowest" on the height read-out
    /// uses the same height.
    let lowestY: Double?
    /// The pinch point's height above the table as a share of the box's height above it, 0 to 1, for the shadow under
    /// the pinch point: the only height cue the view from above has.
    let lift: Double?
    /// Draw which way is forward and which way is up on the views, and say it in their accessibility labels.
    let directionLabels: Bool
    let fixedLayout: Bool
    let pinchAboveRearView: Bool

    /// `aids`: the guide's aids in force (`Assist.guide`); nil draws and says exactly what version 1.0.1 does.
    init(reading: ArmReading, profile: RobotProfile, aids: GuideAids? = nil, views: ViewAim? = nil) {
        let frames = profile.frames
        let ends = (profile.workspaceMin + reading.boxShift, profile.workspaceMax + reading.boxShift)
        workBoxLow = SIMD3<Double>(simd_min(ends.0, ends.1))
        workBoxHigh = SIMD3<Double>(simd_max(ends.0, ends.1))
        let corners = (Self.operatorPoint(ends.0, frames: frames), Self.operatorPoint(ends.1, frames: frames))
        // Corners swap sides where an axis is mirrored into the operator's frame.
        let boxLow = simd_min(corners.0, corners.1), boxHigh = simd_max(corners.0, corners.1)
        let table = Double(profile.tableHeight)
        let floor = max(boxLow.z, table)
        let projection: GuideProjection
        fixedLayout = views != nil
        if let views {
            let profileLow = Self.operatorPoint(profile.workspaceMin, frames: frames)
            let profileHigh = Self.operatorPoint(profile.workspaceMax, frames: frames)
            projection = GuideProjection(
                frames: frames, boxLow: simd_min(profileLow, profileHigh), boxHigh: simd_max(profileLow, profileHigh),
                table: table,
                behindTop: table + views.behindTopAboveTableM)
        } else {
            projection = GuideProjection(frames: frames, boxLow: boxLow, boxHigh: boxHigh, table: table)
        }
        self.projection = projection
        let width = projection.across.upperBound - projection.across.lowerBound

        func mark(_ base: SIMD3<Float>) -> Mark {
            let p = Self.operatorPoint(base, frames: frames)
            let fromAbove = projection.above(p), fromBehind = projection.behind(p)
            let above = Spot(x: fromAbove.x, y: fromAbove.y)
            let behind = Spot(x: fromBehind.x, y: fromBehind.y)
            let shown = (above: Self.clamp(above), behind: Self.clamp(behind))
            return Mark(
                above: shown.above, behind: shown.behind, pinned: shown.above != above || shown.behind != behind)
        }

        // From above, the box's farthest forward side is its top edge; from behind, its highest side is.
        let lowAbove = projection.above(boxLow), highAbove = projection.above(boxHigh)
        boxAbove = Area(minX: lowAbove.x, minY: highAbove.y, maxX: highAbove.x, maxY: lowAbove.y)
        let topBehind = projection.behind(boxHigh)
        let floorBehind = projection.behind(SIMD3(boxLow.x, boxLow.y, floor))
        boxBehind = Area(minX: floorBehind.x, minY: max(0, topBehind.y), maxX: topBehind.x, maxY: floorBehind.y)
        tableY = projection.behind(SIMD3(boxLow.x, boxLow.y, table)).y

        let pinchPoint = Self.operatorPoint(reading.pinchPoint, frames: frames)
        pinchAboveRearView = fixedLayout && pinchPoint.z > projection.height.upperBound
        pinch = mark(reading.pinchPoint)
        commanded = reading.commanded.map(mark)
        goTarget = reading.goTarget.map(mark)
        jawOpening = reading.jawOpening.map { min(max($0, 0), 1) }
        target = reading.target.map(mark)
        goal = reading.goal.map(mark)
        targetEdge = Double(profile.targetSize) / width
        goalEdge = Double(profile.goalSize) / width
        outside = (0..<3).contains {
            pinchPoint[$0] < boxLow[$0] - Self.boxSlack || pinchPoint[$0] > boxHigh[$0] + Self.boxSlack
        }

        let tolerance = SIMD2<Double>(profile.graspTolerance)
        // Only "On target" takes the wider window; the level word keeps the grasp tolerance.
        let window = Self.onTargetWindow(profile, aids: aids)
        func gap(to thing: SIMD3<Float>) -> SIMD2<Double> {
            let t = Self.operatorPoint(thing, frames: frames)
            return SIMD2(simd_length(SIMD2(pinchPoint.x - t.x, pinchPoint.y - t.y)), pinchPoint.z - t.z)
        }
        func compare(_ thing: SIMD3<Float>) -> (across: Double, height: Height, within: Bool) {
            let gap = gap(to: thing)
            let rise = gap.y
            let height: Height =
                abs(rise) <= tolerance.y ? .level : (rise > 0 ? .above(cm: rise * 100) : .below(cm: -rise * 100))
            return (gap.x, height, OnTargetCue.inside(gap, window: window))
        }

        targetGap = reading.target.map(gap(to:))
        holding = reading.gripping && reading.target != nil
        approximate = reading.pinchSource.isApproximate

        // The lowest height is the pinch point's own when the server reported the pinch point at the stall: on a table
        // it stays put whatever the arm's posture. Without it, the gripper link's lowest height is moved by this
        // reading's offset, as the ring and the box are, which is off by as much as the offset changed with the
        // posture since. The lowest heights are along up (`Frames.height(of:)`), as the picture's heights are.
        let offset = SIMD3<Double>(profile.toolOffset + reading.boxShift)
        let lowestHeight =
            reading.lowestPinchZ.map(Double.init)
            ?? reading.lowestGripperZ.map { Double($0) + frames.height(of: offset) }
        let lowest = aids?.lowestCue == true ? lowestHeight : nil
        lowestY = lowest.map { min(max(projection.behind(SIMD3(pinchPoint.x, pinchPoint.y, $0)).y, 0), 1) }
        let rise = boxHigh.z - table
        lift = aids?.shadow == true ? (rise > 0 ? min(max((pinchPoint.z - table) / rise, 0), 1) : 0) : nil
        directionLabels = aids?.directionLabels == true

        // Back within the blocked rule's moved distance (2 mm on the SO-101) of the lowest height, the height says so.
        let atLowest = lowest.map { abs(pinchPoint.z - $0) <= profile.blocked.movedM } ?? false
        let heightCm = (pinchPoint.z - table) * 100
        var lines: [Line] = [atLowest ? .heightLowest(cm: heightCm) : .height(cm: heightCm)]
        if let open = jawOpening { lines.append(.jaws(percentOpen: Int((open * 100).rounded()))) }
        if reading.wristTurnDeg != nil || reading.wristTiltDeg != nil {
            lines.append(
                .wrist(
                    turnDeg: reading.wristTurnDeg.map { Int($0.rounded()) },
                    tiltDeg: reading.wristTiltDeg.map { Int($0.rounded()) }))
        }
        if approximate { lines.append(.approximate) }
        var onTarget = false
        if holding {
            lines.append(.holding)
            if let goal = reading.goal {
                let gap = compare(goal)
                lines.append(.goal(acrossCm: gap.across * 100, height: gap.height))
            }
        } else if let target = reading.target {
            let gap = compare(target)
            lines.append(.target(acrossCm: gap.across * 100, height: gap.height))
            onTarget = gap.within && !approximate
            if onTarget { lines.append(.onTarget) }
        }
        self.onTarget = onTarget
        if aids?.workAreaWords == true, let side = reading.commandOutside { lines.append(.commandOutside(side)) }
        if outside { lines.append(.outside) }
        self.lines = lines
    }

    /// The window "On target" is judged in, across the table and in height, metres: the profile's wider window when the
    /// guide's aids ask for it and the profile gives one, else the grasp tolerance, as in version 1.0.1. The on-target
    /// cue is made with the same window, so what is felt is what is drawn.
    static func onTargetWindow(_ profile: RobotProfile, aids: GuideAids?) -> SIMD2<Double> {
        guard aids?.widerOnTarget == true, let window = profile.onTargetWindow else {
            return SIMD2<Double>(profile.graspTolerance)
        }
        return SIMD2<Double>(window)
    }

    /// Right, forward and up as the operator sees them, metres, from a point in the robot base frame, by the profile's
    /// frames: the projection's own conversion.
    static func operatorPoint(_ base: SIMD3<Float>, frames: Frames) -> SIMD3<Double> {
        frames.operatorPoint(SIMD3<Double>(base))
    }

    private static func clamp(_ spot: Spot) -> Spot {
        Spot(x: min(max(spot.x, 0), 1), y: min(max(spot.y, 0), 1))
    }
}
