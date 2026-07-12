import NookKit
import SwiftUI

/// The iOS article reader. Mirrors the macOS reader: a native, selectable body
/// (system typography) with a toggle into the styled `WKWebView` reader/original
/// page presented as a sheet.
struct ReaderDetailView: View {
    @Bindable var store: ReaderStore

    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage("markReadDelaySeconds") private var markReadDelaySeconds = 3
    @AppStorage("readerViewMode") private var readerViewMode = ReaderViewMode.reader
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
    }

    private func reader(_ article: Article) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(article)
                Divider()

                if let html = article.contentHTML {
                    HTMLContentText(html: html)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(article.bodyParagraphs, id: \.self) { paragraph in
                            Text(paragraph)
                                .font(.body)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: article.id) { await markReadAfterDwell(article) }
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
                }

                Menu {
                    Button {
                        isShowingInfo = true
                    } label: {
                        Label("Article Info", systemImage: "info.circle")
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
                    Text(feed.title)
                }
                Text("·")
                Text(article.publishedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Text(article.title)
                .font(.title.bold())
                .textSelection(.enabled)
        }
    }

    private func openBrowser(for article: Article) {
        let feedMode = store.feed(for: article.feedID)?.preferredViewMode
        store.browserMode = feedMode ?? readerViewMode
        store.isBrowserPresented = true
    }

    /// Keeps the article visible while reading, then marks it read only after
    /// the user dwells for the configured delay. Navigating away cancels this
    /// task before the delay elapses, so the article stays unread.
    private func markReadAfterDwell(_ article: Article) async {
        store.retainArticle(id: article.id)
        guard markReadOnOpen else { return }
        do {
            if markReadDelaySeconds > 0 {
                try await Task.sleep(for: .seconds(Double(markReadDelaySeconds)))
            } else {
                await Task.yield()
            }
            store.markArticleOpened(articleID: article.id)
        } catch {
            // Cancelled before the dwell completed — leave it unread.
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
                    LabeledContent("Published", value: article.publishedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Reading Time", value: String(localized: "\(article.estimatedReadMinutes) min"))
                    Toggle("Starred", isOn: store.starredBinding(articleID: article.id))
                    Toggle("Read", isOn: store.readBinding(articleID: article.id))
                }

                if let feed = store.feed(for: article.feedID) {
                    Section("Source") {
                        LabeledContent("Feed", value: feed.title)
                        if !feed.category.isEmpty {
                            LabeledContent("Category", value: feed.category)
                        }
                        LabeledContent(
                            "Last Refresh",
                            value: feed.lastFetchedAt?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Never")
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

    var body: some View {
        NavigationStack {
            ArticleWebView(
                url: article.url,
                useReaderMode: store.browserMode == .reader,
                style: style,
                linkOpensInApp: linkOpensInApp
            )
            .id("\(article.id)|\(store.browserMode.rawValue)|\(style.identity)")
            .ignoresSafeArea(edges: .bottom)
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
