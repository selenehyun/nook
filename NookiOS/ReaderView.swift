import NaturalLanguage
import NookKit
import SwiftUI
import Translation

/// The iOS article reader. Mirrors the macOS reader: a native, selectable body
/// (system typography) with a toggle into the styled `WKWebView` reader/original
/// page presented as a sheet.
struct ReaderDetailView: View {
    @Bindable var store: ReaderStore

    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @AppStorage("readerLinkBehavior") private var readerLinkBehavior = ReaderLinkBehavior.inApp
    @AppStorage("readerFont") private var readerFont = ReaderFont.system
    @AppStorage("readerFontSize") private var readerFontSize = 18
    @AppStorage("readerLineHeight") private var readerLineHeight = 1.7
    @AppStorage("readerLetterSpacing") private var readerLetterSpacing = 0.0
    @AppStorage("readerBackgroundOption") private var readerBackgroundOption = ReaderColorOption.automatic
    @AppStorage("readerBackgroundHex") private var readerBackgroundHex = "#FFFFFF"
    @AppStorage("readerTextOption") private var readerTextOption = ReaderColorOption.automatic
    @AppStorage("readerTextHex") private var readerTextHex = "#1A1A1A"

    @State private var isShowingInfo = false
    @State private var imagePresenter = ArticleImagePresenter()
    @State private var haptics = ReaderHaptics()
    @State private var pendingBuildup: Task<Void, Never>?

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
        return detected != target
    }

    /// Whether the currently-selected article is showing a translation. Rich
    /// (contentHTML) articles use the streaming native translator; others use the
    /// legacy plain-body path.
    private func translationActive(_ article: Article) -> Bool {
        article.contentHTML != nil ? nativeTranslator.isActive : isTranslated
    }

    /// Whether a translation is in progress (either path).
    private var translationBusy: Bool {
        nativeTranslator.isTranslating || isTranslating
    }

    /// The title to show: the streamed translation for rich articles, the legacy
    /// translated title otherwise, else the original.
    private func displayTitle(_ article: Article) -> String {
        if article.contentHTML != nil {
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

    var body: some View {
        Group {
            if !store.isStorageConfigured {
                ContentUnavailableView {
                    Label("Set Up Sync", systemImage: "icloud.and.arrow.up")
                } description: {
                    Text("Choose a sync folder so Nook keeps your feeds in sync across your devices.")
                }
            } else if let article = store.selectedArticle {
                reader(article)
            } else {
                ContentUnavailableView("Select an Article", systemImage: "newspaper")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color("ListBackground").ignoresSafeArea())
        .articleImageOverlay(imagePresenter)
    }

    private func reader(_ article: Article) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(article)
                    Divider()

                    if let html = article.contentHTML {
                        // Text selection is disabled so the double-tap /
                        // long-press gestures below own the body. The translator
                        // streams translated blocks in place when active.
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

                    Spacer(minLength: 0)
                }
                .padding()
                // Fill at least the whole viewport so the gestures also fire in
                // the empty space below a short article, not only on the text.
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                // Double-tap the body to star; press-and-hold to open the web
                // view with a build-up of haptic taps ending in one deep pulse.
                .onTapGesture(count: 2) {
                    let willStar = !article.isStarred
                    store.toggleStarred(articleID: article.id)
                    haptics.star(on: willStar)
                    triggerStarBurst(on: willStar)
                }
                .onLongPressGesture(minimumDuration: hapticStartDelay + ReaderHaptics.buildupDuration, maximumDistance: 10) {
                    pendingBuildup?.cancel()
                    pendingBuildup = nil
                    openBrowser(for: article)
                } onPressingChanged: { pressing in
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
            }
        }
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
        .animation(.easeInOut(duration: 0.2), value: translationBusy)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    openBrowser(for: article)
                } label: {
                    Image(systemName: "doc.plaintext")
                }
                .help("Open Reader / Original")

                Button {
                    store.toggleStarred(articleID: article.id)
                } label: {
                    Image(systemName: article.isStarred ? "star.fill" : "star")
                        .contentTransition(.symbolEffect(.replace))
                }

                Menu {
                    Button {
                        isShowingInfo = true
                    } label: {
                        Label("Article Info", systemImage: "info.circle")
                    }
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
                    ShareLink(item: article.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Link(destination: article.url) {
                        Label("Open Original", systemImage: "safari")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
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
            detectedLanguage = Self.detectLanguage(for: article)
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
    }

    private func header(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let feed = store.feed(for: article.feedID) {
                    if let icon = store.faviconImage(for: feed) {
                        icon.resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    } else {
                        Image(systemName: feed.systemImage)
                    }
                    Text(feed.displayTitle)
                }
                Text("·")
                Text(article.publishedAt.localized(date: .abbreviated, time: .shortened))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Text(displayTitle(article))
                .font(.title.bold())
                .textSelection(.enabled)

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

    // MARK: - Translation

    /// Detects the dominant language of an article's text (e.g. "en", "ko").
    static func detectLanguage(for article: Article) -> String? {
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
        let code = targetLanguage.languageCode?.identifier ?? "en"
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }

    /// Toggles inline translation. Uses Apple Intelligence for a natural
    /// translation when available; otherwise presents the system Translation
    /// overlay as a fallback.
    private func toggleTranslation(_ article: Article) {
        // Rich articles translate in place, block by block, preserving markup.
        if let html = article.contentHTML {
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
    @Environment(\.openURL) private var openURL
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @State private var isTranslationOn = false
    @State private var translationInFlight = false
    @State private var loadingProgress: Double = 0
    @State private var bottomPull: CGFloat = 0

    /// Web-view translation uses Apple Intelligence; offer it only when that's
    /// available and the article's language differs from the app's.
    private var canTranslate: Bool {
        guard NaturalTranslator.isAvailable,
              let detected = ReaderDetailView.detectLanguage(for: article),
              let target = targetLanguage.languageCode?.identifier else { return false }
        return detected != target
    }

    private var targetLanguage: Locale.Language {
        let locale = appLanguage == .system ? Locale.current : appLanguage.locale
        return locale.language
    }

    private var targetLanguageName: String {
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
                onBottomOverscrollEnded: handleBottomRelease
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
                        openURL(article.url)
                    } label: {
                        Image(systemName: "safari")
                    }
                    ShareLink(item: article.url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
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
