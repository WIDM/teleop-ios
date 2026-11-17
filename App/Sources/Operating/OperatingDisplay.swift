import TeleopCore

/// Settings → Control → Mode.
enum ControlMode: String, CaseIterable, Sendable { case screenTurns, keyTurns, buttons }

enum WaitReason: Equatable, Sendable { case saving, resetting, notReady }

/// The one thing the operating screen says is happening (specification §7.2, without the voice rows).
enum OperatingState: Equatable, Sendable {
    case notConnected(reason: String?)
    case connecting(address: String)
    case ready
    case moving(catchingUp: Bool)
    /// The arm follows the phone with no key held, until any key or touch stops it.
    case locked(catchingUp: Bool)
    /// The jaws go to a point tapped on the guide, with no key held, until they arrive or any key or touch stops them.
    case going(catchingUp: Bool)
    case turning(degrees: Double, limit: Double, estimated: Bool)
    case tilting(degrees: Double, limit: Double, estimated: Bool)
    case opening
    case closing(gripped: Bool)
    case wait(WaitReason)
    case trackingLost  // the camera stopped: the keys and the phone's movement do nothing
    case refused(Refusal)  // shown for 1 s
    /// A follow or a move nobody held ended for this reason, which the operator did not give. Shown as a refusal is,
    /// for 1 s, in the words spoken.
    case ended(DriveEnd)
    case slowLink(ms: Int)
    case stopped(cause: EmergencyCause?)
    case linkLost
    case saved(count: Int)  // shown for 2 s after a take is saved
}

/// What the arm and the task look like, for the guide. Robot base frame, metres.
struct ArmReading: Equatable, Sendable {
    var pinchPoint: SIMD3<Float>  // where the jaws close
    var commanded: SIMD3<Float>?  // during a move: where the arm is being asked to go
    var jawOpening: Double?  // 0 closed … 1 open
    var wristTurnDeg: Double?
    var wristTiltDeg: Double?
    var target: SIMD3<Float>?  // a task object, when the server reports one
    var goal: SIMD3<Float>?  // where it should go, when the server reports one
    var gripping: Bool
    var pinchSource: PinchSource = .estimated(approximate: false)
    /// How far the workspace box is drawn from the profile's: the reading's gripper-to-pinch offset minus the
    /// profile's `toolOffset`. Zero unless the server reports a tool point.
    var boxShift: SIMD3<Float> = .zero
    /// While a move to a point tapped on the guide runs: where it is headed, pinch point. Nil otherwise.
    var goTarget: SIMD3<Float>? = nil
    /// The guide's aids: the side the commanded point is outside the work area on, the lowest gripper-link height a
    /// downward stall reached, and the lowest pinch-point height one reached when the server reports the pinch point.
    /// Nil with the aids off.
    var commandOutside: OperatorDirection? = nil
    var lowestGripperZ: Float? = nil
    var lowestPinchZ: Float? = nil
}

/// Everything the operating screen draws. The screens read this and nothing else about the link.
struct OperatingDisplay: Equatable, Sendable {
    var mode: ControlMode
    var hand: Hand
    var state: OperatingState
    var layout: SurfaceLayout?  // nil until the screen has reported its size
    var engaged: HoldKind?
    var resetCountdown: Double?  // 0…1 while the top band is held toward a reset
    var heldButton: ButtonID?  // buttons mode
    var speed: ButtonSpeed
    var recorder: RecorderDisplay
    var stopExits: StopExits
    var linkUp: Bool
    var latencyMs: Int?
    var address: String
    var arm: ArmReading?  // nil until the server has reported the arm
    var practice: Bool
    var taskAid: Bool
    /// The guide as numbers, built once per refresh from `arm`: the screen draws this picture and the on-target cue
    /// judges by it, so the two cannot disagree. Nil while there is no arm reading.
    var guide: GuidePicture? = nil
    /// The robot offers hands-free aids and their master switch is off, on the real server: a tap on the guide does
    /// nothing, and the screen says so.
    var aidsOff = false
}
