import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// Adds "pull past the edge to change article" to the NATIVE reader's scroll
/// view — pull up past the bottom for the next article, pull down past the top
/// for the previous one. The web reader keeps its own bottom-only affordance
/// (`ArticleWebView` + `BottomPullAffordance`) and is untouched.
///
/// The two platforms detect the pull differently because their scroll engines
/// differ, each using the method that's reliable there:
/// - macOS: a `.scrollWheel` event monitor accumulates the overscroll directly
///   and consumes the events while pulling, so the content stays put and the
///   commit fires deterministically on gesture end (the same approach the web
///   reader uses in `ArticleWebView`).
/// - iOS: `UIScrollView` reflects the elastic overscroll in its offset, so
///   `onScrollGeometryChange` + `onScrollPhaseChange` read it directly.
public extension View {
    func readerSwipeNavigation(
        nextTitle: String?,
        previousTitle: String?,
        onNext: @escaping () -> Void,
        onPrevious: @escaping () -> Void
    ) -> some View {
        modifier(ReaderSwipeNavigation(
            nextTitle: nextTitle,
            previousTitle: previousTitle,
            onNext: onNext,
            onPrevious: onPrevious
        ))
    }
}

/// Which edge a pull is acting on. `.bottom` navigates to the next article,
/// `.top` to the previous one.
enum ReaderPullEdge { case top, bottom }

/// The live pull distance past each edge, in points (0 when resting or scrolling
/// within bounds). Only one side is ever non-zero at a time.
private struct EdgePull: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
}

private struct ReaderSwipeNavigation: ViewModifier {
    let nextTitle: String?
    let previousTitle: String?
    let onNext: () -> Void
    let onPrevious: () -> Void

    /// Pull distance past an edge needed to commit to a navigation. Matches the
    /// web reader's next-article threshold so the two surfaces feel the same.
    static let threshold: CGFloat = BottomPullAffordance.nextThreshold

    @State private var pull = EdgePull()

    // iOS-only tracking.
    @State private var peak = EdgePull()
    @State private var isDragging = false
    @State private var beganAtTop = false
    @State private var beganAtBottom = false

    func body(content: Content) -> some View {
        platformContent(content)
            // Reuse the web reader's affordance so the gradual emerge and the
            // selection roll are identical — bottom pulls to the next article,
            // top mirrors it to the previous one (no "close" stage here).
            .overlay(alignment: .bottom) {
                BottomPullAffordance(pull: pull.bottom, nextTitle: nextTitle, edge: .bottom, includeClose: false, forward: true)
            }
            .overlay(alignment: .top) {
                BottomPullAffordance(pull: pull.top, nextTitle: previousTitle, edge: .top, includeClose: false, forward: false)
            }
    }

    private func commit(_ edge: ReaderPullEdge) {
        switch edge {
        case .bottom: if nextTitle != nil { onNext() }
        case .top: if previousTitle != nil { onPrevious() }
        }
        pull = EdgePull()
    }

    #if os(macOS)
    @ViewBuilder
    private func platformContent(_ content: Content) -> some View {
        content
            .background(
                // Reads the real NSScrollView position directly, so "at the edge"
                // is exact rather than derived from ambiguous scroll geometry.
                ScrollWheelOverscrollMonitor(
                    threshold: Self.threshold,
                    onPull: { pull = $0 },
                    onCommit: commit
                )
            )
    }
    #else
    @ViewBuilder
    private func platformContent(_ content: Content) -> some View {
        content
            // Guarantee an elastic edge even when the article is shorter than the
            // viewport, so it can always be pulled.
            .scrollBounceBehavior(.always, axes: .vertical)
            .onScrollGeometryChange(for: EdgePull.self) { geometry in
                Self.pull(from: geometry)
            } action: { _, newValue in
                // Only surface the pull when the finger is down AND the drag began
                // resting at that edge — so scrolling through the body (or its
                // momentum bounce) never flashes the indicator. It shows only at
                // the very top/bottom of the article.
                let bottom = (isDragging && beganAtBottom) ? newValue.bottom : 0
                let top = (isDragging && beganAtTop) ? newValue.top : 0
                pull = EdgePull(top: top, bottom: bottom)
                if isDragging {
                    peak = EdgePull(top: max(peak.top, top), bottom: max(peak.bottom, bottom))
                }
            }
            .onScrollPhaseChange { oldPhase, newPhase, context in
                switch newPhase {
                case .tracking, .interacting:
                    if !isDragging {
                        peak = EdgePull()
                        let edges = Self.edges(context.geometry)
                        beganAtTop = edges.top
                        beganAtBottom = edges.bottom
                    }
                    isDragging = true
                default:
                    if oldPhase == .interacting || oldPhase == .tracking {
                        if beganAtBottom, peak.bottom >= Self.threshold {
                            commit(.bottom)
                        } else if beganAtTop, peak.top >= Self.threshold {
                            commit(.top)
                        }
                    }
                    isDragging = false
                    peak = EdgePull()
                }
                if newPhase == .idle { pull = EdgePull() }
            }
    }

    /// iOS overscroll past each edge. Unamplified, so the commit threshold maps
    /// to the same real overscroll distance the web reader uses.
    private static func pull(from geometry: ScrollGeometry) -> EdgePull {
        let amplification: CGFloat = 1.0
        let minY = -geometry.contentInsets.top
        let maxY = max(minY, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)
        let top = max(0, minY - geometry.contentOffset.y) * amplification
        let bottom = max(0, geometry.contentOffset.y - maxY) * amplification
        return EdgePull(top: top, bottom: bottom)
    }
    #endif

    /// Whether the content rests at (within a hair of) each edge. Uses the
    /// visible region vs. the content extent rather than an inset-derived max
    /// offset — the latter overshot on macOS, so the bottom edge was never
    /// detected and only the top pull engaged.
    private static func edges(_ geometry: ScrollGeometry) -> EdgePair {
        let tolerance: CGFloat = 8
        let atTop = geometry.contentOffset.y <= -geometry.contentInsets.top + tolerance
        let atBottom = geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - tolerance
        return EdgePair(top: atTop, bottom: atBottom)
    }
}

/// At-edge flags, as an `Equatable` value for `onScrollGeometryChange`.
private struct EdgePair: Equatable {
    var top: Bool
    var bottom: Bool
}

// MARK: - macOS overscroll monitor

#if os(macOS)
/// Drives the native reader's edge pull from raw `.scrollWheel` events — the
/// reliable path on macOS, where SwiftUI's elastic overscroll is tiny and its
/// scroll phases don't cleanly mark the release. While a pull is engaged the
/// events are consumed, so the article content doesn't move; the commit fires
/// on the gesture's `.ended` phase. Mirrors `ArticleWebView.Coordinator`.
private struct ScrollWheelOverscrollMonitor: NSViewRepresentable {
    var threshold: CGFloat
    var onPull: (EdgePull) -> Void
    var onCommit: (ReaderPullEdge) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let c = context.coordinator
        c.threshold = threshold
        c.onPull = onPull
        c.onCommit = onCommit
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var threshold: CGFloat = 15
        var onPull: (EdgePull) -> Void = { _ in }
        var onCommit: (ReaderPullEdge) -> Void = { _ in }

        private weak var probe: NSView?
        private weak var cachedScrollView: NSScrollView?
        private var monitor: Any?
        private var engaged: ReaderPullEdge?
        private var raw: CGFloat = 0
        private var beganAtTop = false
        private var beganAtBottom = false
        private var lastReported: CGFloat = 0
        private var didCrossThreshold = false

        func attach(to view: NSView) {
            probe = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// The reader's `NSScrollView`, found (and cached) by picking the scroll
        /// view in the window that overlaps this monitor's background the most —
        /// that's the reader's, not the sidebar's or the article list's.
        private func scrollView() -> NSScrollView? {
            if let cached = cachedScrollView, cached.window != nil { return cached }
            guard let probe, let content = probe.window?.contentView else { return nil }
            let target = probe.convert(probe.bounds, to: nil)
            var best: (view: NSScrollView, overlap: CGFloat)?
            func walk(_ view: NSView) {
                if let scroll = view as? NSScrollView {
                    let frame = scroll.convert(scroll.bounds, to: nil)
                    let intersection = frame.intersection(target)
                    if !intersection.isNull {
                        let area = intersection.width * intersection.height
                        if best == nil || area > best!.overlap { best = (scroll, area) }
                    }
                }
                view.subviews.forEach(walk)
            }
            walk(content)
            cachedScrollView = best?.view
            return cachedScrollView
        }

        /// Whether the reader content rests at each edge. Derived from the clip
        /// view's actual scrollable range via `constrainBoundsRect`, which folds
        /// in content insets (a top toolbar/safe-area inset otherwise made the
        /// resting top read as negative, so 10–20pt down still counted as "top").
        private func edges() -> (top: Bool, bottom: Bool) {
            guard let scroll = scrollView() else { return (false, false) }
            let clip = scroll.contentView
            let bounds = clip.bounds
            let currentY = bounds.minY
            // The clamped bounds for pulling far past each end give the true
            // min/max scroll positions, insets and document size included.
            let minY = clip.constrainBoundsRect(CGRect(x: bounds.minX, y: -1_000_000, width: bounds.width, height: bounds.height)).minY
            let maxY = clip.constrainBoundsRect(CGRect(x: bounds.minX, y: 1_000_000, width: bounds.width, height: bounds.height)).minY
            let tolerance: CGFloat = 3
            return (currentY <= minY + tolerance, currentY >= maxY - tolerance)
        }

        /// Rubber-band resistance matching the web reader's, so the pull needs a
        /// firm, deliberate overscroll — the same feel as the in-app browser.
        private func rubberBand(_ distance: CGFloat, limit: CGFloat = 420, softness: CGFloat = 700) -> CGFloat {
            guard distance > 0 else { return 0 }
            return limit * distance / (distance + softness)
        }

        private func reset() {
            engaged = nil
            raw = 0
            lastReported = 0
            didCrossThreshold = false
        }

        /// Returns true to consume the event (we're driving the pull).
        private func handle(_ event: NSEvent) -> Bool {
            guard let probe, let window = probe.window, event.window === window else { return false }
            // Only act when the pointer is over the reader, so scrolling the
            // sidebar or article list never drives article navigation.
            let point = probe.convert(event.locationInWindow, from: nil)
            let overReader = probe.bounds.contains(point)
            let delta = event.scrollingDeltaY

            // Record, at the start of each gesture, whether it began resting at an
            // edge — read live from the scroll view, so it's correct at rest.
            if event.phase.contains(.began) {
                let atEdge = edges()
                beganAtTop = atEdge.top
                beganAtBottom = atEdge.bottom
            }

            if engaged == nil {
                // Require a real (phased) gesture that began at the edge, isn't in
                // momentum, and is over the reader — so scrolling through the body
                // (or a legacy mouse wheel with no gesture end) never engages.
                guard overReader, event.momentumPhase == [], !event.phase.isEmpty else { return false }
                // Engage only when the content is STILL at that edge right now AND
                // the gesture began there. The live check stops a gesture that
                // began at the top, scrolled down, then reversed back up (now away
                // from the top) from flipping to the previous article — and vice
                // versa at the bottom.
                let atEdge = edges()
                if delta > 0, beganAtTop, atEdge.top {
                    engaged = .top
                    raw = 0
                } else if delta < 0, beganAtBottom, atEdge.bottom {
                    engaged = .bottom
                    raw = 0
                } else {
                    return false
                }
            }

            switch engaged {
            case .top:
                raw = max(0, raw + delta)
                lastReported = rubberBand(raw)
                onPull(EdgePull(top: lastReported, bottom: 0))
            case .bottom:
                raw = max(0, raw - delta)
                lastReported = rubberBand(raw)
                onPull(EdgePull(top: 0, bottom: lastReported))
            case nil:
                return false
            }

            // Fire a single Taptic tick when the pull crosses the commit
            // threshold (iOS gets its haptics from the affordance's sensoryFeedback).
            if !didCrossThreshold, lastReported >= threshold {
                didCrossThreshold = true
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                let amount = lastReported
                let edge = engaged
                reset()
                onPull(EdgePull())
                if let edge, amount >= threshold { onCommit(edge) }
                return true
            }
            // Pulled all the way back: hand scrolling back to the scroll view.
            if raw == 0 {
                reset()
                onPull(EdgePull())
                return false
            }
            return true
        }
    }
}
#endif
