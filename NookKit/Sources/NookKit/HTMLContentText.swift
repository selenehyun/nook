import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Renders a fragment of trusted feed HTML as native, selectable text. Replaces
/// the HTML importer's default fonts with the system font (preserving
/// bold/italic) and adapts non-link text to light/dark appearance.
public struct HTMLContentText: View {
    let html: String
    let selectable: Bool
    @State private var attributed: AttributedString?

    public init(html: String, selectable: Bool = true) {
        self.html = html
        self.selectable = selectable
    }

    public var body: some View {
        Group {
            if let attributed {
                let text = Text(attributed).lineSpacing(4).tint(.accentColor)
                if selectable {
                    text.textSelection(.enabled)
                } else {
                    text.textSelection(.disabled)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: html) {
            attributed = Self.render(html)
        }
    }

    private static func render(_ html: String) -> AttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let mutable = try? NSMutableAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }

        let fullRange = NSRange(location: 0, length: mutable.length)

        #if canImport(AppKit)
        let baseSize = NSFont.preferredFont(forTextStyle: .body).pointSize

        // Replace the HTML importer's default fonts with the system font while
        // preserving bold/italic emphasis.
        mutable.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            let existingTraits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var traits: NSFontDescriptor.SymbolicTraits = []
            if existingTraits.contains(.bold) { traits.insert(.bold) }
            if existingTraits.contains(.italic) { traits.insert(.italic) }
            let descriptor = NSFont.systemFont(ofSize: baseSize).fontDescriptor.withSymbolicTraits(traits)
            let font = NSFont(descriptor: descriptor, size: baseSize) ?? NSFont.systemFont(ofSize: baseSize)
            mutable.addAttribute(.font, value: font, range: range)
        }

        // Keep link runs their own color; make everything else adapt to light/dark.
        mutable.enumerateAttribute(.link, in: fullRange, options: []) { link, range, _ in
            if link == nil {
                mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }

        return try? AttributedString(mutable, including: \.appKit)
        #else
        let baseSize = UIFont.preferredFont(forTextStyle: .body).pointSize

        mutable.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            let existingTraits = (value as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            var traits: UIFontDescriptor.SymbolicTraits = []
            if existingTraits.contains(.traitBold) { traits.insert(.traitBold) }
            if existingTraits.contains(.traitItalic) { traits.insert(.traitItalic) }
            let base = UIFont.systemFont(ofSize: baseSize)
            let descriptor = base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor
            let font = UIFont(descriptor: descriptor, size: baseSize)
            mutable.addAttribute(.font, value: font, range: range)
        }

        mutable.enumerateAttribute(.link, in: fullRange, options: []) { link, range, _ in
            if link == nil {
                mutable.addAttribute(.foregroundColor, value: UIColor.label, range: range)
            }
        }

        return try? AttributedString(mutable, including: \.uiKit)
        #endif
    }
}
