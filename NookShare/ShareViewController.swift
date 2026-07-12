import UIKit
import UniformTypeIdentifiers

/// Share-sheet extension: takes the URL of the page the user is viewing and
/// hands it to Nook via `nook://add-feed?url=…`, which adds the feed
/// (auto-discovering RSS/Atom). No App Group is needed, so it works with a
/// free developer account.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        Task {
            if let shared = await extractSharedURL(), let deepLink = Self.addFeedURL(for: shared) {
                await open(deepLink)
            }
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// Finds the shared web URL among the extension's input attachments.
    private func extractSharedURL() async -> URL? {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }

        if let urlProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            return await withCheckedContinuation { continuation in
                urlProvider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    continuation.resume(returning: item as? URL)
                }
            }
        }
        if let textProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            return await withCheckedContinuation { continuation in
                textProvider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    let url = (item as? String).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    continuation.resume(returning: url)
                }
            }
        }
        return nil
    }

    private static func addFeedURL(for shared: URL) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&?=+/:")
        let encoded = shared.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "nook://add-feed?url=\(encoded)")
    }

    /// Opens the containing app. Uses the extension context first; if that is
    /// refused, walks the responder chain to reach UIApplication as a fallback.
    private func open(_ url: URL) async {
        let opened = await withCheckedContinuation { continuation in
            guard let context = extensionContext else {
                continuation.resume(returning: false)
                return
            }
            context.open(url) { continuation.resume(returning: $0) }
        }
        if !opened { openViaResponderChain(url) }
    }

    private func openViaResponderChain(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }
}
