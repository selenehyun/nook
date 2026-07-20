import AppKit
import NookKit
import SwiftUI
import UserNotifications

@main
struct NookApp: App {
    // Owns the app-lifetime background refresher so feeds keep updating (and new
    // articles can notify) even when the window is closed.
    @NSApplicationDelegateAdaptor(BackgroundRefreshController.self) private var backgroundRefresh

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
            MainWindowContent()
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

/// The main window's content. Captures the `openWindow` action so the app
/// delegate can re-open the window after it's been closed (the app keeps
/// running in the background rather than quitting on last-window-close).
private struct MainWindowContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            // Format dates/numbers with the chosen UI language, not the OS
            // locale (`Text(_, format:)` otherwise follows the environment).
            .environment(\.locale, AppLanguage.formattingLocale)
            .onAppear { WindowReopener.shared.reopen = { openWindow(id: "main") } }
    }
}

/// Bridges the SwiftUI `openWindow` action to the AppKit app delegate, which has
/// no environment of its own.
@MainActor
final class WindowReopener {
    static let shared = WindowReopener()
    var reopen: (() -> Void)?
    private init() {}
}

/// macOS's equivalent of the iOS background task. Drives periodic feed refreshes
/// for the whole app lifetime — not tied to a window, so refreshing continues
/// when the window is closed — and posts a local notification when new articles
/// arrive while Nook isn't the active app.
@MainActor
final class BackgroundRefreshController: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var loopTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        if NewArticleNotifier.isEnabled {
            Task { await NewArticleNotifier.requestAuthorizationIfNeeded() }
        }
        // Tell the store whether Nook is frontmost so it can mark on-screen
        // articles "seen" and skip re-notifying about them later.
        ReaderStore.shared.setForegroundActive(NSApp.isActive)
        loopTask = Task { [weak self] in await self?.runLoop() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ReaderStore.shared.setForegroundActive(true)
        // The user is now in the app; a lingering "new articles" banner is just
        // clutter, so dismiss any delivered one.
        NewArticleNotifier.clearDelivered()
    }

    func applicationDidResignActive(_ notification: Notification) {
        ReaderStore.shared.setForegroundActive(false)
    }

    // Keep running in the background when the window is closed so scheduled
    // refreshes and notifications continue; the user quits explicitly with ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Re-open the main window when the Dock icon is clicked and nothing's shown.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            WindowReopener.shared.reopen?()
        }
        return true
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let defaults = UserDefaults.standard
            let enabled = defaults.object(forKey: "autoRefreshEnabled") as? Bool ?? true
            let minutes = defaults.object(forKey: "refreshIntervalMinutes") as? Int ?? 30

            do {
                try await Task.sleep(for: .seconds(max(5, minutes * 60)))
            } catch {
                return
            }

            guard !Task.isCancelled, enabled else { continue }
            let store = ReaderStore.shared
            guard store.isStorageConfigured, !store.isRefreshing else { continue }

            let result = await store.refreshAllReportingNew()
            // Only notify when there's genuinely new unread content, the user
            // opted in, and Nook isn't already frontmost (the Dock badge covers
            // the active case).
            guard result.newArticleCount > 0, NewArticleNotifier.isEnabled, !NSApp.isActive else {
                continue
            }
            let body = await NewArticleSummarizer.notificationBody(
                titles: result.sampleTitles,
                count: result.newArticleCount
            )
            await NewArticleNotifier.post(
                title: String(localized: "New in Nook"),
                body: body,
                badge: result.badgeCount
            )
            store.markNotificationsDelivered(result.articleIDs)
        }
    }

    // Present the banner even if Nook happens to become active as it fires.
    // `nonisolated` because the delegate requirement isn't main-actor-isolated;
    // the body touches no actor state.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
