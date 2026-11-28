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
        func share(_ path: String, _ value: Double) {
            if !(value.isFinite && value > 0 && value <= 1) { faults.append("\(path) must be above 0 and at most 1.") }
        }
        func sign(_ path: String, _ value: Double) {
            if value != 1 && value != -1 { faults.append("\(path) must be 1 or -1.") }
        }

        if name.trimmingCharacters(in: .whitespaces).isEmpty { faults.append("name must not be empty.") }

        faults += frames.faults()

        sign("robot.wrist.roll_sign", wrist.rollSign)
        sign("robot.wrist.tilt_sign", wrist.tiltSign)
        positive("robot.wrist.roll_window_deg", wrist.rollWindowDeg)
        positive("robot.wrist.tilt_window_deg", wrist.tiltWindowDeg)
        positive("robot.wrist.roll_clamp_deg", wrist.rollClampDeg)
        positive("robot.wrist.tilt_clamp_deg", wrist.tiltClampDeg)
        if wrist.rollClampDeg > wrist.rollWindowDeg {
            faults.append("robot.wrist.roll_clamp_deg must not be above robot.wrist.roll_window_deg.")
        }
        if wrist.tiltClampDeg > wrist.tiltWindowDeg {
            faults.append("robot.wrist.tilt_clamp_deg must not be above robot.wrist.tilt_window_deg.")
        }
        if case .fixed(let centre) = wrist.tiltCentre, !centre.isFinite {
            faults.append("robot.wrist.tilt_centre_deg must be a finite number, or null.")
        }
        positive("robot.wrist.turn_rate_deg_s", wrist.turnRateDegS)
        positive("robot.wrist.tilt_rate_deg_s", wrist.tiltRateDegS)
        notNegative("robot.wrist.lead.lead_deg", wrist.lead.leadDeg)
        notNegative("robot.wrist.lead.rate_max_deg_s", wrist.lead.rateMaxDegS)
        notNegative("robot.wrist.lead.memory_deg", wrist.lead.memoryDeg)
        if wrist.lead.freshStateMs <= 0 { faults.append("robot.wrist.lead.fresh_state_ms must be above zero.") }
        positive("robot.motion.fine_mps", motion.fineMps)
        positive("robot.motion.coarse_mps", motion.coarseMps)
        positive("robot.motion.max_lead_m", Double(motion.maxLeadM))
        positive("robot.motion.tool_max_lead_m", Double(motion.toolMaxLeadM))
        positive("server.stop_distance_m", server.stopDistanceM)
        if server.stopDistanceM.isFinite {
            for (path, cap) in [("max_lead_m", motion.maxLeadM), ("tool_max_lead_m", motion.toolMaxLeadM)]
            where cap.isFinite && cap > 0 && Double(cap) >= server.stopDistanceM {
                faults.append("robot.motion.\(path) must be under server.stop_distance_m.")
            }
        }
        for (path, ms) in [
            ("after_ms", server.resync.afterMs), ("tool_after_ms", server.resync.toolAfterMs),
            ("timeout_ms", server.resync.timeoutMs),
        ] where ms <= 0 {
            faults.append("server.resync.\(path) must be above zero.")
        }
        let jaw = gripper
        if !(jaw.closedReading.isFinite && jaw.openReading.isFinite && jaw.closedReading != jaw.openReading) {
            faults.append("robot.gripper.closed_reading and robot.gripper.open_reading must be different numbers.")
        } else if jaw.closedReading > jaw.openReading {
            faults.append(
                "robot.gripper.closed_reading must be below robot.gripper.open_reading; a jaw whose reading falls "
                    + "as it opens is not supported.")
        }
        let validEnds = jaw.validMin.isFinite && jaw.validMax.isFinite && jaw.validMin < jaw.validMax
        if !validEnds { faults.append("robot.gripper.valid_min must be below robot.gripper.valid_max.") }
        if validEnds {
            for (path, reading) in [("closed_reading", jaw.closedReading), ("open_reading", jaw.openReading)]
            where !(reading >= jaw.validMin && reading <= jaw.validMax) {
                faults.append(
                    "robot.gripper.\(path) must be inside the valid readings, robot.gripper.valid_min to valid_max.")
            }
        }
        for (path, threshold) in [("empty_at", jaw.emptyAt), ("fully_open_at", jaw.fullyOpenAt)]
        where !threshold.isFinite {
            faults.append("robot.gripper.\(path) must be a finite number.")
        }
        if !(jaw.emptyAt >= jaw.closedReading) {
            faults.append("robot.gripper.empty_at must be at or above robot.gripper.closed_reading.")
        }
        if !(jaw.fullyOpenAt <= jaw.openReading) {
            faults.append("robot.gripper.fully_open_at must be at or below robot.gripper.open_reading.")
        }
        if jaw.emptyAt.isFinite, jaw.fullyOpenAt.isFinite, jaw.emptyAt >= jaw.fullyOpenAt {
            faults.append("robot.gripper.empty_at must be below robot.gripper.fully_open_at.")
        }

        positive("response.blocked.short_m", blocked.shortM)
        positive("response.blocked.moved_m", blocked.movedM)
        positive("response.blocked.window_ms", Double(blocked.windowMs))
        positive("response.blocked.fresh_ms", Double(blocked.freshMs))
        positive("response.blocked.arrival_gap_ms", Double(blocked.arrivalGapMs))
        share("response.blocked.lead_progress_share", blocked.leadProgressShare)
        positive("response.blocked.exclusion_m", blocked.exclusionM)
        share("response.blocked.following_share", blocked.followingShare)
        if !(blocked.sameWayDeg.isFinite && blocked.sameWayDeg > 0 && blocked.sameWayDeg < 90) {
            faults.append("response.blocked.same_way_deg must be above 0 and below 90.")
        }
        positive("response.lowest.sustain_m", lowest.sustainM)
        positive("response.lowest.quick_short_m", lowest.quickShortM)
        positive("response.lowest.quick_moved_m", lowest.quickMovedM)
        positive("response.lowest.quick_ms", Double(lowest.quickMs))
        positive("response.lowest.descent_mps", lowest.descentMps)

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
            if window.x < graspTolerance.x || window.y < graspTolerance.y {
                faults.append(
                    "scene.on_target_window_m must not be narrower than scene.grasp_tolerance_m on either axis.")
            }
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
            let pacing = goTo.pacing
            share("assist.go_to.pacing.follow_share", pacing.followShare)
            positive("assist.go_to.pacing.pace_gain", pacing.paceGain)
            share("assist.go_to.pacing.slowest_share", pacing.slowestShare)
            share("assist.go_to.pacing.start_share", pacing.startShare)
            positive("assist.go_to.pacing.path_watch_tolerances", pacing.pathWatchTolerances)
            positive("assist.go_to.pacing.fresh_ms", Double(pacing.freshMs))
            positive("assist.go_to.pacing.still_m", pacing.stillM)
            if !(pacing.paceChangeShare.isFinite && pacing.paceChangeShare >= 0 && pacing.paceChangeShare <= 1) {
                faults.append("assist.go_to.pacing.pace_change_share must be between 0 and 1.")
            }
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
