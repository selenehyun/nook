import SwiftUI

/// A floating indicator revealed at the bottom of the in-app browser when the
/// user keeps pulling up past the end of the page. Its three actions occupy a
/// vertical wheel: crossing a threshold rotates the next action into the fixed
/// selection slot with a spring, like a compact slot-machine reel. The selected
/// action is always fully opaque so release behaviour is never ambiguous.
///
/// The thresholds are shared so the browser's release handler decides the same
/// way the indicator reads.
public struct BottomPullAffordance: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pullDirection: PullDirection = .forward

    /// The primary action: pull a little past this to open the next article.
    public static let nextThreshold: CGFloat = 80
    /// Pull further, past this, to close the browser instead. Kept well clear of
    /// the next threshold so the over-pull can't slip into close by accident.
    public static let closeThreshold: CGFloat = 170

    private let pull: CGFloat
    private let nextTitle: String?
    /// Which screen edge the affordance is anchored to. `.bottom` (default) is
    /// the in-app browser's pull-up; `.top` mirrors it for the native reader's
    /// pull-down-to-previous.
    private let edge: VerticalEdge
    /// Whether the extra "release to close" stage is available (the browser).
    /// The native reader has nothing to close, so it passes `false`.
    private let includeClose: Bool
    /// Whether the primary action goes forward (next) or backward (previous),
    /// which chooses the arrow direction and the "nothing more" message.
    private let forward: Bool
    /// The pull distance at which the "next" action is reached. Overridable so a
    /// surface can require a firmer pull (the native reader uses a larger value);
    /// defaults to the shared `nextThreshold`. Must match the caller's commit
    /// threshold so the indicator fills exactly when release will navigate.
    private let nextThreshold: CGFloat
    /// Whether the pull has been held long enough to be allowed to commit. While
    /// false, the reel never rolls to the "next/previous" action no matter how far
    /// it's pulled — it shows a "hold" hint instead — so a quick flick can't look
    /// ready. Defaults to true so the web reader's own affordance is unaffected.
    private let armed: Bool

    public init(
        pull: CGFloat,
        nextTitle: String?,
        edge: VerticalEdge = .bottom,
        includeClose: Bool = true,
        forward: Bool = true,
        nextThreshold: CGFloat = BottomPullAffordance.nextThreshold,
        armed: Bool = true
    ) {
        self.pull = pull
        self.nextTitle = nextTitle
        self.edge = edge
        self.includeClose = includeClose
        self.forward = forward
        self.nextThreshold = nextThreshold
        self.armed = armed
    }

    /// +1 for the bottom edge, -1 to mirror the reel geometry for the top edge.
    private var sign: CGFloat { edge == .bottom ? 1 : -1 }

    private enum Stage: Int, CaseIterable, Equatable {
        case hint
        case next
        case close
    }

    private enum PullDirection: Equatable { case forward, backward }

    private var stage: Stage {
        // Not armed yet (held too briefly): stay in the hint stage regardless of
        // distance, so pulling fast/far can't roll the reel to "next".
        guard armed else { return .hint }
        if includeClose, pull >= Self.closeThreshold { return .close }
        if pull >= nextThreshold { return .next }
        return .hint
    }

    private var isPresented: Bool { pull > 6 }

    /// A stepped value that climbs as the pull grows through the "hint" zone, so
    /// a very light haptic can tick in response to the scroll before either
    /// threshold is reached. Zero outside the hint stage.
    private var hintTick: Int {
        guard stage == .hint, pull > 6 else { return 0 }
        return Int(pull / 10)
    }

    public var body: some View {
        ZStack {
            reelItem(.hint) { hintCard }
            reelItem(.next) { nextCard }
            if includeClose { reelItem(.close) { closeCard } }
        }
        .frame(height: 82)
        .clipped()
        // Presentation is spring-driven. Within a stage, pull distance only
        // draws the incoming neighbour closer; the selected cell stays fixed.
        .scaleEffect(isPresented ? 1 : 0.86, anchor: edge == .bottom ? .bottom : .top)
        .offset(y: isPresented ? 0 : 38 * sign)
        .opacity(isPresented ? 1 : 0)
        .padding(edge == .bottom ? .bottom : .top, 22)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .interpolatingSpring(
            mass: 0.9, stiffness: 230, damping: 15.5, initialVelocity: 0
        ), value: stage)
        .animation(reduceMotion ? nil : .interpolatingSpring(
            mass: 0.55, stiffness: 260, damping: 23, initialVelocity: 0
        ), value: pullDirection)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .interpolatingSpring(
            mass: 0.7, stiffness: 260, damping: 22, initialVelocity: 0
        ), value: isPresented)
        // iOS haptics. macOS ones are performed in the web view coordinator
        // (ArticleWebView), off the scroll, because SwiftUI's `.sensoryFeedback`
        // doesn't reliably re-fire the trackpad patterns on a repeated pull.
        #if !os(macOS)
        .sensoryFeedback(trigger: stage) { _, newStage in
            switch newStage {
            case .hint: nil
            case .next: .impact(weight: .light)
            case .close: .impact(weight: .medium)
            }
        }
        .sensoryFeedback(trigger: hintTick) { oldTick, newTick in
            newTick > oldTick ? .selection : nil
        }
        #endif
        .onChange(of: pull) { oldValue, newValue in
            guard abs(newValue - oldValue) > 0.2 else { return }
            pullDirection = newValue >= oldValue ? .forward : .backward
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .allowsHitTesting(false)
    }

    /// Positions every card on the same cylindrical reel. The neighbour in the
    /// scroll direction approaches partway with the gesture, but the active card
    /// does not budge. At a threshold `stage` changes and the low-damping spring
    /// takes over from the gesture, letting the incoming card push through the
    /// centre with carried velocity and settle elastically.
    private func reelItem<Content: View>(_ item: Stage, @ViewBuilder content: () -> Content) -> some View {
        let slotDistance = CGFloat(item.rawValue - stage.rawValue)
        let isSelected = item == stage
        let approach = approachProgress(for: item)
        let travel: CGFloat = reduceMotion ? 0.10 : 0.27
        let distance = slotDistance == 0
            ? 0
            : slotDistance.sign == .minus
                ? slotDistance + travel * approach
                : slotDistance - travel * approach
        let isNeighbour = abs(slotDistance) == 1
        return content()
            .rotation3DEffect(
                .degrees(reduceMotion ? 0 : Double(distance * -52 * sign)),
                axis: (x: 1, y: 0, z: 0),
                anchor: (distance * sign) > 0 ? .top : .bottom,
                perspective: 0.58
            )
            .scaleEffect(isSelected ? 1 : 0.82 + 0.06 * approach)
            .offset(y: distance * 54 * sign)
            // The release target is invariantly solid. The incoming neighbour
            // may gain emphasis as it approaches, but never at its expense.
            .opacity(isSelected ? 1 : (isNeighbour ? 0.3 + 0.2 * approach : 0))
            .zIndex(isSelected ? 2 : 1)
    }

    /// Gesture-controlled pre-travel. It deliberately stops well short of the
    /// centre; crossing the boundary is always completed by the stage spring.
    private func approachProgress(for item: Stage) -> CGFloat {
        let eased = { (value: CGFloat) -> CGFloat in
            let clamped = clamp01(value)
            return clamped * clamped * (3 - 2 * clamped)
        }
        switch (stage, item) {
        case (.hint, .next):
            return eased(pull / nextThreshold)
        case (.next, .close) where pullDirection == .forward:
            return eased((pull - nextThreshold) / (Self.closeThreshold - nextThreshold))
        case (.next, .hint) where pullDirection == .backward:
            return 1 - eased((pull - nextThreshold) / (Self.closeThreshold - nextThreshold))
        case (.close, .next):
            return 1 - eased((pull - Self.closeThreshold) / 62)
        default:
            return 0
        }
    }

    private var hintCard: some View {
        pill {
            Image(systemName: edge == .bottom ? "chevron.up" : "chevron.down").font(.headline)
            Text("Keep pulling", bundle: .module)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.secondary)
    }

    private var emptyActionTitle: String {
        forward
            ? String(localized: "You're all caught up", bundle: .module)
            : String(localized: "You're at the start", bundle: .module)
    }

    private var nextCard: some View {
        pill {
            Image(systemName: nextTitle == nil ? "checkmark.circle" : (forward ? "arrow.right" : "arrow.left"))
                .font(.headline)
            Text(nextTitle ?? emptyActionTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260)
        }
        .foregroundStyle(.tint)
    }

    private var closeCard: some View {
        pill {
            Image(systemName: "xmark").font(.headline)
            Text("Release to close", bundle: .module)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.primary)
    }

    private var accessibilityLabel: Text {
        switch stage {
        case .hint: Text("Keep pulling", bundle: .module)
        case .next: Text(nextTitle ?? emptyActionTitle)
        case .close: Text("Release to close", bundle: .module)
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 9) { content() }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .modifier(GlassPill())
    }

    private func clamp01(_ value: CGFloat) -> CGFloat { max(0, min(1, value)) }
}

/// A capsule background using the system Liquid Glass material where available,
/// falling back to a regular material on earlier OSes.
struct GlassPill: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        }
    }
}
