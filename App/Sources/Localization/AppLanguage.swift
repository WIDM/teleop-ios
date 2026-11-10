import Foundation

/// In-app language choice. `system` follows the iPhone setting.
enum AppLanguage: String, CaseIterable {
    case system
    case zhHant = "zh-Hant"
    case en

    private static let key = "appLanguage"

    static var saved: AppLanguage {
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func save() { UserDefaults.standard.set(rawValue, forKey: Self.key) }

    var locale: Locale {
        self == .system ? .current : Locale(identifier: rawValue)
    }

    /// Shown in its own language, so a reader can always find their way back.
    var nativeName: String? {
        switch self {
        case .system: return nil
        case .zhHant: return "中文"
        case .en: return "English"
        }
    }
}

/// Runtime lookups (format strings) that SwiftUI's environment locale does not reach.
enum L10n {
    static var language: AppLanguage = .saved

    static func string(_ key: String) -> String {
        if language != .system,
           let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }
        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}
