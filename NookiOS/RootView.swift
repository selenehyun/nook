import NookKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// The iOS reader UI. Reuses the shared `ReaderStore` from NookKit; only the
/// presentation differs from the macOS app.
struct RootView: View {
    @Bindable private var store = ReaderStore.shared

    /// A single file importer backs both the sync-folder picker and OPML import;
    /// stacking two `.fileImporter` modifiers on one view makes only one work.
    enum ImportKind { case folder, opml }
    @State private var importKind: ImportKind = .folder
    @State private var isImporting = false
    @State private var isAddingFeed = false
    @State private var isExportingOPML = false
    @State private var opmlImport: OPMLImportRequest?
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var isShowingSettings = false
    @AppStorage("showUnreadBadge") private var showUnreadBadge = true

    var body: some View {
        NavigationSplitView {
            Sidebar(
                store: store,
                chooseFolder: { importKind = .folder; isImporting = true },
                importOPML: { importKind = .opml; isImporting = true },
                isAddingFeed: $isAddingFeed,
                isExportingOPML: $isExportingOPML,
                isCreatingFolder: $isCreatingFolder,
                isShowingSettings: $isShowingSettings
            )
        } content: {
            ArticleList(store: store)
        } detail: {
            ReaderDetailView(store: store)
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            // The store computes the unread count; iOS reflects it on the app
            // icon badge (requires notification authorization).
            store.onUnreadBadgeChange = { count in
                UNUserNotificationCenter.current().setBadgeCount(count)
            }
            store.showsUnreadBadge = showUnreadBadge
            store.bootstrap()
            try? await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])
        }
        .onChange(of: showUnreadBadge) { _, newValue in store.showsUnreadBadge = newValue }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: importKind == .folder ? [.folder] : [.opml, .xml],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            switch importKind {
            case .folder:
                _ = url.startAccessingSecurityScopedResource()
                store.configureSyncFolder(url)
            case .opml:
                let candidates = store.parseOPML(at: url)
                if candidates.isEmpty {
                    store.errorMessage = String(localized: "No feeds found in the OPML file.")
                } else {
                    opmlImport = OPMLImportRequest(feeds: candidates)
                }
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
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(store: store)
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

/// A selectable sidebar entry. Binding the List selection to this (rather than
/// using plain buttons) is what lets a collapsed NavigationSplitView push to the
/// article-list column when a row is tapped on iPhone.
enum SidebarItem: Hashable {
    case smart(SmartSource)
    case feed(Feed.ID)
}

private struct Sidebar: View {
    @Bindable var store: ReaderStore
    var chooseFolder: () -> Void
    var importOPML: () -> Void
    @Binding var isAddingFeed: Bool
    @Binding var isExportingOPML: Bool
    @Binding var isCreatingFolder: Bool
    @Binding var isShowingSettings: Bool

    @State private var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                ForEach(SmartSource.allCases) { source in
                    HStack {
                        Label(source.title, systemImage: source.systemImage)
                        Spacer()
                        let count = store.count(for: source)
                        if count > 0 {
                            Text(count, format: .number).foregroundStyle(.secondary)
                        }
                    }
                    .tag(SidebarItem.smart(source))
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
        .onChange(of: selection) { _, item in
            switch item {
            case .smart(let source):
                store.selectSmartSource(source)
            case .feed(let id):
                store.feedSelection = [id]
                store.smartSelection = nil
            case nil:
                break
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
                        importOPML()
                    } label: {
                        Label("Import OPML", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        isExportingOPML = true
                    } label: {
                        Label("Export OPML", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.feeds.isEmpty)
                    Divider()
                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
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
                chooseFolder()
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
        .tag(SidebarItem.feed(feed.id))
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
    @AppStorage("readerViewMode") private var readerViewMode = ReaderViewMode.reader

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
                    Button {
                        store.selectedArticleID = article.id
                        store.browserMode = store.feed(for: article.feedID)?.preferredViewMode ?? readerViewMode
                        store.isBrowserPresented = true
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
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
