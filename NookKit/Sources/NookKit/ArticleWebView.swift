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
    /// When true, translate the page's text in place into `translationLanguage`.
    let translate: Bool
    /// The English name of the target language (e.g. "Korean") for translation.
    let translationLanguage: String
    /// Reports when in-place translation is running so the UI can show progress.
    var onTranslatingChange: (Bool) -> Void
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
        translate: Bool = false,
        translationLanguage: String = "",
        onTranslatingChange: @escaping (Bool) -> Void = { _ in },
        onOverscroll: @escaping (CGFloat) -> Void = { _ in },
        onOverscrollEnded: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.url = url
        self.useReaderMode = useReaderMode
        self.style = style
        self.linkOpensInApp = linkOpensInApp
        self.translate = translate
        self.translationLanguage = translationLanguage
        self.onTranslatingChange = onTranslatingChange
        self.onOverscroll = onOverscroll
        self.onOverscrollEnded = onOverscrollEnded
    }

    @MainActor
    func makeConfiguration(coordinator: Coordinator) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // Reuse the process pool warmed at launch so the first article opens
        // without WebKit's cold-start delay.
        configuration.processPool = WebViewWarmer.processPool
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
        context.coordinator.webView = webView
        context.coordinator.onTranslatingChange = onTranslatingChange
        context.coordinator.applyTranslation(translate: translate, languageName: translationLanguage)
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
        context.coordinator.webView = webView
        context.coordinator.onTranslatingChange = onTranslatingChange
        context.coordinator.applyTranslation(translate: translate, languageName: translationLanguage)
    }

    public static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "nookScroll")
    }
}
#endif

// MARK: - Coordinator

extension ArticleWebView {
    public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, @unchecked Sendable {
        var linkOpensInApp: Bool
        var onOverscroll: (CGFloat) -> Void
        var onOverscrollEnded: (CGFloat) -> Void
        var onTranslatingChange: (Bool) -> Void = { _ in }

        weak var webView: WKWebView?
        private var atTop = true

        // In-place translation state.
        private var translationApplied = false
        private var translationInFlight = false
        private var wantsTranslation = false
        private var translationLanguage = ""

        #if canImport(AppKit)
        private var monitor: Any?
        private var overscroll: CGFloat = 0
        private var engaged = false
        #endif

        init(linkOpensInApp: Bool, onOverscroll: @escaping (CGFloat) -> Void, onOverscrollEnded: @escaping (CGFloat) -> Void) {
            self.linkOpensInApp = linkOpensInApp
            self.onOverscroll = onOverscroll
            self.onOverscrollEnded = onOverscrollEnded
        }

        // MARK: Translation

        /// Applies or removes in-place translation of the page content. Runs the
        /// translation once per toggle-on; toggling off reloads the original.
        @MainActor
        func applyTranslation(translate: Bool, languageName: String) {
            translationLanguage = languageName
            if translate {
                wantsTranslation = true
                runTranslationIfNeeded()
            } else {
                wantsTranslation = false
                if translationApplied {
                    translationApplied = false
                    webView?.reload()
                }
            }
        }

        /// Translates once the page is loaded; safe to call repeatedly (guards
        /// against re-entry and re-translation).
        @MainActor
        private func runTranslationIfNeeded() {
            guard wantsTranslation, !translationApplied, !translationInFlight,
                  !translationLanguage.isEmpty, let webView else { return }
            translationInFlight = true
            onTranslatingChange(true)
            collectAndTranslate(webView, languageName: translationLanguage)
        }

        @MainActor
        private func collectAndTranslate(_ webView: WKWebView, languageName: String) {
            webView.evaluateJavaScript(Self.collectTextScript) { [weak self] result, _ in
                guard let self else { return }
                guard let text = (result as? String), !text.isEmpty else {
                    self.translationInFlight = false
                    self.onTranslatingChange(false)
                    return
                }
                Task { [weak self] in
                    let translated = try? await NaturalTranslator.translate(text, into: languageName)
                    await MainActor.run {
                        guard let self else { return }
                        self.translationInFlight = false
                        self.onTranslatingChange(false)
                        guard let translated, !translated.isEmpty, let webView = self.webView else { return }
                        webView.evaluateJavaScript(Self.injectTranslationScript(translated))
                        self.translationApplied = true
                    }
                }
            }
        }

        /// Collects the main content's block text, joined by blank lines.
        private static let collectTextScript = """
        (function () {
          var root = document.querySelector('#nook-reader') || document.body;
          var nodes = root.querySelectorAll('p, h1, h2, h3, h4, h5, h6, li, blockquote, figcaption');
          var parts = [];
          nodes.forEach(function (n) {
            var t = (n.innerText || '').trim();
            if (t) parts.push(t);
          });
          if (parts.length === 0) {
            var all = (root.innerText || '').trim();
            if (all) parts.push(all);
          }
          return parts.join('\\n\\n');
        })();
        """

        /// Rebuilds the main content as translated paragraphs, keeping the
        /// reader styling. Returns the JS to run.
        private static func injectTranslationScript(_ translated: String) -> String {
            let json: String
            if let data = try? JSONSerialization.data(withJSONObject: translated, options: [.fragmentsAllowed]),
               let string = String(data: data, encoding: .utf8) {
                json = string
            } else {
                json = "\"\""
            }
            return """
            (function () {
              var root = document.querySelector('#nook-reader') || document.body;
              var text = \(json);
              var parts = text.split('\\n\\n');
              function esc(s) { return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
              root.innerHTML = parts.map(function (p) {
                return '<p style="margin:0 0 1.1em; line-height:1.7;">' + esc(p) + '</p>';
              }).join('');
            })();
            """
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

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Translate after the page (and reader script) has loaded, if the
            // user toggled translation on.
            runTranslationIfNeeded()
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "nookScroll" else { return }
            let top = (message.body as? NSNumber)?.doubleValue ?? 0
            atTop = top <= 0.5
        }
    }
}
