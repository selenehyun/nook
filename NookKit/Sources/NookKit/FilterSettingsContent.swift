import SwiftUI

/// The rows for managing article filters, shared by both apps. Each host embeds
/// it inside its own `Section` (iOS `List`, macOS `Form`) with a "Filters"
/// header — this view supplies the filter rows, an "Add Filter" button, and a
/// short explanatory caption. Localized via `.module`.
///
/// Reads/writes go through `ReaderStore`, so edits persist and sync across
/// devices. `ReaderStore` is `@Observable`, so reading `store.filters` here makes
/// the list update live when a peer's edit arrives.
public struct FilterSettingsContent: View {
    private let store: ReaderStore

    public init(store: ReaderStore) {
        self.store = store
    }

    public var body: some View {
        ForEach(store.filters) { filter in
            FilterRow(
                filter: filter,
                onChange: { store.updateFilter($0) },
                onDelete: { store.removeFilter(id: filter.id) }
            )
        }

        Button {
            store.addFilter()
        } label: {
            Label { Text("Add Filter", bundle: .module) } icon: { Image(systemName: "plus") }
        }

        Text("Articles matching an enabled filter are hidden from every list and unread count, and collected under Filtered. Filters sync across your devices.", bundle: .module)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// One editable filter row. Edits mutate a local `draft` so typing stays smooth;
/// the draft is committed to the store on a short debounce (`task(id:)`). An
/// external change to the same filter (e.g. a peer sync) is adopted back into
/// the draft when the user isn't the source of it.
private struct FilterRow: View {
    let filter: ArticleFilter
    let onChange: (ArticleFilter) -> Void
    let onDelete: () -> Void

    @State private var draft: ArticleFilter

    init(filter: ArticleFilter, onChange: @escaping (ArticleFilter) -> Void, onDelete: @escaping () -> Void) {
        self.filter = filter
        self.onChange = onChange
        self.onDelete = onDelete
        _draft = State(initialValue: filter)
    }

    private var showsInvalidRegex: Bool {
        draft.kind == .regex
            && !draft.pattern.isEmpty
            && (try? NSRegularExpression(pattern: draft.pattern)) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(isOn: $draft.enabled) { Text("Enabled", bundle: .module) }
                    .labelsHidden()

                TextField(text: $draft.pattern) {
                    Text("Pattern", bundle: .module)
                }
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Delete filter", bundle: .module))
            }

            HStack(spacing: 10) {
                Picker(selection: $draft.kind) {
                    ForEach(ArticleFilter.Kind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                } label: { Text("Type", bundle: .module) }
                .labelsHidden()
                .fixedSize()

                Picker(selection: $draft.matchTarget) {
                    ForEach(ArticleFilter.MatchTarget.allCases, id: \.self) { target in
                        Text(target.title).tag(target)
                    }
                } label: { Text("Match in", bundle: .module) }
                .labelsHidden()
                .fixedSize()

                Spacer()

                Toggle(isOn: $draft.caseSensitive) { Text(verbatim: "Aa") }
                    .toggleStyle(.button)
                    .accessibilityLabel(Text("Case sensitive", bundle: .module))

                if showsInvalidRegex {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(Text("Invalid regular expression", bundle: .module))
                        .accessibilityLabel(Text("Invalid regular expression", bundle: .module))
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 2)
        // Adopt an external update (e.g. a peer sync) only when we're not the
        // source: after our own commit the store's value equals the draft, so
        // this is a no-op then.
        .onChange(of: filter) { _, new in
            if new != draft { draft = new }
        }
        // Debounced commit: restarts whenever the draft changes, so a burst of
        // keystrokes commits (and re-classifies) once the user pauses.
        .task(id: draft) {
            guard draft != filter else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            onChange(draft)
        }
    }
}
