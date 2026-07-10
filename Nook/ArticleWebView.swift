import SwiftUI
import WebKit

/// An in-app reader-mode web view. It loads the article page in a WKWebView,
/// injects Mozilla's Readability.js, and re-renders the parsed article in a
/// clean, theme-aware layout.
///
/// This is the one deliberate exception to Nook's otherwise web-view-free,
/// native UI: an opt-in full-article reader the user invokes from the title.
struct ArticleWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController

        // Mozilla Readability.js defines a global `Readability`; inject it
        // first so the reader script below can use it.
        if let readabilitySource = Self.readabilitySource {
            controller.addUserScript(WKUserScript(source: readabilitySource, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        controller.addUserScript(WKUserScript(source: Self.readerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    private static let readabilitySource: String? = {
        guard let url = Bundle.main.url(forResource: "Readability", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    /// Parses the page with Readability and rebuilds it with a clean,
    /// `color-scheme`-aware layout. Leaves the original page in place when
    /// parsing fails.
    private static let readerScript = """
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
          'html, body { margin: 0; padding: 0; background: Canvas; color: CanvasText; }',
          '#nook-reader { max-width: 720px; margin: 0 auto; padding: 44px 28px 96px; font-family: -apple-system, system-ui, sans-serif; font-size: 18px; line-height: 1.7; }',
          '#nook-reader h1 { font-size: 30px; line-height: 1.25; font-weight: 700; margin: 0 0 12px; }',
          '#nook-reader .nook-byline { color: color-mix(in srgb, CanvasText 60%, transparent); margin: 0 0 24px; font-size: 15px; }',
          '#nook-reader h2, #nook-reader h3 { line-height: 1.3; margin: 1.6em 0 0.6em; }',
          '#nook-reader p { margin: 0 0 1.1em; }',
          '#nook-reader img, #nook-reader video, #nook-reader figure { max-width: 100%; height: auto; border-radius: 6px; }',
          '#nook-reader figure { margin: 1.4em 0; }',
          '#nook-reader figcaption { font-size: 14px; color: color-mix(in srgb, CanvasText 60%, transparent); }',
          '#nook-reader a { color: LinkText; }',
          '#nook-reader pre { overflow-x: auto; background: color-mix(in srgb, CanvasText 8%, transparent); padding: 12px; border-radius: 6px; }',
          '#nook-reader code { font-family: ui-monospace, monospace; }',
          '#nook-reader blockquote { margin: 0 0 1.1em; padding-left: 16px; border-left: 3px solid color-mix(in srgb, CanvasText 25%, transparent); color: color-mix(in srgb, CanvasText 72%, transparent); }'
        ].join('\\n');
        document.head.appendChild(style);
      } catch (error) {
        /* Leave the original page in place if extraction fails. */
      }
    })();
    """
}
