import Foundation
import UserNotifications

/// Shared local-notification plumbing for "new article" alerts, used by the iOS
/// background task and the macOS background refresher. Callers build the
/// localized title/body in their own target (where the strings live) and hand
/// them here; this manages authorization and posting.
public enum NewArticleNotifier {
    /// `@AppStorage`/`UserDefaults` key backing the "Notify me about new
    /// articles" preference. Shared so every reader of the toggle agrees.
    public static let enabledKey = "newArticleNotifications"

    /// Shared identifier for every new-article notification, so a newer one
    /// replaces the last and they can be cleared together.
    private static let identifier = "nook.new-articles"

    /// Whether the user opted into new-article notifications. Defaults off.
    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }

    /// Requests notification authorization once — the system prompts only the
    /// first time, so we ask for the full set (`alert`, `sound`, `badge`) up
    /// front to avoid a badge-only first prompt foreclosing alerts later. No-op
    /// once the user has answered.
    public static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Posts a new-article notification when alerts are authorized. `badge`
    /// sets the notification badge (0 leaves it unchanged). All new-article
    /// notifications share one identifier so a newer one replaces the last.
    public static func post(title: String, body: String, badge: Int) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if badge > 0 { content.badge = NSNumber(value: badge) }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await center.add(request)
    }

    /// Removes any delivered new-article notification from Notification Center.
    /// Called when Nook becomes active: once the user is in the app (where the
    /// unread counts and the sidebar flash surface new content), a lingering
    /// banner is just clutter.
    public static func clearDelivered() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
