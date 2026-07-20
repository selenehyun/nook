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

    /// Pull distance past an edge needed to commit to a navigation. Deliberately
    /// small — a pull only ever starts at an edge (never mid-scroll), so a light
    /// overscroll is enough and there's no risk of an accidental trigger.
    static let threshold: CGFloat = 15
    /// The pull distance below which the affordance stays hidden.
    private static let revealThreshold: CGFloat = 1

    @State private var pull = EdgePull()

    // iOS-only tracking.
    @State private var atTop = false
    @State private var atBottom = false
    @State private var peak = EdgePull()
    @State private var isDragging = false
    @State private var beganAtTop = false
    @State private var beganAtBottom = false

    func body(content: Content) -> some View {
        platformContent(content)
            .overlay(alignment: .bottom) {
                if pull.bottom > Self.revealThreshold {
                    ReaderEdgePullAffordance(edge: .bottom, pull: pull.bottom, title: nextTitle)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                if pull.top > Self.revealThreshold {
                    ReaderEdgePullAffordance(edge: .top, pull: pull.top, title: previousTitle)
                        .transition(.opacity)
                }
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
            // Track which edge the content rests at; the monitor only engages a
            // pull that starts at an edge.
            .onScrollGeometryChange(for: EdgePair.self) { geometry in
                Self.edges(geometry)
            } action: { _, edges in
                atTop = edges.top
                atBottom = edges.bottom
            }
            .background(
                ScrollWheelOverscrollMonitor(
                    atTop: atTop,
                    atBottom: atBottom,
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

    /// iOS overscroll past each edge, amplified so the elastic distance drives
    /// the affordance and threshold comfortably.
    private static func pull(from geometry: ScrollGeometry) -> EdgePull {
        let amplification: CGFloat = 2.5
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
    var atTop: Bool
    var atBottom: Bool
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
        c.atTop = atTop
        c.atBottom = atBottom
        c.threshold = threshold
        c.onPull = onPull
        c.onCommit = onCommit
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var atTop = false
        var atBottom = false
        var threshold: CGFloat = 70
        var onPull: (EdgePull) -> Void = { _ in }
        var onCommit: (ReaderPullEdge) -> Void = { _ in }

        private weak var view: NSView?
        private var monitor: Any?
        private var engaged: ReaderPullEdge?
        private var raw: CGFloat = 0
        private var beganAtTop = false
        private var beganAtBottom = false
        private var lastReported: CGFloat = 0

        func attach(to view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Light rubber-band resistance. Softer than the web reader's so the pull
        /// grows quickly and the low commit threshold is reached with a gentle
        /// overscroll rather than a hard one.
        private func rubberBand(_ distance: CGFloat, limit: CGFloat = 420, softness: CGFloat = 240) -> CGFloat {
            guard distance > 0 else { return 0 }
            return limit * distance / (distance + softness)
        }

        private func reset() {
            engaged = nil
            raw = 0
            lastReported = 0
        }

        /// Returns true to consume the event (we're driving the pull).
        private func handle(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, event.window === window else { return false }
            // Only act when the pointer is over the reader, so scrolling the
            // sidebar or article list never drives article navigation.
            let point = view.convert(event.locationInWindow, from: nil)
            let overReader = view.bounds.contains(point)
            let delta = event.scrollingDeltaY

            // Record, at the start of each gesture, whether it began resting at
            // an edge. Only such a gesture may drive navigation.
            if event.phase.contains(.began) {
                beganAtTop = atTop
                beganAtBottom = atBottom
            }

            if engaged == nil {
                // Require a real (phased) gesture that began at the edge, isn't in
                // momentum, and is over the reader — so scrolling through the body
                // (or a legacy mouse wheel with no gesture end) never engages.
                guard overReader, event.momentumPhase == [], !event.phase.isEmpty else { return false }
                if atTop, delta > 0, beganAtTop {
                    engaged = .top
                    raw = 0
                } else if atBottom, delta < 0, beganAtBottom {
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

// MARK: - Affordance

/// A floating pill revealed as the native reader is pulled past an edge: a hint
/// while pulling, turning into the target article's title once past the commit
/// threshold. Mirrors the web reader's affordance styling.
private struct ReaderEdgePullAffordance: View {
    enum Edge { case top, bottom }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let edge: Edge
    let pull: CGFloat
    /// The target article's title, or nil at the end/start of the list.
    let title: String?

    private var reached: Bool { pull >= ReaderSwipeNavigation.threshold }

    private var hintTick: Int {
        guard !reached, pull > ReaderSwipeNavigation.threshold * 0.06 else { return 0 }
        return Int(pull / 10)
    }

    var body: some View {
        pill
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(edge == .bottom ? .bottom : .top, 22)
            .padding(.horizontal, 20)
            .scaleEffect(reached ? 1 : 0.94, anchor: edge == .bottom ? .bottom : .top)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .interpolatingSpring(
                mass: 0.7, stiffness: 260, damping: 22
            ), value: reached)
            #if !os(macOS)
            .sensoryFeedback(trigger: reached) { _, isReached in
                isReached ? .impact(weight: .light) : nil
            }
            .sensoryFeedback(trigger: hintTick) { old, new in
                new > old ? .selection : nil
            }
            #endif
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(label))
    }

    private var pill: some View {
        HStack(spacing: 9) {
            Image(systemName: iconName)
                .font(.headline)
            Text(label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260)
        }
        .foregroundStyle(reached ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .modifier(GlassPill())
    }

    private var iconName: String {
        if reached {
            if title == nil { return "checkmark.circle" }
            return edge == .bottom ? "arrow.right" : "arrow.left"
        }
        return edge == .bottom ? "chevron.up" : "chevron.down"
    }

    private var label: String {
        if reached {
            if let title { return title }
            return edge == .bottom
                ? String(localized: "You're all caught up", bundle: .module)
                : String(localized: "You're at the start", bundle: .module)
        }
        return String(localized: "Keep pulling", bundle: .module)
    }
}
