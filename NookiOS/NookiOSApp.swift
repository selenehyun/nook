import NookKit
import SwiftUI

@main
struct NookiOSApp: App {
    init() {
        // Keep the AppleLanguages override in sync with the stored preference,
        // and capture the language Nook launched with.
        AppLanguage.applyStoredPreference()
        _ = AppLanguage.launchLanguage
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Format dates/numbers with the chosen UI language, not the OS
                // locale (`Text(_, format:)` otherwise follows the environment).
                .environment(\.locale, AppLanguage.formattingLocale)
        }
    }
}
