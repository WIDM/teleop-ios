import Foundation
import TeleopCore

/// The guide's read-outs in the app's language.
enum GuideWords {
    static func text(_ line: GuidePicture.Line) -> String {
        switch line {
        case .height(let cm):
            return format("guide.height", centimetres(cm))
        case .heightLowest(let cm):
            return format("guide.height_lowest", centimetres(cm))
        case .jaws(let percent):
            return String(format: L10n.string("guide.jaws"), percent)
        case .wrist(let turn?, let tilt?):
            return String(format: L10n.string("guide.wrist"), turn, tilt)
        case .wrist(let turn?, nil):
            return String(format: L10n.string("guide.wrist_turn"), turn)
        case .wrist(nil, let tilt?):
            return String(format: L10n.string("guide.wrist_tilt"), tilt)
        case .wrist(nil, nil):
            return ""
        case .approximate:
            return L10n.string("guide.approximate")
        case .target(let across, let height):
            return gap(
                ("guide.target_above", "guide.target_below", "guide.target_level"), across: across, height: height)
        case .goal(let across, let height):
            return gap(("guide.goal_above", "guide.goal_below", "guide.goal_level"), across: across, height: height)
        case .onTarget:
            return L10n.string("guide.on_target")
        case .holding:
            return L10n.string("guide.holding")
        case .commandOutside(let side):
            return L10n.string(commandOutsideKey(side))
        case .outside:
            return L10n.string("guide.outside")
        }
    }

    /// One literal key per side, so the string check sees each one used.
    private static func commandOutsideKey(_ side: OperatorDirection) -> String {
        switch side {
        case .forward: return "guide.command_outside.forward"
        case .back: return "guide.command_outside.back"
        case .left: return "guide.command_outside.left"
        case .right: return "guide.command_outside.right"
        case .up: return "guide.command_outside.up"
        case .down: return "guide.command_outside.down"
        }
    }

    private static func gap(
        _ keys: (above: String, below: String, level: String), across: Double, height: GuidePicture.Height
    ) -> String {
        switch height {
        case .above(let cm): return format(keys.above, centimetres(across), centimetres(cm))
        case .below(let cm): return format(keys.below, centimetres(across), centimetres(cm))
        case .level: return format(keys.level, centimetres(across))
        }
    }

    private static func centimetres(_ value: Double) -> String { String(format: "%.1f", value) }

    private static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: L10n.string(key), arguments: arguments)
    }
}
