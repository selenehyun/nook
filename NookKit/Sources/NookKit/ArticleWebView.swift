import QuartzCore
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
    /// Reports the page's estimated load progress (0...1) so the UI can show a
    /// loading bar. Fires 1.0 when a load finishes or fails.
    var onLoadingProgress: (Double) -> Void
    /// Live overscroll amount while pulling down at the top (sheet follows).
    /// macOS only; ignored on iOS where the sheet has native drag-to-dismiss.
    var onOverscroll: (CGFloat) -> Void
    /// The gesture ended with the given overscroll amount (decide dismiss/snap).
    var onOverscrollEnded: (CGFloat) -> Void
    /// Live overscroll amount while pulling up past the bottom of the page, so
    /// the UI can reveal a close / next-article affordance (both platforms).
    var onBottomOverscroll: (CGFloat) -> Void
    /// The bottom pull ended with the given amount (decide close/next/snap).
    var onBottomOverscrollEnded: (CGFloat) -> Void

    public init(
        url: URL,
        useReaderMode: Bool,
        style: ReaderStyle,
        linkOpensInApp: Bool,
        translate: Bool = false,
        translationLanguage: String = "",
        onTranslatingChange: @escaping (Bool) -> Void = { _ in },
        onLoadingProgress: @escaping (Double) -> Void = { _ in },
        onOverscroll: @escaping (CGFloat) -> Void = { _ in },
        onOverscrollEnded: @escaping (CGFloat) -> Void = { _ in },
        onBottomOverscroll: @escaping (CGFloat) -> Void = { _ in },
        onBottomOverscrollEnded: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.url = url
        self.useReaderMode = useReaderMode
        self.style = style
        self.linkOpensInApp = linkOpensInApp
        self.translate = translate
        self.translationLanguage = translationLanguage
        self.onTranslatingChange = onTranslatingChange
        self.onLoadingProgress = onLoadingProgress
        self.onOverscroll = onOverscroll
        self.onOverscrollEnded = onOverscrollEnded
        self.onBottomOverscroll = onBottomOverscroll
        self.onBottomOverscrollEnded = onBottomOverscrollEnded
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
    /// content is at the very top or bottom (used to drive the overscroll
    /// gestures that move the sheet).
    static let scrollReportScript = """
    (function () {
      function report() {
        var doc = document.documentElement;
        var top = window.scrollY || doc.scrollTop || 0;
        var scrollHeight = doc.scrollHeight || 0;
        var viewport = window.innerHeight || 0;
        var scrollable = (scrollHeight - viewport) > 4;
        var bottomGap = Math.max(0, scrollHeight - (top + viewport));
        try {
          window.webkit.messageHandlers.nookScroll.postMessage({ top: top, bottomGap: bottomGap, scrollable: scrollable });
        } catch (e) {}
      }
      window.addEventListener('scroll', report, { passive: true });
      window.addEventListener('resize', report, { passive: true });
      window.addEventListener('load', report, { passive: true });
      report();
      // Re-report once layout settles (reader content, images), so a long page
      // that momentarily measured as non-scrollable is corrected.
      setTimeout(report, 300);
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
        context.coordinator.onLoadingProgress = onLoadingProgress
        context.coordinator.attach(to: webView)
        context.coordinator.observeProgress(of: webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.linkOpensInApp = linkOpensInApp
        context.coordinator.onOverscroll = onOverscroll
        context.coordinator.onOverscrollEnded = onOverscrollEnded
        context.coordinator.onBottomOverscroll = onBottomOverscroll
        context.coordinator.onBottomOverscrollEnded = onBottomOverscrollEnded
        context.coordinator.webView = webView
        context.coordinator.onTranslatingChange = onTranslatingChange
        context.coordinator.onLoadingProgress = onLoadingProgress
        context.coordinator.applyTranslation(translate: translate, languageName: translationLanguage)
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
        coordinator.stopObservingProgress()
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
        // Bounce vertically even when the content fits, so a short (non-scrollable)
        // page can still be pulled up past its bottom to reveal the affordance.
        webView.scrollView.alwaysBounceVertical = true
        context.coordinator.onLoadingProgress = onLoadingProgress
        context.coordinator.onBottomOverscroll = onBottomOverscroll
        context.coordinator.onBottomOverscrollEnded = onBottomOverscrollEnded
        context.coordinator.observeProgress(of: webView)
        webView.scrollView.panGestureRecognizer.addTarget(context.coordinator, action: #selector(Coordinator.handleScrollPan(_:)))
        webView.load(URLRequest(url: url))
        return webView
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.linkOpensInApp = linkOpensInApp
        context.coordinator.webView = webView
        context.coordinator.onTranslatingChange = onTranslatingChange
        context.coordinator.onLoadingProgress = onLoadingProgress
        context.coordinator.onBottomOverscroll = onBottomOverscroll
        context.coordinator.onBottomOverscrollEnded = onBottomOverscrollEnded
        context.coordinator.applyTranslation(translate: translate, languageName: translationLanguage)
    }

    public static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObservingProgress()
        webView.scrollView.panGestureRecognizer.removeTarget(coordinator, action: #selector(Coordinator.handleScrollPan(_:)))
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
        var onLoadingProgress: (Double) -> Void = { _ in }
        var onBottomOverscroll: (CGFloat) -> Void = { _ in }
        var onBottomOverscrollEnded: (CGFloat) -> Void = { _ in }
        private var progressObservation: NSKeyValueObservation?

        weak var webView: WKWebView?
        private var atTop = true
        private var atBottom = false
        // Set once the page finishes loading. A genuinely short (non-scrollable)
        // page has no bottom to scroll to, so it only counts as "bottomed out"
        // — and thus pull-able — after load, never while a long page is still
        // laying out and momentarily measuring shorter than the viewport.
        private var hasFinishedLoading = false
        private var lastBottomGap: Double = .greatestFiniteMagnitude

        // Rate-limited "reported" bottom pull. The raw pull is speed-agnostic —
        // a short, hard flick piles up as much distance as a slow deliberate
        // drag — so instead of reporting it directly we ease a displayed value
        // up toward it at a capped rate (points/second). Crossing a threshold
        // then takes *sustained* pulling (~0.24s to close) rather than a fast
        // impulse, which makes the gesture far easier to control. Shrinking
        // (release or pull-back) is applied instantly so it still feels snappy.
        private var displayedBottomPull: CGFloat = 0
        private var lastBottomPullTime: CFTimeInterval = 0

        /// Eases `displayedBottomPull` toward `target`, capping how fast it may
        /// grow; shrinking is immediate. `now` is a monotonic timestamp.
        private func easedBottomPull(target: CGFloat, now: CFTimeInterval) -> CGFloat {
            let maxGrowthPerSecond: CGFloat = 700
            let dt = lastBottomPullTime == 0 ? (1.0 / 60.0) : min(0.1, max(0, now - lastBottomPullTime))
            lastBottomPullTime = now
            if target <= displayedBottomPull {
                displayedBottomPull = target
            } else {
                displayedBottomPull = min(target, displayedBottomPull + maxGrowthPerSecond * CGFloat(dt))
            }
            return displayedBottomPull
        }

        private func resetBottomEase() {
            displayedBottomPull = 0
            lastBottomPullTime = 0
        }

        // In-place translation state.
        private var translationApplied = false
        private var translationInFlight = false
        private var wantsTranslation = false
        private var translationLanguage = ""

        #if canImport(AppKit)
        private var monitor: Any?
        private var overscroll: CGFloat = 0
        private var engaged = false
        private var bottomOverscroll: CGFloat = 0
        private var bottomEngaged = false
        // Whether the current trackpad scroll gesture began already at the
        // bottom. A bottom pull only counts as deliberate when it starts from
        // rest at the end of the page — not when a hard scroll flings into it.
        private var gestureBeganAtBottom = false
        // macOS haptics for the bottom pull are performed here rather than via
        // SwiftUI's `.sensoryFeedback`, which doesn't reliably re-fire the
        // trackpad patterns on a repeated pull.
        private var hapticRatchetStep = 0
        private var hapticStageLevel = 0
        #endif

        #if canImport(UIKit)
        // Whether the current scroll-view drag began already at the bottom, so a
        // hard fling into the bottom doesn't count as a deliberate pull.
        private var panBeganAtBottom = false
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
        /// iOS-style rubber-band resistance: the pull grows ever more slowly,
        /// asymptotically approaching `limit`, so the harder you pull the less it
        /// moves. `softness` sets how much raw travel it takes to reach half of
        /// `limit` — larger means stronger resistance (decoupled from `limit` so
        /// the thresholds stay reachable). (iOS gets this for free from the
        /// scroll view's native bounce; macOS accumulates raw wheel deltas, so it
        /// needs the curve applied explicitly.)
        static func rubberBand(_ distance: CGFloat, limit: CGFloat = 420, softness: CGFloat = 700) -> CGFloat {
            guard distance > 0 else { return 0 }
            return limit * distance / (distance + softness)
        }

        // The scroll monitor is app-wide, so only the newest web view may drive
        // the gesture — otherwise the coordinator we navigated away from (still
        // holding `atBottom == true`) would hijack the next page's scrolling.
        static weak var activeMonitorOwner: Coordinator?

        func attach(to webView: WKWebView) {
            self.webView = webView
            Coordinator.activeMonitorOwner?.detach()
            Coordinator.activeMonitorOwner = self
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }

        func detach() {
            if Coordinator.activeMonitorOwner === self { Coordinator.activeMonitorOwner = nil }
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Returns true to consume the event (we are driving the sheet).
        ///
        /// Natural scrolling: a positive `scrollingDeltaY` pulls the page down
        /// (a top overscroll → move the sheet), a negative one pulls it up (a
        /// bottom overscroll → reveal the close / next-article affordance).
        private func handle(_ event: NSEvent) -> Bool {
            // A stale monitor from a previous article must never act.
            guard Coordinator.activeMonitorOwner === self else { return false }
            guard let webView, event.window === webView.window else { return false }
            let delta = event.scrollingDeltaY

            // Record, at the start of each trackpad gesture, whether it began
            // already at the bottom — so a hard scroll that flings into the
            // bottom (which began mid-page) can't trigger the pull.
            if event.phase.contains(.began) {
                gestureBeganAtBottom = atBottom
            }

            // Engage a fresh top- or bottom-overscroll gesture over the web view.
            if !engaged, !bottomEngaged {
                let overPointer = webView.bounds.contains(webView.convert(event.locationInWindow, from: nil))
                guard event.momentumPhase == [], overPointer else { return false }
                if atTop, delta > 0 {
                    engaged = true
                    overscroll = 0
                } else if atBottom, delta < 0, event.phase.isEmpty || gestureBeganAtBottom {
                    // A phased (trackpad) pull must have begun at the bottom; a
                    // phase-less mouse wheel scroll is discrete, so allow it.
                    bottomEngaged = true
                    bottomOverscroll = 0
                    resetBottomEase()
                    hapticRatchetStep = 0
                    hapticStageLevel = 0
                } else {
                    return false
                }
            }

            if engaged {
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

            // Bottom overscroll: accumulate the raw upward pull (negative delta),
            // rubber-band it for iOS-like resistance, then rate-limit its growth
            // so a hard flick can't slam straight past a threshold.
            bottomOverscroll = max(0, bottomOverscroll - delta)
            let reported = easedBottomPull(target: Self.rubberBand(bottomOverscroll), now: event.timestamp)
            onBottomOverscroll(reported)
            performBottomPullHaptics(reported: reported, rawPull: bottomOverscroll)
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                let amount = reported
                bottomEngaged = false
                bottomOverscroll = 0
                resetBottomEase()
                onBottomOverscrollEnded(amount)
                return true
            }
            if bottomOverscroll == 0 {
                bottomEngaged = false
                resetBottomEase()
                return false
            }
            return true
        }

        /// Trackpad haptics for the bottom pull, driven straight off the scroll
        /// so they respond to the drag and reliably re-fire on a repeated pull.
        /// `.levelChange` is the strongest pattern the Taptic Engine exposes on
        /// macOS. A firm tick marks crossing into the next / close stages; a
        /// lighter ratchet follows the scroll while still in the hint zone.
        private func performBottomPullHaptics(reported: CGFloat, rawPull: CGFloat) {
            let level = reported >= BottomPullAffordance.closeThreshold ? 2
                : (reported >= BottomPullAffordance.nextThreshold ? 1 : 0)
            if level > hapticStageLevel {
                performStrongTick(count: 3) // firm thunk on crossing a threshold
            }
            hapticStageLevel = level

            if level == 0 {
                let step = Int(rawPull / 30)
                if step > hapticRatchetStep {
                    performStrongTick(count: 2) // firmer ratchet following the scroll
                }
                hapticRatchetStep = step
            }
        }

        /// A stronger macOS tick. The Taptic Engine exposes no intensity control,
        /// so a rapid burst of `.levelChange` reads as one firmer bump than a
        /// single perform.
        private func performStrongTick(count: Int) {
            for i in 0..<max(1, count) {
                let delay = 0.03 * Double(i)
                if delay == 0 {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                    }
                }
            }
        }
        #endif

        #if canImport(UIKit)
        /// Drives the bottom-overscroll affordance from the web view's scroll
        /// view. Added as an extra target on the built-in pan recognizer (not a
        /// delegate), so it never interferes with WKWebView's own scrolling.
        @objc func handleScrollPan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            // A scrollable page can be pulled past its bottom; a short page has
            // no bottom to scroll to, so it only becomes pull-able once loaded
            // (a still-laying-out long page must not read as an instant pull).
            let scrollable = scrollView.contentSize.height > scrollView.bounds.height + 4
            let bottomReachable = scrollable || hasFinishedLoading
            // Clamp to the top resting offset so a short page's "bottom" is its
            // rest position (overscroll 0 at rest, positive only when pulled up).
            let maxOffset = max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            let overscroll = bottomReachable ? max(0, scrollView.contentOffset.y - maxOffset) : 0
            switch gesture.state {
            case .began:
                // The pull only counts if the drag starts from rest at the very
                // bottom — not when a fast scroll flings past it mid-drag.
                panBeganAtBottom = bottomReachable && scrollView.contentOffset.y >= maxOffset - 2
                resetBottomEase()
            case .changed:
                // Rate-limit the reported pull so a short, hard flick can't slam
                // past a threshold; only a sustained drag climbs.
                let target = panBeganAtBottom ? overscroll : 0
                onBottomOverscroll(easedBottomPull(target: target, now: CACurrentMediaTime()))
            case .ended, .cancelled, .failed:
                // Decide on the eased value, so a flick that never let it catch
                // up settles back instead of triggering.
                onBottomOverscrollEnded(panBeganAtBottom ? displayedBottomPull : 0)
                panBeganAtBottom = false
                resetBottomEase()
            default:
                break
            }
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

        /// Observes `estimatedProgress` (0...1) via KVO and forwards it so the UI
        /// can drive a loading bar. `change.newValue` is a plain `Double`, so the
        /// closure never touches the main-actor-isolated web view off-main.
        func observeProgress(of webView: WKWebView) {
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                guard let self, let progress = change.newValue else { return }
                Task { @MainActor in self.onLoadingProgress(progress) }
            }
        }

        func stopObservingProgress() {
            progressObservation?.invalidate()
            progressObservation = nil
        }

        public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // A new page starts at the top and hasn't reported its real height
            // yet; clear stale scroll/overscroll state so it isn't mistaken for
            // being at the bottom (which would trigger the pull gesture on the
            // first downward scroll).
            atTop = true
            atBottom = false
            hasFinishedLoading = false
            lastBottomGap = .greatestFiniteMagnitude
            resetBottomEase()
            #if canImport(AppKit)
            engaged = false
            bottomEngaged = false
            overscroll = 0
            bottomOverscroll = 0
            #endif
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Now that the page has settled, a short page with no scroll counts
            // as bottomed-out so it can be pulled to advance. (The scroll report
            // only re-fires on scroll/resize, which a short page never triggers.)
            hasFinishedLoading = true
            if lastBottomGap <= 2 { atBottom = true }
            // Translate after the page (and reader script) has loaded, if the
            // user toggled translation on.
            runTranslationIfNeeded()
        }

        // A failed load leaves estimatedProgress below 1; report completion so
        // the loading bar hides instead of hanging.
        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let report = onLoadingProgress
            Task { @MainActor in report(1) }
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let report = onLoadingProgress
            Task { @MainActor in report(1) }
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "nookScroll" else { return }
            if let body = message.body as? [String: Any] {
                let top = (body["top"] as? NSNumber)?.doubleValue ?? 0
                let bottomGap = (body["bottomGap"] as? NSNumber)?.doubleValue ?? .greatestFiniteMagnitude
                let scrollable = (body["scrollable"] as? NSNumber)?.boolValue ?? false
                atTop = top <= 0.5
                lastBottomGap = bottomGap
                // A scrollable page is at the bottom when the gap closes; a short
                // (non-scrollable) page counts as bottomed-out once loaded, so it
                // too can be pulled. A still-loading long page that momentarily
                // measures short is excluded until its load finishes.
                atBottom = bottomGap <= 2 && (scrollable || hasFinishedLoading)
            } else if let top = (message.body as? NSNumber)?.doubleValue {
                atTop = top <= 0.5
            }
        }
    }
}
