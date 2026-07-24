import SwiftUI

#if os(macOS)
import AppKit
#endif

/// Coalescing state shared by the macOS bridge and its regression tests. The
/// first sample belongs to the row's initial layout and needs no cache
/// invalidation; only a later reveal frame or surrounding-content revision does.
struct ListRowHeightInvalidationTracker {
    private var lastSample: (progress: CGFloat, layoutRevision: Int)?

    mutating func consume(progress: CGFloat, layoutRevision: Int) -> Bool {
        defer { lastSample = (progress, layoutRevision) }
        guard let lastSample else { return false }
        return abs(progress - lastSample.progress) > 0.000_1
            || layoutRevision != lastSample.layoutRevision
    }
}

/// Carries the animated reveal sample from a translated child to the outer
/// macOS list row, where the native container can remeasure the actual row.
public enum NativeListRowRevealProgressKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0

    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

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
        let clamped = min(max(progress, 0), 1)
        // Collapsed (the common case for every non-translating row while scrolling):
        // height is zero regardless of content, so skip the expensive text
        // measurement entirely. This is what stops a streamed update from making
        // every visible row re-measure.
        guard clamped > 0 else { return CGSize(width: proposal.width ?? 0, height: 0) }
        let natural = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
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

#if os(macOS)
/// A zero-size probe embedded in one SwiftUI `List` row. SwiftUI correctly
/// recomputes the hosting view's fitting size while `IntrinsicRevealLayout`
/// animates, but its AppKit-backed list can retain the row height that was cached
/// when a newly inserted row was first measured. Explicitly invalidating only
/// this row keeps the public `NSTableView` cache in lockstep with the SwiftUI
/// animation without reloading the list or disturbing selection/scroll position.
private struct MacListRowHeightInvalidator: NSViewRepresentable {
    let progress: CGFloat
    let layoutRevision: Int

    func makeNSView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.receive(progress: progress, layoutRevision: layoutRevision)
    }

    @MainActor
    final class ProbeView: NSView {
        private var tracker = ListRowHeightInvalidationTracker()
        private var pendingInvalidation: Task<Void, Never>?
        private var needsAttachmentRetry = false

        override var isFlipped: Bool { true }

        func receive(progress: CGFloat, layoutRevision: Int) {
            guard tracker.consume(
                progress: progress,
                layoutRevision: layoutRevision
            ) else { return }
            scheduleInvalidation()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, needsAttachmentRetry {
                scheduleInvalidation()
            }
        }

        private func scheduleInvalidation() {
            pendingInvalidation?.cancel()
            pendingInvalidation = Task { @MainActor [weak self] in
                // Let SwiftUI commit this animation sample's fitting size before
                // asking AppKit to query it. Multiple updates in one run-loop turn
                // coalesce into the latest sample.
                await Task.yield()
                guard !Task.isCancelled else { return }
                self?.invalidateEnclosingRow()
            }
        }

        private func invalidateEnclosingRow() {
            invalidateHostingHierarchy()

            if let tableView = enclosingView(of: NSTableView.self) {
                let rowView = enclosingView(of: NSTableRowView.self)
                let row = rowView.map { tableView.row(for: $0) }
                    ?? rowAtProbe(in: tableView)
                guard row >= 0 else {
                    needsAttachmentRetry = true
                    return
                }
                needsAttachmentRetry = false
                tableView.noteHeightOfRows(
                    withIndexesChanged: IndexSet(integer: row)
                )
                tableView.needsLayout = true
                tableView.layoutSubtreeIfNeeded()
                return
            }

            // Newer SwiftUI List implementations can be collection-backed.
            // Invalidating the layout does not reload items or replace SwiftUI
            // identity, so selection, scrolling, and the reveal animation remain
            // intact.
            if let collectionView = enclosingView(of: NSCollectionView.self) {
                needsAttachmentRetry = false
                collectionView.collectionViewLayout?.invalidateLayout()
                collectionView.needsLayout = true
                collectionView.layoutSubtreeIfNeeded()
                return
            }

            needsAttachmentRetry = true
        }

        private func invalidateHostingHierarchy() {
            var candidate: NSView? = self
            while let current = candidate {
                current.invalidateIntrinsicContentSize()
                current.needsUpdateConstraints = true
                current.needsLayout = true
                if current is NSTableView || current is NSCollectionView { break }
                candidate = current.superview
            }
        }

        private func rowAtProbe(in tableView: NSTableView) -> Int {
            let point = convert(
                CGPoint(x: bounds.midX, y: bounds.midY),
                to: tableView
            )
            return tableView.row(at: point)
        }

        private func enclosingView<ViewType: NSView>(
            of type: ViewType.Type
        ) -> ViewType? {
            var candidate: NSView? = self
            while let current = candidate {
                if let match = current as? ViewType { return match }
                candidate = current.superview
            }
            return nil
        }
    }
}
#endif

/// Couples the animatable reveal progress to the platform list container.
/// `AnimatableModifier` exposes every interpolated progress sample to the macOS
/// probe; iOS keeps its native collection-view self-sizing path, which already
/// invalidates dynamic row heights correctly.
private struct ListRowSynchronizedReveal: @preconcurrency AnimatableModifier {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        IntrinsicRevealLayout(progress: progress) {
            content
        }
        .preference(
            key: NativeListRowRevealProgressKey.self,
            value: progress
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
/// A live reveal animates one deliberate row-height change on both platforms.
/// Streaming text itself never owns a height animation, so macOS avoids the old
/// `NSTableView` failure mode where every generated token remeasured the list.
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

    init(
        isVisible: Bool,
        animateAppearance: Bool,
        animation: Animation
    ) {
        self.isVisible = isVisible
        self.animateAppearance = animateAppearance
        self.animation = animation
        // Seed from the prop so a cached row is correct from its first layout.
        _expanded = State(initialValue: isVisible)
        _revealed = State(initialValue: isVisible)
    }

    func body(content: Content) -> some View {
        content
        .modifier(
            ListRowSynchronizedReveal(
                progress: expanded ? 1 : 0
            )
        )
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
        // Phase 1: grow the empty row. Phase 2: fade the content in.
        withAnimation(animation) {
            expanded = true
        } completion: {
            guard id == transitionID else { return }
            withAnimation(contentReveal) { revealed = true }
        }
    }

    private func hide(transitionID id: Int) {
        // Fade the content out, then collapse the row.
        withAnimation(contentHide) {
            revealed = false
        } completion: {
            guard id == transitionID else { return }
            withAnimation(animation) { expanded = false }
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
    /// Connects a SwiftUI row-level layout revision to its native macOS list
    /// container. Place this on the outer row, not only on a changing descendant,
    /// so newly inserted rows cannot retain their initial AppKit height.
    @ViewBuilder
    func synchronizeNativeListRowHeight(
        progress: CGFloat,
        layoutRevision: Int
    ) -> some View {
        #if os(macOS)
        background(
            MacListRowHeightInvalidator(
                progress: progress,
                layoutRevision: layoutRevision
            )
        )
        #else
        self
        #endif
    }

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
        modifier(
            ExpandRevealModifier(
                isVisible: isVisible,
                animateAppearance: animateAppearance,
                animation: animation
            )
        )
    }
}
