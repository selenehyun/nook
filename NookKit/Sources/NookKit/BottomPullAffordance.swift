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

    /// The primary action: pull a little past this to open the next article.
    public static let nextThreshold: CGFloat = 80
    /// Pull further, past this, to close the browser instead. Kept well clear of
    /// the next threshold so the over-pull can't slip into close by accident.
    public static let closeThreshold: CGFloat = 170

    private let pull: CGFloat
    private let nextTitle: String?

    public init(pull: CGFloat, nextTitle: String?) {
        self.pull = pull
        self.nextTitle = nextTitle
    }

    private enum Stage: Int, CaseIterable, Equatable {
        case hint
        case next
        case close
    }

    private var stage: Stage {
        if pull >= Self.closeThreshold { return .close }
        if pull >= Self.nextThreshold { return .next }
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
            reelItem(.close) { closeCard }
        }
        .frame(height: 82)
        .clipped()
        // Presentation is itself spring-driven. Pull distance only chooses a
        // discrete slot; it no longer directly scrubs visual opacity/position.
        .scaleEffect(isPresented ? 1 : 0.86, anchor: .bottom)
        .offset(y: isPresented ? 0 : 38)
        .opacity(isPresented ? 1 : 0)
        .padding(.bottom, 22)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .interpolatingSpring(
            mass: 0.82, stiffness: 245, damping: 19, initialVelocity: 0
        ), value: stage)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .allowsHitTesting(false)
    }

    /// Positions every card on the same cylindrical reel. Only `stage` changes
    /// the target position, so SwiftUI's spring carries velocity and overshoot
    /// across a threshold instead of the scroll offset scrubbing every frame.
    private func reelItem<Content: View>(_ item: Stage, @ViewBuilder content: () -> Content) -> some View {
        let distance = CGFloat(item.rawValue - stage.rawValue)
        let isSelected = item == stage
        return content()
            .rotation3DEffect(
                .degrees(reduceMotion ? 0 : Double(distance * -52)),
                axis: (x: 1, y: 0, z: 0),
                anchor: distance > 0 ? .top : .bottom,
                perspective: 0.58
            )
            .scaleEffect(isSelected ? 1 : 0.84)
            .offset(y: distance * 54)
            // The release target is invariantly solid. Only neighbouring reel
            // cells are de-emphasised, and that value is discrete—not scrubbed.
            .opacity(isSelected ? 1 : (abs(distance) == 1 ? 0.38 : 0))
            .zIndex(isSelected ? 2 : 1)
    }

    private var hintCard: some View {
        pill {
            Image(systemName: "chevron.up").font(.headline)
            Text("Keep pulling", bundle: .module)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.secondary)
    }

    private var nextCard: some View {
        pill {
            Image(systemName: nextTitle == nil ? "checkmark.circle" : "arrow.right")
                .font(.headline)
            Text(nextTitle ?? String(localized: "You're all caught up", bundle: .module))
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
        case .next: Text(nextTitle ?? String(localized: "You're all caught up", bundle: .module))
        case .close: Text("Release to close", bundle: .module)
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 9) { content() }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .modifier(GlassPill())
    }
}

/// A capsule background using the system Liquid Glass material where available,
/// falling back to a regular material on earlier OSes.
private struct GlassPill: ViewModifier {
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
