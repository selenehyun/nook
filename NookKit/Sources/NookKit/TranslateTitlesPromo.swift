import SwiftUI

/// A one-time card that introduces the "translate article titles automatically"
/// feature and lets the user turn it on right away. Shared by both apps so the
/// copy and look stay identical; each app owns when it's shown (once, then never
/// again) and what "Turn On" flips. `.module` bundle so it localises in NookKit.
public struct TranslateTitlesPromoView: View {
    private let onEnable: () -> Void
    private let onNotNow: () -> Void

    public init(onEnable: @escaping () -> Void, onNotNow: @escaping () -> Void) {
        self.onEnable = onEnable
        self.onNotNow = onNotNow
    }

    public var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "character.bubble.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .padding(.top, 8)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Translate Titles Automatically", bundle: .module)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text("Nook can translate the article titles on screen into your language with Apple Intelligence, shown beneath the original. It's on-device and only translates titles you actually look at.", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Button(action: onEnable) {
                    Text("Turn On", bundle: .module)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onNotNow) {
                    Text("Not Now", bundle: .module)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Text("You can change this anytime in Settings › Experimental.", bundle: .module)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: 420)
    }
}
