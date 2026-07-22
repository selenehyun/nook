import WebKit

/// Warms up WebKit so the first article web view opens instantly.
///
/// Creating the first `WKWebView` cold-starts WebKit's WebContent, networking,
/// and GPU processes, which takes ~2-3s; every web view after that is instant
/// because the processes are already running. Calling `warmUp()` at launch
/// pays that cost off the critical path (before the user taps), and sharing
/// `processPool` means the real reader reuses the warmed processes.
@MainActor
public enum WebViewWarmer {
    /// Shared so the warmed web content process is reused by the reader.
    public static let processPool = WKProcessPool()

    /// The persistent, shared website data store used by every in-app web view
    /// (reader/original, warmer, reader-mode extractor). Persistent so cookies and
    /// localStorage — i.e. logged-in sessions — survive across launches, and
    /// shared so a login in one web view is seen by the others.
    public static let dataStore = WKWebsiteDataStore.default()

    private static var warmView: WKWebView?

    /// Creates a hidden web view once to spin up WebKit's processes. Idempotent.
    public static func warmUp() {
        guard warmView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // A trivial load is enough to launch the WebContent/networking processes.
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        warmView = webView
    }
}
