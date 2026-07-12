import UIKit
import UniformTypeIdentifiers

/// Share-sheet extension: takes the URL of the page the user is viewing and
/// hands it to Nook via `nook://add-feed?url=…`, which adds the feed
/// (auto-discovering RSS/Atom). No App Group is needed, so it works with a
/// free developer account.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        extractSharedURL { [weak self] shared in
            guard let self else { return }
            if let shared, let deepLink = Self.addFeedURL(for: shared) {
                self.open(deepLink) {
                    self.finish()
                }
            } else {
                self.finish()
            }
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Finds the shared web URL among the extension's input attachments.
    private func extractSharedURL(completion: @escaping (URL?) -> Void) {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }

        // Prefer a real URL attachment; fall back to plain text that is a URL.
        if let urlProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            urlProvider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                DispatchQueue.main.async { completion(item as? URL) }
            }
            return
        }
        if let textProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            textProvider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let url = (item as? String).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                DispatchQueue.main.async { completion(url) }
            }
            return
        }
        completion(nil)
    }

    private static func addFeedURL(for shared: URL) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&?=+/:")
        let encoded = shared.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "nook://add-feed?url=\(encoded)")
    }

    /// Opens the containing app. Uses the extension context first; if that is
    /// refused, walks the responder chain to reach UIApplication as a fallback.
    private func open(_ url: URL, completion: @escaping () -> Void) {
        extensionContext?.open(url) { [weak self] opened in
            if opened {
                completion()
            } else {
                self?.openViaResponderChain(url)
                completion()
            }
        }
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
