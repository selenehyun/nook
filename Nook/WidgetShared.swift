import Foundation

/// Shared between the app and the widget extension (add this file to both
/// targets' membership). The app writes a small snapshot of unread articles
/// into the App Group container; the widget reads it and deep-links back into
/// the app via the `nook://` URL scheme.
enum WidgetShared {
    static let appGroupID = "group.com.tim.nook"
    static let urlScheme = "nook"
    static let widgetKind = "NookWidget"

    private static let snapshotFileName = "widget-snapshot.json"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    private static var snapshotURL: URL? {
        containerURL?.appending(path: snapshotFileName, directoryHint: .notDirectory)
    }

    static func writeSnapshot(_ snapshot: WidgetSnapshot) {
        guard let snapshotURL, let data = try? JSONEncoder.shared.encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: [.atomic])
    }

    static func readSnapshot() -> WidgetSnapshot {
        guard let snapshotURL,
              let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder.shared.decode(WidgetSnapshot.self, from: data) else {
            return WidgetSnapshot(unreadCount: 0, generatedAt: nil, articles: [])
        }
        return snapshot
    }

    /// A deep link that opens a specific article in the app.
    static func articleURL(id: String) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "article"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url ?? URL(string: "\(urlScheme)://")!
    }

    /// A deep link that just opens the app.
    static var openAppURL: URL {
        URL(string: "\(urlScheme)://open")!
    }

    static func articleID(from url: URL) -> String? {
        guard url.scheme == urlScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "id" })?.value
    }
}

struct WidgetSnapshot: Codable {
    var unreadCount: Int
    var generatedAt: Date?
    var articles: [WidgetArticle]

    static let placeholder = WidgetSnapshot(
        unreadCount: 3,
        generatedAt: nil,
        articles: [
            WidgetArticle(id: "1", title: "A calm place to read your feeds", feedTitle: "Nook", publishedAt: .distantPast),
            WidgetArticle(id: "2", title: "Your unread articles, at a glance", feedTitle: "Nook", publishedAt: .distantPast),
            WidgetArticle(id: "3", title: "Tap an article to open it", feedTitle: "Nook", publishedAt: .distantPast)
        ]
    )
}

struct WidgetArticle: Codable, Identifiable {
    var id: String
    var title: String
    var feedTitle: String
    var publishedAt: Date
}

private extension JSONEncoder {
    static let shared: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let shared: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
