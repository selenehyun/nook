import BackgroundTasks
import NookKit
import UserNotifications

/// Periodic background refresh: iOS wakes the app on its own schedule (no sooner
/// than the user's interval), Nook fetches feeds, and if new articles arrived it
/// posts a local notification. Gated on the "New article notifications" setting.
enum BackgroundRefresh {
    static let taskIdentifier = "com.tim.nook.ios.refresh"

    static let enabledKey = NewArticleNotifier.enabledKey
    private static let intervalKey = "refreshIntervalMinutes"

    static var isEnabled: Bool { NewArticleNotifier.isEnabled }

    /// Asks iOS to wake the app for a refresh. The system decides the actual
    /// time; `earliestBeginDate` is only a lower bound.
    static func schedule() {
        guard isEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        let minutes = UserDefaults.standard.object(forKey: intervalKey) as? Int ?? 30
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(max(15, minutes) * 60))
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Cancels any pending background refresh (e.g. when the feature is turned
    /// off).
    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    /// Runs one background refresh and notifies about new articles. Always
    /// reschedules first so refreshes continue.
    @MainActor
    static func run() async {
        schedule()
        guard isEnabled else { return }
        let result = await ReaderStore.shared.refreshForBackground()
        guard result.newArticleCount > 0 else { return }
        await postNotification(for: result)
    }

    @MainActor
    private static func postNotification(for result: ReaderStore.BackgroundRefreshResult) async {
        await NewArticleNotifier.post(
            title: String(localized: "New in Nook"),
            body: body(for: result),
            badge: result.newArticleCount
        )
    }

    private static func body(for result: ReaderStore.BackgroundRefreshResult) -> String {
        let summary = String(localized: "\(result.newArticleCount) new articles")
        guard !result.sampleTitles.isEmpty else { return summary }
        return summary + "\n" + result.sampleTitles.joined(separator: "\n")
    }
}
