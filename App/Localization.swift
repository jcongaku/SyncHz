import Foundation

/// The interface language. `.system` follows macOS; the others override it for
/// this app only and take effect live — the panel injects `locale` into the
/// SwiftUI environment, and `L10n` reads the same choice.
enum AppLanguage: String, CaseIterable, Identifiable {
    // Listed in this order in the picker, like the macOS language list:
    // Latin-script languages first, then the rest.
    case system
    case english = "en"
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    /// `UserDefaults` key; also used by `@AppStorage` in the views.
    static let storageKey = "appLanguage"

    var id: String { rawValue }

    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// Each language is listed in its own script, as the macOS language list does.
    /// `.system` has no native name; the picker shows a localized "Follow System".
    var nativeName: String {
        switch self {
        case .system: return ""
        case .english: return "English"
        case .japanese: return "日本語"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        }
    }

    /// The override locale, or nil to follow macOS.
    var locale: Locale? {
        self == .system ? nil : Locale(identifier: rawValue)
    }

    /// What the panel puts in the SwiftUI environment. `.system` resolves to
    /// the localization macOS picked for this bundle, so the environment is
    /// always set and switching never changes the view tree's identity.
    var resolvedLocale: Locale {
        locale ?? Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// The `.lproj` bundle holding this language's strings; nil follows macOS.
    fileprivate var bundle: Bundle? {
        guard self != .system else { return nil }
        if let cached = AppLanguage.bundles[self] { return cached }
        let bundle = Bundle.main.path(forResource: rawValue, ofType: "lproj").flatMap(Bundle.init(path:))
        AppLanguage.bundles[self] = bundle
        return bundle
    }

    private static var bundles: [AppLanguage: Bundle] = [:]
}

/// Lookups for text built outside SwiftUI's `Text` — status messages and
/// formatted counts. `String(localized:)` and `NSLocalizedString` always
/// resolve against the macOS language, so they would ignore the in-app choice.
enum L10n {
    static func string(_ key: String) -> String {
        (AppLanguage.current.bundle ?? .main).localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: AppLanguage.current.locale ?? .current, arguments: arguments)
    }
}
