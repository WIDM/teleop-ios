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
    static let emergencyBorder = Color(hex: 0xFACC15)
    static let background = Color(hex: 0xF8FAFC)
    static let card = Color.white
    static let textPrimary = Color(hex: 0x0F172A)
    static let textSecondary = Color(hex: 0x475569)
    static let chevronMuted = Color(hex: 0x64748B)
    static let recording = Color(hex: 0x0F172A)
    static let basePanel = Color(hex: 0x0F172A, opacity: 0.8)
    static let scrim = Color(hex: 0x0F172A, opacity: 0.6)
    static let gripperCard = Color(hex: 0xE2E8F0)
    static let camera = Color(hex: 0x14213D)
    static let failSoft = Color(hex: 0xFEF3C7)
    static let passSoft = Color(hex: 0xDCFCE7)
}

enum TeleopMetrics {
    static let corner: CGFloat = 12
    static let margin: CGFloat = 16
    static let touch: CGFloat = 48
    static let stopHeight: CGFloat = 72
}
