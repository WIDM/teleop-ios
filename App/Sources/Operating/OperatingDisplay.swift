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
    case turning(degrees: Double, limit: Double, estimated: Bool)
    case tilting(degrees: Double, limit: Double, estimated: Bool)
    case opening
    case closing(gripped: Bool)
    case wait(WaitReason)
    case trackingLost                 // the camera stopped: the keys and the phone's movement do nothing
    case refused(Refusal)             // shown for 1 s
    case slowLink(ms: Int)
    case stopped(cause: EmergencyCause?)
    case linkLost
    case saved(count: Int)            // shown for 2 s after a take is saved
}

/// What the arm and the task look like, for the guide. Robot base frame, metres.
struct ArmReading: Equatable, Sendable {
    var pinchPoint: SIMD3<Float>      // where the jaws close
    var commanded: SIMD3<Float>?      // during a move: where the arm is being asked to go
    var jawOpening: Double?           // 0 closed … 1 open
    var wristTurnDeg: Double?
    var wristTiltDeg: Double?
    var target: SIMD3<Float>?         // a task object, when the server reports one
    var goal: SIMD3<Float>?           // where it should go, when the server reports one
    var gripping: Bool
}

/// Everything the operating screen draws. The screens read this and nothing else about the link.
struct OperatingDisplay: Equatable, Sendable {
    var mode: ControlMode
    var hand: Hand
    var state: OperatingState
    var layout: SurfaceLayout?        // nil until the screen has reported its size
    var engaged: HoldKind?
    var resetCountdown: Double?       // 0…1 while the top band is held toward a reset
    var heldButton: ButtonID?         // buttons mode
    var speed: ButtonSpeed
    var recorder: RecorderDisplay
    var stopExits: StopExits
    var linkUp: Bool
    var latencyMs: Int?
    var address: String
    var arm: ArmReading?              // nil until the server has reported the arm
    var practice: Bool
    var taskAid: Bool
}
