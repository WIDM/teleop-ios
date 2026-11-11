import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Palette from visual-spec v1.14. Red is reserved for STOP, e-stop and disconnect.
enum TeleopColors {
    static let primary = Color(hex: 0x2563EB)
    static let statusGreen = Color(hex: 0x16A34A)
    static let statusAmber = Color(hex: 0xD97706)
    static let emergency = Color(hex: 0xDC2626)
    static let background = Color(hex: 0xF8FAFC)
    static let card = Color.white
    static let textPrimary = Color(hex: 0x0F172A)
    static let textSecondary = Color(hex: 0x475569)
    static let gripperCard = Color(hex: 0xE2E8F0)
    /// The operating screen's bands and gap.
    static let band = Color(hex: 0x0F172A)
    static let bandText = Color(hex: 0x94A3B8)
    /// The control surface takes the state's colour (§7.2).
    static let stateGrey = Color(hex: 0x64748B)
    static let stateGreen = Color(hex: 0x15803D)
    static let stateBlue = Color(hex: 0x1D4ED8)
    static let stateAmber = Color(hex: 0xB45309)
    static let stateRed = Color(hex: 0xB91C1C)
    static let stateDarkGrey = Color(hex: 0x334155)
    static let stateGold = Color(hex: 0xEAB308)
    /// Practice: diagonal stripes and its mark, on every screen (§7.4).
    static let practice = Color(hex: 0x7C3AED)
    /// The guide's marks.
    static let guideTarget = Color(hex: 0xFB923C)
    static let guideGoal = Color(hex: 0x4ADE80)
    static let guideOnTarget = Color(hex: 0x4ADE80)
}

enum TeleopMetrics {
    static let corner: CGFloat = 12
    static let margin: CGFloat = 16
    static let touch: CGFloat = 48
    static let stopHeight: CGFloat = 72
}
