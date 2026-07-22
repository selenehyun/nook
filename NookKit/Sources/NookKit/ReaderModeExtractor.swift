import Foundation
import WebKit

/// Extracts reader-mode content from an article page headlessly, using the exact
/// same Readability.js algorithm and media handling as the in-app WKWebView
/// reader (`ArticleWebView`) so the native reader shows the same result.
///
/// Readability needs a live DOM, so this loads the page in an offscreen
/// `WKWebView` (reusing the warmed process pool), injects Readability plus a
/// small extraction script, and returns the cleaned content HTML. The native
/// renderer (`HTMLContentView`) then turns that HTML into native views.
@MainActor
public final class ReaderModeExtractor {
    public init() {}

    /// The result of an extraction attempt.
    public enum Outcome: Sendable {
        /// Reader content HTML was extracted.
        case success(String)
        /// The original page is gone (HTTP 404/410) — the article can be deleted.
        case gone
        /// Extraction failed for another reason (no article found, load error, timeout).
        case failed
    }

    /// Loads `url`, runs Readability, and returns the extracted content — or a
    /// `.gone`/`.failed` outcome so the caller can distinguish a removed page
    /// (offer deletion) from a transient failure (offer retry).
    public func extract(url: URL, timeout: TimeInterval = 15) async -> Outcome {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .failed
        }
        return await withCheckedContinuation { continuation in
            var session: ExtractionSession!
            session = ExtractionSession(url: url, timeout: timeout) { [weak self] outcome in
                self?.retain.remove(session)
                continuation.resume(returning: outcome)
            }
            retain.insert(session)
            session.start()
        }
    }

    // Sessions are retained for their lifetime (they own an offscreen web view)
    // and released when they finish. Overlapping extractions (rapid navigation)
    // each keep their own session, so a new one never cancels an older one.
    private var retain: Set<ExtractionSession> = []
}

/// One offscreen extraction. Owns its web view + delegates and calls `onFinish`
/// exactly once (success, failure, or timeout), then tears everything down.
@MainActor
private final class ExtractionSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let url: URL
    private let timeout: TimeInterval
    // Optional so it can be released after firing, breaking the session↔closure
    // retain cycle (the completion captures the session to deregister it).
    private var onFinish: ((ReaderModeExtractor.Outcome) -> Void)?
    private var webView: WKWebView?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    init(url: URL, timeout: TimeInterval, onFinish: @escaping (ReaderModeExtractor.Outcome) -> Void) {
        self.url = url
        self.timeout = timeout
        self.onFinish = onFinish
    }

    func start() {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = WebViewWarmer.processPool
        let controller = configuration.userContentController
        if let readability = ArticleWebView.readabilitySource {
            controller.addUserScript(WKUserScript(source: readability, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        controller.addUserScript(WKUserScript(source: Self.extractionScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.add(self, name: "nookExtract")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // A non-zero frame so pages that gate content on a viewport still lay out
        // and expose their article body to Readability, even though this web view
        // is never shown.
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1024), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.timeout ?? 15))
            self?.finish(.failed)
        }
        webView.load(URLRequest(url: url))
    }

    private func finish(_ outcome: ReaderModeExtractor.Outcome) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "nookExtract")
            webView.configuration.userContentController.removeAllUserScripts()
        }
        webView = nil
        let callback = onFinish
        onFinish = nil
        callback?(outcome)
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "nookExtract" else { return }
        if let body = message.body as? [String: Any],
           (body["ok"] as? NSNumber)?.boolValue == true,
           let content = body["content"] as? String,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finish(.success(content))
        } else {
            finish(.failed)
        }
    }

    // MARK: WKNavigationDelegate

    /// Inspect the main-frame response status: a 404/410 means the original is
    /// gone, so report `.gone` (the reader offers deletion) instead of loading the
    /// server's error page and trying to extract from it.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse,
           http.statusCode == 404 || http.statusCode == 410 {
            decisionHandler(.cancel)
            finish(.gone)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failed)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failed)
    }

    /// Runs after the page settles. Mirrors `ArticleWebView`'s reader extraction
    /// — same Readability options, same embed allowlist, same media
    /// normalization — but instead of rewriting the DOM it posts the cleaned
    /// content HTML back to native. Retries briefly for script-heavy pages.
    static let extractionScript = """
    (function () {
      var attempts = 0;
      var originalURL = document.baseURI;

      function normalizeMedia(root) {
        root.querySelectorAll('img').forEach(function (img) {
          if (!img.getAttribute('src')) {
            var lazy = img.getAttribute('data-src') || img.getAttribute('data-lazy-src');
            if (lazy) img.setAttribute('src', lazy);
          }
        });
        root.querySelectorAll('img, iframe, video, source').forEach(function (media) {
          var src = media.getAttribute('src') || media.getAttribute('data-src');
          if (src) {
            try { media.setAttribute('src', new URL(src, originalURL).href); } catch (_) {}
          }
        });
      }

      function extractedArticle() {
        if (typeof Readability !== 'undefined') {
          var clone = document.cloneNode(true);
          normalizeMedia(clone);
          var allowedEmbeds = /\\/\\/(www\\.)?((dailymotion|youtube|youtube-nocookie|player\\.vimeo|v\\.qq|codepen)\\.(com|io)|(archive|upload\\.wikimedia)\\.org|player\\.twitch\\.tv)/i;
          var parsed = new Readability(clone, { allowedVideoRegex: allowedEmbeds }).parse();
          if (parsed && parsed.content && parsed.textContent && parsed.textContent.trim().length > 80) {
            return parsed;
          }
        }
        var fallback = document.querySelector('article .article-content, article [itemprop="articleBody"], article, main');
        if (!fallback || (fallback.innerText || '').trim().length < 80) return null;
        var content = fallback.cloneNode(true);
        normalizeMedia(content);
        return {
          title: document.querySelector('h1') ? document.querySelector('h1').textContent.trim() : document.title,
          byline: '',
          content: content.innerHTML
        };
      }

      function done(payload) {
        try { window.webkit.messageHandlers.nookExtract.postMessage(payload); } catch (e) {}
      }

      function run() {
        try {
          var article = extractedArticle();
          if (!article) {
            attempts += 1;
            if (attempts < 3) { setTimeout(run, attempts * 300); return; }
            done({ ok: false });
            return;
          }
          done({ ok: true, title: article.title || '', byline: article.byline || '', content: article.content || '' });
        } catch (error) {
          done({ ok: false });
        }
      }

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', run, { once: true });
      } else {
        setTimeout(run, 0);
      }
    })();
    """
}
