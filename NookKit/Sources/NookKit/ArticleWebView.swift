import SwiftUI
import WebKit

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The in-app browser. Renders either a Readability.js reader view (styled by
/// `style`) or the original page, and routes link clicks in-app or externally.
///
/// Cross-platform: an `NSViewRepresentable` on macOS and a `UIViewRepresentable`
/// on iOS. The reader-script generation and Readability source are shared; only
/// the view wrapper, link-opening, and overscroll handling differ.
public struct ArticleWebView {
    let url: URL
    let useReaderMode: Bool
    let style: ReaderStyle
    let linkOpensInApp: Bool
    /// Live overscroll amount while pulling down at the top (sheet follows).
    /// macOS only; ignored on iOS where the sheet has native drag-to-dismiss.
    var onOverscroll: (CGFloat) -> Void
    /// The gesture ended with the given overscroll amount (decide dismiss/snap).
    var onOverscrollEnded: (CGFloat) -> Void

    public init(
        url: URL,
        useReaderMode: Bool,
        style: ReaderStyle,
        linkOpensInApp: Bool,
        onOverscroll: @escaping (CGFloat) -> Void = { _ in },
        onOverscrollEnded: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.url = url
        self.useReaderMode = useReaderMode
        self.style = style
        self.linkOpensInApp = linkOpensInApp
        self.onOverscroll = onOverscroll
        self.onOverscrollEnded = onOverscrollEnded
    }

    func makeConfiguration(coordinator: Coordinator) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController

        if useReaderMode {
            if let readabilitySource = Self.readabilitySource {
                controller.addUserScript(WKUserScript(source: readabilitySource, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
            controller.addUserScript(WKUserScript(source: readerScript(style: style), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        controller.add(coordinator, name: "nookScroll")
        controller.addUserScript(WKUserScript(source: Self.scrollReportScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return configuration
    }

    /// Reports the page's scroll position so the native layer knows when the
    /// content is at the very top.
    static let scrollReportScript = """
    (function () {
      function report() {
        var top = window.scrollY || document.documentElement.scrollTop || 0;
        try { window.webkit.messageHandlers.nookScroll.postMessage(top); } catch (e) {}
      }
      window.addEventListener('scroll', report, { passive: true });
      report();
    })();
    """

    static let readabilitySource: String? = {
        guard let url = Bundle.module.url(forResource: "Readability", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    func readerScript(style: ReaderStyle) -> String {
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

// MARK: - macOS

#if canImport(AppKit)
extension ArticleWebView: NSViewRepresentable {
    public func makeCoordinator() -> Coordinator {
        Coordinator(linkOpensInApp: linkOpensInApp, onOverscroll: onOverscroll, onOverscrollEnded: onOverscrollEnded)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeConfiguration(coordinator: context.coordinator))
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(to: webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.linkOpensInApp = linkOpensInApp
        context.coordinator.onOverscroll = onOverscroll
        context.coordinator.onOverscrollEnded = onOverscrollEnded
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "nookScroll")
    }
}
#endif

// MARK: - iOS

#if canImport(UIKit)
extension ArticleWebView: UIViewRepresentable {
    public func makeCoordinator() -> Coordinator {
        Coordinator(linkOpensInApp: linkOpensInApp, onOverscroll: onOverscroll, onOverscrollEnded: onOverscrollEnded)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: makeConfiguration(coordinator: context.coordinator))
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.linkOpensInApp = linkOpensInApp
    }

    public static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "nookScroll")
    }
}
#endif

// MARK: - Coordinator

extension ArticleWebView {
    public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var linkOpensInApp: Bool
        var onOverscroll: (CGFloat) -> Void
        var onOverscrollEnded: (CGFloat) -> Void

        private var atTop = true

        #if canImport(AppKit)
        private weak var webView: WKWebView?
        private var monitor: Any?
        private var overscroll: CGFloat = 0
        private var engaged = false
        #endif

        init(linkOpensInApp: Bool, onOverscroll: @escaping (CGFloat) -> Void, onOverscrollEnded: @escaping (CGFloat) -> Void) {
            self.linkOpensInApp = linkOpensInApp
            self.onOverscroll = onOverscroll
            self.onOverscrollEnded = onOverscrollEnded
        }

        #if canImport(AppKit)
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
            guard let webView else { return false }

            // Positive scrollingDeltaY at the top means pulling the page down
            // (natural scrolling), i.e. an overscroll that should move the sheet.
            let delta = event.scrollingDeltaY

            if !engaged {
                // Engage only when starting a top overscroll over the web view.
                guard atTop, delta > 0, event.momentumPhase == [],
                      event.window === webView.window,
                      webView.bounds.contains(webView.convert(event.locationInWindow, from: nil)) else {
                    return false
                }
                engaged = true
                overscroll = 0
            }

            // Once engaged, keep driving the sheet regardless of where the
            // pointer is (the sheet slides out from under it).
            overscroll = max(0, overscroll + delta)
            onOverscroll(overscroll)

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                let amount = overscroll
                engaged = false
                overscroll = 0
                onOverscrollEnded(amount)
                return true
            }

            if overscroll == 0 {
                // Pulled back to the top: hand scrolling back to the web view.
                engaged = false
                return false
            }

            return true
        }
        #endif

        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only user-clicked links are subject to the in-app/external choice;
            // the initial article load always proceeds in-app.
            if navigationAction.navigationType == .linkActivated,
               !linkOpensInApp,
               let target = navigationAction.request.url {
                #if canImport(AppKit)
                NSWorkspace.shared.open(target)
                #elseif canImport(UIKit)
                UIApplication.shared.open(target)
                #endif
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "nookScroll" else { return }
            let top = (message.body as? NSNumber)?.doubleValue ?? 0
            atTop = top <= 0.5
        }
    }
}
