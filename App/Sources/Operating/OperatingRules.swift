import simd
import TeleopCore

/// What the operating screen's state is judged from, gathered from the session, the link and the input rules.
struct OperatingFacts {
    var connected = false
    /// The real server's socket is open and has not said welcome yet.
    var connecting = false
    /// A working link dropped and none is up since.
    var connectionLost = false
    var address = ""
    var emergencyStop = false
    /// STOP was pressed with no connection up: no estop has reached a server yet (it goes out after the next welcome).
    var stopOwed = false
    var stopCause: EmergencyCause?
    /// ARKit stopped the camera, so the volume keys change the volume and the phone's movement does nothing.
    var cameraStopped = false
    var commandsBlocked = false
    var latencyMs: Int?
    /// The hold the input rules or the pad run now.
    var engaged: HoldKind?
    /// The engaged wrist hold's target: its axis once committed, and the degrees asked for in this hold.
    var wristTarget = WristTarget.identity
    /// The server reports wrist angles; without them the angle shown is the one asked for, an estimate.
    var wristMeasured = false
    /// The engaged translation hold is held back while the arm catches up.
    var catchingUp = false
    var gripping = false
    /// The server shows a success and saves the take, or resets the scene.
    var serverSaving = false
    var serverResetting = false
    /// The newest refusal the operator heard and the newest saved take, with when (ms on the model's clock).
    var lastRefusal: (refusal: Refusal, atMs: Int)?
    var lastSaved: (count: Int, atMs: Int)?
    var nowMs = 0
    /// The per-hold wrist clamps, degrees.
    var turnLimit = 55.0
    var tiltLimit = 20.0
}

/// The operating screen's one state (§7.2) and the arm reading for the guide, as pure functions of the facts.
/// Practice is not a state: the display's `practice` flag stripes every state.
enum OperatingRules {
    /// How long a refusal and a saved take stay on screen.
    static let refusalShownMs = 1000
    static let savedShownMs = 2000

    /// The rows of §7.2 that version 1 has, highest first: the stop, the link, the camera, a take just saved, the
    /// engaged hold, a refusal just heard, the server not ready, a slow link, ready. A STOP that reached no server is
    /// not shown as stopped: the robot is not (§2.8, J7).
    static func state(_ f: OperatingFacts) -> OperatingState {
        if f.emergencyStop, !f.stopOwed { return .stopped(cause: f.stopCause) }
        if !f.connected {
            if f.connecting { return .connecting(address: f.address) }
            return f.connectionLost ? .linkLost : .notConnected(reason: nil)
        }
        if f.cameraStopped { return .trackingLost }
        if let saved = f.lastSaved, f.nowMs - saved.atMs < savedShownMs { return .saved(count: saved.count) }
        if let held = f.engaged { return holding(held, f) }
        if let refused = f.lastRefusal, f.nowMs - refused.atMs < refusalShownMs { return .refused(refused.refusal) }
        if f.serverResetting { return .wait(.resetting) }
        if f.serverSaving { return .wait(.saving) }
        if f.commandsBlocked { return .slowLink(ms: f.latencyMs ?? 0) }
        return .ready
    }

    private static func holding(_ held: HoldKind, _ f: OperatingFacts) -> OperatingState {
        switch held {
        case .translation:
            return .moving(catchingUp: f.catchingUp)
        case .gripper(.open):
            return .opening
        case .gripper(.closed):
            return .closing(gripped: f.gripping)
        case .wrist:
            let degrees = abs(f.wristTarget.degrees)
            if f.wristTarget.axis == .tilt {
                return .tilting(degrees: degrees, limit: f.tiltLimit, estimated: !f.wristMeasured)
            }
            return .turning(degrees: degrees, limit: f.turnLimit, estimated: !f.wristMeasured)
        }
    }

    /// What the arm and the task look like, robot base frame; nil until the server has reported the arm.
    /// `commanded`: where the link sends the reported arm point during a translation hold.
    static func arm(
        _ state: ServerState?, commanded: SIMD3<Float>?, gripping: Bool, profile: RobotProfile
    ) -> ArmReading? {
        guard let state, let reported = state.endEffector.map(float) else { return nil }
        let pinch = profile.pinchPoint(
            gripper: reported, tool: state.toolPoint.map(float), flexDeg: state.wristFlexDeg,
            rollDeg: state.wristRollDeg
        )
        return ArmReading(
            pinchPoint: pinch.point,
            commanded: commanded.map { $0 + pinch.offset },
            jawOpening: state.gripperDeg.map { min(max($0 / profile.gripperOpenDeg, 0), 1) },
            wristTurnDeg: state.wristRollDeg,
            wristTiltDeg: state.wristFlexDeg,
            target: state.object.map { profile.inBase(world: float($0)) },
            goal: state.goal.map { profile.inBase(world: float($0)) },
            gripping: gripping,
            pinchSource: pinch.source,
            boxShift: pinch.offset - profile.toolOffset
        )
    }

    private static func float(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
}
