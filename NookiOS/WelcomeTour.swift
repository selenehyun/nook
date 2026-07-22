import NookKit
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Device-local flags for the first-run tutorial. Kept in the view layer (not
/// ReaderStore) per the project's state split, and never synced — completing the
/// tour is per-install UI state.
enum TourFlags {
    static let hasCompletedWelcomeKey = "hasCompletedWelcome"
    static let seenReaderGestureHintKey = "seenReaderGestureHint"
    static let seenListHintKey = "seenListTapHint"
}

/// In-memory coordinator that lets the welcome cover drive the live app: hand the
/// sample feed off to the Add Feed screen, then nudge the user to open their
/// first story. View-layer only (never persisted or synced), shared down the tree
/// via `.environment`.
@MainActor
@Observable
final class TourCoordinator {
    /// A popular, dependable starter feed the tour offers to copy so a brand-new
    /// user has something to read immediately.
    static let sampleFeedURL = "https://news.ycombinator.com/rss"

    /// The welcome cover copied the sample feed and asked to add it: switch to the
    /// Feeds tab and open Add Feed with a paste hint. Consumed (reset) by the shell.
    var wantsAddSampleFeed = false
    /// The tutorial finished adding a feed: the shell switches to Home, and Home
    /// spotlights the list once it's on screen with articles. Kept as a standing
    /// request (not an edge) so it survives the tab switch and is consumed by Home
    /// itself when it appears — no cross-view onChange race.
    var pendingFirstStoryHint = false
}

/// The first-run welcome tour: a paged, swipeable cover that gets a new user set
/// up — choose a sync folder (skipped when one is already configured) and copy a
/// starter feed to add. Skippable at any moment (a Skip button on every page, and
/// swipe-to-dismiss counts as done), and replayable from Settings. The reading
/// gestures are taught later, live, by the reader coach marks.
struct WelcomeSheet: View {
    @Bindable var store: ReaderStore
    /// Called when the tour is finished or skipped; the caller records completion
    /// and dismisses.
    var onFinish: () -> Void

    @Environment(TourCoordinator.self) private var tour

    private enum Page: Hashable { case welcome, sync, addFeed }

    @State private var page: Page = .welcome
    @State private var isChoosingFolder = false
    /// Whether to include the sync-folder step, captured once at presentation so
    /// the page set stays stable (and doesn't reflow when the folder is chosen).
    @State private var includeSyncStep: Bool

    init(store: ReaderStore, onFinish: @escaping () -> Void) {
        self.store = store
        self.onFinish = onFinish
        _includeSyncStep = State(initialValue: !store.isStorageConfigured)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color("ListBackground").ignoresSafeArea()

            TabView(selection: $page) {
                TourPage(
                    illustration: AnyView(NestAssemblyView(size: 132, assembled: true)),
                    title: "Welcome to Nook",
                    message: "Like a bird gathering twigs into a nest, gather the reading you care about into a space that's yours."
                )
                .tag(Page.welcome)

                if includeSyncStep {
                    TourPage(
                        illustration: AnyView(SyncIllustration()),
                        title: "Pick a home for your feeds",
                        message: "Nook keeps your feeds in a folder you choose. Put it in iCloud Drive and every device stays in sync — nothing ever leaves your own storage.",
                        primaryTitle: store.isStorageConfigured ? "Folder Ready" : "Choose Folder",
                        onPrimary: { isChoosingFolder = true }
                    )
                    .tag(Page.sync)
                }

                TourPage(
                    illustration: AnyView(AddFeedIllustration()),
                    title: "Start with Hacker News",
                    message: "We'll copy a popular feed for you. Tap below, then paste it on the Add Feed screen. You can add any RSS link or website the same way.",
                    accessory: AnyView(FeedURLPill(url: TourCoordinator.sampleFeedURL)),
                    primaryTitle: "Copy & Add",
                    onPrimary: copyAndAdd
                )
                .tag(Page.addFeed)
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
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            store.configureSyncFolder(url)
            // Move on to the starter feed once a home is set.
            withAnimation { page = .addFeed }
        }
    }

    /// Copies the starter feed and hands it to the Add Feed screen. If no sync
    /// folder is set yet (the user swiped past that step), bounce back to it first
    /// — a feed can't be stored without one.
    private func copyAndAdd() {
        guard store.isStorageConfigured else {
            withAnimation { page = .sync }
            return
        }
        UIPasteboard.general.string = TourCoordinator.sampleFeedURL
        tour.wantsAddSampleFeed = true
        onFinish()
    }
}

/// One tour page: a looping illustration, a title, a short message, an optional
/// accessory (e.g. the copyable feed URL), and an optional primary button.
private struct TourPage: View {
    let illustration: AnyView
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var accessory: AnyView? = nil
    var primaryTitle: LocalizedStringKey? = nil
    var onPrimary: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack { illustration }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
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

            if let accessory { accessory }

            if let primaryTitle, let onPrimary {
                Button(action: onPrimary) {
                    Text(primaryTitle)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 44)
                .padding(.top, 2)
            }

            Spacer()
            Spacer()
        }
        .padding(.bottom, 44)
    }
}

/// The copyable feed URL, shown on the starter-feed page so the user sees exactly
/// what they're about to copy and paste.
private struct FeedURLPill: View {
    let url: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link").foregroundStyle(.secondary)
            Text(url)
                .font(.footnote.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .padding(.horizontal, 36)
        .accessibilityElement()
        .accessibilityLabel(Text("Feed URL"))
        .accessibilityValue(Text(url))
    }
}

// MARK: - Looping illustrations (not anchored to any real view)

private struct SyncIllustration: View {
    @State private var pulse = false
    var body: some View {
        Image(systemName: "icloud.and.arrow.up")
            .font(.system(size: 86, weight: .regular))
            .foregroundStyle(Color.accentColor)
            .scaleEffect(pulse ? 1.05 : 0.95)
            .shadow(color: .accentColor.opacity(0.22), radius: pulse ? 14 : 6)
            .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true } }
    }
}

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
