import Foundation

/// Shared between the app and the widget extension (add this file to both
/// targets' membership). This build shares no data — it only defines the
/// `nook://` deep links the widget uses to open the app. No App Group needed.
enum WidgetShared {
    static let urlScheme = "nook"
    static let widgetKind = "NookWidget"

    /// Opens the app without changing the view.
    static var openAppURL: URL {
        URL(string: "\(urlScheme)://open")!
    }

    /// Opens the app focused on a smart source (Unread, Today, …).
    static func sourceURL(_ source: WidgetSource) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "source"
        components.queryItems = [URLQueryItem(name: "smart", value: source.rawValue)]
        return components.url ?? openAppURL
    }

    /// The `smart` value from a `nook://source?smart=…` deep link.
    static func smartSourceRaw(from url: URL) -> String? {
        guard url.scheme == urlScheme, url.host == "source",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "smart" })?.value
    }
}

/// The smart sources the widget can jump to. Raw values match the app's
/// `SmartSource` so the app can map them back.
enum WidgetSource: String, CaseIterable, Identifiable {
    case unread
    case today
    case starred
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unread: "Unread"
        case .today: "Today"
        case .starred: "Starred"
        case .all: "All Articles"
        }
    }

    var systemImage: String {
        switch self {
        case .unread: "largecircle.fill.circle"
        case .today: "calendar"
        case .starred: "star"
        case .all: "tray.full"
        }
    }
}
