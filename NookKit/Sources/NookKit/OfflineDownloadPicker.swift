import SwiftUI

/// Lets the user pick which articles from the current source to save for offline
/// reading, instead of exporting the whole list at once. Shared by both apps:
/// macOS presents it from the article-list toolbar; iOS presents it from Offline
/// settings (where offline saving lives). Candidates are the current source's
/// articles that aren't already saved. Localised via `.module`.
public struct OfflineDownloadPicker: View {
    private let store: ReaderStore
    private let onDone: () -> Void

    @State private var selected: Set<Article.ID> = []
    @State private var seeded = false

    public init(store: ReaderStore, onDone: @escaping () -> Void) {
        self.store = store
        self.onDone = onDone
    }

    /// The current source's not-yet-saved articles.
    private var candidates: [Article] {
        store.visibleArticles.filter { !store.isOfflineSaved($0.id) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if candidates.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Everything here is already saved for offline.", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                Spacer()
            } else {
                List {
                    ForEach(candidates) { article in
                        Button {
                            toggle(article.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected.contains(article.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(article.id) ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(article.title).lineLimit(2)
                                    Text(store.feed(for: article.feedID)?.displayTitle ?? "")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            selected = Set(candidates.map(\.id))
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Download for Offline", bundle: .module)
                    .font(.headline)
                Text(store.selectedSourceTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !candidates.isEmpty {
                Button(action: toggleAll) {
                    Text(allSelected ? "Deselect All" : "Select All", bundle: .module)
                }
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button(role: .cancel, action: onDone) {
                Text("Cancel", bundle: .module)
            }
            Spacer()
            Button(action: download) {
                Text("Download \(selected.count)", bundle: .module)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty)
        }
        .padding(16)
    }

    private var allSelected: Bool {
        !candidates.isEmpty && selected.count == candidates.count
    }

    private func toggle(_ id: Article.ID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func toggleAll() {
        selected = allSelected ? [] : Set(candidates.map(\.id))
    }

    private func download() {
        let chosen = candidates.filter { selected.contains($0.id) }
        store.downloadOffline(chosen)
        onDone()
    }
}
