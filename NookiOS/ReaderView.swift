import NaturalLanguage
import NookKit
import SafariServices
import SwiftUI
import Translation

/// The iOS article reader. Mirrors the macOS reader: a native, selectable body
/// (system typography) with a toggle into the styled `WKWebView` reader/original
/// page presented as a sheet.
/// Reports the inline title's measured height so the reader knows the scroll
/// distance at which it passes under the navigation bar.
private struct TitleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A scroll sample for the chrome auto-hide: the vertical offset plus how far
/// the bottom is, so toggling can be suppressed near the end (where the bottom
/// bar's collapse/expand would rubber-band the offset and oscillate the bars).
private struct ScrollSnapshot: Equatable {
    var y: CGFloat
    var distanceToBottom: CGFloat
}

struct ReaderDetailView: View {
    @Bindable var store: ReaderStore
    /// The article to show, as a binding the compact tab shell owns, so the pushed
    /// reader is driven by its own value — not the shared, scope-dependent
    /// `store.selectedArticle` (which another tab's scope change can null out) — and
    /// so previous/next swipe can move it. nil on iPad, where the split-view detail
    /// follows `store.selectedArticle`.
    var articleOverride: Binding<Article?>? = nil

    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @AppStorage("readerLinkBehavior") private var readerLinkBehavior = ReaderLinkBehavior.inApp
    /// Opt-in: press-and-hold the article body to open the in-app browser. Off by
    /// default now that the native reader covers most reading; the toolbar button
    /// still opens the browser.
    @AppStorage(ReaderStore.longPressOpensBrowserKey) private var longPressOpensBrowser = false
    @AppStorage("readerFont") private var readerFont = ReaderFont.system
    @AppStorage("readerFontSize") private var readerFontSize = 18
    @AppStorage("readerLineHeight") private var readerLineHeight = 1.7
    @AppStorage("readerLetterSpacing") private var readerLetterSpacing = 0.0
    @AppStorage("readerBackgroundOption") private var readerBackgroundOption = ReaderColorOption.automatic
    @AppStorage("readerBackgroundHex") private var readerBackgroundHex = "#FFFFFF"
    @AppStorage("readerTextOption") private var readerTextOption = ReaderColorOption.automatic
    @AppStorage("readerTextHex") private var readerTextHex = "#1A1A1A"

    @State private var isShowingInfo = false
    @State private var confirmingDelete = false
    @AppStorage(TourFlags.seenReaderGestureHintKey) private var seenReaderGestureHint = false
    /// The interactive reader coach mark step shown the first time the reader ever
    /// opens (nil = inactive). The persisted flag is marked immediately so it's
    /// strictly one-shot; this drives the transient spotlight walkthrough, and
    /// lives on the parent so it survives the per-article `.id` reset (letting the
    /// pull-to-next step carry over to the next article).
    @State private var coachStep: ReaderCoachStep?
    /// The open-original glass button's measured global frame, so the coach mark
    /// spotlights the real control exactly.
    @State private var originalButtonFrame: CGRect = .zero
    @State private var imagePresenter = ArticleImagePresenter()
    @State private var haptics = ReaderHaptics()
    @State private var pendingBuildup: Task<Void, Never>?

    // Native title handling: the full title renders inline at the top of the
    // article; once it scrolls up under the navigation bar, the bar's own title
    // fades in — the standard iOS large-to-inline title reveal, but keeping the
    // full multi-line inline title so long titles stay fully readable.
    @State private var titleHidden = false
    @State private var titleHeight: CGFloat = 0
    /// Safari-style chrome auto-hide: scrolling down fades the top and bottom bars
    /// (background + controls) so the body has the screen; scrolling up (or
    /// reaching the top) brings them back. The bars keep their layout space and
    /// only their opacity/background change, so nothing shifts and the scroll
    /// offset never feeds back. Reset per article (identity-keyed on article id).
    @State private var chromeHidden = false
    /// Scroll bookkeeping for a stable auto-hide: accumulate distance since the
    /// last direction change and only flip once it passes a threshold, so momentum
    /// and tiny jitters can't flicker the bars.
    @State private var lastScrollY: CGFloat = 0
    @State private var scrollAccum: CGFloat = 0
    /// Whether the chrome was showing when a next/prev pull began, so it can be
    /// restored if the pull is released without navigating.
    @State private var chromeShownBeforePull = false
    /// Set when a pull actually commits to a navigation, so the pull-release
    /// handler doesn't restore chrome that the new article should drive instead.
    @State private var navigatedFromPull = false

    /// The press must stay put this long before the haptic build-up begins, so a
    /// swipe or scroll (which moves past the gesture's maximumDistance well
    /// within this window) never kicks off a stray vibration.
    private let hapticStartDelay: Double = 0.16

    // Double-tap star "burst" overlay.
    @State private var starBurstOn = true
    @State private var starBurstScale: CGFloat = 0.4
    @State private var starBurstOpacity: Double = 0

    // On-device translation. Offered only when the detected content language
    // differs from the app's language. Prefers Apple Intelligence (natural,
    // inline) and falls back to the system Translation overlay.
    @State private var detectedLanguage: String?
    @State private var isShowingTranslation = false
    @State private var translatedTitle: String?
    @State private var translatedBody: [String]?
    @State private var isTranslated = false
    @State private var isTranslating = false
    /// Streaming in-place translator for the rich (contentHTML) reader: it swaps
    /// each block's text as it arrives while preserving markup. The legacy
    /// `translatedBody` path above still handles plain-paragraph-only articles.
    @State private var nativeTranslator = NativeArticleTranslator()

    /// The language to translate into: the app's chosen language, or the system
    /// language when set to "System".
    private var targetLanguage: Locale.Language {
        let locale = appLanguage == .system ? Locale.current : appLanguage.locale
        return locale.language
    }

    /// True when the article's detected language differs from the target, so
    /// translation is worth offering.
    private var canTranslate: Bool {
        guard let detected = detectedLanguage,
              let target = targetLanguage.languageCode?.identifier else { return false }
        // Compare base languages so a script-qualified detection ("zh-Hans")
        // isn't treated as different from the bare target ("zh").
        let detectedBase = Locale.Language(identifier: detected).languageCode?.identifier ?? detected
        return detectedBase != target
    }

    /// The HTML the reader is actually showing: the reader-mode extraction when
    /// ready, else the feed's own content HTML (nil = plain-paragraph body). The
    /// translator must consume exactly this so its per-block overrides line up
    /// with the rendered blocks.
    /// Cache-warming identity: changes when the article switches, and again when
    /// reader-mode content becomes ready (so the extracted HTML gets warmed too).
    private func warmingKey(for article: Article) -> String {
        if case .ready = store.readerContentState(for: article) { return "\(article.id)|ready" }
        return "\(article.id)"
    }

    private func renderedReaderHTML(for article: Article) -> String? {
        if store.usesReaderContentByDefault, case .ready(let extracted) = store.readerContentState(for: article) {
            return extracted
        }
        return article.contentHTML
    }

    /// Whether the currently-selected article is showing a translation. Rich
    /// articles use the streaming native translator; others use the legacy
    /// plain-body path.
    private func translationActive(_ article: Article) -> Bool {
        renderedReaderHTML(for: article) != nil ? nativeTranslator.isActive : isTranslated
    }

    /// Whether a translation is in progress (either path).
    private var translationBusy: Bool {
        nativeTranslator.isTranslating || isTranslating
    }

    /// The title to show: the streamed translation for rich articles, the legacy
    /// translated title otherwise, else the original.
    private func displayTitle(_ article: Article) -> String {
        if renderedReaderHTML(for: article) != nil {
            return nativeTranslator.isActive ? (nativeTranslator.translatedTitle ?? article.title) : article.title
        }
        return isTranslated ? (translatedTitle ?? article.title) : article.title
    }

    private var readerStyle: ReaderStyle {
        ReaderStyle(
            font: readerFont,
            fontSize: readerFontSize,
            lineHeight: readerLineHeight,
            letterSpacing: readerLetterSpacing,
            backgroundOption: readerBackgroundOption,
            backgroundHex: readerBackgroundHex,
            textOption: readerTextOption,
            textHex: readerTextHex
        )
    }

    /// The article currently on screen, re-resolved live from the store by ID so
    /// mutations made in the reader (star, read) reflect immediately — the captured
    /// `pushed` snapshot the compact shell drives this with wouldn't otherwise
    /// update. Falls back to the snapshot if the store no longer has it.
    private var currentArticle: Article? {
        guard store.isStorageConfigured,
              let base = articleOverride?.wrappedValue ?? store.selectedArticle else { return nil }
        return store.article(withID: base.id) ?? base
    }

    var body: some View {
        Group {
            if !store.isStorageConfigured {
                ContentUnavailableView {
                    Label("Set Up Sync", systemImage: "icloud.and.arrow.up")
                } description: {
                    Text("Choose a sync folder so Nook keeps your feeds in sync across your devices.")
                }
            } else if let article = currentArticle {
                reader(article)
            } else {
                ContentUnavailableView("Select an Article", systemImage: "newspaper")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("ListBackground").ignoresSafeArea())
        // Keep the left-edge swipe-to-go-back working even while the reader hides
        // its back button (immersive reading). Hiding the back button otherwise
        // makes the system disable the interactive pop gesture.
        .background(InteractivePopGestureEnabler())
        .articleImageOverlay(imagePresenter)
        // The interactive coach marks live here — outside the per-article `.id`
        // subtree in `reader(_:)` — so their step survives an article change (the
        // pull-to-next step advances onto the next article without resetting).
        .onPreferenceChange(OriginalButtonFrameKey.self) { originalButtonFrame = $0 }
        .overlay {
            GeometryReader { proxy in
                if coachStep != nil, currentArticle != nil {
                    ReaderCoachMarks(
                        step: $coachStep,
                        size: proxy.size,
                        originalButtonRect: originalButtonFrame == .zero ? nil : originalButtonFrame,
                        onNext: { advanceCoach(from: $0) },
                        onSkip: { withAnimation { coachStep = nil } }
                    )
                }
            }
            .ignoresSafeArea()
        }
        // Advance the walkthrough when the taught action actually happens.
        .onChange(of: currentArticle?.isStarred ?? false) { _, starred in
            if starred { advanceCoach(from: .star) }
        }
        .onChange(of: currentArticle?.id) { _, _ in
            advanceCoach(from: .pullNext)
        }
        .onChange(of: store.isBrowserPresented) { _, presented in
            if presented { advanceCoach(from: .original) }
        }
    }

    /// Advances the coach walkthrough from `step` to the next one (or ends it),
    /// but only if that step is the one currently showing — so a live action and
    /// the "Next" button share one path and out-of-order changes are ignored.
    private func advanceCoach(from step: ReaderCoachStep) {
        guard coachStep == step else { return }
        withAnimation(.easeInOut(duration: 0.28)) { coachStep = step.next }
    }

    private func reader(_ article: Article) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(article)
                    Divider()

                    readerBody(article)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                // Fill at least the whole viewport so the gestures also fire in
                // the empty space below a short article, not only on the text.
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                // Double-tap the body to star; press-and-hold (opt-in) to open the
                // web view with a build-up of haptic taps ending in one deep pulse.
                .onTapGesture(count: 2) {
                    let willStar = !article.isStarred
                    store.toggleStarred(articleID: article.id)
                    haptics.star(on: willStar)
                    triggerStarBurst(on: willStar)
                }
                // Single tap toggles the chrome, so it can be controlled without
                // scrolling. It can only HIDE once the large inline title has
                // scrolled away (same condition the scroll auto-hide uses) — a tap
                // while the big title still shows does nothing; showing is always
                // allowed. Disabled during the coach marks (chrome is frozen then).
                .onTapGesture {
                    guard coachStep == nil else { return }
                    if chromeHidden {
                        withAnimation(.easeInOut(duration: 0.25)) { chromeHidden = false }
                    } else if titleHidden {
                        scrollAccum = 0
                        withAnimation(.easeInOut(duration: 0.25)) { chromeHidden = true }
                    }
                }
                .modifier(LongPressToOpenBrowser(
                    enabled: longPressOpensBrowser,
                    minimumDuration: hapticStartDelay + ReaderHaptics.buildupDuration,
                    onOpen: {
                        pendingBuildup?.cancel()
                        pendingBuildup = nil
                        openBrowser(for: article)
                    },
                    onPressingChanged: { pressing in
                        if pressing {
                            // Defer the haptic; if the finger moves (swipe/scroll),
                            // the gesture cancels and pressing flips false first.
                            pendingBuildup = Task {
                                try? await Task.sleep(for: .seconds(hapticStartDelay))
                                if !Task.isCancelled { haptics.startLongPressBuildup() }
                            }
                        } else {
                            pendingBuildup?.cancel()
                            pendingBuildup = nil
                            haptics.cancelLongPressBuildup()
                        }
                    }
                ))
            }
            // Pull past the bottom for the next article, past the top for the
            // previous one. The web reader keeps its own bottom-only affordance.
            .readerSwipeNavigation(
                nextTitle: store.article(after: article.id)?.title,
                previousTitle: store.article(before: article.id)?.title,
                onNext: { navigatedFromPull = true; navigateReader(forward: true) },
                onPrevious: { navigatedFromPull = true; navigateReader(forward: false) },
                onPullEngagedChange: { engaged in
                    // While the next/prev affordance is on screen, get the (possibly
                    // tap-shown) chrome out of its way so the bar and the indicator
                    // don't overlap. Restore it if the pull is released without
                    // navigating; if it navigates, the new article's scroll position
                    // drives the chrome afresh.
                    if engaged {
                        navigatedFromPull = false
                        chromeShownBeforePull = !chromeHidden
                        if !chromeHidden {
                            withAnimation(.easeInOut(duration: 0.2)) { chromeHidden = true }
                        }
                    } else if navigatedFromPull {
                        navigatedFromPull = false
                    } else if chromeShownBeforePull, chromeHidden {
                        withAnimation(.easeInOut(duration: 0.2)) { chromeHidden = false }
                    }
                }
            )
            .onPreferenceChange(TitleHeightKey.self) { titleHeight = $0 }
            // Reveal the navigation-bar title once the inline title has scrolled up
            // under the bar (its bottom = top padding + its height). The content top
            // sits at the bar's bottom, so the raw scroll offset is the distance
            // travelled — no bar-geometry math needed.
            .onScrollGeometryChange(for: ScrollSnapshot.self) { geo in
                let maxY = max(0, geo.contentSize.height - geo.containerSize.height)
                return ScrollSnapshot(y: geo.contentOffset.y, distanceToBottom: maxY - geo.contentOffset.y)
            } action: { _, snap in
                // Freeze the chrome while the coach marks are up, so the bottom bar
                // (and its document button, spotlighted in one step) stays put.
                guard coachStep == nil else { return }
                let newY = snap.y
                // Content starts under the bar with 16pt top padding, so the inline
                // title's bottom passes the bar after scrolling ~padding + height.
                let pastTitle = newY > titleHeight + 8
                if pastTitle != titleHidden {
                    withAnimation(.easeInOut(duration: 0.2)) { titleHidden = pastTitle }
                }

                let delta = newY - lastScrollY
                lastScrollY = newY

                // Near the bottom, freeze the bars: the bottom bar's collapse/expand
                // there changes the content height and rubber-bands the offset, which
                // would otherwise bounce the bars in and out.
                guard snap.distanceToBottom > 100 else { return }

                // Chrome auto-hide with hysteresis. Accumulate scroll distance since
                // the last direction change; only flip after a sustained move, and
                // always show near the top.
                if (delta > 0) != (scrollAccum > 0) { scrollAccum = 0 }
                scrollAccum += delta

                let target: Bool
                if !pastTitle {
                    target = false
                } else if scrollAccum > 44 {
                    target = true
                } else if scrollAccum < -44 {
                    target = false
                } else {
                    target = chromeHidden
                }
                if target != chromeHidden {
                    scrollAccum = 0
                    withAnimation(.easeInOut(duration: 0.25)) { chromeHidden = target }
                }
            }
        }
        // System inline title: correct width, truncation, and position (centered in
        // the real space between the back button and trailing group) — no custom
        // bounding. Empty near the top (the big inline title in the body shows
        // there); once that scrolls away it fills in, which also anchors the bar's
        // height so hiding the controls never collapses it.
        .navigationTitle(titleHidden ? displayTitle(article) : "")
        .navigationBarTitleDisplayMode(.inline)
        // Hide the chrome by fading the bar BACKGROUNDS (not by removing the bars),
        // so the bars keep their layout space and the body never shifts. Content
        // already scrolls under the translucent bars, so a hidden background simply
        // reveals the body beneath — Safari-style — top and bottom. Controls fade
        // via opacity alongside (below).
        .toolbarBackground(chromeHidden ? .hidden : .automatic, for: .navigationBar)
        // Hide the system back button too while immersed (its own glass capsule
        // would otherwise linger); the edge-swipe back gesture still works, and
        // scrolling up brings the bar — and the button — right back.
        .navigationBarBackButtonHidden(chromeHidden)
        .overlay {
            Image(systemName: starBurstOn ? "star.fill" : "star.slash.fill")
                .font(.system(size: 104, weight: .bold))
                .foregroundStyle(starBurstOn ? .yellow : .white)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .scaleEffect(starBurstScale)
                .opacity(starBurstOpacity)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if translationBusy {
                TranslationProgressBanner()
            }
        }
        // Bottom action bar. Rendered as a content overlay of Liquid Glass capsules
        // (matching the native `.bottomBar` look) rather than a system bottom bar,
        // so its buttons are ordinary SwiftUI views the coach mark can measure and
        // spotlight exactly — while never participating in layout (no shift/bounce).
        .overlay(alignment: .bottom) { readerBottomBar(article) }
        .animation(.easeInOut(duration: 0.2), value: translationBusy)
        .toolbar {
            // The button controls carry iOS 26 glass capsules, so remove them (not
            // just fade them) while immersed — a fade would leave the empty pills.
            // The system navigationTitle (below) fills the bar once the inline title
            // scrolls away, which also keeps the bar from collapsing (no shift).
            if !chromeHidden {
                // Top-right stays a single, uncrowded "more" menu for the occasional
                // actions; the frequent ones live in the bottom toolbar below.
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if canTranslate {
                            Button {
                                toggleTranslation(article)
                            } label: {
                                if translationBusy {
                                    Label("Translating…", systemImage: "character.bubble")
                                } else {
                                    Label(
                                        translationActive(article) ? "Show Original" : "Translate",
                                        systemImage: translationActive(article) ? "character.bubble.fill" : "character.bubble"
                                    )
                                }
                            }
                            .disabled(translationBusy)
                        }
                        Button {
                            isShowingInfo = true
                        } label: {
                            Label("Article Info", systemImage: "info.circle")
                        }
                        Link(destination: article.url) {
                            Label("Open Original", systemImage: "safari")
                        }
                        Divider()
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Delete Article", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task(id: article.id) {
            // Detect the article's language so translation is offered only when
            // it differs from the app's language; reset any prior translation.
            isShowingTranslation = false
            isTranslated = false
            translatedTitle = nil
            translatedBody = nil
            nativeTranslator.stop()
            detectedLanguage = nil
            // Start reader-mode extraction first so it isn't delayed behind
            // language detection.
            store.ensureReaderContent(for: article)
            // First time the reader is ever opened, run the interactive coach-mark
            // walkthrough once. Mark the flag immediately so it's strictly
            // one-shot; the walkthrough persists across article changes (its state
            // lives on the parent), so this guard also keeps a later article change
            // from restarting it.
            if !seenReaderGestureHint {
                seenReaderGestureHint = true
                withAnimation { coachStep = .star }
            }
            // Detect the language off the main actor so the recognizer doesn't
            // run on the transition frame.
            let detected = await Task.detached { Self.detectLanguage(for: article) }.value
            if !Task.isCancelled { detectedLanguage = detected }
        }
        // Warm the reader's text-import cache after the open transition settles, so
        // per-block WebKit imports don't stall scrolling. Re-runs when reader-mode
        // content becomes ready (to warm the extracted HTML shown then), and cancels
        // on article switch. Skipped while translating (the translator replaces
        // blocks, so warming the untranslated keys would be wasted).
        .task(id: warmingKey(for: article)) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, !nativeTranslator.isActive else { return }
            if let html = renderedReaderHTML(for: article) {
                await HTMLContentText.warmReaderAttributedCache(html: html, baseURL: article.url)
            }
        }
        // If reader-mode content finishes extracting AFTER translation was turned
        // on, restart the translator against the now-rendered extracted HTML so
        // its per-block overrides line up with what's shown.
        .onChange(of: store.readerContentState(for: article)) { _, newValue in
            guard nativeTranslator.isActive, case .ready(let extracted) = newValue else { return }
            nativeTranslator.start(html: extracted, baseURL: article.url, title: article.title, into: targetLanguageName)
        }
        .translationPresentation(
            isPresented: $isShowingTranslation,
            text: Self.translationText(for: article)
        )
        .sheet(isPresented: $store.isBrowserPresented) {
            InAppBrowserSheet(
                store: store,
                article: article,
                style: readerStyle,
                linkOpensInApp: readerLinkBehavior == .inApp
            )
        }
        .sheet(isPresented: $isShowingInfo) {
            ArticleInfoView(store: store, article: article)
        }
        .confirmationDialog(
            "Delete this article?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Article", role: .destructive) { deleteAndClose(article) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's removed from your list on all your devices. This can't be undone.")
        }
        .id(article.id)
        .transition(.push(from: readerNavForward ? .bottom : .top))
    }

    /// Whether the last article change moved forward (next). Drives the push
    /// transition direction so previous/next slide the natural way.
    @State private var readerNavForward = true

    /// Navigates to the adjacent article with a directional push animation.
    private func navigateReader(forward: Bool) {
        // Navigate relative to the article actually on screen (the override binding
        // when pushed in a tab, else the store selection), and move BOTH that
        // binding and the store selection — otherwise the pushed reader keeps
        // showing the captured article and the gesture appears to do nothing.
        let currentID = (articleOverride?.wrappedValue ?? store.selectedArticle)?.id
        guard let currentID else { return }
        guard let next = forward ? store.article(after: currentID) : store.article(before: currentID) else { return }
        readerNavForward = forward
        withAnimation(.easeInOut(duration: 0.3)) {
            store.selectedArticleID = next.id
            articleOverride?.wrappedValue = next
        }
    }

    /// Deletes the article (its original is gone) and leaves the reader: clears
    /// the pushed binding to pop on iPhone; on iPad the store clears the selection
    /// so the detail column empties.
    private func deleteAndClose(_ article: Article) {
        store.deleteArticle(articleID: article.id)
        articleOverride?.wrappedValue = nil
    }

    /// The reader body: reader-mode-extracted content when the experiment is on,
    /// falling back to the original feed content (with a notice) on failure.
    @ViewBuilder
    private func readerBody(_ article: Article) -> some View {
        if store.usesReaderContentByDefault {
            switch store.readerContentState(for: article) {
            case .ready(let html):
                HTMLContentView(html: html, baseURL: article.url, selectable: false, translator: nativeTranslator)
            case .failed, .gone:
                VStack(alignment: .leading, spacing: 14) {
                    ReaderUnavailableNotice(
                        onRetry: { store.retryReaderContent(for: article) },
                        onDelete: { deleteAndClose(article) }
                    )
                    originalArticleBody(article)
                }
            case .loading, .none:
                ReaderLoadingPlaceholder()
            }
        } else {
            originalArticleBody(article)
        }
    }

    /// The article's original feed content — the pre-experiment reading surface.
    @ViewBuilder
    private func originalArticleBody(_ article: Article) -> some View {
        if let html = article.contentHTML {
            // Text selection is disabled so the double-tap / long-press gestures
            // own the body. The translator streams translated blocks when active.
            HTMLContentView(html: html, baseURL: article.url, selectable: false, translator: nativeTranslator)
        } else if isTranslated, let translatedBody {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(translatedBody.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(article.bodyParagraphs, id: \.self) { paragraph in
                    Text(paragraph)
                        .font(.body)
                        .lineSpacing(4)
                }
            }
        }
    }

    private func header(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title first and prominent (system text style, Dynamic Type), the way
            // Safari Reader / News present an article.
            Text(displayTitle(article))
                .font(.title.weight(.bold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: TitleHeightKey.self, value: g.size.height)
                    }
                )

            // Source + date as a single secondary metadata line. The feed name
            // truncates with an ellipsis so a long name never wraps or pushes the
            // date off; the date keeps its intrinsic width.
            HStack(spacing: 6) {
                if let feed = store.feed(for: article.feedID) {
                    if let icon = store.faviconImage(for: feed) {
                        icon.resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    } else {
                        Image(systemName: feed.systemImage).imageScale(.small)
                    }
                    Text(feed.displayTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                }
                Text(article.publishedAt.localized(date: .abbreviated, time: .shortened))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if translationActive(article) {
                Label("Translated by Apple Intelligence", systemImage: "apple.intelligence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Pops a large star over the article that springs in, holds, then fades
    /// out and drifts up — the visual counterpart to the double-tap star.
    private func triggerStarBurst(on: Bool) {
        starBurstOn = on
        starBurstScale = 0.4
        starBurstOpacity = 0
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
            starBurstScale = 1.0
            starBurstOpacity = 1.0
        }
        Task {
            try? await Task.sleep(for: .seconds(0.45))
            withAnimation(.easeOut(duration: 0.35)) {
                starBurstOpacity = 0
                starBurstScale = 1.3
            }
        }
    }

    private func openBrowser(for article: Article) {
        store.browserMode = store.resolvedBrowserMode(for: article)
        store.isBrowserPresented = true
    }

    /// The reader's bottom action bar, built to look like the native iOS 26
    /// `.bottomBar`: Liquid Glass capsules floating over the content (share + star
    /// grouped on the leading side, open-original trailing), with content scrolling
    /// under them. It's a content overlay — so it never affects layout (no
    /// collapse/shift/bounce) and its buttons are ordinary SwiftUI views the coach
    /// mark can measure. Fades with the chrome.
    private func readerBottomBar(_ article: Article) -> some View {
        GlassBarContainer {
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    ShareLink(item: article.url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 20))
                            .frame(width: 52, height: 48)
                    }
                    Button {
                        let willStar = !article.isStarred
                        store.toggleStarred(articleID: article.id)
                        haptics.star(on: willStar)
                    } label: {
                        Image(systemName: article.isStarred ? "star.fill" : "star")
                            .font(.system(size: 20))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 52, height: 48)
                    }
                }
                .glassCapsule()

                Spacer(minLength: 0)

                Button {
                    openBrowser(for: article)
                } label: {
                    Image(systemName: "doc.plaintext")
                        .font(.system(size: 20))
                        .frame(width: 52, height: 48)
                }
                .glassCapsule()
                // Publish the real capsule frame so the coach mark spotlights it.
                .reportGlobalFrame(OriginalButtonFrameKey.self)
                .help("Open Reader / Original")
            }
            .tint(Color("AccentColor"))
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .opacity(chromeHidden ? 0 : 1)
        .allowsHitTesting(!chromeHidden)
        .animation(.easeInOut(duration: 0.25), value: chromeHidden)
    }

    // MARK: - Translation

    /// Detects the dominant language of an article's text (e.g. "en", "ko").
    nonisolated static func detectLanguage(for article: Article) -> String? {
        let sample = (article.bodyParagraphs.prefix(4).joined(separator: " ") + " " + article.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.dominantLanguage?.rawValue
    }

    /// The text handed to the system translation overlay: the title followed by
    /// the article body.
    private static func translationText(for article: Article) -> String {
        ([article.title] + article.bodyParagraphs)
            .joined(separator: "\n\n")
    }

    /// The target language's English name for the translation prompt (e.g.
    /// "Korean"), which reads more reliably to the model than a code.
    private var targetLanguageName: String {
        // Give the model the script for Chinese so it doesn't guess Simplified vs
        // Traditional; other languages use their plain English name.
        if let script = targetLanguage.script?.identifier {
            if script == "Hans" { return "Simplified Chinese" }
            if script == "Hant" { return "Traditional Chinese" }
        }
        let code = targetLanguage.languageCode?.identifier ?? "en"
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }

    /// Toggles inline translation. Uses Apple Intelligence for a natural
    /// translation when available; otherwise presents the system Translation
    /// overlay as a fallback.
    private func toggleTranslation(_ article: Article) {
        // Rich articles translate in place, block by block, preserving markup —
        // against the same HTML the reader renders (extracted reader-mode content
        // when ready), so overrides line up with the shown blocks.
        if let html = renderedReaderHTML(for: article) {
            if nativeTranslator.isActive {
                nativeTranslator.stop()
            } else if NaturalTranslator.isAvailable {
                nativeTranslator.start(
                    html: html, baseURL: article.url, title: article.title, into: targetLanguageName
                )
            } else {
                isShowingTranslation = true
            }
            return
        }

        // Plain-paragraph articles: legacy whole-body translation.
        if isTranslated {
            isTranslated = false
            return
        }
        if translatedBody != nil {
            isTranslated = true
            return
        }
        guard NaturalTranslator.isAvailable else {
            isShowingTranslation = true
            return
        }
        isTranslating = true
        let body = article.bodyParagraphs
        let title = article.title
        let language = targetLanguageName
        Task {
            defer { isTranslating = false }
            do {
                async let titleText = NaturalTranslator.translate(title, into: language)
                async let bodyText = NaturalTranslator.translate(body.joined(separator: "\n\n"), into: language)
                let (t, b) = try await (titleText, bodyText)
                // Guard against the model "answering" an imperative title instead
                // of translating it: drop a result that ballooned past the source.
                let cleanedTitle = t.trimmingCharacters(in: .whitespacesAndNewlines)
                translatedTitle = cleanedTitle.count <= max(120, title.count * 4) ? cleanedTitle : title
                translatedBody = b
                    .components(separatedBy: "\n\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                isTranslated = true
            } catch {
                // Apple Intelligence unavailable mid-flight — fall back.
                isShowingTranslation = true
            }
        }
    }

}

/// Restores the navigation stack's left-edge swipe-to-go-back while a pushed
/// screen hides its back button. SwiftUI (via UIKit) disables the
/// `interactivePopGestureRecognizer` when there's no visible back button, so the
/// reader's immersive mode — which hides the button — would otherwise lose the
/// edge swipe. This installs a permissive gesture delegate that allows the pop
/// whenever the stack has something to pop back to, and restores the original
/// delegate when it goes away.
private struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        // Defer so the view is in the hierarchy and `navigationController` resolves.
        DispatchQueue.main.async {
            guard let gesture = controller.navigationController?.interactivePopGestureRecognizer else { return }
            context.coordinator.navigationController = controller.navigationController
            if context.coordinator.originalDelegate == nil, gesture.delegate !== context.coordinator {
                context.coordinator.originalDelegate = gesture.delegate
            }
            gesture.delegate = context.coordinator
            gesture.isEnabled = true
        }
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        if let gesture = coordinator.navigationController?.interactivePopGestureRecognizer,
           gesture.delegate === coordinator {
            gesture.delegate = coordinator.originalDelegate
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?
        weak var originalDelegate: UIGestureRecognizerDelegate?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // Only pop when there's a screen to go back to (never at the root).
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

/// Article metadata, mirroring the macOS inspector: status, published date,
/// reading time, read/starred toggles, and the source feed.
struct ArticleInfoView: View {
    @Bindable var store: ReaderStore
    let article: Article

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Article") {
                    LabeledContent("Status", value: article.isRead ? String(localized: "Read") : String(localized: "Unread"))
                    LabeledContent("Published", value: article.publishedAt.localized(date: .abbreviated, time: .shortened))
                    LabeledContent("Reading Time", value: String(localized: "\(article.estimatedReadMinutes) min"))
                    Toggle("Starred", isOn: store.starredBinding(articleID: article.id))
                    Toggle("Read", isOn: store.readBinding(articleID: article.id))
                }

                if let feed = store.feed(for: article.feedID) {
                    Section("Source") {
                        LabeledContent("Feed", value: feed.displayTitle)
                        if !feed.category.isEmpty {
                            LabeledContent("Category", value: feed.category)
                        }
                        LabeledContent(
                            "Last Refresh",
                            value: feed.lastFetchedAt?.localized(date: .abbreviated, time: .shortened) ?? String(localized: "Never")
                        )
                        Link("Open Site", destination: feed.siteURL)
                        Link("Open Feed", destination: feed.feedURL)
                    }
                }

                Section {
                    Link("Open Article", destination: article.url)
                }
            }
            .navigationTitle("Article Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The in-app browser sheet: the shared `ArticleWebView` with a toolbar to
/// switch reader/original, open in the system browser, and share.
struct InAppBrowserSheet: View {
    @Bindable var store: ReaderStore
    let article: Article
    let style: ReaderStyle
    let linkOpensInApp: Bool

    @Environment(\.dismiss) private var dismiss
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @State private var isTranslationOn = false
    @State private var translationInFlight = false
    @State private var loadingProgress: Double = 0
    @State private var bottomPull: CGFloat = 0
    /// The page's live URL (following redirects / navigation), handed to Safari.
    @State private var currentWebURL: URL?
    /// When set, present the page in Safari (shares the system session, so
    /// logins and passkeys work); nil dismisses.
    @State private var safariURL: URL?

    /// Web-view translation uses Apple Intelligence; offer it only when that's
    /// available and the article's language differs from the app's.
    private var canTranslate: Bool {
        guard NaturalTranslator.isAvailable,
              let detected = ReaderDetailView.detectLanguage(for: article),
              let target = targetLanguage.languageCode?.identifier else { return false }
        let detectedBase = Locale.Language(identifier: detected).languageCode?.identifier ?? detected
        return detectedBase != target
    }

    private var targetLanguage: Locale.Language {
        let locale = appLanguage == .system ? Locale.current : appLanguage.locale
        return locale.language
    }

    private var targetLanguageName: String {
        // Give the model the script for Chinese so it doesn't guess Simplified vs
        // Traditional; other languages use their plain English name.
        if let script = targetLanguage.script?.identifier {
            if script == "Hans" { return "Simplified Chinese" }
            if script == "Hant" { return "Traditional Chinese" }
        }
        let code = targetLanguage.languageCode?.identifier ?? "en"
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }

    /// A short bottom pull-up opens the next article; a longer one closes the
    /// browser; anything less snaps back.
    private func handleBottomRelease(_ amount: CGFloat) {
        if amount >= BottomPullAffordance.closeThreshold {
            dismiss()
        } else if amount >= BottomPullAffordance.nextThreshold {
            store.selectNextArticle()
            bottomPull = 0
        } else {
            withAnimation(.easeOut(duration: 0.2)) { bottomPull = 0 }
        }
    }

    var body: some View {
        NavigationStack {
            ArticleWebView(
                url: article.url,
                useReaderMode: store.browserMode == .reader,
                style: style,
                linkOpensInApp: linkOpensInApp,
                translate: isTranslationOn,
                translationLanguage: targetLanguageName,
                onTranslatingChange: { translationInFlight = $0 },
                onLoadingProgress: { loadingProgress = $0 },
                onBottomOverscroll: { bottomPull = $0 },
                onBottomOverscrollEnded: handleBottomRelease,
                onURLChange: { currentWebURL = $0 }
            )
            .id("\(article.id)|\(store.browserMode.rawValue)|\(style.identity)")
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                WebLoadingBar(progress: loadingProgress)
            }
            .overlay(alignment: .bottom) {
                BottomPullAffordance(pull: bottomPull, nextTitle: store.article(after: article.id)?.title)
            }
            .overlay(alignment: .top) {
                if translationInFlight {
                    TranslationProgressBanner()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: translationInFlight)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Button {
                        store.toggleBrowserMode()
                    } label: {
                        Label(
                            store.browserMode == .reader ? "Reader" : "Original",
                            systemImage: store.browserMode == .reader ? "doc.plaintext" : "globe"
                        )
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if canTranslate {
                        Button {
                            isTranslationOn.toggle()
                        } label: {
                            Image(systemName: isTranslationOn ? "character.bubble.fill" : "character.bubble")
                        }
                    }
                    Button {
                        // Open the CURRENT page in Safari (in-app) — it shares the
                        // system session, so logins and passkeys, which an embedded
                        // WKWebView can't do for arbitrary sites, work there.
                        let target = currentWebURL ?? article.url
                        safariURL = ["http", "https"].contains(target.scheme?.lowercased() ?? "") ? target : article.url
                    } label: {
                        Image(systemName: "safari")
                    }
                    .accessibilityLabel(Text("Open in Safari"))
                    ShareLink(item: article.url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { safariURL != nil }, set: { if !$0 { safariURL = nil } })) {
            if let safariURL {
                SafariView(url: safariURL).ignoresSafeArea()
            }
        }
        .task(id: article.id) {
            store.retainArticle(id: article.id)
            if markReadOnOpen {
                store.markArticleOpened(articleID: article.id)
            }
        }
    }
}

/// Presents a page in `SFSafariViewController` — a real Safari surface that runs
/// in its own process with the user's Safari session, so logins and passkeys
/// (which an embedded WKWebView can't do for arbitrary sites) work. Shown in-app
/// as a full-screen cover; its session doesn't flow back into our WKWebView.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Applies the press-and-hold-to-open-browser gesture only when the opt-in
/// setting is enabled; otherwise the body carries no long-press gesture.
private struct LongPressToOpenBrowser: ViewModifier {
    let enabled: Bool
    let minimumDuration: Double
    let onOpen: () -> Void
    let onPressingChanged: (Bool) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onLongPressGesture(
                minimumDuration: minimumDuration,
                maximumDistance: 10,
                perform: onOpen,
                onPressingChanged: onPressingChanged
            )
        } else {
            content
        }
    }
}

/// A small "translating" banner shown while Apple Intelligence works, so a slow
/// translation reads as in-progress rather than stuck.
struct TranslationProgressBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Translating with Apple Intelligence…")
                .font(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.top, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
