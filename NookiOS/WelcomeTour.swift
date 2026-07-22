import SwiftUI

/// Device-local flags for the first-run tutorial. Kept in the view layer (not
/// ReaderStore) per the project's state split, and never synced — completing the
/// tour is per-install UI state.
enum TourFlags {
    static let hasCompletedWelcomeKey = "hasCompletedWelcome"
    static let seenReaderGestureHintKey = "seenReaderGestureHint"
}

/// The first-run welcome tour: a paged, swipeable cover that teaches the core
/// gestures with small looping illustrations. Skippable at any moment (a Skip
/// button on every page, and swipe-to-dismiss counts as done), and replayable
/// from Settings. Renders identically on iPhone and iPad because nothing is
/// anchored to the live UI.
struct WelcomeSheet: View {
    /// Called when the tour is finished or skipped; the caller records completion
    /// and dismisses.
    var onFinish: () -> Void

    @State private var page = 0
    private let lastPage = 5

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color("ListBackground").ignoresSafeArea()

            TabView(selection: $page) {
                TourPage(
                    title: "Welcome to Nook",
                    message: "Like a bird gathering twigs into a nest, gather the reading you care about into a space that's yours.",
                    illustration: { NestAssemblyView(size: 132, assembled: true) }
                )
                .tag(0)

                TourPage(
                    title: "Add a feed",
                    message: "Tap + to add a feed. Paste an RSS link or just a website — Nook finds the feed for you.",
                    illustration: { AddFeedIllustration() }
                )
                .tag(1)

                TourPage(
                    title: "Open a story",
                    message: "Tap any story in the list to open it in the clean, native reader.",
                    illustration: { TapIllustration() }
                )
                .tag(2)

                TourPage(
                    title: "On to the next",
                    message: "At the end of a story, keep pulling up past the bottom to jump to the next one.",
                    illustration: { PullUpIllustration() }
                )
                .tag(3)

                TourPage(
                    title: "Star what you love",
                    message: "Double-tap anywhere on an article to star it — and find it later under Starred.",
                    illustration: { DoubleTapStarIllustration() }
                )
                .tag(4)

                TourPage(
                    title: "The full page, and back",
                    message: "Want the original? Tap the document button at the bottom. Swipe in from the left edge to return to your list.",
                    illustration: { OriginalAndBackIllustration() },
                    isLast: true,
                    onStart: onFinish
                )
                .tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button(action: onFinish) {
                Text("Skip")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.trailing, 20)
            .padding(.top, 12)
            .accessibilityLabel(Text("Skip tutorial"))
        }
        .tint(Color("AccentColor"))
    }
}

/// One tour page: a looping illustration, a title, a short message, and — on the
/// final page — a prominent "Get Started" button.
private struct TourPage<Illustration: View>: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder var illustration: Illustration
    var isLast = false
    var onStart: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            ZStack { illustration }
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 32)

            VStack(spacing: 10) {
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)

            if isLast, let onStart {
                Button(action: onStart) {
                    Text("Get Started")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 44)
                .padding(.top, 4)
            }

            Spacer()
            Spacer()
        }
        .padding(.bottom, 44)
    }
}

// MARK: - Looping gesture illustrations (not anchored to any real view)

private struct AddFeedIllustration: View {
    @State private var pulse = false
    var body: some View {
        Image(systemName: "plus.circle.fill")
            .font(.system(size: 92, weight: .regular))
            .foregroundStyle(Color.accentColor)
            .scaleEffect(pulse ? 1.06 : 0.94)
            .shadow(color: .accentColor.opacity(0.25), radius: pulse ? 16 : 6)
            .onAppear { withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

private struct TapIllustration: View {
    @State private var ripple = false
    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                mockLine(width: 150)
                mockLine(width: 110).opacity(0.6)
            }
            .frame(width: 190, alignment: .leading)

            ZStack {
                Circle().stroke(Color.accentColor, lineWidth: 3)
                    .frame(width: 46, height: 46)
                    .scaleEffect(ripple ? 1.7 : 0.7)
                    .opacity(ripple ? 0 : 0.9)
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
            }
            .offset(x: 70, y: 30)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { ripple = true } }
    }

    private func mockLine(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.secondary.opacity(0.3))
            .frame(width: width, height: 12)
    }
}

private struct PullUpIllustration: View {
    @State private var rise = false
    var body: some View {
        ZStack {
            VStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: "chevron.up")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Color.accentColor.opacity(0.9 - Double(i) * 0.25))
                        .offset(y: rise ? -16 : 14)
                        .opacity(rise ? 0.15 : 1)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false).delay(Double(i) * 0.12), value: rise)
                }
            }
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .offset(y: 58)
        }
        .onAppear { rise = true }
    }
}

private struct DoubleTapStarIllustration: View {
    @State private var animate = false
    var body: some View {
        ZStack {
            Circle().stroke(Color.accentColor, lineWidth: 3)
                .frame(width: 44, height: 44)
                .scaleEffect(animate ? 1.5 : 0.7)
                .opacity(animate ? 0 : 0.9)
            Image(systemName: "star.fill")
                .font(.system(size: 62))
                .foregroundStyle(.yellow)
                .scaleEffect(animate ? 1.0 : 0.5)
                .opacity(animate ? 1 : 0.4)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.5).repeatForever(autoreverses: true)) { animate = true }
        }
    }
}

private struct OriginalAndBackIllustration: View {
    @State private var slide = false
    var body: some View {
        HStack(spacing: 36) {
            // Swipe-from-left-edge back.
            ZStack {
                Image(systemName: "chevron.left")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .offset(x: slide ? -6 : 14)
                    .opacity(slide ? 1 : 0.3)
                Image(systemName: "list.bullet")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .offset(x: 22)
            }
            // The document / original button.
            Image(systemName: "doc.plaintext")
                .font(.system(size: 42))
                .foregroundStyle(Color.accentColor)
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { slide = true } }
    }
}
