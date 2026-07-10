import AppKit
import SwiftUI

@main
struct NookApp: App {
    init() {
        // Keep the AppleLanguages override in sync with the stored preference,
        // and capture the language Nook launched with so Settings can tell when
        // a relaunch is still required.
        AppLanguage.applyStoredPreference()
        _ = AppLanguage.launchLanguage
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            TextEditingCommands()
            ReaderAppCommands()
        }

        Settings {
            ReaderSettingsView()
        }
    }
}

/// The app's UI language. `system` follows the macOS language order; the other
/// cases pin Nook to a specific localization via the `AppleLanguages` default,
/// which macOS reads at launch (the same mechanism as the per-app language in
/// System Settings). Language changes therefore take effect after a relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case korean = "ko"

    static let storageKey = "appLanguage"
    private static let appleLanguagesKey = "AppleLanguages"

    /// The language Nook actually launched with. Captured once at startup.
    static let launchLanguage = current

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: String(localized: "System Default")
        case .english: "English"
        case .korean: "한국어"
        }
    }

    static var current: AppLanguage {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let language = AppLanguage(rawValue: raw) else {
            return .system
        }
        return language
    }

    /// Reconciles the persisted preference with the `AppleLanguages` override.
    /// Safe to call on every launch.
    static func applyStoredPreference() {
        apply(current)
    }

    static func apply(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        switch language {
        case .system:
            defaults.removeObject(forKey: appleLanguagesKey)
        case .english, .korean:
            defaults.set([language.rawValue], forKey: appleLanguagesKey)
        }
    }

    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { application, _ in
            guard application != nil else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
