import SwiftUI
import WebKit

// MARK: - Reader configuration

enum ReaderViewMode: String, CaseIterable, Identifiable {
    case reader
    case original
    var id: String { rawValue }
    var label: String {
        switch self {
        case .reader: String(localized: "Reader Mode")
        case .original: String(localized: "Original Page")
        }
    }
}

enum ReaderLinkBehavior: String, CaseIterable, Identifiable {
    case inApp
    case external
    var id: String { rawValue }
    var label: String {
        switch self {
        case .inApp: String(localized: "Open in Nook")
        case .external: String(localized: "Open in Browser")
        }
    }
}

enum ReaderFont: String, CaseIterable, Identifiable {
    case system
    case serif
    case monospaced
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .serif: String(localized: "Serif")
        case .monospaced: String(localized: "Monospaced")
        }
    }
    var cssFamily: String {
        switch self {
        case .system: "-apple-system, system-ui, sans-serif"
        case .serif: "ui-serif, Georgia, 'Times New Roman', serif"
        case .monospaced: "ui-monospace, SFMono-Regular, Menlo, monospace"
        }
    }
}

enum ReaderColorOption: String, CaseIterable, Identifiable {
    case automatic
    case custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: String(localized: "Match Appearance")
        case .custom: String(localized: "Custom")
        }
    }
}

/// The typography/appearance used when rendering an article in reader mode.
struct ReaderStyle: Equatable {
    var font: ReaderFont = .system
    var fontSize: Int = 18
    var lineHeight: Double = 1.7
    var letterSpacing: Double = 0
    var backgroundOption: ReaderColorOption = .automatic
    var backgroundHex: String = "#FFFFFF"
    var textOption: ReaderColorOption = .automatic
    var textHex: String = "#1A1A1A"

    /// A stable key so the web view is recreated when the style changes.
    var identity: String {
        "\(font.rawValue)-\(fontSize)-\(lineHeight)-\(letterSpacing)-\(backgroundOption.rawValue)-\(backgroundHex)-\(textOption.rawValue)-\(textHex)"
    }

    var backgroundCSS: String { backgroundOption == .automatic ? "Canvas" : backgroundHex }
    var textCSS: String { textOption == .automatic ? "CanvasText" : textHex }
    var secondaryTextCSS: String {
        textOption == .automatic
            ? "color-mix(in srgb, CanvasText 65%, transparent)"
            : "color-mix(in srgb, \(textHex) 65%, transparent)"
    }
}

// MARK: - Web view

/// The in-app browser. Renders either a Readability.js reader view (styled by
/// `style`) or the original page, and routes link clicks in-app or externally.
struct ArticleWebView: NSViewRepresentable {
    let url: URL
    let useReaderMode: Bool
    let style: ReaderStyle
    let linkOpensInApp: Bool
    /// Live overscroll amount while pulling down at the top (sheet follows).
    var onOverscroll: (CGFloat) -> Void = { _ in }
    /// The gesture ended with the given overscroll amount (decide dismiss/snap).
    var onOverscrollEnded: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(linkOpensInApp: linkOpensInApp, onOverscroll: onOverscroll, onOverscrollEnded: onOverscrollEnded)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController

        if useReaderMode {
            if let readabilitySource = Self.readabilitySource {
                controller.addUserScript(WKUserScript(source: readabilitySource, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
            controller.addUserScript(WKUserScript(source: readerScript(style: style), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        controller.add(context.coordinator, name: "nookScroll")
        controller.addUserScript(WKUserScript(source: Self.scrollReportScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(to: webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.linkOpensInApp = linkOpensInApp
        context.coordinator.onOverscroll = onOverscroll
        context.coordinator.onOverscrollEnded = onOverscrollEnded
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "nookScroll")
    }

    /// Reports the page's scroll position so the native layer knows when the
    /// content is at the very top.
    private static let scrollReportScript = """
    (function () {
      function report() {
        var top = window.scrollY || document.documentElement.scrollTop || 0;
        try { window.webkit.messageHandlers.nookScroll.postMessage(top); } catch (e) {}
      }
      window.addEventListener('scroll', report, { passive: true });
      report();
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var linkOpensInApp: Bool
        var onOverscroll: (CGFloat) -> Void
        var onOverscrollEnded: (CGFloat) -> Void

        private weak var webView: WKWebView?
        private var monitor: Any?
        private var atTop = true
        private var overscroll: CGFloat = 0
        private var engaged = false

        init(linkOpensInApp: Bool, onOverscroll: @escaping (CGFloat) -> Void, onOverscrollEnded: @escaping (CGFloat) -> Void) {
            self.linkOpensInApp = linkOpensInApp
            self.onOverscroll = onOverscroll
            self.onOverscrollEnded = onOverscrollEnded
        }

        func attach(to webView: WKWebView) {
            self.webView = webView
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Returns true to consume the event (we are driving the sheet).
        private func handle(_ event: NSEvent) -> Bool {
            guard let webView, event.window === webView.window else { return false }
            let point = webView.convert(event.locationInWindow, from: nil)
            guard webView.bounds.contains(point) else { return false }

            // Positive scrollingDeltaY at the top means pulling the page down
            // (natural scrolling), i.e. an overscroll that should move the sheet.
            let delta = event.scrollingDeltaY

            if !engaged {
                guard atTop, delta > 0, event.momentumPhase == [] else { return false }
                engaged = true
            }

            overscroll = max(0, overscroll + delta)
            onOverscroll(overscroll)

            let finished = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            if finished || overscroll == 0 {
                let amount = overscroll
                engaged = false
                overscroll = 0
                onOverscrollEnded(amount)
            }
            return true
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only user-clicked links are subject to the in-app/external choice;
            // the initial article load always proceeds in-app.
            if navigationAction.navigationType == .linkActivated,
               !linkOpensInApp,
               let target = navigationAction.request.url {
                NSWorkspace.shared.open(target)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "nookScroll" else { return }
            let top = (message.body as? NSNumber)?.doubleValue ?? 0
            atTop = top <= 0.5
        }
    }

    private static let readabilitySource: String? = {
        guard let url = Bundle.main.url(forResource: "Readability", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private func readerScript(style: ReaderStyle) -> String {
        """
        (function () {
          try {
            if (typeof Readability === 'undefined') { return; }
            function esc(s) { return (s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }

            var article = new Readability(document.cloneNode(true)).parse();
            if (!article || !article.content) { return; }

            var titleHTML = article.title ? '<h1>' + esc(article.title) + '</h1>' : '';
            var bylineHTML = article.byline ? '<p class="nook-byline">' + esc(article.byline) + '</p>' : '';

            document.head.innerHTML = '<meta name="viewport" content="width=device-width, initial-scale=1">';
            document.body.innerHTML = '<div id="nook-reader">' + titleHTML + bylineHTML + article.content + '</div>';

            var style = document.createElement('style');
            style.textContent = [
              ':root { color-scheme: light dark; }',
              'html, body { margin: 0; padding: 0; background: \(style.backgroundCSS); color: \(style.textCSS); }',
              '#nook-reader { max-width: 720px; margin: 0 auto; padding: 44px 28px 96px; font-family: \(style.font.cssFamily); font-size: \(style.fontSize)px; line-height: \(style.lineHeight); letter-spacing: \(style.letterSpacing)em; }',
              '#nook-reader h1 { font-size: 1.7em; line-height: 1.25; font-weight: 700; margin: 0 0 12px; letter-spacing: normal; }',
              '#nook-reader .nook-byline { color: \(style.secondaryTextCSS); margin: 0 0 24px; font-size: 0.85em; }',
              '#nook-reader h2, #nook-reader h3 { line-height: 1.3; margin: 1.6em 0 0.6em; }',
              '#nook-reader p { margin: 0 0 1.1em; }',
              '#nook-reader img, #nook-reader video, #nook-reader figure { max-width: 100%; height: auto; border-radius: 6px; }',
              '#nook-reader figure { margin: 1.4em 0; }',
              '#nook-reader figcaption { font-size: 0.8em; color: \(style.secondaryTextCSS); }',
              '#nook-reader a { color: LinkText; }',
              '#nook-reader pre { overflow-x: auto; background: color-mix(in srgb, \(style.textCSS) 8%, transparent); padding: 12px; border-radius: 6px; }',
              '#nook-reader code { font-family: ui-monospace, monospace; }',
              '#nook-reader blockquote { margin: 0 0 1.1em; padding-left: 16px; border-left: 3px solid color-mix(in srgb, \(style.textCSS) 25%, transparent); color: \(style.secondaryTextCSS); }'
            ].join('\\n');
            document.head.appendChild(style);
          } catch (error) {
            /* Leave the original page in place if extraction fails. */
          }
        })();
        """
    }
}

// MARK: - Color hex helpers

extension Color {
    init(hex: String) {
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

    var hexString: String {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int((nsColor.redComponent * 255).rounded())
        let g = Int((nsColor.greenComponent * 255).rounded())
        let b = Int((nsColor.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
