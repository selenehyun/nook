import SwiftUI

/// A brief, native-feeling "new content arrived" flash for a sidebar feed row.
///
/// Automatic refreshes no longer flip feed icons to a spinner (that got visually
/// tiring on every background tick). Instead, when a refresh brings in new
/// articles, the feed's icon blinks a couple of times behind an accent glow and
/// pulses slightly, then settles. A refresh that changes nothing leaves the
/// trigger untouched, so there is no visual change at all.
private struct FeedActivityFlash: ViewModifier {
    /// A value that changes each time the feed gains new articles. Each change
    /// plays the flash once.
    let trigger: Int

    // Two blink cycles: rest → bright → rest → bright → rest.
    private let phases: [Double] = [0, 1, 0, 1, 0]

    func body(content: Content) -> some View {
        content
            .phaseAnimator(phases, trigger: trigger) { view, level in
                view
                    .scaleEffect(1 + 0.18 * level)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.accentColor)
                            .opacity(0.55 * level)
                            .blur(radius: 2)
                            .padding(-4)
                            .allowsHitTesting(false)
                    }
            } animation: { _ in
                .easeInOut(duration: 0.22)
            }
    }
}

public extension View {
    /// Flashes the view once whenever `trigger` changes, with a soft accent glow
    /// and pulse. Used on sidebar feed icons to signal that a refresh brought in
    /// new articles.
    func feedActivityFlash(trigger: Int) -> some View {
        modifier(FeedActivityFlash(trigger: trigger))
    }
}
