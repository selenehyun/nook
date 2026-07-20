import SwiftUI

/// A brief, native-feeling "new content arrived" flash for a sidebar feed row.
///
/// Automatic refreshes no longer flip feed icons to a spinner (that got visually
/// tiring on every background tick). Instead, when a refresh brings in new
/// articles, the feed's icon blinks a few times behind a soft accent glow, then
/// settles. A refresh that changes nothing produces no visual change at all.
private struct FeedActivityFlash: ViewModifier {
    /// Held true briefly by the store right after new articles arrive.
    let isActive: Bool

    @State private var glow: Double = 0

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor)
                    .opacity(glow * 0.30)
                    .blur(radius: 1.5)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
            // Re-runs whenever the flag flips. On activation it blinks a few
            // times, then leaves the glow off; when the store clears the flag the
            // task restarts and simply confirms the glow is down.
            .task(id: isActive) {
                guard isActive else {
                    glow = 0
                    return
                }
                for _ in 0..<3 {
                    withAnimation(.easeInOut(duration: 0.26)) { glow = 1 }
                    try? await Task.sleep(for: .milliseconds(280))
                    withAnimation(.easeInOut(duration: 0.26)) { glow = 0 }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
    }
}

public extension View {
    /// Blinks the view with a soft accent glow while `active` is true. Used on
    /// sidebar feed icons to signal that a refresh brought in new articles.
    func feedActivityFlash(active: Bool) -> some View {
        modifier(FeedActivityFlash(isActive: active))
    }
}
