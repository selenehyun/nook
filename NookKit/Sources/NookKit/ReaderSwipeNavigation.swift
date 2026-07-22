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

/// Minimum time the edge pull must be actively held (from when the overscroll
/// starts until release) before a release commits. A pull that crosses the
/// distance threshold but is let go faster than this reads as an accidental flick
/// while scrolling, so it snaps back instead of navigating. Measured from the
/// overscroll's start — not the whole scroll — so a long scroll that ends in a
/// quick flick is still caught.
private let readerCommitMinHold: TimeInterval = 0.25

private struct ReaderSwipeNavigation: ViewModifier {
    let nextTitle: String?
    let previousTitle: String?
    let onNext: () -> Void
    let onPrevious: () -> Void

    /// Pull distance past an edge needed to commit to a navigation. Deliberately
    /// firmer than the web reader's, so a small nudge at the top/bottom of a short
    /// article doesn't jump to the next one — a full, intentional pull is required.
    static let threshold: CGFloat = 160
    /// The top edge (pull-down to the previous article) commits a bit sooner — a
    /// top overscroll is harder to sustain than a bottom one, so 160 there felt
    /// too stiff.
    static let topThreshold: CGFloat = 120

    @State private var pull = EdgePull()

    // iOS-only tracking.
    @State private var isDragging = false
    @State private var beganAtTop = false
    @State private var beganAtBottom = false

    /// Whether the current pull has been held long enough to be allowed to commit.
    /// Drives BOTH the visual (the reel only rolls to "next" once armed) and the
    /// commit decision, so what the user sees and what happens always agree. Set by
    /// a timer started when the overscroll begins; cleared when it ends.
    @State private var armed = false
    @State private var armTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        platformContent(content)
            // Arm the pull once the overscroll has been held for the min hold, and
            // disarm the moment it returns to rest. Timed off the pull itself, so it
            // covers both platforms (each drives `pull`).
            .onChange(of: pull) { _, newValue in
                let engaged = newValue.top > 0 || newValue.bottom > 0
                if engaged {
                    if armTask == nil, !armed {
                        armTask = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(readerCommitMinHold))
                            if !Task.isCancelled { armed = true }
                        }
                    }
                } else {
                    armTask?.cancel()
                    armTask = nil
                    armed = false
                }
            }
            // Reuse the web reader's affordance so the gradual emerge and the
            // selection roll are identical — bottom pulls to the next article,
            // top mirrors it to the previous one (no "close" stage here). `armed`
            // holds the reel in the hint stage until the min hold passes.
            .overlay(alignment: .bottom) {
                BottomPullAffordance(pull: pull.bottom, nextTitle: nextTitle, edge: .bottom, includeClose: false, forward: true, nextThreshold: Self.threshold, armed: armed)
            }
            .overlay(alignment: .top) {
                BottomPullAffordance(pull: pull.top, nextTitle: previousTitle, edge: .top, includeClose: false, forward: false, nextThreshold: Self.topThreshold, armed: armed)
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
            }
            .onScrollPhaseChange { oldPhase, newPhase, context in
                switch newPhase {
                case .tracking, .interacting:
                    if !isDragging {
                        let edges = Self.edges(context.geometry)
                        beganAtTop = edges.top
                        beganAtBottom = edges.bottom
                    }
                    isDragging = true
                default:
                    // Commit from the overscroll AT RELEASE (not the peak), so
                    // pulling past the threshold and then easing back before
                    // lifting cancels instead of still navigating. Also require the
                    // pull to have been held long enough — a faster release reads as
                    // an accidental flick and snaps back.
                    if oldPhase == .interacting || oldPhase == .tracking {
                        let released = Self.pull(from: context.geometry)
                        // `armed` is the same signal that rolled the reel, so a
                        // release only commits when the indicator actually showed
                        // "ready".
                        if armed, beganAtBottom, released.bottom >= Self.threshold {
                            commit(.bottom)
                        } else if armed, beganAtTop, released.top >= Self.topThreshold {
                            commit(.top)
                        }
                    }
                    isDragging = false
                }
                if newPhase == .idle { pull = EdgePull() }
            }
    }

    /// iOS overscroll past each edge, measured relative to each edge's resting
    /// position. The top uses the content offset vs. the top inset (its resting
    /// offset), so a top safe-area/nav-bar inset doesn't add a phantom baseline
    /// that made the previous pull trigger almost immediately. The bottom uses
    /// the visible rect vs. the content height (correct regardless of how the
    /// container size folds in insets).
    private static func pull(from geometry: ScrollGeometry) -> EdgePull {
        let top = max(0, -geometry.contentInsets.top - geometry.contentOffset.y)
        let bottom = max(0, geometry.visibleRect.maxY - geometry.contentSize.height)
        return EdgePull(top: top, bottom: bottom)
    }
    #endif

    /// Whether the content rests at (within a hair of) each edge, using the same
    /// per-edge measures as `pull(from:)`.
    private static func edges(_ geometry: ScrollGeometry) -> EdgePair {
        let tolerance: CGFloat = 8
        return EdgePair(
            top: geometry.contentOffset.y <= -geometry.contentInsets.top + tolerance,
            bottom: geometry.visibleRect.maxY >= geometry.contentSize.height - tolerance
        )
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
        private var engagedAt: Date?
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
            engagedAt = nil
            raw = 0
            lastReported = 0
            didCrossThreshold = false
        }

        /// Returns true to consume the event (we're driving the pull).
        private func handle(_ event: NSEvent) -> Bool {
            guard let probe, let window = probe.window, event.window === window else { return false }
            let delta = event.scrollingDeltaY

            // Record, at the start of each gesture, whether it began resting at an
            // edge — read live from the scroll view, so it's correct at rest.
            if event.phase.contains(.began) {
                let atEdge = edges()
                beganAtTop = atEdge.top
                beganAtBottom = atEdge.bottom
            }

            if engaged == nil {
                // Require a real (phased) gesture that isn't in momentum (a legacy
                // mouse wheel has no gesture end to commit on).
                guard event.momentumPhase == [], !event.phase.isEmpty else { return false }
                // Only engage when the scroll actually targets the reader's scroll
                // view — not the sidebar/article list, and not an overlay on top of
                // the reader (e.g. the in-app browser web view, which may itself be
                // non-scrollable). Hit-testing the top-most view under the pointer
                // excludes anything covering the reader.
                guard let scroll = scrollView(),
                      let hit = window.contentView?.hitTest(event.locationInWindow),
                      hit.isDescendant(of: scroll) else { return false }
                // Engage only when the content is STILL at that edge right now AND
                // the gesture began there. The live check stops a gesture that
                // began at the top, scrolled down, then reversed back up (now away
                // from the top) from flipping to the previous article — and vice
                // versa at the bottom.
                let atEdge = edges()
                if delta > 0, beganAtTop, atEdge.top {
                    engaged = .top
                    engagedAt = Date()
                    raw = 0
                } else if delta < 0, beganAtBottom, atEdge.bottom {
                    engaged = .bottom
                    engagedAt = Date()
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
                // Require the pull to have been held long enough; a faster release
                // reads as an accidental flick while scrolling and cancels.
                let heldLongEnough = engagedAt.map { Date().timeIntervalSince($0) >= readerCommitMinHold } ?? false
                reset()
                onPull(EdgePull())
                if let edge, amount >= threshold, heldLongEnough { onCommit(edge) }
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
