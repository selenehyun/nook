import SwiftUI

/// Lays out a single subview at its natural height scaled by `progress` (0…1),
/// computed synchronously in the same layout pass. Because the height is known
/// the moment the row is laid out — not measured asynchronously and fed back
/// through `@State` — a `List` row never lays out short and then grows a pass
/// later, which is what made macOS `NSTableView` re-anchor and judder while
/// scrolling up. `progress` is animatable, so a live reveal can still grow.
private struct IntrinsicRevealLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let natural = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let clamped = min(max(progress, 0), 1)
        return CGSize(width: proposal.width ?? natural.width, height: natural.height * clamped)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        // Place at full natural height, top-anchored; the (shorter) bounds clip it,
        // so the content is revealed from the top as `progress` grows.
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}

/// Reveals/hides a view without ever popping the layout: it grows from zero to
/// its natural height, then the content fades in — reverse on hide.
///
/// The revealed height is intrinsic and synchronous (see ``IntrinsicRevealLayout``)
/// so a `List` row is correct on its very first layout; `@State` is seeded from
/// `isVisible` so an already-translated (cached) row that scrolls into view is
/// full height immediately instead of growing in again.
///
/// On macOS the row height is opened instantly (only the content fades), because
/// animating `NSTableView` row heights mid-scroll is what destabilises the list;
/// iOS keeps the animated grow, which its collection-view-backed list absorbs.
private struct ExpandRevealModifier: ViewModifier {
    let isVisible: Bool
    /// Whether an appearance should animate. False for a cache hit scrolling in.
    let animateAppearance: Bool
    let animation: Animation

    /// Height phase: is the row grown to make room?
    @State private var expanded: Bool
    /// Content phase: is the content faded in?
    @State private var revealed: Bool
    /// Guards against a stale phase completion (e.g. a give-up collapse finishing
    /// after the row was re-shown) acting on an out-of-date transition.
    @State private var transitionID = 0

    private let contentReveal = Animation.easeOut(duration: 0.22)
    private let contentHide = Animation.easeIn(duration: 0.16)

    init(isVisible: Bool, animateAppearance: Bool, animation: Animation) {
        self.isVisible = isVisible
        self.animateAppearance = animateAppearance
        self.animation = animation
        // Seed from the prop so a cached row is correct from its first layout.
        _expanded = State(initialValue: isVisible)
        _revealed = State(initialValue: isVisible)
    }

    func body(content: Content) -> some View {
        IntrinsicRevealLayout(progress: expanded ? 1 : 0) {
            content
        }
        .opacity(revealed ? 1 : 0)
        .clipped()
        .onChange(of: isVisible) { _, nowVisible in
            transitionID &+= 1
            let id = transitionID
            if nowVisible {
                show(transitionID: id)
            } else {
                hide(transitionID: id)
            }
        }
    }

    private func show(transitionID id: Int) {
        guard animateAppearance else {
            setInstantly(expanded: true, revealed: true)
            return
        }
        #if os(macOS)
        // Open the height instantly (no mid-scroll NSTableView row-height
        // animation), then fade the content in on the next runloop tick.
        setExpanded(true, animated: false)
        Task { @MainActor in
            await Task.yield()
            guard id == transitionID else { return }
            withAnimation(contentReveal) { revealed = true }
        }
        #else
        // Phase 1: grow the empty row. Phase 2: fade the content in.
        withAnimation(animation) {
            expanded = true
        } completion: {
            guard id == transitionID else { return }
            withAnimation(contentReveal) { revealed = true }
        }
        #endif
    }

    private func hide(transitionID id: Int) {
        // Fade the content out, then collapse the row.
        withAnimation(contentHide) {
            revealed = false
        } completion: {
            guard id == transitionID else { return }
            #if os(macOS)
            setExpanded(false, animated: false)
            #else
            withAnimation(animation) { expanded = false }
            #endif
        }
    }

    private func setExpanded(_ value: Bool, animated: Bool) {
        if animated {
            withAnimation(animation) { expanded = value }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { expanded = value }
        }
    }

    private func setInstantly(expanded expandedValue: Bool, revealed revealedValue: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            expanded = expandedValue
            revealed = revealedValue
        }
    }
}

public extension View {
    /// Grows this view from zero to its natural height then fades its content in
    /// (reverse on hide), without popping the layout — safe inside a `List` on both
    /// platforms. Pass `animateAppearance: false` when the content is already known
    /// (a cache hit) so scrolling it into view shows it instantly. See
    /// ``ExpandRevealModifier`` for the macOS/iOS difference.
    func expandReveal(
        isVisible: Bool,
        animateAppearance: Bool = true,
        animation: Animation = .smooth(duration: 0.32)
    ) -> some View {
        modifier(ExpandRevealModifier(isVisible: isVisible, animateAppearance: animateAppearance, animation: animation))
    }
}
