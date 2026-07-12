import NookKit
import SwiftUI

struct OPMLImportRequest: Identifiable {
    let id = UUID()
    let feeds: [OPMLFeed]
}

/// An import preview: pick which OPML feeds to bring in before merging.
/// Feeds already subscribed are shown disabled and unchecked by default.
struct OPMLImportView: View {
    let feeds: [OPMLFeed]
    let existingKeys: Set<String>
    var onImport: ([OPMLFeed]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<OPMLFeed.ID>

    init(feeds: [OPMLFeed], existingKeys: Set<String>, onImport: @escaping ([OPMLFeed]) -> Void) {
        self.feeds = feeds
        self.existingKeys = existingKeys
        self.onImport = onImport
        let isNew: (OPMLFeed) -> Bool = { feed in
            !(existingKeys.contains(feed.feedURL.feedIdentityKey)
                || (feed.siteURL.map { existingKeys.contains($0.feedIdentityKey) } ?? false))
        }
        _selection = State(initialValue: Set(feeds.filter(isNew).map(\.id)))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedFeeds, id: \.category) { group in
                    Section(group.category ?? String(localized: "Ungrouped")) {
                        ForEach(group.feeds) { feed in
                            row(feed)
                        }
                    }
                }
            }
            .navigationTitle("Import Feeds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(allSelected ? "Deselect All" : "Select All") {
                        selection = allSelected ? [] : Set(feeds.map(\.id))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(selection.count)") {
                        onImport(feeds.filter { selection.contains($0.id) })
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
    }

    private func row(_ feed: OPMLFeed) -> some View {
        let existing = isExisting(feed)
        return Button {
            if selection.contains(feed.id) {
                selection.remove(feed.id)
            } else {
                selection.insert(feed.id)
            }
        } label: {
            HStack {
                Image(systemName: selection.contains(feed.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.contains(feed.id) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(feed.title).foregroundStyle(.primary)
                    Text(feed.feedURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if existing {
                    Text("Added").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(existing)
    }

    private func isExisting(_ feed: OPMLFeed) -> Bool {
        existingKeys.contains(feed.feedURL.feedIdentityKey)
            || (feed.siteURL.map { existingKeys.contains($0.feedIdentityKey) } ?? false)
    }

    private var allSelected: Bool { selection.count == feeds.count }

    private var groupedFeeds: [(category: String?, feeds: [OPMLFeed])] {
        var order: [String?] = []
        var map: [String?: [OPMLFeed]] = [:]
        for feed in feeds {
            if map[feed.category] == nil { order.append(feed.category) }
            map[feed.category, default: []].append(feed)
        }
        return order.map { ($0, map[$0] ?? []) }
    }
}
