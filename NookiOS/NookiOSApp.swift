// `@preconcurrency` so passing the non-`Sendable` `BGTask` into the async
// handler doesn't trip Swift 6 strict-concurrency checks.
@preconcurrency import BackgroundTasks
import NookKit
import SwiftUI
import UIKit
import UserNotifications

final class NookiOSDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Register the background-refresh handler here (UIKit `BGTaskScheduler`
        // registration) rather than via SwiftUI's `.backgroundTask` modifier.
        // The register-based path is what iOS's launcher — and Xcode's
        // `_simulateLaunchForTaskWithIdentifier` debug command — actually drive,
        // so the task launches reliably and is testable.
        // Run the launch handler on the main queue: it's created in this
        // @MainActor context, so it inherits main-actor isolation, and iOS would
        // otherwise invoke it on a background queue — tripping the Swift runtime's
        // executor-isolation check (dispatch_assert_queue). The handler only
        // spawns the async work and returns, so main-queue execution is cheap.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundRefresh.taskIdentifier,
            using: .main
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { await BackgroundRefresh.handle(refreshTask) }
        }
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}

@main
struct NookiOSApp: App {
    @UIApplicationDelegateAdaptor(NookiOSDelegate.self) private var appDelegate
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
