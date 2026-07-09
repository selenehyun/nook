import Observation
import SwiftUI

struct ContentView: View {
    @State private var store = ReaderStore()
    @State private var isAddingFeed = false
    @State private var isInspectorPresented = true

    var body: some View {
        NavigationSplitView {
            FeedSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } content: {
            ArticleListView(store: store)
                .navigationSplitViewColumnWidth(min: 340, ideal: 420, max: 520)
        } detail: {
            ReaderWorkspaceView(store: store, isInspectorPresented: $isInspectorPresented)
        }
        .frame(minWidth: 920, minHeight: 640)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    isAddingFeed = true
                } label: {
                    Label("Add Feed", systemImage: "plus")
                }
                .help("Add Feed")

                Button {
                    store.refreshAll()
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .help("Refresh All Feeds")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.toggleSelectedStarred()
                } label: {
                    Label(
                        store.selectedArticle?.isStarred == true ? "Unstar" : "Star",
                        systemImage: store.selectedArticle?.isStarred == true ? "star.fill" : "star"
                    )
                }
                .disabled(store.selectedArticle == nil)
                .help("Star Article")

                Button {
                    store.markSelectedRead()
                } label: {
                    Label("Mark Read", systemImage: "checkmark.circle")
                }
                .disabled(store.selectedArticle == nil)
                .help("Mark Selected Article as Read")

                if let article = store.selectedArticle {
                    ShareLink(item: article.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share Article")
                }

                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Toggle Inspector")
            }
        }
        .sheet(isPresented: $isAddingFeed) {
            AddFeedSheet { feedURL in
                store.addFeed(urlString: feedURL)
            }
        }
        .focusedSceneValue(
            \.readerCommandActions,
            ReaderCommandActions(
                refreshAll: store.refreshAll,
                markSelectedRead: store.markSelectedRead,
                toggleSelectedStarred: store.toggleSelectedStarred,
                selectNextArticle: store.selectNextArticle,
                selectPreviousArticle: store.selectPreviousArticle
            )
        )
    }
}

private struct ReaderWorkspaceView: View {
    @Bindable var store: ReaderStore
    @Binding var isInspectorPresented: Bool

    var body: some View {
        HStack(spacing: 0) {
            ReaderDetailView(store: store)

            if isInspectorPresented {
                Divider()

                ArticleInspector(store: store)
                    .frame(width: 300)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }
}

private struct FeedSidebar: View {
    @Bindable var store: ReaderStore

    var body: some View {
        List(selection: $store.selectedSource) {
            Section("Library") {
                ForEach(SmartSource.allCases) { source in
                    SourceRow(
                        title: source.title,
                        systemImage: source.systemImage,
                        count: store.count(for: source)
                    )
                    .tag(SourceSelection.smart(source))
                }
            }

            Section("Feeds") {
                ForEach(store.feeds) { feed in
                    SourceRow(
                        title: feed.title,
                        subtitle: feed.siteDescription,
                        systemImage: feed.systemImage,
                        count: store.unreadCount(feedID: feed.id)
                    )
                    .tag(SourceSelection.feed(feed.id))
                    .contextMenu {
                        Button("Refresh Feed") {
                            store.refresh(feedID: feed.id)
                        }
                        Button("Mark Feed as Read") {
                            store.markFeedRead(feedID: feed.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Feeds")
    }
}

private struct SourceRow: View {
    var title: String
    var subtitle: String?
    var systemImage: String
    var count: Int

    var body: some View {
        Label {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if count > 0 {
                    Text(count, format: .number)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

private struct ArticleListView: View {
    @Bindable var store: ReaderStore

    var body: some View {
        Group {
            if store.visibleArticles.isEmpty {
                ContentUnavailableView {
                    Label("No Articles", systemImage: "newspaper")
                } description: {
                    Text(store.searchText.isEmpty ? "Refresh feeds or add a new source." : "No article matches the current search.")
                }
            } else {
                List(selection: $store.selectedArticleID) {
                    ForEach(store.visibleArticles) { article in
                        ArticleRow(article: article, feed: store.feed(for: article.feedID))
                            .tag(article.id)
                            .contextMenu {
                                Button(article.isRead ? "Mark as Unread" : "Mark as Read") {
                                    store.setRead(articleID: article.id, isRead: !article.isRead)
                                }
                                Button(article.isStarred ? "Remove Star" : "Star") {
                                    store.toggleStarred(articleID: article.id)
                                }
                                Divider()
                                Link("Open in Browser", destination: article.url)
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(store.selectedSourceTitle)
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search Articles")
        .safeAreaInset(edge: .bottom) {
            ArticleListStatusBar(store: store)
        }
        .onChange(of: store.selectedSource) { _, _ in
            store.selectFirstVisibleArticleIfNeeded()
        }
        .onChange(of: store.searchText) { _, _ in
            store.selectFirstVisibleArticleIfNeeded()
        }
    }
}

private struct ArticleRow: View {
    var article: Article
    var feed: Feed?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(article.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(article.title)
                        .fontWeight(article.isRead ? .regular : .semibold)
                        .lineLimit(2)

                    if article.isStarred {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Starred")
                    }
                }

                Text(article.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(feed?.title ?? "Unknown Feed")
                    Text("·")
                    Text(article.publishedAt, format: .relative(presentation: .named))
                    Text("·")
                    Text("\(article.estimatedReadMinutes) min")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ArticleListStatusBar: View {
    @Bindable var store: ReaderStore

    var body: some View {
        HStack(spacing: 12) {
            Text("\(store.visibleArticles.count) articles")
            Text("\(store.unreadCount()) unread")

            Spacer()

            Picker("Filter", selection: $store.readingFilter) {
                ForEach(ReadingFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

private struct ReaderDetailView: View {
    @Bindable var store: ReaderStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let article = store.selectedArticle {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        articleHeader(article)

                        Divider()

                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(article.bodyParagraphs, id: \.self) { paragraph in
                                Text(paragraph)
                                    .font(.body)
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                            }
                        }

                        Divider()

                        HStack {
                            Link(destination: article.url) {
                                Label("Open Original", systemImage: "safari")
                            }

                            ShareLink(item: article.url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 44)
                    .padding(.vertical, 36)
                    .frame(maxWidth: 820, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .task(id: article.id) {
                    await Task.yield()
                    store.markArticleOpened(articleID: article.id)
                }
            } else {
                ContentUnavailableView {
                    Label("Select an Article", systemImage: "newspaper")
                } description: {
                    Text("Choose a story from the article list.")
                }
            }
        }
    }

    private func articleHeader(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let feed = store.feed(for: article.feedID) {
                    Label(feed.title, systemImage: feed.systemImage)
                }

                Text("·")

                Text(article.publishedAt.formatted(date: .abbreviated, time: .shortened))

                Text("·")

                Text("\(article.estimatedReadMinutes) min read")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Text(article.title)
                .font(.system(.largeTitle, design: .serif))
                .fontWeight(.semibold)
                .lineLimit(nil)
                .textSelection(.enabled)

            Text(article.summary)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineSpacing(3)

            HStack(spacing: 10) {
                Button {
                    store.toggleStarred(articleID: article.id)
                } label: {
                    Label(article.isStarred ? "Starred" : "Star", systemImage: article.isStarred ? "star.fill" : "star")
                }

                Button {
                    openURL(article.url)
                } label: {
                    Label("Open", systemImage: "arrow.up.forward")
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct ArticleInspector: View {
    @Bindable var store: ReaderStore

    var body: some View {
        Form {
            if let article = store.selectedArticle {
                Section("Article") {
                    LabeledContent("Status", value: article.isRead ? "Read" : "Unread")
                    LabeledContent("Published", value: article.publishedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Reading Time", value: "\(article.estimatedReadMinutes) min")

                    Toggle("Starred", isOn: store.starredBinding(articleID: article.id))
                    Toggle("Read", isOn: store.readBinding(articleID: article.id))
                }

                Section("Source") {
                    if let feed = store.feed(for: article.feedID) {
                        LabeledContent("Feed", value: feed.title)
                        LabeledContent("Category", value: feed.category)
                        Link("Open Site", destination: feed.siteURL)
                    }

                    Link("Open Article", destination: article.url)
                }

                Section("Feed Health") {
                    if let feed = store.feed(for: article.feedID) {
                        Gauge(value: feed.healthScore, in: 0...1) {
                            Text("Availability")
                        } currentValueLabel: {
                            Text(feed.healthScore.formatted(.percent))
                        }
                    }
                }
            } else {
                ContentUnavailableView("No Article", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AddFeedSheet: View {
    var onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var feedURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add Feed")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Paste an RSS, Atom, or website URL. The parser will be wired in after the UI flow is settled.")
                    .foregroundStyle(.secondary)
            }

            TextField("https://example.com/feed.xml", text: $feedURL)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    onAdd(feedURL)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

struct ReaderSettingsView: View {
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes = 30
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage("openLinksInBrowser") private var openLinksInBrowser = true

    var body: some View {
        Form {
            Section("Reading") {
                Toggle("Mark articles as read when opened", isOn: $markReadOnOpen)
                Toggle("Open original links in the default browser", isOn: $openLinksInBrowser)
            }

            Section("Feeds") {
                Stepper("Refresh every \(refreshIntervalMinutes) minutes", value: $refreshIntervalMinutes, in: 5...240, step: 5)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
    }
}

@MainActor
@Observable
private final class ReaderStore {
    var feeds: [Feed] = Feed.sampleFeeds
    var articles: [Article] = Article.sampleArticles
    var selectedSource: SourceSelection? = .smart(.unread)
    var selectedArticleID: Article.ID? = Article.sampleArticles.first?.id
    var searchText = ""
    var readingFilter = ReadingFilter.all
    var lastRefreshedAt = Date.now

    var selectedArticle: Article? {
        guard let selectedArticleID else { return nil }
        return articles.first { $0.id == selectedArticleID }
    }

    var visibleArticles: [Article] {
        articles
            .filter(matchesSelectedSource)
            .filter(matchesReadingFilter)
            .filter(matchesSearch)
            .sorted { $0.publishedAt > $1.publishedAt }
    }

    var selectedSourceTitle: String {
        switch selectedSource {
        case .smart(let source):
            source.title
        case .feed(let feedID):
            feed(for: feedID)?.title ?? "Feed"
        case nil:
            "Articles"
        }
    }

    func feed(for feedID: Feed.ID) -> Feed? {
        feeds.first { $0.id == feedID }
    }

    func unreadCount(feedID: Feed.ID? = nil) -> Int {
        articles.filter { article in
            !article.isRead && (feedID == nil || article.feedID == feedID)
        }.count
    }

    func count(for source: SmartSource) -> Int {
        switch source {
        case .unread:
            unreadCount()
        case .today:
            articles.filter { Calendar.current.isDateInToday($0.publishedAt) }.count
        case .starred:
            articles.filter(\.isStarred).count
        case .all:
            articles.count
        }
    }

    func markArticleOpened(articleID: Article.ID) {
        setRead(articleID: articleID, isRead: true)
    }

    func setRead(articleID: Article.ID, isRead: Bool) {
        guard let index = articles.firstIndex(where: { $0.id == articleID }),
              articles[index].isRead != isRead else { return }

        articles[index].isRead = isRead
    }

    func markSelectedRead() {
        guard let selectedArticleID else { return }
        setRead(articleID: selectedArticleID, isRead: true)
    }

    func markFeedRead(feedID: Feed.ID) {
        for index in articles.indices where articles[index].feedID == feedID {
            if !articles[index].isRead {
                articles[index].isRead = true
            }
        }
    }

    func toggleSelectedStarred() {
        guard let selectedArticleID else { return }
        toggleStarred(articleID: selectedArticleID)
    }

    func toggleStarred(articleID: Article.ID) {
        updateArticle(articleID) { article in
            article.isStarred.toggle()
        }
    }

    func refreshAll() {
        lastRefreshedAt = Date.now
    }

    func refresh(feedID: Feed.ID) {
        lastRefreshedAt = Date.now
        selectedSource = .feed(feedID)
    }

    func addFeed(urlString: String) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }

        let url = URL(string: trimmedURL) ?? URL(string: "https://example.com/feed.xml")!
        let host = url.host(percentEncoded: false) ?? "New Feed"
        let feed = Feed(
            id: "feed-\(feeds.count + 1)",
            title: host.replacingOccurrences(of: "www.", with: ""),
            siteDescription: "Added just now",
            category: "Inbox",
            systemImage: "dot.radiowaves.left.and.right",
            siteURL: url,
            healthScore: 0.72
        )

        feeds.append(feed)
        selectedSource = .feed(feed.id)
        selectedArticleID = nil
    }

    func selectFirstVisibleArticleIfNeeded() {
        let visibleIDs = Set(visibleArticles.map(\.id))
        if let selectedArticleID, visibleIDs.contains(selectedArticleID) {
            return
        }

        selectedArticleID = visibleArticles.first?.id
    }

    func selectNextArticle() {
        moveSelection(offset: 1)
    }

    func selectPreviousArticle() {
        moveSelection(offset: -1)
    }

    func readBinding(articleID: Article.ID) -> Binding<Bool> {
        Binding {
            self.articles.first { $0.id == articleID }?.isRead ?? false
        } set: { isRead in
            self.setRead(articleID: articleID, isRead: isRead)
        }
    }

    func starredBinding(articleID: Article.ID) -> Binding<Bool> {
        Binding {
            self.articles.first { $0.id == articleID }?.isStarred ?? false
        } set: { isStarred in
            self.updateArticle(articleID) { article in
                article.isStarred = isStarred
            }
        }
    }

    private func moveSelection(offset: Int) {
        let visible = visibleArticles
        guard !visible.isEmpty else {
            selectedArticleID = nil
            return
        }

        guard let selectedArticleID,
              let currentIndex = visible.firstIndex(where: { $0.id == selectedArticleID }) else {
            self.selectedArticleID = visible.first?.id
            return
        }

        let nextIndex = min(max(currentIndex + offset, visible.startIndex), visible.index(before: visible.endIndex))
        self.selectedArticleID = visible[nextIndex].id
    }

    private func updateArticle(_ articleID: Article.ID, update: (inout Article) -> Void) {
        guard let index = articles.firstIndex(where: { $0.id == articleID }) else { return }
        update(&articles[index])
    }

    private func matchesSelectedSource(_ article: Article) -> Bool {
        switch selectedSource {
        case .smart(.all), nil:
            true
        case .smart(.unread):
            !article.isRead
        case .smart(.today):
            Calendar.current.isDateInToday(article.publishedAt)
        case .smart(.starred):
            article.isStarred
        case .feed(let feedID):
            article.feedID == feedID
        }
    }

    private func matchesReadingFilter(_ article: Article) -> Bool {
        switch readingFilter {
        case .all:
            true
        case .unread:
            !article.isRead
        case .starred:
            article.isStarred
        }
    }

    private func matchesSearch(_ article: Article) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        return article.title.localizedStandardContains(query)
            || article.summary.localizedStandardContains(query)
            || article.bodyParagraphs.joined(separator: " ").localizedStandardContains(query)
            || (feed(for: article.feedID)?.title.localizedStandardContains(query) ?? false)
    }
}

private enum SourceSelection: Hashable {
    case smart(SmartSource)
    case feed(Feed.ID)
}

private enum SmartSource: String, CaseIterable, Identifiable {
    case unread
    case today
    case starred
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .unread: "Unread"
        case .today: "Today"
        case .starred: "Starred"
        case .all: "All Articles"
        }
    }

    var systemImage: String {
        switch self {
        case .unread: "largecircle.fill.circle"
        case .today: "calendar"
        case .starred: "star"
        case .all: "tray.full"
        }
    }
}

private enum ReadingFilter: String, CaseIterable, Identifiable {
    case all
    case unread
    case starred

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .unread: "Unread"
        case .starred: "Starred"
        }
    }
}

private struct Feed: Identifiable {
    var id: String
    var title: String
    var siteDescription: String
    var category: String
    var systemImage: String
    var siteURL: URL
    var healthScore: Double

    static let sampleFeeds: [Feed] = [
        Feed(
            id: "swift",
            title: "Swift Blog",
            siteDescription: "Language and tooling",
            category: "Development",
            systemImage: "swift",
            siteURL: URL(string: "https://www.swift.org/blog/")!,
            healthScore: 0.96
        ),
        Feed(
            id: "apple-news",
            title: "Apple Developer",
            siteDescription: "Platform updates",
            category: "Development",
            systemImage: "apple.logo",
            siteURL: URL(string: "https://developer.apple.com/news/")!,
            healthScore: 0.91
        ),
        Feed(
            id: "design",
            title: "Design Notes",
            siteDescription: "Interface research",
            category: "Design",
            systemImage: "paintpalette",
            siteURL: URL(string: "https://example.com/design")!,
            healthScore: 0.84
        ),
        Feed(
            id: "infra",
            title: "Systems Weekly",
            siteDescription: "Infrastructure essays",
            category: "Engineering",
            systemImage: "server.rack",
            siteURL: URL(string: "https://example.com/systems")!,
            healthScore: 0.78
        )
    ]
}

private struct Article: Identifiable, Hashable {
    var id: String
    var feedID: Feed.ID
    var title: String
    var summary: String
    var bodyParagraphs: [String]
    var publishedAt: Date
    var url: URL
    var estimatedReadMinutes: Int
    var isRead: Bool
    var isStarred: Bool

    static let sampleArticles: [Article] = [
        Article(
            id: "swift-observation",
            feedID: "swift",
            title: "Designing fast state updates with Observation",
            summary: "A practical look at how fine-grained view invalidation changes the structure of SwiftUI apps.",
            bodyParagraphs: [
                "Observation lets a SwiftUI view depend on the values it actually reads. For an RSS reader, that means the article list, reader pane, and inspector can react independently instead of forcing broad redraws.",
                "The draft keeps the store small on purpose. Feed parsing, persistence, and background refresh can be added behind the same model without changing the main navigation structure.",
                "For web developers, the closest mental model is a reactive store with automatic dependency tracking. You mutate regular Swift properties, and SwiftUI schedules the UI update."
            ],
            publishedAt: .now.addingTimeInterval(-1_800),
            url: URL(string: "https://www.swift.org/blog/")!,
            estimatedReadMinutes: 4,
            isRead: false,
            isStarred: true
        ),
        Article(
            id: "xcode-previews",
            feedID: "apple-news",
            title: "Using previews to iterate on native Mac layouts",
            summary: "Preview-driven UI work is especially useful when balancing sidebars, inspectors, and reading panes.",
            bodyParagraphs: [
                "The primary navigation uses a three-column split view because it maps directly to long-running macOS reading workflows: source selection, item selection, and detail reading.",
                "Toolbar items use SF Symbols and native controls so they inherit platform spacing, keyboard focus, and accessibility behavior.",
                "The inspector keeps metadata and toggles out of the reading surface while still making them available to power users."
            ],
            publishedAt: .now.addingTimeInterval(-7_200),
            url: URL(string: "https://developer.apple.com/xcode/")!,
            estimatedReadMinutes: 3,
            isRead: false,
            isStarred: false
        ),
        Article(
            id: "rss-parser-boundaries",
            feedID: "infra",
            title: "Separating feed fetching from reader state",
            summary: "Treat network refresh, parsing, and read state as separate responsibilities before adding persistence.",
            bodyParagraphs: [
                "RSS and Atom feeds vary in shape, date formats, and content encoding. The UI should not know about those differences. It should receive normalized articles from a feed service.",
                "A native macOS app can refresh in the background later, but the first useful milestone is a local store that makes read, unread, and starred state reliable.",
                "Once the interaction model is stable, the next layer can add URLSession fetching, XML parsing, OPML import, and SwiftData persistence."
            ],
            publishedAt: .now.addingTimeInterval(-18_000),
            url: URL(string: "https://example.com/systems/rss-parser-boundaries")!,
            estimatedReadMinutes: 5,
            isRead: false,
            isStarred: false
        ),
        Article(
            id: "mac-interface-density",
            feedID: "design",
            title: "Density rules for desktop reading tools",
            summary: "A desktop reader should optimize for scanning, triage, and repeated actions instead of a marketing-style layout.",
            bodyParagraphs: [
                "The article list keeps rows compact and information-rich. Feed name, relative date, unread state, and reading time are visible without opening a story.",
                "The detail pane uses generous text width and selectable text, while commands stay in the toolbar and context menus.",
                "This shape leaves room for future native affordances such as drag-and-drop feed organization, menu commands, and system share sheets."
            ],
            publishedAt: .now.addingTimeInterval(-26_400),
            url: URL(string: "https://example.com/design/density")!,
            estimatedReadMinutes: 6,
            isRead: true,
            isStarred: true
        ),
        Article(
            id: "opml-import",
            feedID: "apple-news",
            title: "Planning an OPML import flow",
            summary: "A native document picker can make subscription migration feel like a normal Mac file operation.",
            bodyParagraphs: [
                "OPML support should use the platform file importer rather than a custom file picker. That gives the app sandbox-compatible access to user-selected files.",
                "The visible UI can start with Add Feed and grow into Import OPML once parsing and validation are ready.",
                "Keeping the command in the File menu later will make the workflow discoverable to experienced Mac users."
            ],
            publishedAt: .now.addingTimeInterval(-90_000),
            url: URL(string: "https://developer.apple.com/documentation/swiftui/")!,
            estimatedReadMinutes: 4,
            isRead: true,
            isStarred: false
        )
    ]
}

struct ReaderCommandActions {
    var refreshAll: @MainActor () -> Void
    var markSelectedRead: @MainActor () -> Void
    var toggleSelectedStarred: @MainActor () -> Void
    var selectNextArticle: @MainActor () -> Void
    var selectPreviousArticle: @MainActor () -> Void
}

private struct ReaderCommandActionsKey: FocusedValueKey {
    typealias Value = ReaderCommandActions
}

extension FocusedValues {
    var readerCommandActions: ReaderCommandActions? {
        get { self[ReaderCommandActionsKey.self] }
        set { self[ReaderCommandActionsKey.self] = newValue }
    }
}

struct ReaderAppCommands: Commands {
    @FocusedValue(\.readerCommandActions) private var actions

    var body: some Commands {
        CommandMenu("Feeds") {
            Button("Refresh All") {
                actions?.refreshAll()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(actions == nil)

            Divider()

            Button("Mark Selected as Read") {
                actions?.markSelectedRead()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Button("Star Selected") {
                actions?.toggleSelectedStarred()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Divider()

            Button("Next Article") {
                actions?.selectNextArticle()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            .disabled(actions == nil)

            Button("Previous Article") {
                actions?.selectPreviousArticle()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(actions == nil)
        }
    }
}

#Preview {
    ContentView()
}
