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

    /// Pull distance, past an edge, needed to commit to a navigation. Matches the
    /// web reader's `nextThreshold` so the two surfaces feel the same.
    static let threshold = BottomPullAffordance.nextThreshold

    @State private var pull = EdgePull()

    func body(content: Content) -> some View {
        content
            // Guarantee an elastic edge on both platforms even when the article
            // is shorter than the viewport, so it can always be pulled.
            .scrollBounceBehavior(.always, axes: .vertical)
            .onScrollGeometryChange(for: EdgePull.self) { geometry in
                Self.pull(from: geometry)
            } action: { _, newValue in
                pull = newValue
            }
            .onScrollPhaseChange { oldPhase, newPhase, context in
                // Decide the instant the finger lifts after a drag — using the
                // geometry at that transition, so a settle-back bounce can't
                // retrigger and a flick is judged by where it was released.
                if oldPhase == .interacting, newPhase == .decelerating || newPhase == .idle {
                    let released = Self.pull(from: context.geometry)
                    if released.bottom >= Self.threshold, nextTitle != nil {
                        onNext()
                    } else if released.top >= Self.threshold, previousTitle != nil {
                        onPrevious()
                    }
                }
                if newPhase == .idle { pull = EdgePull() }
            }
            .overlay(alignment: .bottom) {
                if pull.bottom > 6 {
                    ReaderEdgePullAffordance(edge: .bottom, pull: pull.bottom, title: nextTitle)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                if pull.top > 6 {
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
    /// math (offset vs. inset-adjusted min/max) the web reader uses on iOS, so
    /// the reading is consistent.
    private static func pull(from geometry: ScrollGeometry) -> EdgePull {
        let minY = -geometry.contentInsets.top
        let maxY = max(minY, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)
        let top = max(0, minY - geometry.contentOffset.y)
        let bottom = max(0, geometry.contentOffset.y - maxY)
        return EdgePull(top: top, bottom: bottom)
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
