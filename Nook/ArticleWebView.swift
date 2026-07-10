import SwiftUI
import WebKit

/// An in-app reader-mode web view. It loads the article page in a WKWebView
/// and injects a self-contained reader script that isolates the main content
/// and restyles it for comfortable, theme-aware reading.
///
/// This is the one deliberate exception to Nook's otherwise web-view-free,
/// native UI: an opt-in full-article reader the user invokes from the title.
struct ArticleWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let readerScript = WKUserScript(
            source: Self.readerScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(readerScript)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    /// Reader-mode transform: pick the best semantic content container, strip
    /// chrome, and re-render it with a clean, `color-scheme`-aware layout.
    private static let readerScript = """
    (function () {
      try {
        function esc(s) { return (s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }

        function pick() {
          var selectors = ['article', 'main', '[role=main]'];
          for (var i = 0; i < selectors.length; i++) {
            var el = document.querySelector(selectors[i]);
            if (el && el.innerText && el.innerText.trim().length > 200) { return el; }
          }
          var best = null, bestLen = 0;
          document.querySelectorAll('div, section').forEach(function (el) {
            var len = 0;
            el.querySelectorAll('p').forEach(function (p) { len += p.innerText.length; });
            if (len > bestLen) { bestLen = len; best = el; }
          });
          return bestLen > 200 ? best : document.body;
        }

        var pageTitle = document.title || '';
        var node = pick();
        var clone = node.cloneNode(true);
        clone.querySelectorAll('script, style, noscript, nav, aside, header, footer, form, iframe, button, svg').forEach(function (e) { e.remove(); });

        var titleHTML = clone.querySelector('h1') ? '' : '<h1>' + esc(pageTitle) + '</h1>';
        var content = clone.innerHTML;

        document.head.innerHTML = '<meta name="viewport" content="width=device-width, initial-scale=1">';
        document.body.innerHTML = '<div id="nook-reader">' + titleHTML + content + '</div>';

        var style = document.createElement('style');
        style.textContent = [
          ':root { color-scheme: light dark; }',
          'html, body { margin: 0; padding: 0; background: Canvas; color: CanvasText; }',
          '#nook-reader { max-width: 720px; margin: 0 auto; padding: 44px 28px 96px; font-family: -apple-system, system-ui, sans-serif; font-size: 18px; line-height: 1.7; }',
          '#nook-reader h1 { font-size: 30px; line-height: 1.25; font-weight: 700; margin: 0 0 24px; }',
          '#nook-reader h2, #nook-reader h3 { line-height: 1.3; margin: 1.6em 0 0.6em; }',
          '#nook-reader p { margin: 0 0 1.1em; }',
          '#nook-reader img, #nook-reader video { max-width: 100%; height: auto; border-radius: 6px; }',
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
