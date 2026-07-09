import SwiftUI

@main
struct NookApp: App {
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
