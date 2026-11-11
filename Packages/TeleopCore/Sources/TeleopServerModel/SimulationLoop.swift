import Foundation

/// The server's simulation loop: one pass per physics step, each doing exactly one of the things below, in
/// this order of priority: a scene reset in progress, the E-stop freeze, the success display, the success check,
/// taking the next command, the watchdog, or one step of the running command.
extension ServerModel {
    func loopPass() {
        if reset != nil {
            continueReset()
            return
        }
        publishMeasured()
        if estop {
            recorder?.discard()
            let interrupted = active
            active = nil
            stepWorld()
            update(["ee_pos": .numbers(world.arm), "estop": .bool(true), "ik": "stopped"])
            estopFrozen = true
            if let interrupted { finish(interrupted, "rejected", "estop") }
            return
        }
        if successDisplayLeft > 0 {
            stepWorld()
            successDisplayLeft -= 1
            if successDisplayLeft == 0 { beginReset(command: nil) }
            return
        }
        if checkSuccess() { return }
        if active == nil, world.cube.z < config.fallenCubeHeightWorld {
            beginReset(command: nil)
            return
        }
        if active == nil {
            guard let request = pending, !request.taken, !request.finished else {
                stepWorld()
                return
            }
            request.taken = true
            guard time <= request.deadline else {
                finish(request, "rejected", "expired_before_execution")
                return
            }
            active = request
            if request.kind == "reset_scene" {
                beginReset(command: request)
                return
            }
            take(request)
        }
        guard let command = active else { return }
        guard time <= command.deadline else {
            watchdog(command)
            return
        }
        switch command.kind {
        case "pose_start": poseStep(command)
        case "orient_start": orientStep(command)
        case "joint_jog_start": jointJogStep(command)
        case "joint_delta": jointDeltaStep(command)
        case "gripper_jog_start": gripperJogStep(command)
        case "gripper": gripperStep(command)
        case "jog_start": jogStep(command)
        default: moveStep(command)
        }
    }

    /// The fields the loop refreshes at the top of every pass.
    func publishMeasured() {
        update([
            "ee_pos": .numbers(world.arm), "object_pos": .numbers(world.cube), "goal_pos": .numbers(config.goalWorld),
            "wrist_flex_deg": .double(rounded(world.wristFlex)), "wrist_roll_deg": .double(rounded(world.wristRoll)),
            "gripper_deg": .double(rounded(world.jaw)),
            "rec": .string(recorder?.label ?? "none"), "rec_saved": .int(recorder?.saved ?? 0),
            "rec_discarded": .int(recorder?.discarded ?? 0), "rec_samples": .int(recorder?.samples ?? 0),
        ])
    }

    /// One physics step. The recorder samples before it.
    private func stepWorld() {
        recorder?.beforeStep(commandRunning: active.map { Command.recordedKinds.contains($0.kind) } ?? false)
        world.settle(config)
    }

    // MARK: Task

    /// The cube resting in the goal with the gripper reported open, for enough passes in a row, latches success.
    private func checkSuccess() -> Bool {
        guard !successLatched else { return false }
        let sample = world.cubeInGoal(config) && world.cubeSpeed <= config.successMaxSpeed
            && state["gripper"]?.stringValue == "open"
        successRun = sample ? successRun + 1 : 0
        guard successRun >= config.successSteps else { return false }
        successLatched = true
        successDisplayLeft = config.successDisplaySteps
        ready = false
        update(["task_success": .bool(true), "ik": "task_success"])
        // A hold still pressed at the moment of success ends now, so it cannot outlive the display.
        if let running = active {
            finish(running, "ok", "task_success")
            active = nil
            stopRequested = []
        }
        recorder?.success()
        return true
    }

    private func beginReset(command: Command?) {
        ready = false
        recorder?.discard()
        world = World(config)
        successRun = 0
        successLatched = false
        successDisplayLeft = 0
        reset = Reset(stepsLeft: config.resetSteps, command: command)
        continueReset()
    }

    private func continueReset() {
        guard var current = reset else { return }
        world.settle(config)
        current.stepsLeft -= 1
        reset = current
        guard current.stepsLeft <= 0 else { return }
        reset = nil
        episode += 1
        update([
            "ee_pos": .numbers(world.arm), "gripper": "closed", "ik": "ok", "object_pos": .numbers(world.cube),
            "goal_pos": .numbers(config.goalWorld), "task_success": .bool(false), "episode": .int(episode),
        ])
        recorder?.arm()
        ready = true
        if let command = current.command {
            finish(command, "ok", "scene_reset")
            active = nil
        }
    }

    // MARK: Commands

    /// What the loop does when it takes a command off the queue.
    private func take(_ command: Command) {
        let carrying = state["gripper"]?.stringValue == "close"
        let step = command.step
        switch command.kind {
        case "jog_start":
            world.command = world.arm
            command.speed = (carrying ? config.jogCarrySpeed : config.jogSpeed)[step] ?? 0
            update(["step": .string(step), "ik": "jogging"])
        case "move_delta":
            let length = command.direction * (config.moveStepLength[step] ?? 0)
            var requested = world.arm
            requested[command.axis] += length
            command.startPoint = world.arm
            command.goalPoint = clampToWorkspace(requested)
            command.completion = allClose(command.goalPoint, requested) ? "ok" : "clamped"
            let share = (config.moveStepLength[step] ?? 0) / (config.moveStepLength["coarse"] ?? 1)
            command.rampSteps = Int((Double(config.coarseMoveSteps) * share).rounded(.up))
            command.tolerance = config.moveTolerance[step] ?? 0
            update(["step": .string(step), "ik": "moving"])
        case "joint_jog_start":
            command.speed = (carrying ? config.jointJogCarryRate : config.jointJogRate)[step] ?? 0
            update(["step": .string(step), "ik": "joint_jogging"])
        case "joint_delta":
            command.startAngle = angle(of: command.joint)
            let requested = command.startAngle + command.direction * (config.jointStep[step] ?? 0)
            command.goalAngle = clamp(requested, limits(of: command.joint))
            command.completion = abs(command.goalAngle - requested) <= 1e-5 ? "ok" : "clamped"
            command.rampSteps = config.jointMoveSteps[step] ?? 1
            update(["ik": "joint_moving"])
        case "orient_start":
            command.startFlex = world.wristFlex
            command.startRoll = world.wristRoll
            update(["ik": "orienting", "orient_deg": .double(0)])
        case "pose_start":
            command.startPoint = world.arm
            world.command = world.arm
            command.startFlex = world.wristFlex
            command.startAngle = world.jawTarget
            command.speed = carrying ? config.poseCarrySpeed : config.poseSpeed
            update(["ik": "pose_tracking", "orient_deg": .double(0), "gripper_delta": .double(0)])
        case "gripper_jog_start":
            command.speed = (command.action == "close" ? config.gripperJogCloseRate : config.gripperJogOpenRate)[step] ?? 0
            // The jog starts from the measured jaw angle.
            world.jawTarget = world.jaw
            update(["gripper": .string(command.action), "step": .string(step), "ik": "gripper_jogging"])
        case "gripper":
            command.startAngle = world.jaw
            let requested = command.action == "open" ? 100.0 : 0.0
            command.goalAngle = clamp(requested, config.jawLimits)
            command.completion = command.goalAngle == requested ? "ok" : "clamped"
        default:
            break
        }
    }

    private func watchdog(_ command: Command) {
        if Command.holdKinds.contains(command.kind) {
            // A missed keepalive releases the hold; it is not an E-stop, and the targets stay where they are.
            update(["ik": "stopped"])
            finish(command, "rejected", String(command.kind.dropLast("_start".count)) + "_watchdog_timeout")
        } else {
            update(["ik": "no_solution"])
            finish(command, "rejected", "execution_timeout")
            engageEstop()
        }
        active = nil
    }

    /// True, after ending the hold, when its stop has been asked for.
    private func stopIfAsked(_ command: Command) -> Bool {
        guard stopRequested.contains(command.kind) else { return false }
        stopRequested.remove(command.kind)
        return true
    }

    private func end(_ command: Command, _ status: String, _ reason: String) {
        finish(command, status, reason)
        active = nil
    }

    private func poseStep(_ command: Command) {
        if stopIfAsked(command) {
            update([
                "ik": command.wasClamped ? "pose_clamped" : "ok", "ee_pos": .numbers(world.arm),
                "orient_deg": .double(degrees(length(rotationVector(command.usedQ)))),
                "gripper_delta": .double(command.usedGripperDelta),
            ])
            end(command, "ok", "pose_stopped")
            return
        }
        command.usedQ = command.qRel
        command.usedGripperDelta = command.gripperDelta
        if command.payload["control_mode"]?.stringValue == "wrist" {
            poseWristStep(command)
            return
        }
        // Phone x, y, z to robot base x, y, −z (the server's calibrated mapping), relative to where the arm was.
        let requested = command.startPoint + SIMD3(command.pRel.x, command.pRel.y, -command.pRel.z)
        let target = clampToWorkspace(requested)
        let clampedNow = !allClose(target, requested)
        command.wasClamped = command.wasClamped || clampedNow
        world.command += limited(target - world.command, to: command.speed * config.simStep)

        let wanted = clamp(command.startAngle + command.gripperDelta * config.poseJawRange, config.jawLimits)
        let rate = wanted >= world.jawTarget ? config.poseJawOpenRate : config.poseJawCloseRate
        world.jawTarget += clamp(wanted - world.jawTarget, -rate * config.simStep...rate * config.simStep)

        world.moveArm(toward: world.command, maxStep: config.armStepInPose, config)
        stepWorld()
        if length(world.command - world.arm) > config.trackingSafetyDistance {
            update(["ik": "no_solution"])
            end(command, "rejected", "pose_tracking_safety_stop")
            engageEstop()
            return
        }
        command.motionStep += 1
        let label: JSONValue = command.gripperDelta > 0.02 ? "open"
            : command.gripperDelta < -0.02 ? "close" : (state["gripper"] ?? "closed")
        update([
            "ee_pos": .numbers(world.arm), "gripper": label, "ik": clampedNow ? "pose_clamped" : "pose_tracking",
            "orient_deg": .double(degrees(length(rotationVector(command.qRel)))),
            "gripper_delta": .double(command.gripperDelta),
        ])
    }

    /// A pose hold in wrist mode: phone pitch tilts the wrist, everything else is held.
    private func poseWristStep(_ command: Command) {
        let pitch = degrees(rotationVector(command.qRel).x)
        let relative = clamp(pitch, -config.orientFlexClamp...config.orientFlexClamp)
        let desired = clamp(command.startFlex + relative, config.wristFlexLimits)
        world.wristFlex += clamp(desired - world.wristFlex, -config.wristStepPerStep...config.wristStepPerStep)
        let clampedNow = relative != pitch || desired != command.startFlex + relative
        command.usedGripperDelta = 0
        command.wasClamped = command.wasClamped || clampedNow
        stepWorld()
        command.motionStep += 1
        update([
            "ik": clampedNow ? "orient_clamped" : "orienting", "ee_pos": .numbers(world.arm),
            "orient_deg": .double(pitch), "gripper_delta": .double(0),
        ])
    }

    private func orientStep(_ command: Command) {
        if stopIfAsked(command) {
            update([
                "ik": command.wasClamped ? "orient_clamped" : "ok",
                "orient_deg": .double(degrees(length(rotationVector(command.usedQ)))),
            ])
            end(command, "ok", "orient_stopped")
            return
        }
        command.usedQ = command.qRel
        let turn = rotationVector(command.qRel)
        let flex = command.startFlex + clamp(degrees(turn.x), -config.orientFlexClamp...config.orientFlexClamp)
        let roll = command.startRoll + clamp(-degrees(turn.y), -config.orientRollClamp...config.orientRollClamp)
        let desiredFlex = clamp(flex, config.wristFlexLimits)
        let desiredRoll = clamp(roll, config.wristRollLimits)
        let clampedNow = desiredFlex != flex || desiredRoll != roll
        command.wasClamped = command.wasClamped || clampedNow
        let step = config.wristStepPerStep
        world.wristFlex += clamp(desiredFlex - world.wristFlex, -step...step)
        world.wristRoll += clamp(desiredRoll - world.wristRoll, -step...step)
        stepWorld()
        command.motionStep += 1
        update([
            "ik": clampedNow ? "orient_clamped" : "orienting",
            "orient_deg": .double(degrees(length(turn))),
        ])
    }

    private func jointJogStep(_ command: Command) {
        if stopIfAsked(command) {
            update(["ik": "ok"])
            end(command, "ok", "joint_jog_stopped")
            return
        }
        let joint = command.joint
        setAngle(of: joint, clamp(angle(of: joint) + command.direction * command.speed * config.simStep, limits(of: joint)))
        stepWorld()
        command.motionStep += 1
    }

    private func jointDeltaStep(_ command: Command) {
        let share = min(Double(command.motionStep + 1) / Double(command.rampSteps), 1)
        setAngle(of: command.joint, command.startAngle + share * (command.goalAngle - command.startAngle))
        stepWorld()
        let error = abs(command.goalAngle - angle(of: command.joint))
        command.motionStep += 1
        let settled = command.motionStep >= command.rampSteps && error <= config.jointTolerance
        command.stableCount = settled ? command.stableCount + 1 : 0
        guard command.stableCount >= config.stableSteps || command.motionStep >= command.rampSteps + config.settleSteps else {
            return
        }
        if command.stableCount >= config.stableSteps {
            update(["ik": "ok"])
            end(command, command.completion, "completed")
        } else {
            update(["ik": "no_solution"])
            end(command, "rejected", "joint_tolerance_not_met")
            engageEstop()
        }
    }

    private func gripperJogStep(_ command: Command) {
        if stopIfAsked(command) {
            update(["gripper": .string(command.action), "ik": "ok"])
            end(command, "ok", "gripper_jog_stopped")
            return
        }
        let closing = command.action == "close"
        if !command.stalled {
            world.jawTarget = clamp(world.jawTarget + (closing ? -1 : 1) * command.speed * config.simStep, config.jawLimits)
        }
        stepWorld()
        let lag = max(world.jaw - world.jawTarget, 0)
        command.motionStep += 1
        command.contactCount = closing && lag >= config.gripperJogContactLag ? command.contactCount + 1 : 0
        if !command.stalled, command.contactCount >= config.gripperJogContactSteps {
            // Contact: stop squeezing harder, keep a small preload. The hold itself goes on.
            world.jawTarget = clamp(world.jaw - config.gripperPreload, config.jawLimits)
            command.stalled = true
            update(["gripper": "close", "ik": "gripper_contact"])
        }
    }

    private func gripperStep(_ command: Command) {
        let share = min(Double(command.motionStep + 1) / Double(config.gripperMoveSteps), 1)
        let target = command.startAngle + share * (command.goalAngle - command.startAngle)
        world.jawTarget = target
        stepWorld()
        let closing = command.action == "close"
        let lag = max(world.jaw - target, 0)
        let reached = closing ? world.jaw <= config.gripperClosedBelow
            : abs(command.goalAngle - world.jaw) <= config.gripperOpenTolerance
        command.motionStep += 1
        command.contactCount = closing && lag >= config.gripperContactLag ? command.contactCount + 1 : 0
        if command.contactCount >= config.gripperContactSteps {
            world.jawTarget = clamp(world.jaw - config.gripperPreload, config.jawLimits)
            update(["gripper": "close", "ik": "ok"])
            end(command, "ok", "contact_stopped")
            return
        }
        command.stableCount = command.motionStep >= config.gripperMoveSteps && reached ? command.stableCount + 1 : 0
        guard command.stableCount >= config.gripperStableSteps
            || command.motionStep >= config.gripperMoveSteps + config.settleSteps else { return }
        if command.stableCount >= config.gripperStableSteps {
            update(["gripper": .string(command.action), "ik": "ok"])
            end(command, command.completion, "completed")
        } else {
            end(command, "rejected", "gripper_tolerance_not_met")
            engageEstop()
        }
    }

    /// A Cartesian jog. The `tool` frame is treated as `base`: the model has no tool orientation.
    private func jogStep(_ command: Command) {
        if stopIfAsked(command) {
            update(["ik": "ok", "ee_pos": .numbers(world.arm)])
            end(command, "ok", "jog_stopped")
            return
        }
        var requested = world.command
        requested[command.axis] += command.direction * command.speed * config.simStep
        let commanded = clampToWorkspace(requested)
        if allClose(commanded, world.command) {
            // The commanded point stopped moving: it is at the edge of the workspace.
            stopRequested.remove(command.kind)
            update(["ik": "ok", "ee_pos": .numbers(world.arm)])
            end(command, "clamped", "workspace_limit")
            return
        }
        world.command = commanded
        cartesianStep(command, safetyReason: "tracking_safety_stop")
    }

    /// A fixed-distance `move_delta`. The `tool` frame is treated as `base`.
    private func moveStep(_ command: Command) {
        let share = min(Double(command.motionStep + 1) / Double(command.rampSteps), 1)
        world.command = command.startPoint + share * (command.goalPoint - command.startPoint)
        guard cartesianStep(command, safetyReason: "tracking_safety_stop") else { return }
        let error = length(command.goalPoint - world.arm)
        let settled = command.motionStep >= command.rampSteps && error <= command.tolerance
        command.stableCount = settled ? command.stableCount + 1 : 0
        guard command.stableCount >= config.stableSteps || command.motionStep >= command.rampSteps + config.settleSteps else {
            return
        }
        if command.stableCount >= config.stableSteps {
            update(["ik": "ok", "ee_pos": .numbers(world.arm)])
            end(command, command.completion, "completed")
        } else {
            update(["ik": "no_solution", "ee_pos": .numbers(world.arm)])
            end(command, "rejected", "position_tolerance_not_met")
            engageEstop()
        }
    }

    /// Moves the arm one step toward the commanded point; false when that tripped the safety stop.
    @discardableResult
    private func cartesianStep(_ command: Command, safetyReason: String) -> Bool {
        world.moveArm(toward: world.command, maxStep: config.armStepInJog, config)
        stepWorld()
        update(["ee_pos": .numbers(world.arm)])
        if length(world.command - world.arm) > config.trackingSafetyDistance {
            update(["ik": "no_solution"])
            end(command, "rejected", safetyReason)
            engageEstop()
            return false
        }
        command.motionStep += 1
        return true
    }

    // MARK: Helpers

    private func clampToWorkspace(_ point: SIMD3<Double>) -> SIMD3<Double> {
        let half = SIMD3(repeating: config.workspaceHalfSize)
        return boxClamp(point, config.armStart - half, config.armStart + half)
    }

    private func angle(of joint: String) -> Double {
        switch joint {
        case "wrist_flex": return world.wristFlex
        case "wrist_roll": return world.wristRoll
        default: return world.armJoints[joint] ?? 0
        }
    }

    private func setAngle(of joint: String, _ value: Double) {
        switch joint {
        case "wrist_flex": world.wristFlex = value
        case "wrist_roll": world.wristRoll = value
        default: world.armJoints[joint] = value
        }
    }

    private func limits(of joint: String) -> ClosedRange<Double> {
        switch joint {
        case "wrist_flex": return config.wristFlexLimits
        case "wrist_roll": return config.wristRollLimits
        default: return config.armJointLimits[joint] ?? -180...180
        }
    }
}

/// The server compares positions with `torch.allclose`: within 1e-7 plus 1e-5 of the second value.
func allClose(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
    (0..<3).allSatisfy { abs(a[$0] - b[$0]) <= 1e-7 + 1e-5 * abs(b[$0]) }
}

func boxClamp(_ value: SIMD3<Double>, _ lower: SIMD3<Double>, _ upper: SIMD3<Double>) -> SIMD3<Double> {
    value.replacing(with: lower, where: value .< lower).replacing(with: upper, where: value .> upper)
}

func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

/// Two decimals, as the server rounds measured angles.
func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
