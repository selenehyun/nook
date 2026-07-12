import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// The app's UI language. `system` follows the OS language order; the other
/// cases pin Nook to a specific localization via the `AppleLanguages` default,
/// which the OS reads at launch (the same mechanism as the per-app language in
/// System Settings). Language changes therefore take effect after a relaunch.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case korean = "ko"
    case japanese = "ja"
    case chineseSimplified = "zh-Hans"

    public static let storageKey = "appLanguage"
    private static let appleLanguagesKey = "AppleLanguages"

    /// The language Nook actually launched with. Captured once at startup.
    public static let launchLanguage = current

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: String(localized: "System Default", bundle: Bundle.module)
        case .english: "English"
        case .korean: "한국어"
        case .japanese: "日本語"
        case .chineseSimplified: "简体中文"
        }
    }

    /// The locale to use for date/number formatting so it matches the chosen
    /// UI language instead of the OS. `system` follows the OS.
    public var locale: Locale {
        switch self {
        case .system: Locale.autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .korean: Locale(identifier: "ko")
        case .japanese: Locale(identifier: "ja")
        case .chineseSimplified: Locale(identifier: "zh-Hans")
        }
    }

    /// Formatting locale for the running session. Uses the language Nook
    /// launched with, since a language change only takes effect after relaunch —
    /// keeping dates consistent with the rest of the UI.
    public static var formattingLocale: Locale { launchLanguage.locale }

    public static var current: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let language = AppLanguage(rawValue: raw) else {
            return .system
        }
        return language
    }

    /// Reconciles the persisted preference with the `AppleLanguages` override.
    /// Safe to call on every launch.
    public static func applyStoredPreference() {
        apply(current)
    }

    public static func apply(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        switch language {
        case .system:
            defaults.removeObject(forKey: appleLanguagesKey)
        case .english, .korean, .japanese, .chineseSimplified:
            defaults.set([language.rawValue], forKey: appleLanguagesKey)
        }
    }

    #if canImport(AppKit)
    /// Relaunches the app so a language change takes effect. macOS only; on iOS
    /// the user relaunches the app manually.
    @MainActor
    public static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { application, _ in
            guard application != nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    #endif
}

extension Date {
    /// Formats the date using the app's chosen language locale rather than the
    /// OS locale, so dates match the rest of the UI.
    public func localized(
        date: Date.FormatStyle.DateStyle = .abbreviated,
        time: Date.FormatStyle.TimeStyle = .omitted
    ) -> String {
        formatted(Date.FormatStyle(date: date, time: time).locale(AppLanguage.formattingLocale))
    }
}
