import Foundation

/// How an article opens in the in-app browser: the cleaned-up reader, or the
/// original web page.
public enum ReaderViewMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case reader
    case original

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .reader: String(localized: "Reader Mode", bundle: Bundle.module)
        case .original: String(localized: "Original Page", bundle: Bundle.module)
        }
    }
}
