import SwiftUI
import WidgetKit

// This file belongs to the "NookWidget" widget-extension target.
// Setup in Xcode:
//   • Add this file and Nook/WidgetShared.swift to the NookWidget target.
// No App Group is required: this is a quick-access launcher. Each shortcut
// deep-links into the app via the nook:// URL scheme, launching or
// activating Nook and focusing the chosen smart source.

struct NookEntry: TimelineEntry {
    let date: Date
}

struct NookProvider: TimelineProvider {
    func placeholder(in context: Context) -> NookEntry { NookEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (NookEntry) -> Void) {
        completion(NookEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NookEntry>) -> Void) {
        completion(Timeline(entries: [NookEntry(date: .now)], policy: .never))
    }
}

// The @main WidgetBundle lives in the Xcode-generated NookWidgetBundle.swift,
// which references NookWidget().
struct NookWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.widgetKind, provider: NookProvider()) { _ in
            NookWidgetView()
                .containerBackground(.background, for: .widget)
                .widgetURL(WidgetShared.openAppURL)
        }
        .configurationDisplayName("Nook")
        .description("Quick access to your reader.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct NookWidgetView: View {
    @Environment(\.widgetFamily) private var family

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text("Nook")
                    .font(.headline)
                Spacer(minLength: 0)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(WidgetSource.allCases) { source in
                    Link(destination: WidgetShared.sourceURL(source)) {
                        shortcut(source)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func shortcut(_ source: WidgetSource) -> some View {
        HStack(spacing: 6) {
            Image(systemName: source.systemImage)
                .font(.callout)
                .foregroundStyle(.tint)
                .frame(width: 18)
            Text(source.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
