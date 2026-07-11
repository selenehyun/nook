import Observation
import Sparkle

/// Owns Sparkle's updater and bridges it to SwiftUI as observable state.
///
/// Uses Sparkle's standard updater and user driver, but opts into "gentle
/// reminders" so scheduled update checks never interrupt with a modal — not
/// even near launch. When a background check finds an update, it is surfaced as
/// ``availableUpdate`` and rendered by the quiet sidebar banner. The standard
/// update dialog (release notes + install + progress) appears only when the
/// user explicitly acts, via the banner's "Update" button or Settings.
///
/// This is an app-global singleton: Sparkle allows one updater per app, and the
/// same live state must back both the main-window banner and the separate
/// Settings scene (which the codebase's explicit-argument passing can't reach).
@MainActor
@Observable
final class UpdateController: NSObject {
    static let shared = UpdateController()

    /// The update Sparkle found during a background check, if any. Non-nil means
    /// the sidebar banner should offer it; cleared once handled or dismissed.
    private(set) var availableUpdate: SUAppcastItem?

    @ObservationIgnored private var updaterController: SPUStandardUpdaterController!

    private override init() {
        super.init()
        // `startingUpdater: true` schedules background checks immediately. It
        // does not block launch and shows no UI on its own — our delegate below
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
    /// dialog (version, release notes, install + progress). Used by the banner's
    /// "Update" button and Settings' "Check Now".
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Hides the banner ("Later"). Sparkle re-surfaces the update on its next
    /// scheduled background check.
    func dismissAvailableUpdate() {
        availableUpdate = nil
    }
}

extension UpdateController: @MainActor SPUUpdaterDelegate {}

extension UpdateController: @MainActor SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Never let Sparkle show a scheduled update modally — not even near
        // launch. We always surface it through the quiet sidebar banner instead.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if handleShowingUpdate {
            // Sparkle is presenting its own dialog (e.g. a user-initiated
            // check), so the banner isn't needed.
            availableUpdate = nil
        } else {
            // A scheduled update we suppressed — offer it via the banner.
            availableUpdate = update
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableUpdate = nil
    }
}
