import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Gives a plain SwiftUI `ScrollView` — the native article reader — the same
/// bottom pull-to-advance gesture the in-app browser has. Pulling up past the
/// end of the content reports a growing `pull`; releasing hands the final amount
/// to `onRelease`, which decides next-article vs close against the shared
/// `BottomPullAffordance` thresholds. Pair it with a `BottomPullAffordance`
/// overlay bound to the same `pull` value.
///
/// Where the web view has to work for its overscroll — its macOS path
/// accumulates raw wheel deltas and rubber-bands them by hand — a SwiftUI
/// `ScrollView` bounces natively on *both* platforms. The distance we read from
/// the scroll geometry is therefore already resisted, so we pass it straight
/// through with no manual curve.
public struct BottomPullToAdvance: ViewModifier {
    @Binding private var pull: CGFloat
    private let isEnabled: Bool
    private let onRelease: (CGFloat) -> Void

    public init(
        pull: Binding<CGFloat>,
        isEnabled: Bool = true,
        onRelease: @escaping (CGFloat) -> Void
    ) {
        self._pull = pull
        self.isEnabled = isEnabled
        self.onRelease = onRelease
    }

    /// The peak overscroll of the current pull, and whether a pull is in
    /// progress (armed for release).
    @State private var peak: CGFloat = 0
    @State private var armed = false
    /// Whether scroll-phase callbacks are reaching us at all. When they are, they
    /// give the precise finger-lift moment for the release; when they never fire
    /// (some configurations don't deliver them), we fall back to detecting the
    /// spring-back to rest instead.
    @State private var sawPhaseChange = false
    #if os(macOS)
    @State private var lastStage = 0
    @State private var lastHintBucket = 0
    #endif

    public func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                // The distance the scroll is bounced past its bottom edge.
                // `contentOffset` tracks the elastic bounce past the end (unlike
                // `visibleRect`, which clamps to the content), matching the
                // convention the breadcrumb strip already relies on. Require
                // genuine scrollability so a short, non-scrolling article
                // (content no taller than the viewport) never reads as a
                // constant overscroll and self-triggers.
                guard geometry.contentSize.height > geometry.containerSize.height + 1 else { return 0 }
                let maxOffset = geometry.contentSize.height - geometry.containerSize.height
                return max(0, geometry.contentOffset.y - maxOffset)
            } action: { _, overscroll in
                guard isEnabled else { return }
                pull = overscroll
                if overscroll > 1 {
                    armed = true
                    if overscroll > peak { peak = overscroll }
                    #if os(macOS)
                    updateMacHaptics(for: overscroll)
                    #endif
                } else if armed {
                    // Sprung back to rest. If scroll phases never reached us this
                    // is the only release signal we get; otherwise the phase
                    // handler already fired and we just clear.
                    if sawPhaseChange {
                        resetTransient()
                    } else {
                        fireRelease(amount: peak)
                    }
                }
            }
            .onScrollPhaseChange { oldPhase, newPhase, _ in
                guard isEnabled else { return }
                sawPhaseChange = true
                let wasActive = oldPhase == .interacting || oldPhase == .tracking
                let isActive = newPhase == .interacting || newPhase == .tracking
                // The finger just lifted — report the pull at that moment.
                if wasActive && !isActive { fireRelease(amount: pull) }
            }
    }

    /// Hand the release amount to the caller once per pull, then disarm.
    private func fireRelease(amount: CGFloat) {
        guard armed else { return }
        resetTransient()
        if amount > 1 { onRelease(amount) }
    }

    private func resetTransient() {
        armed = false
        peak = 0
        #if os(macOS)
        lastStage = 0
        lastHintBucket = 0
        #endif
    }

    #if os(macOS)
    /// Mirrors the web view coordinator's macOS haptics: a firm triple tick when
    /// the pull crosses into next/close, and a lighter double tick ratcheting
    /// through the "keep pulling" hint zone. (SwiftUI's `.sensoryFeedback`, which
    /// `BottomPullAffordance` uses for iOS, doesn't reliably re-fire the trackpad
    /// patterns on a repeated pull, so macOS drives them here off the scroll.)
    private func updateMacHaptics(for pull: CGFloat) {
        let stage = pull >= BottomPullAffordance.closeThreshold ? 2
            : (pull >= BottomPullAffordance.nextThreshold ? 1 : 0)
        if stage > lastStage { performTicks(3) }
        lastStage = stage

        if stage == 0 {
            let bucket = Int(pull / 24)
            if bucket > lastHintBucket { performTicks(2) }
            lastHintBucket = bucket
        } else {
            lastHintBucket = 0
        }
    }

    private func performTicks(_ count: Int) {
        let performer = NSHapticFeedbackManager.defaultPerformer
        for i in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.04) {
                performer.perform(.levelChange, performanceTime: .now)
            }
        }
    }
    #endif
}

public extension View {
    /// Reveal a bottom pull-to-advance affordance on a scrolling reader. Pair
    /// with a `BottomPullAffordance` overlay bound to the same `pull`.
    func bottomPullToAdvance(
        pull: Binding<CGFloat>,
        isEnabled: Bool = true,
        onRelease: @escaping (CGFloat) -> Void
    ) -> some View {
        modifier(BottomPullToAdvance(pull: pull, isEnabled: isEnabled, onRelease: onRelease))
    }
}
