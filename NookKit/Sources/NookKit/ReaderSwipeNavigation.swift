import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// Adds "pull past the edge to change article" to the NATIVE reader's scroll
/// view — pull up past the bottom for the next article, pull down past the top
/// for the previous one. The web reader keeps its own bottom-only affordance
/// (`ArticleWebView` + `BottomPullAffordance`) and is untouched.
///
/// Both platforms are driven by the same Apple scroll APIs — `scrollBounce
/// Behavior(.always)` to guarantee an elastic edge even for short articles,
/// `onScrollGeometryChange` for the live overscroll amount, and
/// `onScrollPhaseChange` to decide on release — so macOS and iOS behave
/// identically instead of relying on platform-specific event plumbing.
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

/// The live overscroll past each edge, in points (0 when resting or scrolling
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

    /// Pull distance (amplified, see `amplification`) past an edge needed to
    /// commit to a navigation. Kept low so a modest pull triggers reliably —
    /// native elastic overscroll is heavily damped, especially on macOS.
    static let threshold: CGFloat = 70

    /// The platform's elastic overscroll is small and stiff, so the raw distance
    /// is scaled up before it drives the affordance and the decision. This makes
    /// the indicator appear immediately and the threshold reachable with a normal
    /// pull instead of a very hard one.
    private static let amplification: CGFloat = 3.0

    /// The pull distance below which the affordance stays hidden.
    private static let revealThreshold: CGFloat = 4

    @State private var pull = EdgePull()
    /// The greatest pull reached while the finger is down. Decisions use this
    /// peak (not the value at lift-off), so both a slow pull-and-hold and a quick
    /// flick past the edge commit reliably; momentum-only overscroll after
    /// lift-off is ignored because it isn't tracked.
    @State private var peak = EdgePull()
    @State private var isDragging = false
    // Whether the drag began already resting at an edge. A pull only navigates
    // when it started at that edge, so scrolling down through the article (which
    // ends by momentarily touching the bottom) never flips to the next article —
    // the user must deliberately pull from the edge, like the web reader.
    @State private var beganAtTop = false
    @State private var beganAtBottom = false

    func body(content: Content) -> some View {
        content
            // Guarantee an elastic edge on both platforms even when the article
            // is shorter than the viewport, so it can always be pulled.
            .scrollBounceBehavior(.always, axes: .vertical)
            .onScrollGeometryChange(for: EdgePull.self) { geometry in
                Self.pull(from: geometry)
            } action: { _, newValue in
                pull = newValue
                if isDragging {
                    peak = EdgePull(top: max(peak.top, newValue.top), bottom: max(peak.bottom, newValue.bottom))
                }
            }
            .onScrollPhaseChange { oldPhase, newPhase, context in
                switch newPhase {
                case .tracking, .interacting:
                    // A new touch begins: start tracking the peak fresh and note
                    // which edge (if any) the content was resting at.
                    if !isDragging {
                        peak = EdgePull()
                        let edges = Self.edges(context.geometry)
                        beganAtTop = edges.atTop
                        beganAtBottom = edges.atBottom
                    }
                    isDragging = true
                default:
                    // The finger lifted: commit from the peak reached while
                    // dragging, but only for an edge the drag actually began at.
                    if oldPhase == .interacting || oldPhase == .tracking {
                        if beganAtBottom, peak.bottom >= Self.threshold, nextTitle != nil {
                            onNext()
                        } else if beganAtTop, peak.top >= Self.threshold, previousTitle != nil {
                            onPrevious()
                        }
                    }
                    isDragging = false
                    peak = EdgePull()
                }
                if newPhase == .idle { pull = EdgePull() }
            }
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
            #if os(macOS)
            // macOS has no `.sensoryFeedback`; tick the Taptic engine when a pull
            // crosses the commit threshold on either edge.
            .onChange(of: crossedThreshold) { _, crossed in
                if crossed { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
            }
            #endif
    }

    /// True while a pull on either edge is past the commit threshold.
    private var crossedThreshold: Bool {
        pull.bottom >= Self.threshold || pull.top >= Self.threshold
    }

    /// Overscroll past each edge from a scroll geometry, using the same offset
    /// math (offset vs. inset-adjusted min/max) the web reader uses on iOS, then
    /// amplified so the stiff native elastic distance is easy to act on.
    private static func pull(from geometry: ScrollGeometry) -> EdgePull {
        let minY = -geometry.contentInsets.top
        let maxY = max(minY, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)
        let top = max(0, minY - geometry.contentOffset.y) * amplification
        let bottom = max(0, geometry.contentOffset.y - maxY) * amplification
        return EdgePull(top: top, bottom: bottom)
    }

    /// Whether the content is resting at (or within a hair of) each edge — used
    /// at drag start to decide which edge, if any, a pull may navigate from.
    private static func edges(_ geometry: ScrollGeometry) -> (atTop: Bool, atBottom: Bool) {
        let minY = -geometry.contentInsets.top
        let maxY = max(minY, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)
        return (geometry.contentOffset.y <= minY + 2, geometry.contentOffset.y >= maxY - 2)
    }
}

/// A floating pill revealed as the native reader is pulled past an edge: a hint
/// while pulling, turning into the target article's title once past the commit
/// threshold. Mirrors the web reader's affordance styling, adapted to two edges
/// and a single (next/previous) action.
private struct ReaderEdgePullAffordance: View {
    enum Edge { case top, bottom }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let edge: Edge
    let pull: CGFloat
    /// The target article's title, or nil at the end/start of the list.
    let title: String?

    private var reached: Bool { pull >= ReaderSwipeNavigation.threshold }

    /// A stepped value that climbs through the hint zone so a light selection
    /// haptic can tick with the scroll before the threshold is reached.
    private var hintTick: Int {
        guard !reached, pull > 6 else { return 0 }
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
