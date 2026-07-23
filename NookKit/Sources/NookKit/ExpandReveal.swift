import SwiftUI

/// Carries the measured natural content height up to the modifier.
private struct ExpandRevealHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Reveals/hides a view in two clear phases so it never "pops": first the row
/// grows to make room (empty), then the content fades in — and the reverse on
/// hide. Collapsing/expanding an always-mounted view's `frame(height:)` (rather
/// than inserting/removing it) is what lets a `List` animate the row height
/// smoothly and push the following rows down, instead of snapping.
///
/// A cache hit (the translation is already known when the row appears) is shown
/// instantly with no animation, so scrolling a known row into view doesn't
/// replay the grow-in; only a genuinely new (streaming) translation animates.
private struct ExpandRevealModifier: ViewModifier {
    /// Whether the content should be shown at all.
    let isVisible: Bool
    /// Whether an appearance (`isVisible` false→true) should animate. False for a
    /// cache hit that's simply scrolling into view.
    let animateAppearance: Bool
    let animation: Animation

    @State private var contentHeight: CGFloat = 0
    /// Height phase: is the row grown to make room?
    @State private var expanded = false
    /// Content phase: is the content faded in?
    @State private var revealed = false
    @State private var didInitialSync = false

    private var contentReveal: Animation { .easeOut(duration: 0.22) }
    private var contentHide: Animation { .easeIn(duration: 0.16) }

    func body(content: Content) -> some View {
        content
            // Measure the real content's natural height directly (fixedSize keeps
            // the frame below from feeding its clamped height back in), so there's
            // no duplicate/ghost subtree and only one symbol effect instance.
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ExpandRevealHeightKey.self, value: proxy.size.height)
                }
            )
            .frame(height: expanded ? contentHeight : 0, alignment: .top)
            .opacity(revealed ? 1 : 0)
            .clipped()
            .onPreferenceChange(ExpandRevealHeightKey.self) { newValue in
                guard abs(newValue - contentHeight) > 0.5 else { return }
                // Always set the height instantly. The reveal itself is animated via
                // `expanded` (phase 1); animating height here too would replay an
                // animation on every streamed token and again when the final text
                // lands — the exact "it re-animates after finishing" jank. Content
                // that grows mid-stream just tracks size under the shown block.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { contentHeight = newValue }
            }
            .onAppear {
                // Match the current visibility immediately (no animation), so a row
                // that's already translated when it appears shows at full height.
                expanded = isVisible
                revealed = isVisible
                didInitialSync = true
            }
            .onChange(of: isVisible) { _, nowVisible in
                guard didInitialSync else { return }
                if nowVisible {
                    if animateAppearance {
                        // Phase 1: grow the empty row. Phase 2: fade the content in.
                        withAnimation(animation) {
                            expanded = true
                        } completion: {
                            withAnimation(contentReveal) { revealed = true }
                        }
                    } else {
                        setInstantly(visible: true)
                    }
                } else {
                    // Fade the content out, then collapse the row.
                    withAnimation(contentHide) {
                        revealed = false
                    } completion: {
                        withAnimation(animation) { expanded = false }
                    }
                }
            }
    }

    private func setInstantly(visible: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            expanded = visible
            revealed = visible
        }
    }
}

public extension View {
    /// Smoothly grows/collapses this view's height between zero and its content
    /// height when `isVisible` flips — expanding the (empty) space first, then
    /// fading the content in — so it never pops inside a `List`. Pass
    /// `animateAppearance: false` when the content is already known (a cache hit)
    /// so scrolling it into view shows it instantly instead of replaying the
    /// grow-in. See ``ExpandRevealModifier`` for why this beats a conditional insert.
    func expandReveal(
        isVisible: Bool,
        animateAppearance: Bool = true,
        animation: Animation = .smooth(duration: 0.32)
    ) -> some View {
        modifier(ExpandRevealModifier(isVisible: isVisible, animateAppearance: animateAppearance, animation: animation))
    }
}
