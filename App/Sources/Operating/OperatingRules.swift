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
    /// A STOP pressed here has reached no server yet: pressed before a connection was welcomed, or the link went before
    /// the server confirmed it. Its estop goes out after the next welcome.
    var stopOwed = false
    var stopCause: EmergencyCause?
    /// The simulator behind the server paused (`SimStallDetector`): nothing new is sent and the stop is kept until it
    /// runs again.
    var simulatorPaused = false
    /// The simulator stopped responding: nothing moves and the stop cannot be released until the server is restarted.
    var simulatorStalled = false
    /// ARKit stopped the camera, so the volume keys change the volume and the phone's movement does nothing.
    var cameraStopped = false
    var commandsBlocked = false
    var latencyMs: Int?
    /// The hold the input rules or the pad run now.
    var engaged: HoldKind?
    /// The move nobody holds, when the input rules run one.
    var loose: Engagement?
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
    /// A server's refusal of a start (`moveEnded` false) or ending of a move nobody holds, by what the operator can do
    /// about it. Shown in a refusal's place and time.
    var lastServerRefusal: (refusalClass: ServerRefusalClass, moveEnded: Bool, atMs: Int)?
    /// The newest ending of a follow or a move nobody held that the operator heard and did not cause, with when.
    var lastEnded: (end: DriveEnd, atMs: Int)?
    var lastSaved: (count: Int, atMs: Int)?
    /// When the screen last told the operator to open the jaws before moving in.
    var lastOpenJawsFirstAtMs: Int?
    var nowMs = 0
    /// The per-hold wrist clamps, degrees: the arm's, from its profile.
    var turnLimit: Double
    var tiltLimit: Double

    init(wrist: WristProfile) {
        turnLimit = wrist.rollClampDeg
        tiltLimit = wrist.tiltClampDeg
    }
}

/// The operating screen's one state (§7.2) and the arm reading for the guide, as pure functions of the facts.
/// Practice is not a state: the display's `practice` flag stripes every state.
enum OperatingRules {
    /// How long a refusal and a saved take stay on screen.
    static let refusalShownMs = 1000
    static let savedShownMs = 2000
    /// How long the reminder to open the jaws stays under a moving state.
    static let openJawsFirstShownMs = 4000

    /// The rows of §7.2 that version 1 has, highest first: a simulator that is not responding or paused while the link
    /// is up, which says why the stop stays and what to do, then the stop, the link, the camera, a take just saved, the
    /// engaged hold, a refusal just heard (or why a follow or a move nobody held just ended), the server not ready, a
    /// slow link, ready. A STOP that reached no server is
    /// not shown as stopped: the robot is not (§2.8, J7). Until it goes out the screen shows the link as it does with no
    /// link up, also while Connect replaces a link that is up: never ready, a hold, a wait or a refusal.
    static func state(_ f: OperatingFacts) -> OperatingState {
        if f.simulatorStalled, f.connected { return .simulatorStalled(stopped: f.emergencyStop && !f.stopOwed) }
        if f.simulatorPaused, f.connected { return .simulatorPaused(stopped: f.emergencyStop && !f.stopOwed) }
        if f.emergencyStop, !f.stopOwed { return .stopped(cause: f.stopCause) }
        if !f.connected || f.stopOwed {
            if f.connecting { return .connecting(address: f.address) }
            return f.connectionLost ? .linkLost : .notConnected(reason: nil)
        }
        if f.cameraStopped { return .trackingLost }
        if let saved = f.lastSaved, f.nowMs - saved.atMs < savedShownMs { return .saved(count: saved.count) }
        if let held = f.engaged { return holding(held, f) }
        // Why a follow or a move nobody held ended takes a refusal's place and time; of the two, the newer is shown.
        // A server's refusal is a refusal too: of the three, the newest is shown.
        let refused = f.lastRefusal.flatMap { f.nowMs - $0.atMs < refusalShownMs ? $0 : nil }
        let serverRefused = f.lastServerRefusal.flatMap { f.nowMs - $0.atMs < refusalShownMs ? $0 : nil }
        let ended = f.lastEnded.flatMap { f.nowMs - $0.atMs < refusalShownMs ? $0 : nil }
        let refusedAtMs = max(refused?.atMs ?? Int.min, serverRefused?.atMs ?? Int.min)
        if let ended, ended.atMs > refusedAtMs { return .ended(ended.end) }
        if let serverRefused, serverRefused.atMs > refused?.atMs ?? Int.min {
            return .serverRefused(serverRefused.refusalClass, moveEnded: serverRefused.moveEnded)
        }
        if let refused { return .refused(refused.refusal) }
        if f.serverResetting { return .wait(.resetting) }
        if f.serverSaving { return .wait(.saving) }
        if f.commandsBlocked { return .slowLink(ms: f.latencyMs ?? 0) }
        return .ready
    }

    /// The reminder to open the jaws shows under a translation's state (moving, locked, going) for a while after the
    /// move that raised it started. Every other state keeps its own lines: a stop, a stalled simulator, a lost link or
    /// a refusal is never covered by it.
    static func showsOpenJawsFirst(_ f: OperatingFacts) -> Bool {
        guard let shown = f.lastOpenJawsFirstAtMs, f.nowMs - shown < openJawsFirstShownMs else { return false }
        switch state(f) {
        case .moving, .locked, .going: return true
        default: return false
        }
    }

    /// A follow or a move nobody holds sits where moving sits: under the stop, the link, the camera and a saved take,
    /// above a refusal.
    private static func holding(_ held: HoldKind, _ f: OperatingFacts) -> OperatingState {
        switch held {
        case .translation:
            switch f.loose {
            case .latched?: return .locked(catchingUp: f.catchingUp)
            case .going?: return .going(catchingUp: f.catchingUp)
            default: return .moving(catchingUp: f.catchingUp)
            }
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

    /// The scheme's hints name touches that move the jaws or the wrist. While a follow or a move nobody holds runs,
    /// those touches stop it instead, so the hints are not shown; the state's detail says how it stops.
    static func hidesSchemeHints(_ state: OperatingState) -> Bool {
        switch state {
        case .locked, .going: return true
        default: return false
        }
    }

    /// What the arm and the task look like, robot base frame; nil until the server has reported the arm.
    /// `commanded`: where the link sends the reported arm point during a translation hold. `goTarget`: where a move to
    /// a point is headed, pinch point. `commandOutside`, `lowestGripperZ` and `lowestPinchZ`: the guide's aids, copied
    /// into the reading. Nil, the default for each, is version 1.0.1's reading.
    static func arm(
        _ state: ServerState?, commanded: SIMD3<Float>?, gripping: Bool, profile: RobotProfile,
        goTarget: SIMD3<Float>? = nil, commandOutside: OperatorDirection? = nil, lowestGripperZ: Float? = nil,
        lowestPinchZ: Float? = nil
    ) -> ArmReading? {
        guard let state, let reported = state.endEffector.map(float) else { return nil }
        let pinch = profile.pinchPoint(
            gripper: reported, tool: state.toolPoint.map(float), flexDeg: state.wristFlexDeg,
            rollDeg: state.wristRollDeg
        )
        return ArmReading(
            pinchPoint: pinch.point,
            commanded: commanded.map { $0 + pinch.offset },
            jawOpening: state.gripperDeg.map(profile.gripper.opening(at:)),
            wristTurnDeg: state.wristRollDeg,
            wristTiltDeg: state.wristFlexDeg,
            target: state.object.map { profile.inBase(world: float($0)) },
            goal: state.goal.map { profile.inBase(world: float($0)) },
            gripping: gripping,
            pinchSource: pinch.source,
            boxShift: pinch.offset - profile.toolOffset,
            goTarget: goTarget,
            commandOutside: commandOutside,
            lowestGripperZ: lowestGripperZ,
            lowestPinchZ: lowestPinchZ
        )
    }

    private static func float(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
}
