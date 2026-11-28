import TeleopCore

/// UI tests only: a named display for every state the operating screen shows, picked with `-operatingFixture <name>`.
/// The arm readings sit inside the profile's workspace, so they stay right if the box moves.
extension OperatingDisplay {
    static func fixture(named name: String) -> OperatingDisplay? {
        OperatingFixtures.all[name]
    }
}

struct OperatingFixtures {
    /// The fixtures of the profile this build drives.
    static let all: [String: OperatingDisplay] = OperatingFixtures(profile: ProfileLoader.current).displays

    /// The robot the scenes are drawn for: heights are along its up and the arm sits inside its work box.
    let profile: RobotProfile

    var displays: [String: OperatingDisplay] {
        var all: [String: OperatingDisplay] = [:]
        // Phone modes.
        // The model reports no reason yet, so neither does the fixture.
        all["not_connected"] = display(.notConnected(reason: nil), link: false, arm: nil, recorder: .unknown)
        all["connecting"] = display(
            .connecting(address: "192.168.0.10:8765"), link: false, arm: nil, recorder: .unknown)
        all["ready"] = display(.ready, arm: task(), recorder: armed)
        all["ready_hotel"] = display(.ready, arm: hotel(), recorder: notRecording)
        all["moving"] = display(.moving(catchingUp: false), arm: task(moving: true), recorder: capturing)
        all["moving_hotel"] = display(.moving(catchingUp: true), arm: hotel(moving: true), recorder: notRecording)
        all["moving_no_arm"] = display(.moving(catchingUp: false), arm: nil, recorder: .unknown)
        // A follow nobody holds: lock chosen, the key let go of after the press.
        all["locked"] = display(.locked(catchingUp: false), arm: task(moving: true), recorder: capturing)
        // A move to a point tapped on the guide: the commanded ring on its way, the cross where it is headed.
        all["going"] = display(.going(catchingUp: false), arm: going(), recorder: capturing)
        all["turning"] = display(
            .turning(degrees: 42, limit: profile.wrist.rollClampDeg, estimated: false), mode: .keyTurns,
            arm: hotel(), recorder: capturing)
        var turningLeft = all["turning"]!
        turningLeft.hand = .left
        all["turning_left"] = turningLeft
        // A server that measures no wrist angles: the estimated pinch point cannot rule out a tilt, so it is approximate.
        all["tilting_estimated"] = display(
            .tilting(degrees: 8, limit: profile.wrist.tiltClampDeg, estimated: true), arm: approximate(task()),
            recorder: .unknown
        )
        all["opening"] = display(.opening, arm: onTarget(), recorder: armed)
        all["closing_gripped"] = display(.closing(gripped: true), mode: .keyTurns, arm: holding(), recorder: capturing)
        all["holding"] = display(.moving(catchingUp: false), arm: holding(moving: true), recorder: capturing)
        all["wait_saving"] = display(.wait(.saving), arm: task(), recorder: waiting)
        all["wait_resetting"] = display(.wait(.resetting), arm: hotel(), recorder: armed)
        all["camera_stopped"] = display(.trackingLost, arm: task(), recorder: armed)
        all["refused"] = display(.refused(.posture), arm: hotel(), recorder: armed)
        // Why a touch on the guide was not a tap, for a second.
        all["refused_tap_still"] = display(.refused(.tapStill), arm: task(), recorder: armed)
        all["refused_tap_let_go"] = display(.refused(.tapLetGo), arm: task(), recorder: armed)
        all["refused_tap_view_above"] = display(.refused(.tapViewAbove), arm: task(), recorder: armed)
        all["refused_use_upper_key"] = display(.refused(.useUpperKey), arm: task(), recorder: armed)
        // A follow or a move nobody held that ran out of time: why it ended, for a second.
        all["ended_time_limit"] = display(.ended(.timeLimit), arm: task(), recorder: armed)
        all["slow_link"] = display(.slowLink(ms: 450), arm: task(), recorder: armed, latency: 450)
        all["stopped"] = display(.stopped(cause: .button), arm: task(), recorder: off, exits: recordingExits)
        all["stopped_release"] = display(.stopped(cause: .behind), arm: hotel(), recorder: notRecording)
        all["stopped_unknown_server"] = display(
            .stopped(cause: .onConnect), arm: task(), recorder: .unknown, exits: unknownServerExits)
        all["link_lost"] = display(.linkLost, link: false, arm: task(), recorder: armed)
        all["saved"] = display(.saved(count: 13), arm: task(), recorder: waiting)
        var countdown = display(.ready, arm: task(), recorder: off)
        countdown.resetCountdown = 0.6
        all["rec_off_countdown"] = countdown
        all["outside"] = display(.ready, arm: outside(), recorder: notRecording)
        // An estimated pinch point that may be off by more than half the grasp tolerance: hollow, said so, and no
        // "On target" though it sits inside the window.
        all["approximate"] = display(.ready, arm: approximate(onTarget()), recorder: armed)
        all["approximate_hotel"] = display(
            .moving(catchingUp: false), arm: approximate(hotel(moving: true)), recorder: notRecording)
        // Practice. The model reads no arm from the practice link, so these show no guide, as the app does.
        all["practice_ready"] = display(.ready, arm: nil, recorder: .unknown, practice: true)
        all["practice_stopped"] = display(.stopped(cause: .button), arm: nil, recorder: .unknown, practice: true)
        // Buttons mode.
        all["buttons_ready"] = display(.ready, mode: .buttons, arm: task(), recorder: armed)
        var moving = display(.moving(catchingUp: false), mode: .buttons, arm: task(moving: true), recorder: capturing)
        moving.heldButton = .forward
        moving.speed = .fine
        moving.engaged = .translation
        all["buttons_moving"] = moving
        var stopped = display(
            .stopped(cause: .other), mode: .buttons, arm: hotel(), recorder: .unknown, exits: unknownServerExits)
        stopped.hand = .left
        all["buttons_stopped"] = stopped
        all["buttons_practice"] = display(.ready, mode: .buttons, arm: nil, recorder: .unknown, practice: true)
        // The guide's aids drawn: the shadow under the jaws, the lowest height a stall reached just above the table,
        // and which way is forward and which way is up.
        all["ready_aids"] = display(.ready, arm: stalledOnTheTableBefore(task()), recorder: armed, aids: .all)
        // The jaws back at the lowest height a stall reached, on something above the table: the height says "lowest",
        // and the dashed line from behind lies at the jaws, clear of the table line.
        all["lowest_aids"] = display(.ready, arm: atTheLowestOnSomething(), recorder: armed, aids: .all)
        // The hands-free aids' master switch off on the real server: the line under the state says a tap does nothing.
        var aidsOff = display(.ready, arm: task(), recorder: armed)
        aidsOff.aidsOff = true
        all["ready_aids_off"] = aidsOff
        return all
    }

    /// The guide is built from the reading as the model builds it, so a fixture draws exactly what the app would.
    /// `aids`: the guide's aids it draws; nil draws version 1.0.1's guide.
    private func display(
        _ state: OperatingState, mode: ControlMode = .screenTurns, link: Bool = true, arm: ArmReading?,
        recorder: RecorderDisplay, exits: StopExits = noRecorderExits, practice: Bool = false, latency: Int = 60,
        aids: GuideAids? = nil
    ) -> OperatingDisplay {
        OperatingDisplay(
            mode: mode, hand: .right, state: state, layout: nil, engaged: nil, resetCountdown: nil, heldButton: nil,
            speed: .coarse, recorder: recorder,
            stopExits: practice ? StopExits.offered(recorder: nil, practice: true) : exits,
            linkUp: link || practice, latencyMs: link ? latency : nil, address: "192.168.0.10:8765", arm: arm,
            practice: practice, taskAid: true,
            guide: arm.map { GuidePicture(reading: $0, profile: profile, aids: aids) }
        )
    }

    // MARK: Arm readings, robot base frame
    // Places are written as an offset across the table from the middle of the work box and a height along the profile's
    // up, so the scenes stay right for an arm whose up is not base +z.

    private var up: SignedAxis { profile.frames.up }
    private var centre: SIMD3<Float> { (profile.workspaceMin + profile.workspaceMax) / 2 }
    private var onTable: Float { profile.tableHeight }

    /// `point` moved by `across` (a base-frame offset: its part along up is dropped) and then `rise` up.
    private func moved(_ point: SIMD3<Float>, across: SIMD3<Float> = .zero, up rise: Float = 0) -> SIMD3<Float> {
        var level = across
        level[up.axis.index] = 0
        var lift = SIMD3<Float>.zero
        lift[up.axis.index] = Float(up.sign) * rise
        return point + level + lift
    }

    /// How high `point` is, metres: its part along up, over the base origin.
    private func height(of point: SIMD3<Float>) -> Float { Float(up.sign) * point[up.axis.index] }

    /// `point` moved straight up or down until its height is `height`.
    private func settingHeight(_ height: Float, of point: SIMD3<Float>) -> SIMD3<Float> {
        var moved = point
        moved[up.axis.index] = Float(up.sign) * height
        return moved
    }

    private var target: SIMD3<Float> {
        settingHeight(onTable + 0.0125, of: moved(centre, across: SIMD3(0.015, -0.035, 0)))
    }
    private var goal: SIMD3<Float> {
        settingHeight(onTable + 0.0135, of: moved(centre, across: SIMD3(-0.05, -0.035, 0)))
    }

    /// No task objects: what any arm reports.
    private func hotel(moving: Bool = false) -> ArmReading {
        let pinch = moved(centre, across: SIMD3(-0.02, 0.01, 0), up: -0.005)
        return ArmReading(
            pinchPoint: pinch, commanded: moving ? moved(pinch, across: SIMD3(-0.025, -0.015, 0), up: -0.01) : nil,
            jawOpening: 0.8, wristTurnDeg: 90, wristTiltDeg: -3, target: nil, goal: nil, gripping: false
        )
    }

    private func task(moving: Bool = false) -> ArmReading {
        let pinch = moved(centre, across: SIMD3(-0.01, 0.02, 0), up: 0.03)
        return ArmReading(
            pinchPoint: pinch, commanded: moving ? moved(pinch, across: SIMD3(0.015, -0.03, 0), up: -0.02) : nil,
            jawOpening: 0.9, wristTurnDeg: 90, wristTiltDeg: 0, target: target, goal: goal, gripping: false
        )
    }

    /// On the way to a point tapped on the guide, at the travel height the profile gives above the table.
    private func going() -> ArmReading {
        var reading = task(moving: true)
        let travel = profile.assist.goTo.map { Float($0.travelHeightM) } ?? 0
        reading.goTarget = settingHeight(onTable + travel, of: moved(centre, across: SIMD3(0.04, -0.03, 0)))
        return reading
    }

    private func onTarget() -> ArmReading {
        ArmReading(
            pinchPoint: moved(target, across: SIMD3(0.002, -0.001, 0), up: 0.003), commanded: nil, jawOpening: 0.7,
            wristTurnDeg: 90, wristTiltDeg: 0, target: target, goal: goal, gripping: false
        )
    }

    private func holding(moving: Bool = false) -> ArmReading {
        let pinch = moved(centre, across: SIMD3(-0.03, -0.02, 0), up: 0.025)
        return ArmReading(
            pinchPoint: pinch, commanded: moving ? moved(pinch, across: SIMD3(-0.02, 0, 0)) : nil, jawOpening: 0.12,
            wristTurnDeg: 90, wristTiltDeg: 0, target: pinch, goal: goal, gripping: true
        )
    }

    private func approximate(_ reading: ArmReading) -> ArmReading {
        var reading = reading
        reading.pinchSource = .estimated(approximate: true)
        return reading
    }

    /// The reading after a downward stall with the jaws just above the table: the lowest height, kept for the gripper
    /// link, is the profile's tool offset above that pinch height.
    private func stalledOnTheTableBefore(_ reading: ArmReading) -> ArmReading {
        var reading = reading
        reading.lowestGripperZ = onTable + 0.005 - height(of: profile.toolOffset)
        return reading
    }

    /// The jaws resting on something 3 cm above the table, where a downward stall left both lowest heights. The server
    /// reports the pinch point, so the line and "lowest" follow it; the gripper link's lowest height is 6 mm off what
    /// the profile's tool offset gives, as a change of the arm's posture leaves it.
    private func atTheLowestOnSomething() -> ArmReading {
        let pinch = settingHeight(onTable + 0.03, of: moved(centre, across: SIMD3(-0.02, 0.01, 0)))
        var reading = ArmReading(
            pinchPoint: pinch, commanded: nil, jawOpening: 0.4, wristTurnDeg: 90, wristTiltDeg: 0, target: nil,
            goal: nil, gripping: false
        )
        reading.pinchSource = .reported
        reading.lowestPinchZ = height(of: pinch)
        reading.lowestGripperZ = height(of: pinch) - height(of: profile.toolOffset) - 0.006
        return reading
    }

    /// Past the work box's low edge on the first base axis that does not lie along up.
    private func outside() -> ArmReading {
        let axis = up.axis == .x ? 1 : 0
        var pinch = centre
        pinch[axis] = profile.workspaceMin[axis] - 0.03
        return ArmReading(
            pinchPoint: pinch, commanded: nil, jawOpening: nil, wristTurnDeg: nil, wristTiltDeg: nil, target: nil,
            goal: nil, gripping: false
        )
    }
}

// Recorder states and stop exits that do not depend on the robot.
private let armed = RecorderDisplay(mode: .armed, saved: 12, discarded: 3)
private let capturing = RecorderDisplay(mode: .capturing, saved: 12, discarded: 3, secondsCaptured: 12.4)
private let waiting = RecorderDisplay(mode: .waiting, saved: 13, discarded: 3)
private let off = RecorderDisplay(mode: .off, saved: 12, discarded: 4)
private let notRecording = RecorderDisplay(mode: .notRecording)
private let recordingExits = StopExits(exits: [.resetScene], recordingMayStayOff: false)
private let noRecorderExits = StopExits(exits: [.resetScene, .releaseKeepScene], recordingMayStayOff: false)
private let unknownServerExits = StopExits(exits: [.resetScene, .releaseKeepScene], recordingMayStayOff: true)
