import NookKit
import SwiftUI
import UniformTypeIdentifiers

/// The iOS reader UI. Reuses the shared `ReaderStore` from NookKit; only the
/// presentation differs from the macOS app.
struct RootView: View {
    @Bindable private var store = ReaderStore.shared
    @State private var isChoosingFolder = false

    var body: some View {
        NavigationSplitView {
            Sidebar(store: store, isChoosingFolder: $isChoosingFolder)
        } content: {
            ArticleList(store: store)
        } detail: {
            ReaderDetail(store: store)
        }
        .task { store.bootstrap() }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                _ = url.startAccessingSecurityScopedResource()
                store.configureSyncFolder(url)
            }
        }
    }
}

private struct Sidebar: View {
    @Bindable var store: ReaderStore
    @Binding var isChoosingFolder: Bool

    var body: some View {
        List {
            Section("Library") {
                ForEach(SmartSource.allCases) { source in
                    Button {
                        store.selectSmartSource(source)
                    } label: {
                        HStack {
                            Label(source.title, systemImage: source.systemImage)
                            Spacer()
                            let count = store.count(for: source)
                            if count > 0 {
                                Text(count, format: .number).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tint(.primary)
                }
            }

            if !store.feedFolders.isEmpty || !store.ungroupedFeeds.isEmpty {
                Section("Feeds") {
                    ForEach(store.ungroupedFeeds) { feed in
                        feedRow(feed)
                    }
                    ForEach(store.feedFolders, id: \.self) { folder in
                        DisclosureGroup(folder) {
                            ForEach(store.feeds(inFolder: folder)) { feed in
                                feedRow(feed)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Nook")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.feeds.isEmpty || store.isRefreshing)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                isChoosingFolder = true
            } label: {
                Label(
                    store.isStorageConfigured ? "Sync Folder" : "Choose Sync Folder",
                    systemImage: store.isStorageConfigured ? "checkmark.icloud" : "icloud"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .padding()
        }
    }

    private func feedRow(_ feed: Feed) -> some View {
        Button {
            store.feedSelection = [feed.id]
            store.smartSelection = nil
        } label: {
            HStack {
                if let icon = store.faviconImage(for: feed) {
                    icon.resizable().frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: feed.systemImage)
                }
                Text(feed.title).lineLimit(1)
                Spacer()
                let count = store.unreadCount(feedID: feed.id)
                if count > 0 {
                    Text(count, format: .number).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
    }
}

private struct ArticleList: View {
    @Bindable var store: ReaderStore

    var body: some View {
        List(store.visibleArticles, selection: $store.selectedArticleID) { article in
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(article.isRead ? .secondary : .primary)
                if !article.summary.isEmpty {
                    Text(article.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(store.feed(for: article.feedID)?.title ?? "")
                    Text("·")
                    Text(article.publishedAt, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .tag(article.id)
        }
        .navigationTitle(store.selectedSourceTitle)
        .overlay {
            if store.visibleArticles.isEmpty {
                ContentUnavailableView("No Articles", systemImage: "newspaper")
            }
        }
    }
}

private struct ReaderDetail: View {
    @Bindable var store: ReaderStore

    var body: some View {
        if let article = store.selectedArticle {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(article.title).font(.title.bold())
                    HStack(spacing: 6) {
                        Text(store.feed(for: article.feedID)?.title ?? "")
                        Text("·")
                        Text(article.publishedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    let paragraphs = article.bodyParagraphs.isEmpty ? [article.summary] : article.bodyParagraphs
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph).font(.body)
                    }

                    Link(destination: article.url) {
                        Label("Open Original", systemImage: "safari")
                    }
                    .padding(.top, 8)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: article.id) { store.markArticleOpened(articleID: article.id) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.toggleStarred(articleID: article.id)
                    } label: {
                        Image(systemName: article.isStarred ? "star.fill" : "star")
                    }
                }
            }
        } else {
            ContentUnavailableView("Select an Article", systemImage: "newspaper")
        }
    }
}
