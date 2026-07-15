import Foundation

/// Watches a file *or a directory* for external changes — chiefly iCloud syncing
/// another device's edits — and invokes `onChange` when the watched item's
/// content may have changed. Registered as an `NSFilePresenter` so the system
/// delivers change notifications as soon as iCloud updates the item on disk,
/// instead of the app only finding out on next launch.
///
/// Nook watches the legacy input plus the v2 content/body/state shard
/// directories. For a directory, the system
/// reports child changes via the `presentedSubitem…` callbacks; for a file, the
/// `presentedItem…` callbacks fire. All of them funnel into `onChange`.
///
/// `onChange` can fire for the app's own writes too; the store guards against
/// that by comparing modification dates before reloading.
final class LibraryFileObserver: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: @Sendable () -> Void

    init(fileURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.presentedItemURL = fileURL
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = queue
        self.onChange = onChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
    }

    // Content changed on disk (e.g. iCloud downloaded a newer version).
    func presentedItemDidChange() {
        onChange()
    }

    // iCloud resolved to a newer version of the item.
    func presentedItemDidGain(_ version: NSFileVersion) {
        onChange()
    }

    // A child of the watched directory changed (a peer's shard was written).
    func presentedSubitemDidChange(at url: URL) {
        onChange()
    }

    // A new child appeared in the watched directory (a new device's shard).
    func presentedSubitemDidAppear(at url: URL) {
        onChange()
    }
}
