import simd
import TeleopCore

/// The guide as plain numbers: where each thing goes in its two views and what its read-outs say. Pure, so every case
/// can be tested without drawing.
///
/// The base form uses only what any arm reports: the pinch point inside the workspace box, seen from above and from
/// behind, its height above the table, how far the jaws are open, the wrist's turn and tilt when reported, and where
/// the arm is being asked to go during a move. Only when the server reports task objects does it add a target and a
/// goal as plain shapes, the gap from the pinch point to the target, "on target" inside the profile's tolerance, and
/// "holding" while the jaws grip.
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
        case jaws(percentOpen: Int)
        case wrist(turnDeg: Int?, tiltDeg: Int?)
        /// From the pinch point to the target: the distance across the table, and the height.
        case target(acrossCm: Double, height: Height)
        case onTarget
        case holding
        /// While holding: from the pinch point to the goal.
        case goal(acrossCm: Double, height: Height)
        /// The pinch point is outside the workspace box.
        case outside
    }

    /// Room around the workspace box, as a share of its larger side, so a mark on the box's edge is drawn whole.
    static let marginShare = 0.15
    /// A reading this close outside the box's faces, metres, still counts as inside.
    static let boxSlack = 0.001

    /// Width over height of the view from above, and of the view from behind.
    let aboveAspect: Double
    let behindAspect: Double
    /// The workspace box in each view. From behind, it stops at the table.
    let boxAbove: Area
    let boxBehind: Area
    /// The table's surface in the view from behind.
    let tableY: Double
    let pinch: Mark
    let commanded: Mark?
    /// 0 closed … 1 open; nil when not reported.
    let jawOpening: Double?
    let target: Mark?
    let goal: Mark?
    /// Edges as shares of the views' width, which both views share.
    let targetEdge: Double
    let goalEdge: Double
    let outside: Bool
    let onTarget: Bool
    let holding: Bool
    let lines: [Line]

    init(reading: ArmReading, profile: RobotProfile) {
        let corners = (Self.operatorPoint(profile.workspaceMin), Self.operatorPoint(profile.workspaceMax))
        // Corners swap sides where an axis is mirrored into the operator's frame.
        let boxLow = simd_min(corners.0, corners.1), boxHigh = simd_max(corners.0, corners.1)
        let span = boxHigh - boxLow
        let margin = max(span.x, span.y) * Self.marginShare
        let table = Double(profile.tableHeight)
        let floor = max(boxLow.z, table)
        let across = (boxLow.x - margin)...(boxHigh.x + margin)
        let depth = (boxLow.y - margin)...(boxHigh.y + margin)
        let height = (table - margin / 2)...(max(boxHigh.z, table) + margin)
        let width = across.upperBound - across.lowerBound
        aboveAspect = width / (depth.upperBound - depth.lowerBound)
        behindAspect = width / (height.upperBound - height.lowerBound)

        func share(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        }
        func mark(_ base: SIMD3<Float>) -> Mark {
            let p = Self.operatorPoint(base)
            let above = Spot(x: share(p.x, across), y: 1 - share(p.y, depth))
            let behind = Spot(x: share(p.x, across), y: 1 - share(p.z, height))
            let shown = (above: Self.clamp(above), behind: Self.clamp(behind))
            return Mark(above: shown.above, behind: shown.behind, pinned: shown.above != above || shown.behind != behind)
        }

        boxAbove = Area(minX: share(boxLow.x, across), minY: 1 - share(boxHigh.y, depth),
                        maxX: share(boxHigh.x, across), maxY: 1 - share(boxLow.y, depth))
        boxBehind = Area(minX: share(boxLow.x, across), minY: 1 - share(boxHigh.z, height),
                         maxX: share(boxHigh.x, across), maxY: 1 - share(floor, height))
        tableY = 1 - share(table, height)

        let pinchPoint = Self.operatorPoint(reading.pinchPoint)
        pinch = mark(reading.pinchPoint)
        commanded = reading.commanded.map(mark)
        jawOpening = reading.jawOpening.map { min(max($0, 0), 1) }
        target = reading.target.map(mark)
        goal = reading.goal.map(mark)
        targetEdge = Double(profile.cubeSize) / width
        goalEdge = Double(Guidance.goalHalfExtent * 2) / width
        outside = (0..<3).contains {
            pinchPoint[$0] < boxLow[$0] - Self.boxSlack || pinchPoint[$0] > boxHigh[$0] + Self.boxSlack
        }

        let tolerance = SIMD2<Double>(profile.graspTolerance)
        func compare(_ thing: SIMD3<Float>) -> (across: Double, height: Height, within: Bool) {
            let t = Self.operatorPoint(thing)
            let across = simd_length(SIMD2(pinchPoint.x - t.x, pinchPoint.y - t.y))
            let rise = pinchPoint.z - t.z
            let height: Height = abs(rise) <= tolerance.y ? .level : (rise > 0 ? .above(cm: rise * 100) : .below(cm: -rise * 100))
            return (across, height, across <= tolerance.x && height == .level)
        }

        holding = reading.gripping && reading.target != nil
        var lines: [Line] = [.height(cm: (pinchPoint.z - table) * 100)]
        if let open = jawOpening { lines.append(.jaws(percentOpen: Int((open * 100).rounded()))) }
        if reading.wristTurnDeg != nil || reading.wristTiltDeg != nil {
            lines.append(.wrist(turnDeg: reading.wristTurnDeg.map { Int($0.rounded()) },
                                tiltDeg: reading.wristTiltDeg.map { Int($0.rounded()) }))
        }
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
            onTarget = gap.within
            if onTarget { lines.append(.onTarget) }
        }
        self.onTarget = onTarget
        if outside { lines.append(.outside) }
        self.lines = lines
    }

    /// Right, forward and up as the operator sees them, metres, from a point in the robot base frame, by §3.3's
    /// axis table.
    static func operatorPoint(_ base: SIMD3<Float>) -> SIMD3<Double> {
        let b = SIMD3<Double>(base)
        return SIMD3(
            simd_dot(b, OperatorDirection.right.baseVector),
            simd_dot(b, OperatorDirection.forward.baseVector),
            simd_dot(b, OperatorDirection.up.baseVector)
        )
    }

    private static func clamp(_ spot: Spot) -> Spot {
        Spot(x: min(max(spot.x, 0), 1), y: min(max(spot.y, 0), 1))
    }
}
