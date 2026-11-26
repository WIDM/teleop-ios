/// What the operator can do about a server's refusal or ending of a manual arm hold, from the reason in its ack. The
/// one place a reason string becomes words the operator can act on; everything after this carries the class.
public enum ServerRefusalClass: String, CaseIterable, Sendable {
    /// The arm was pushed, turned or twisted off its path, most likely by touching something: open the gripper or lift.
    case contact
    /// A joint is as far as it goes this way: move the other way.
    case jointLimit
    /// The arm cannot get there along this path: back off a little.
    case reach
    /// The server's simulation loop has stopped, perhaps only for seconds. Told by the simulator's own line on screen,
    /// and by its one announcement if it does not come back, never per refusal.
    case simulatorStalled
    /// Any other reason, and any reason the app does not know: told with the general refusal words.
    case other

    public init(reason: String) {
        switch reason {
        case "tool_measured_corridor", "tool_wrist_unsettled", "tool_wrist_changed", "tool_roll_changed",
            "tool_orientation_changed", "tool_joint_step", "tool_gravity_offset_unsettled":
            self = .contact
        case "tool_joint_limit", "tool_actuator_joint_limit":
            self = .jointLimit
        case "tool_no_converged_path", "tool_path_corridor", "tool_origin_workspace":
            self = .reach
        case "sim_stalled":
            self = .simulatorStalled
        default:
            self = .other
        }
    }
}
