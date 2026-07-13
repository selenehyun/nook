import SwiftUI

/// The affordance revealed at the bottom of the in-app browser when the user
/// keeps pulling up past the end of the page. It grows with the pull and its
/// label/icon escalates through two thresholds: pull a little to close, pull
/// further to jump to the next article.
///
/// The thresholds are shared so the browser's release handler decides the same
/// way the affordance reads.
public struct BottomPullAffordance: View {
    /// Release beyond this (but below `nextThreshold`) closes the browser.
    public static let closeThreshold: CGFloat = 80
    /// Release beyond this opens the next article instead.
    public static let nextThreshold: CGFloat = 170

    private let pull: CGFloat

    public init(pull: CGFloat) {
        self.pull = pull
    }

    private enum Stage: Equatable { case hint, close, next }

    private var stage: Stage {
        if pull >= Self.nextThreshold { return .next }
        if pull >= Self.closeThreshold { return .close }
        return .hint
    }

    public var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: stage)
            Text(label)
                .font(.footnote.weight(.semibold))
                .contentTransition(.opacity)
        }
        .foregroundStyle(stage == .hint ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        .frame(maxWidth: .infinity)
        .frame(height: min(pull, Self.nextThreshold + 48))
        .background(.bar)
        .opacity(pull > 6 ? 1 : 0)
        .animation(.snappy(duration: 0.2), value: stage)
        .animation(.easeOut(duration: 0.12), value: pull > 6)
        // Native haptic tick each time the pull crosses into a new stage
        // (a no-op on hardware without a haptic engine).
        .sensoryFeedback(trigger: stage) { _, newStage in
            switch newStage {
            case .close: .impact(weight: .light)
            case .next: .impact(weight: .medium)
            case .hint: nil
            }
        }
        .allowsHitTesting(false)
    }

    private var icon: String {
        switch stage {
        case .hint: "chevron.up"
        case .close: "xmark.circle.fill"
        case .next: "arrow.forward.circle.fill"
        }
    }

    private var label: String {
        switch stage {
        case .hint: String(localized: "Keep pulling", bundle: .module)
        case .close: String(localized: "Release to close", bundle: .module)
        case .next: String(localized: "Release for next article", bundle: .module)
        }
    }
}
