import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Reader configuration

/// Whether links tapped inside the reader open in Nook's in-app browser or the
/// system browser.
public enum ReaderLinkBehavior: String, CaseIterable, Identifiable, Sendable {
    case inApp
    case external
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .inApp: String(localized: "Open in Nook", bundle: Bundle.module)
        case .external: String(localized: "Open in Browser", bundle: Bundle.module)
        }
    }
}

public enum ReaderFont: String, CaseIterable, Identifiable, Sendable {
    case system
    case serif
    case monospaced
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .system: String(localized: "System", bundle: Bundle.module)
        case .serif: String(localized: "Serif", bundle: Bundle.module)
        case .monospaced: String(localized: "Monospaced", bundle: Bundle.module)
        }
    }
    public var cssFamily: String {
        switch self {
        case .system: "-apple-system, system-ui, sans-serif"
        case .serif: "ui-serif, Georgia, 'Times New Roman', serif"
        case .monospaced: "ui-monospace, SFMono-Regular, Menlo, monospace"
        }
    }
}

public enum ReaderColorOption: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case custom
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .automatic: String(localized: "Match Appearance", bundle: Bundle.module)
        case .custom: String(localized: "Custom", bundle: Bundle.module)
        }
    }
}

/// The typography/appearance used when rendering an article in reader mode.
public struct ReaderStyle: Equatable, Sendable {
    public var font: ReaderFont
    public var fontSize: Int
    public var lineHeight: Double
    public var letterSpacing: Double
    public var backgroundOption: ReaderColorOption
    public var backgroundHex: String
    public var textOption: ReaderColorOption
    public var textHex: String

    public init(
        font: ReaderFont = .system,
        fontSize: Int = 18,
        lineHeight: Double = 1.7,
        letterSpacing: Double = 0,
        backgroundOption: ReaderColorOption = .automatic,
        backgroundHex: String = "#FFFFFF",
        textOption: ReaderColorOption = .automatic,
        textHex: String = "#1A1A1A"
    ) {
        self.font = font
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.letterSpacing = letterSpacing
        self.backgroundOption = backgroundOption
        self.backgroundHex = backgroundHex
        self.textOption = textOption
        self.textHex = textHex
    }

    /// A stable key so the web view is recreated when the style changes.
    public var identity: String {
        "\(font.rawValue)-\(fontSize)-\(lineHeight)-\(letterSpacing)-\(backgroundOption.rawValue)-\(backgroundHex)-\(textOption.rawValue)-\(textHex)"
    }

    public var backgroundCSS: String { backgroundOption == .automatic ? "Canvas" : backgroundHex }
    public var textCSS: String { textOption == .automatic ? "CanvasText" : textHex }
    public var secondaryTextCSS: String {
        textOption == .automatic
            ? "color-mix(in srgb, CanvasText 65%, transparent)"
            : "color-mix(in srgb, \(textHex) 65%, transparent)"
    }
}

// MARK: - Color hex helpers

extension Color {
    public init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: Double
        if cleaned.count == 6 {
            r = Double((value & 0xFF0000) >> 16) / 255
            g = Double((value & 0x00FF00) >> 8) / 255
            b = Double(value & 0x0000FF) / 255
        } else {
            r = 1; g = 1; b = 1
        }
        self = Color(.sRGB, red: r, green: g, blue: b)
    }

    public var hexString: String {
        #if canImport(AppKit)
        let native = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int((native.redComponent * 255).rounded())
        let g = Int((native.greenComponent * 255).rounded())
        let b = Int((native.blueComponent * 255).rounded())
        #else
        var rc: CGFloat = 0, gc: CGFloat = 0, bc: CGFloat = 0, ac: CGFloat = 0
        UIColor(self).getRed(&rc, green: &gc, blue: &bc, alpha: &ac)
        let r = Int((rc * 255).rounded())
        let g = Int((gc * 255).rounded())
        let b = Int((bc * 255).rounded())
        #endif
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
