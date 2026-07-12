import AppKit
import NookKit
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
        // A single Window (not WindowGroup) so deep links reuse the one main
        // window instead of opening a new one each time.
        Window("Nook", id: "main") {
            ContentView()
                // Format dates/numbers with the chosen UI language, not the OS
                // locale (`Text(_, format:)` otherwise follows the environment).
                .environment(\.locale, AppLanguage.formattingLocale)
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
                .environment(\.locale, AppLanguage.formattingLocale)
        }
    }
}
