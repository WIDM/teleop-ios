import Foundation

extension RobotProfile {
    /// Every fault in this profile, one plain sentence each, naming the field by its path in the file. Empty: the
    /// profile can be used. Decoding checks the format; this checks that the values make sense.
    public func validate() -> [String] {
        var faults: [String] = []
        func finite(_ path: String, _ values: [Float]) {
            if !values.allSatisfy(\.isFinite) { faults.append("\(path) must be finite numbers.") }
        }
        func positive(_ path: String, _ value: Double) {
            if !(value.isFinite && value > 0) { faults.append("\(path) must be above zero.") }
        }
        func notNegative(_ path: String, _ value: Double) {
            if !(value.isFinite && value >= 0) { faults.append("\(path) must be zero or more.") }
        }
        func sign(_ path: String, _ value: Double) {
            if value != 1 && value != -1 { faults.append("\(path) must be 1 or -1.") }
        }

        if name.trimmingCharacters(in: .whitespaces).isEmpty { faults.append("name must not be empty.") }

        sign("robot.wrist.roll_sign", rollSign)
        sign("robot.wrist.tilt_sign", tiltSign)
        positive("robot.gripper.open_deg", gripperOpenDeg)
        notNegative("robot.gripper.empty_deg", gripperEmptyDeg)
        if gripperEmptyDeg.isFinite, gripperOpenDeg.isFinite, gripperEmptyDeg >= gripperOpenDeg {
            faults.append("robot.gripper.empty_deg must be below robot.gripper.open_deg.")
        }

        finite("scene.base_in_world_m", [baseInWorld.x, baseInWorld.y, baseInWorld.z])
        finite("scene.table_height_m", [tableHeight])
        finite("scene.workspace_min_m", [workspaceMin.x, workspaceMin.y, workspaceMin.z])
        finite("scene.workspace_max_m", [workspaceMax.x, workspaceMax.y, workspaceMax.z])
        let wrongAxes = [("x", 0), ("y", 1), ("z", 2)].filter { !(workspaceMin[$0.1] < workspaceMax[$0.1]) }.map(\.0)
        if !wrongAxes.isEmpty {
            faults.append(
                "scene.workspace_min_m must be below scene.workspace_max_m on every axis; it is not on "
                    + "\(wrongAxes.joined(separator: ", ")).")
        }
        positive("scene.target_size_m", Double(targetSize))
        positive("scene.goal_size_m", Double(goalSize))
        positive("scene.grasp_tolerance_m across", Double(graspTolerance.x))
        positive("scene.grasp_tolerance_m height", Double(graspTolerance.y))
        if let window = onTargetWindow {
            positive("scene.on_target_window_m across", Double(window.x))
            positive("scene.on_target_window_m height", Double(window.y))
        }
        finite("scene.tool_offset.offset_m", [toolOffset.x, toolOffset.y, toolOffset.z])
        finite("scene.tool_offset.measured_at_m", [offsetMeasuredAt.x, offsetMeasuredAt.y, offsetMeasuredAt.z])
        finite(
            "scene.tool_offset.measured_flex_deg and measured_roll_deg",
            [Float(offsetMeasuredFlexDeg), Float(offsetMeasuredRollDeg)])
        let bound = estimateBound
        let rates = [
            ("x_mm_per_cm", bound.xMmPerCm), ("plus_y_mm_per_cm", bound.plusYMmPerCm),
            ("minus_y_mm_per_cm", bound.minusYMmPerCm), ("z_mm_per_cm", bound.zMmPerCm),
            ("flex_mm_per_deg", bound.flexMmPerDeg), ("roll_mm_per_deg", bound.rollMmPerDeg),
        ]
        for (key, rate) in rates { notNegative("scene.tool_offset.error_bound.\(key)", Double(rate)) }

        if let lock = assist.lock { positive("assist.lock.time_limit_s", lock.timeLimitS) }
        if let goTo = assist.goTo {
            positive("assist.go_to.travel_height_m", goTo.travelHeightM)
            positive("assist.go_to.speed_mps", goTo.speedMps)
            positive("assist.go_to.arrive_tolerance_m", goTo.arriveToleranceM)
            positive("assist.go_to.settle_s", goTo.settleS)
            positive("assist.go_to.time_factor", goTo.timeFactor)
            positive("assist.go_to.arm_data_timeout_s", goTo.armDataTimeoutS)
            notNegative("assist.go_to.correction_reach_m", goTo.correctionReachM)
            notNegative("assist.go_to.allowance_s", goTo.allowanceS)
            notNegative("assist.go_to.start_grace_s", goTo.startGraceS)
            if goTo.corrections < 0 { faults.append("assist.go_to.corrections must be zero or more.") }
        }
        if let views = assist.views {
            positive("assist.views.behind_top_above_table_m", views.behindTopAboveTableM)
            if let move = views.maxRetargetedMoveS { positive("assist.views.max_retargeted_move_s", move) }
            if let goTo = assist.goTo, views.behindTopAboveTableM < goTo.travelHeightM {
                faults.append(
                    "assist.views.behind_top_above_table_m must not be below assist.go_to.travel_height_m.")
            }
            if assist.goTo == nil { faults.append("assist.views needs assist.go_to; without it the views are unused.") }
        }
        if assist.explain != nil && assist.guide == nil {
            faults.append("assist.explain is set, so assist.guide must be set too.")
        }
        return faults
    }
}
