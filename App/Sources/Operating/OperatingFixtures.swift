import TeleopCore

/// UI tests only: a named display for every state the operating screen shows, picked with `-operatingFixture <name>`.
/// The arm readings sit inside the profile's workspace, so they stay right if the box moves.
extension OperatingDisplay {
    static func fixture(named name: String) -> OperatingDisplay? {
        OperatingFixtures.all[name]
    }
}

enum OperatingFixtures {
    static let all: [String: OperatingDisplay] = {
        var all: [String: OperatingDisplay] = [:]
        // Phone modes.
        // The model reports no reason yet, so neither does the fixture.
        all["not_connected"] = display(.notConnected(reason: nil), link: false, arm: nil, recorder: .unknown)
        all["connecting"] = display(.connecting(address: "192.168.0.10:8765"), link: false, arm: nil, recorder: .unknown)
        all["ready"] = display(.ready, arm: task(), recorder: armed)
        all["ready_hotel"] = display(.ready, arm: hotel(), recorder: notRecording)
        all["moving"] = display(.moving(catchingUp: false), arm: task(moving: true), recorder: capturing)
        all["moving_hotel"] = display(.moving(catchingUp: true), arm: hotel(moving: true), recorder: notRecording)
        all["moving_no_arm"] = display(.moving(catchingUp: false), arm: nil, recorder: .unknown)
        all["turning"] = display(.turning(degrees: 42, limit: 55, estimated: false), mode: .keyTurns, arm: hotel(), recorder: capturing)
        all["tilting_estimated"] = display(.tilting(degrees: 8, limit: 20, estimated: true), arm: task(), recorder: .unknown)
        all["opening"] = display(.opening, arm: onTarget(), recorder: armed)
        all["closing_gripped"] = display(.closing(gripped: true), mode: .keyTurns, arm: holding(), recorder: capturing)
        all["holding"] = display(.moving(catchingUp: false), arm: holding(moving: true), recorder: capturing)
        all["wait_saving"] = display(.wait(.saving), arm: task(), recorder: waiting)
        all["wait_resetting"] = display(.wait(.resetting), arm: hotel(), recorder: armed)
        all["camera_stopped"] = display(.trackingLost, arm: task(), recorder: armed)
        all["refused"] = display(.refused(.posture), arm: hotel(), recorder: armed)
        all["slow_link"] = display(.slowLink(ms: 450), arm: task(), recorder: armed, latency: 450)
        all["stopped"] = display(.stopped(cause: .button), arm: task(), recorder: off, exits: recordingExits)
        all["stopped_release"] = display(.stopped(cause: .behind), arm: hotel(), recorder: notRecording)
        all["stopped_unknown_server"] = display(.stopped(cause: .onConnect), arm: task(), recorder: .unknown, exits: unknownServerExits)
        all["link_lost"] = display(.linkLost, link: false, arm: task(), recorder: armed)
        all["saved"] = display(.saved(count: 13), arm: task(), recorder: waiting)
        var countdown = display(.ready, arm: task(), recorder: off)
        countdown.resetCountdown = 0.6
        all["rec_off_countdown"] = countdown
        all["outside"] = display(.ready, arm: outside(), recorder: notRecording)
        // Practice.
        all["practice_ready"] = display(.ready, arm: hotel(), recorder: .unknown, practice: true)
        all["practice_stopped"] = display(.stopped(cause: .button), arm: hotel(), recorder: .unknown, practice: true)
        // Buttons mode.
        all["buttons_ready"] = display(.ready, mode: .buttons, arm: task(), recorder: armed)
        var moving = display(.moving(catchingUp: false), mode: .buttons, arm: task(moving: true), recorder: capturing)
        moving.heldButton = .forward
        moving.speed = .fine
        moving.engaged = .translation
        all["buttons_moving"] = moving
        var stopped = display(.stopped(cause: .other), mode: .buttons, arm: hotel(), recorder: .unknown, exits: unknownServerExits)
        stopped.hand = .left
        all["buttons_stopped"] = stopped
        all["buttons_practice"] = display(.ready, mode: .buttons, arm: hotel(), recorder: .unknown, practice: true)
        return all
    }()

    private static func display(
        _ state: OperatingState, mode: ControlMode = .screenTurns, link: Bool = true, arm: ArmReading?,
        recorder: RecorderDisplay, exits: StopExits = noRecorderExits, practice: Bool = false, latency: Int = 60
    ) -> OperatingDisplay {
        OperatingDisplay(
            mode: mode, hand: .right, state: state, layout: nil, engaged: nil, resetCountdown: nil, heldButton: nil,
            speed: .coarse, recorder: recorder, stopExits: practice ? StopExits.offered(recorder: nil, practice: true) : exits,
            linkUp: link || practice, latencyMs: link ? latency : nil, address: "192.168.0.10:8765", arm: arm,
            practice: practice, taskAid: true
        )
    }

    private static let armed = RecorderDisplay(mode: .armed, saved: 12, discarded: 3)
    private static let capturing = RecorderDisplay(mode: .capturing, saved: 12, discarded: 3, secondsCaptured: 12.4)
    private static let waiting = RecorderDisplay(mode: .waiting, saved: 13, discarded: 3)
    private static let off = RecorderDisplay(mode: .off, saved: 12, discarded: 4)
    private static let notRecording = RecorderDisplay(mode: .notRecording)
    private static let recordingExits = StopExits(exits: [.resetScene], recordingMayStayOff: false)
    private static let noRecorderExits = StopExits(exits: [.resetScene, .releaseKeepScene], recordingMayStayOff: false)
    private static let unknownServerExits = StopExits(exits: [.resetScene, .releaseKeepScene], recordingMayStayOff: true)

    // MARK: Arm readings, robot base frame (base +x is the operator's left, base −y is forward)

    private static let profile = RobotProfile.so101Simulator
    private static var centre: SIMD3<Float> { (profile.workspaceMin + profile.workspaceMax) / 2 }
    private static var onTable: Float { profile.tableHeight }
    private static var target: SIMD3<Float> { SIMD3(centre.x + 0.015, centre.y - 0.035, onTable + 0.0125) }
    private static var goal: SIMD3<Float> { SIMD3(centre.x - 0.05, centre.y - 0.035, onTable + 0.0135) }

    /// No task objects: what any arm reports.
    private static func hotel(moving: Bool = false) -> ArmReading {
        let pinch = centre + SIMD3(-0.02, 0.01, -0.005)
        return ArmReading(
            pinchPoint: pinch, commanded: moving ? pinch + SIMD3(-0.025, -0.015, -0.01) : nil, jawOpening: 0.8,
            wristTurnDeg: 90, wristTiltDeg: -3, target: nil, goal: nil, gripping: false
        )
    }

    private static func task(moving: Bool = false) -> ArmReading {
        let pinch = centre + SIMD3(-0.01, 0.02, 0.03)
        return ArmReading(
            pinchPoint: pinch, commanded: moving ? pinch + SIMD3(0.015, -0.03, -0.02) : nil, jawOpening: 0.9,
            wristTurnDeg: 90, wristTiltDeg: 0, target: target, goal: goal, gripping: false
        )
    }

    private static func onTarget() -> ArmReading {
        ArmReading(
            pinchPoint: target + SIMD3(0.002, -0.001, 0.003), commanded: nil, jawOpening: 0.7, wristTurnDeg: 90,
            wristTiltDeg: 0, target: target, goal: goal, gripping: false
        )
    }

    private static func holding(moving: Bool = false) -> ArmReading {
        let pinch = centre + SIMD3(-0.03, -0.02, 0.025)
        return ArmReading(
            pinchPoint: pinch, commanded: moving ? pinch + SIMD3(-0.02, 0, 0) : nil, jawOpening: 0.12,
            wristTurnDeg: 90, wristTiltDeg: 0, target: pinch, goal: goal, gripping: true
        )
    }

    private static func outside() -> ArmReading {
        let pinch = SIMD3(profile.workspaceMin.x - 0.03, centre.y, centre.z)
        return ArmReading(
            pinchPoint: pinch, commanded: nil, jawOpening: nil, wristTurnDeg: nil, wristTiltDeg: nil, target: nil,
            goal: nil, gripping: false
        )
    }
}
