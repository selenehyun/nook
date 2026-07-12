import Foundation

/// Watches the library file for external changes — chiefly iCloud syncing
/// another device's edits — and invokes `onChange` when the file's content may
/// have changed. Registered as an `NSFilePresenter` so the system delivers
/// change notifications as soon as iCloud updates the file on disk, instead of
/// the app only finding out on next launch.
///
/// `onChange` can fire for the app's own writes too; the store guards against
/// that by comparing the file's modification date before reloading.
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
}
