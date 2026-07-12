import Foundation
import Observation
import Sparkle

/// Owns Sparkle's updater and bridges it to SwiftUI as observable state.
///
/// Uses Sparkle's standard updater and user driver, but opts into "gentle
/// reminders" so scheduled update checks never interrupt with a modal — not
/// even near launch. When a check finds an update, it is remembered (and
/// persisted) as ``pendingUpdateVersion`` and rendered by the quiet sidebar
/// chip. The standard update dialog (release notes + install + progress)
/// appears only when the user acts, via the chip's popover or Settings.
///
/// The found-update state is persisted and keyed by build number, so the chip
/// keeps appearing on every launch — immediately, without waiting for the next
/// scheduled check — until the update is actually installed (at which point the
/// running build catches up to the pending build and the chip clears).
///
/// App-global singleton: Sparkle allows one updater per app, and the same live
/// state must back both the main-window chip and the separate Settings scene.
@MainActor
@Observable
final class UpdateController: NSObject {
    static let shared = UpdateController()

    private static let pendingBuildKey = "PendingUpdateBuild"
    private static let pendingVersionKey = "PendingUpdateVersion"
    private static let pendingDateKey = "PendingUpdateDate"

    /// Short version string ("1.2.3") of a known-available update, or nil when
    /// up to date. Non-nil keeps the sidebar chip visible.
    private(set) var pendingUpdateVersion: String?

    /// When the pending update was published (its appcast `pubDate`), if known.
    private(set) var pendingUpdateDate: Date?

    /// The running app's version string ("1.2.3"), shown as the "current" version.
    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

    @ObservationIgnored private var updaterController: SPUStandardUpdaterController!

    /// The running app's build number (CFBundleVersion).
    private static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    private override init() {
        super.init()

        // Restore a previously-found update so the chip shows immediately on
        // launch, but only if it is still newer than what's running. Once the
        // update has been installed and relaunched, the running build reaches
        // the pending build and the stale state is cleared here.
        let defaults = UserDefaults.standard
        if defaults.integer(forKey: Self.pendingBuildKey) > Self.currentBuild {
            pendingUpdateVersion = defaults.string(forKey: Self.pendingVersionKey)
            let timestamp = defaults.double(forKey: Self.pendingDateKey)
            pendingUpdateDate = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        } else {
            clearPending()
        }

        // `startingUpdater: true` schedules background checks immediately. It
        // does not block launch and shows no UI on its own — the delegate below
        // decides how anything surfaces.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }

    /// Bound to the "Check for updates automatically" toggle in Settings.
    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Runs a user-initiated check. Sparkle presents its standard, focused
    /// dialog (version, release notes, install + progress). Used by the chip's
    /// popover and Settings' "Check Now".
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    private func recordPending(_ item: SUAppcastItem) {
        let build = Int(item.versionString) ?? 0
        guard build > Self.currentBuild else { return }
        pendingUpdateVersion = item.displayVersionString
        pendingUpdateDate = item.date
        let defaults = UserDefaults.standard
        defaults.set(build, forKey: Self.pendingBuildKey)
        defaults.set(item.displayVersionString, forKey: Self.pendingVersionKey)
        if let date = item.date {
            defaults.set(date.timeIntervalSince1970, forKey: Self.pendingDateKey)
        } else {
            defaults.removeObject(forKey: Self.pendingDateKey)
        }
    }

    private func clearPending() {
        pendingUpdateVersion = nil
        pendingUpdateDate = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.pendingBuildKey)
        defaults.removeObject(forKey: Self.pendingVersionKey)
        defaults.removeObject(forKey: Self.pendingDateKey)
    }
}

extension UpdateController: @MainActor SPUUpdaterDelegate {
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        // A check confirmed we're up to date (e.g. after installing): stop
        // showing the chip. Errors don't call this, so a transient network
        // failure won't clear a real pending update.
        clearPending()
    }
}

extension UpdateController: @MainActor SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Never let Sparkle show a scheduled update modally — not even near
        // launch. We always surface it through the quiet sidebar chip instead.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // An update exists — remember it so the chip persists across launches
        // until it's installed, whether or not Sparkle shows its own UI.
        recordPending(update)
    }

    func standardUserDriverWillFinishUpdateSession() {
        // Intentionally keep the persisted pending state: the chip should
        // return on the next launch unless the update was actually installed,
        // which `updaterDidNotFindUpdate` / the launch build check will clear.
    }
}
