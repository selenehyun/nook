import SwiftUI

/// A one-shot, non-blocking reminder shown the first time the native reader opens
/// — reinforcing the gestures the welcome tour taught (double-tap to star, pull
/// up for the next story). It sits above the bottom bar, never traps input, and
/// auto-dismisses after a few seconds. Only shown while the chrome is visible, so
/// it never points at a faded-out bottom bar.
struct ReaderGestureHint: View {
    var onDismiss: () -> Void

    @State private var shown = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap")
            Text("Double-tap to star · pull up for the next story")
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .padding(.horizontal, 24)
        .padding(.bottom, 78)
        .frame(maxWidth: .infinity)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 12)
        .allowsHitTesting(false)
        .task {
            withAnimation(.easeOut(duration: 0.3)) { shown = true }
            try? await Task.sleep(for: .seconds(4.5))
            withAnimation(.easeIn(duration: 0.3)) { shown = false }
            try? await Task.sleep(for: .milliseconds(320))
            onDismiss()
        }
        .accessibilityLabel(Text("Double-tap to star, pull up for the next story"))
    }
}
