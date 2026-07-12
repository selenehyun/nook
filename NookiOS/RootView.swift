import NookKit
import SwiftUI
import UniformTypeIdentifiers

/// The iOS reader UI. Reuses the shared `ReaderStore` from NookKit; only the
/// presentation differs from the macOS app.
struct RootView: View {
    @Bindable private var store = ReaderStore.shared

    @State private var isChoosingFolder = false
    @State private var isAddingFeed = false
    @State private var isImportingOPML = false
    @State private var isExportingOPML = false
    @State private var opmlImport: OPMLImportRequest?
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""

    var body: some View {
        NavigationSplitView {
            Sidebar(
                store: store,
                isChoosingFolder: $isChoosingFolder,
                isAddingFeed: $isAddingFeed,
                isImportingOPML: $isImportingOPML,
                isExportingOPML: $isExportingOPML,
                isCreatingFolder: $isCreatingFolder
            )
        } content: {
            ArticleList(store: store)
        } detail: {
            ReaderDetailView(store: store)
        }
        .task { store.bootstrap() }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                _ = url.startAccessingSecurityScopedResource()
                store.configureSyncFolder(url)
            }
        }
        .fileImporter(
            isPresented: $isImportingOPML,
            allowedContentTypes: [.opml, .xml],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let fileURL = urls.first else { return }
            let candidates = store.parseOPML(at: fileURL)
            if candidates.isEmpty {
                store.errorMessage = String(localized: "No feeds found in the OPML file.")
            } else {
                opmlImport = OPMLImportRequest(feeds: candidates)
            }
        }
        .fileExporter(
            isPresented: $isExportingOPML,
            document: OPMLDocument(feeds: store.feeds),
            contentType: .opml,
            defaultFilename: "NookSubscriptions.opml"
        ) { result in
            store.handleOPMLExport(result)
        }
        .sheet(isPresented: $isAddingFeed) {
            AddFeedView { store.addFeed(urlString: $0) }
        }
        .sheet(item: $opmlImport) { request in
            OPMLImportView(
                feeds: request.feeds,
                existingKeys: Set(store.feeds.flatMap { [$0.feedURL.feedIdentityKey, $0.siteURL.feedIdentityKey] })
            ) { selected in
                store.importFeeds(selected)
            }
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Folder Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { store.createFolder(name) }
                newFolderName = ""
            }
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            ),
            presenting: store.errorMessage
        ) { _ in
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }
}

private struct Sidebar: View {
    @Bindable var store: ReaderStore
    @Binding var isChoosingFolder: Bool
    @Binding var isAddingFeed: Bool
    @Binding var isImportingOPML: Bool
    @Binding var isExportingOPML: Bool
    @Binding var isCreatingFolder: Bool

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
                        .contextMenu {
                            Button(role: .destructive) {
                                store.removeFolder(folder)
                            } label: {
                                Label("Delete Folder", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Nook")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        isAddingFeed = true
                    } label: {
                        Label("Add Feed", systemImage: "plus")
                    }
                    Button {
                        isCreatingFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Button {
                        isImportingOPML = true
                    } label: {
                        Label("Import OPML", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        isExportingOPML = true
                    } label: {
                        Label("Export OPML", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.feeds.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
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
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.removeFeeds(ids: [feed.id])
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                store.markFeedsRead(ids: [feed.id])
            } label: {
                Label("Mark Read", systemImage: "checkmark")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                store.markFeedsRead(ids: [feed.id])
            } label: {
                Label("Mark All as Read", systemImage: "checkmark.circle")
            }
            if !store.feedFolders.isEmpty {
                Menu {
                    Button("None") { store.moveFeed(feed.id, toFolder: "") }
                    ForEach(store.feedFolders, id: \.self) { folder in
                        Button(folder) { store.moveFeed(feed.id, toFolder: folder) }
                    }
                } label: {
                    Label("Move to Folder", systemImage: "folder")
                }
            }
            Divider()
            Button(role: .destructive) {
                store.removeFeeds(ids: [feed.id])
            } label: {
                Label("Delete Feed", systemImage: "trash")
            }
        }
    }
}

private struct ArticleList: View {
    @Bindable var store: ReaderStore

    var body: some View {
        List(store.visibleArticles, selection: $store.selectedArticleID) { article in
            row(article)
                .tag(article.id)
                .swipeActions(edge: .leading) {
                    Button {
                        store.setRead(articleID: article.id, isRead: !article.isRead)
                    } label: {
                        Label(
                            article.isRead ? "Unread" : "Read",
                            systemImage: article.isRead ? "circle" : "checkmark.circle"
                        )
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        store.toggleStarred(articleID: article.id)
                    } label: {
                        Label("Star", systemImage: article.isStarred ? "star.slash" : "star")
                    }
                    .tint(.yellow)
                }
                .contextMenu {
                    Button {
                        store.setRead(articleID: article.id, isRead: !article.isRead)
                    } label: {
                        Label(article.isRead ? "Mark as Unread" : "Mark as Read",
                              systemImage: article.isRead ? "circle" : "checkmark.circle")
                    }
                    Button {
                        store.toggleStarred(articleID: article.id)
                    } label: {
                        Label(article.isStarred ? "Unstar" : "Star",
                              systemImage: article.isStarred ? "star.slash" : "star")
                    }
                    ShareLink(item: article.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
        }
        .navigationTitle(store.selectedSourceTitle)
        .searchable(text: $store.searchText, prompt: "Search Articles")
        .onChange(of: store.searchText) { _, _ in store.debounceSearch() }
        .overlay {
            if store.visibleArticles.isEmpty {
                ContentUnavailableView("No Articles", systemImage: "newspaper")
            }
        }
    }

    private func row(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !article.isRead {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                }
                Text(article.title)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(article.isRead ? .secondary : .primary)
                if article.isStarred {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                }
            }
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
    }
}
