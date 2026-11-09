import TeleopCore

enum VolumeKey { case up, down }
enum VolumeKeyPhase { case began, ended, cancelled }

/// Hold vol+ to move the arm, press vol− to toggle the gripper. One vol+ press gives one start,
/// so a key that repeats while held cannot restart an arm that was stopped meanwhile.
struct VolumeKeyMapper {
    private(set) var upHeld = false

    mutating func actions(for key: VolumeKey, phase: VolumeKeyPhase) -> [TeleopAction] {
        switch (key, phase) {
        case (.up, .began):
            guard !upHeld else { return [] }
            upHeld = true
            return [.holdArmStart]
        case (.up, .ended), (.up, .cancelled):
            upHeld = false
            return [.holdArmEnd]
        case (.down, .began):
            return [.toggleGripper]
        case (.down, .ended), (.down, .cancelled):
            return []
        }
    }
}
