import SwiftUI
import WidgetKit

// This file belongs to the "NookWidget" widget-extension target.
// Requirements (configure once in Xcode):
//   • Add this file and Nook/WidgetShared.swift to the NookWidget target.
//   • Enable App Groups on both the Nook app and NookWidget targets, using
//     the group id "group.com.tim.nook".
// The app publishes unread articles into the App Group; tapping a row opens
// the app to that article via the nook:// URL scheme.

struct NookEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct NookProvider: TimelineProvider {
    func placeholder(in context: Context) -> NookEntry {
        NookEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (NookEntry) -> Void) {
        let snapshot = context.isPreview ? .placeholder : WidgetShared.readSnapshot()
        completion(NookEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NookEntry>) -> Void) {
        let entry = NookEntry(date: .now, snapshot: WidgetShared.readSnapshot())
        // The app reloads timelines on change; this is just a periodic safety net.
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(1800))))
    }
}

struct NookWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.widgetKind, provider: NookProvider()) { entry in
            NookWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(WidgetShared.openAppURL)
        }
        .configurationDisplayName("Nook")
        .description("Your unread articles, one tap away.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct NookWidgetBundle: WidgetBundle {
    var body: some Widget {
        NookWidget()
    }
}

private struct NookWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NookEntry

    private var rowCount: Int {
        switch family {
        case .systemSmall: return 3
        case .systemMedium: return 3
        case .systemLarge: return 8
        default: return 3
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if entry.snapshot.articles.isEmpty {
                emptyState
            } else if family == .systemSmall {
                smallBody
            } else {
                articleList
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "books.vertical.fill")
                .font(.caption)
                .foregroundStyle(.tint)
            Text("Nook")
                .font(.headline)
            Spacer(minLength: 4)
            if entry.snapshot.unreadCount > 0 {
                Text("\(entry.snapshot.unreadCount)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("All caught up")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entry.snapshot.articles.prefix(2)) { article in
                Link(destination: WidgetShared.articleURL(id: article.id)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(article.title)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(2)
                        Text(article.feedTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private var articleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entry.snapshot.articles.prefix(rowCount).enumerated()), id: \.element.id) { index, article in
                if index > 0 {
                    Divider().opacity(0.5)
                }
                Link(destination: WidgetShared.articleURL(id: article.id)) {
                    row(article)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ article: WidgetArticle) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(.tint)
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(article.feedTitle)
                        .lineLimit(1)
                    if article.publishedAt > .distantPast {
                        Text("·")
                        Text(article.publishedAt, format: .relative(presentation: .named))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }
}
