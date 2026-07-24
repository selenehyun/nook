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
            // Give the app-lifetime activity controller the exact reader window.
            // App activation alone is insufficient: Settings can be frontmost,
            // the reader can be closed/minimized, or the Mac can be unattended.
            .background(ReaderWindowProbe())
            // Format dates/numbers with the chosen UI language, not the OS
            // locale (`Text(_, format:)` otherwise follows the environment).
            .environment(\.locale, AppLanguage.formattingLocale)
            .onAppear { WindowReopener.shared.reopen = { openWindow(id: "main") } }
    }
}

/// Reports the SwiftUI reader's hosting window without retaining it. This is the
/// native equivalent of attaching an element ref in a web app: it lets the
/// app-lifetime controller distinguish the actual reading surface from Settings.
private struct ReaderWindowProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            BackgroundRefreshController.shared?.setReaderWindow(window)
        }
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
/// arrive while the reader isn't genuinely being attended.
@MainActor
final class BackgroundRefreshController: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    fileprivate static weak var shared: BackgroundRefreshController?

    private var loopTask: Task<Void, Never>?
    private var engagementTask: Task<Void, Never>?
    private var localEventMonitor: Any?
    private weak var readerWindow: NSWindow?
    private var loginSessionIsActive = true
    private var screenIsAwake = true
    private let engagementPolicy = ForegroundEngagementPolicy()

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        if NewArticleNotifier.isEnabled {
            Task { await NewArticleNotifier.requestAuthorizationIfNeeded() }
        }
        startEngagementObservation()
        // Defer once so SwiftUI has attached the reader-window probe.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.reevaluateEngagement()
        }
        loopTask = Task { [weak self] in await self?.runLoop() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        reevaluateEngagement(recentInteraction: true)
        // The user is now in the app; a lingering "new articles" banner is just
        // clutter, so dismiss any delivered one.
        NewArticleNotifier.clearDelivered()
    }

    func applicationDidResignActive(_ notification: Notification) {
        reevaluateEngagement()
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
            // An app left frontmost on an unattended Mac is background in the
            // product sense. Notify unless the reader is genuinely being used.
            guard result.newArticleCount > 0,
                  NewArticleNotifier.isEnabled,
                  !store.isForegroundActive else {
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

    fileprivate func setReaderWindow(_ window: NSWindow?) {
        readerWindow = window
        reevaluateEngagement()
    }

    /// Re-evaluates presence periodically because macOS does not emit an event at
    /// the exact moment its system-wide idle counter crosses our grace period.
    private func startEngagementObservation() {
        let inputEvents: NSEvent.EventTypeMask = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel, .gesture, .magnify, .swipe, .rotate,
        ]
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: inputEvents) { [weak self] event in
            Task { @MainActor in self?.reevaluateEngagement(recentInteraction: true) }
            return event
        }

        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification,
        ] {
            center.addObserver(self, selector: #selector(windowStateDidChange), name: name, object: nil)
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(screenDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(screenDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        engagementTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                self?.reevaluateEngagement()
            }
        }
    }

    @objc private func windowStateDidChange(_ notification: Notification) {
        // AppKit can post before the window has finished updating its flags.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.reevaluateEngagement()
        }
    }

    @objc private func sessionDidResignActive(_ notification: Notification) {
        loginSessionIsActive = false
        reevaluateEngagement()
    }

    @objc private func sessionDidBecomeActive(_ notification: Notification) {
        loginSessionIsActive = true
        reevaluateEngagement(recentInteraction: true)
    }

    @objc private func screenDidSleep(_ notification: Notification) {
        screenIsAwake = false
        reevaluateEngagement()
    }

    @objc private func screenDidWake(_ notification: Notification) {
        screenIsAwake = true
        reevaluateEngagement()
    }

    private func reevaluateEngagement(recentInteraction: Bool = false) {
        let windowIsAttended = readerWindow.map {
            $0.isVisible
                && !$0.isMiniaturized
                && $0.occlusionState.contains(.visible)
                && ($0.isKeyWindow || $0.attachedSheet?.isKeyWindow == true)
        } ?? false
        let idleSeconds = recentInteraction
            ? 0
            : CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                // Swift does not import CoreGraphics' `kCGAnyInputEventType`
                // macro; its documented C value is all bits set.
                eventType: CGEventType(rawValue: UInt32.max)!
            )
        let engaged = engagementPolicy.isEngaged(
            appIsActive: NSApp.isActive,
            readerWindowIsAttended: windowIsAttended,
            sessionIsActive: loginSessionIsActive && screenIsAwake,
            secondsSinceLastInput: idleSeconds
        )
        ReaderStore.shared.setForegroundActive(engaged)
    }
}
