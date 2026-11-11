import TeleopCore

enum VolumeKey { case up, down }
enum VolumeKeyPhase { case began, ended, cancelled }

/// Hold vol+ to move the arm, hold vol− to close the gripper (opening is on screen). One press gives one start,
/// so a key that repeats while held cannot restart something that was stopped meanwhile.
/// iOS reports Camera Control and the Action button as vol−; they cannot be told apart.
/// Releasing vol− ends the gripper only while it is still closing: the Open handle may have taken over, and its
/// own release ends that.
struct VolumeKeyMapper {
    private(set) var upHeld = false
    private(set) var downHeld = false

    mutating func actions(for key: VolumeKey, phase: VolumeKeyPhase, in state: FakeTeleopState) -> [TeleopAction] {
        switch (key, phase) {
        case (.up, .began):
            guard !upHeld else { return [] }
            upHeld = true
            return [.holdArmStart]
        case (.up, .ended), (.up, .cancelled):
            upHeld = false
            return [.holdArmEnd]
        case (.down, .began):
            guard !downHeld else { return [] }
            downHeld = true
            return [.gripperStart(.closed)]
        case (.down, .ended), (.down, .cancelled):
            downHeld = false
            guard state.isHolding(.gripperStart(.closed)) else { return [] }
            return [.gripperEnd]
        }
    }
}
