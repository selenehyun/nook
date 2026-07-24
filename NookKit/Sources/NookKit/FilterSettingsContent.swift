import SwiftUI

/// The rows for managing article filters, shared by both apps. Each host embeds
/// it inside its own `Section` (iOS `List`, macOS `Form`) with a "Filters"
/// header. Supplies a "How filters work" help button, the filter rows (each with
/// live feedback), an "Add Filter" button, and a short caption. Localised via
/// `.module`.
///
/// Reads/writes go through `ReaderStore`, so edits persist and sync across
/// devices. `ReaderStore` is `@Observable`, so reading `store.filters` here makes
/// the list update live when a peer's edit arrives.
public struct FilterSettingsContent: View {
    private let store: ReaderStore
    private let onShowGuide: () -> Void

    public init(store: ReaderStore, onShowGuide: @escaping () -> Void) {
        self.store = store
        self.onShowGuide = onShowGuide
    }

    public var body: some View {
        Button(action: onShowGuide) {
            Label { Text("How filters work", bundle: .module) } icon: { Image(systemName: "questionmark.circle") }
        }

        ForEach(store.filters) { filter in
            FilterRow(
                filter: filter,
                onChange: { store.updateFilter($0) },
                onDelete: { store.removeFilter(id: filter.id) },
                matchCount: { await store.matchCount(for: $0) }
            )
        }

        Button {
            store.addFilter()
        } label: {
            Label { Text("Add Filter", bundle: .module) } icon: { Image(systemName: "plus") }
        }

        Text("Matching stories are hidden from every list and unread count, and collected under Filtered. Filters sync across your devices.", bundle: .module)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// One editable filter row. Edits mutate a local `draft` only — they're applied
/// to the article list (and persisted/synced) exclusively when the user taps
/// **Save**, so typing a pattern never re-filters a large library keystroke by
/// keystroke. The live "hides N stories" count is still computed for the draft
/// (off the main actor, and it never touches the list), so the effect previews
/// before saving. An external change to the same filter (e.g. a peer sync) is
/// adopted back into the draft when there's nothing unsaved.
private struct FilterRow: View {
    let filter: ArticleFilter
    let onChange: (ArticleFilter) -> Void
    let onDelete: () -> Void
    let matchCount: (ArticleFilter) async -> Int

    @State private var draft: ArticleFilter
    /// The committed value the draft was last synced to (initial mount, an adopted
    /// external update, or the user's own Save). "Unsaved edits" is measured
    /// against THIS, not the live `filter` prop — so an external change arriving
    /// via sync isn't mistaken for a local edit (which would otherwise block the
    /// new value from ever showing until the row was rebuilt).
    @State private var baseline: ArticleFilter
    @State private var liveCount: Int?

    init(
        filter: ArticleFilter,
        onChange: @escaping (ArticleFilter) -> Void,
        onDelete: @escaping () -> Void,
        matchCount: @escaping (ArticleFilter) async -> Int
    ) {
        self.filter = filter
        self.onChange = onChange
        self.onDelete = onDelete
        self.matchCount = matchCount
        _draft = State(initialValue: filter)
        _baseline = State(initialValue: filter)
    }

    /// Per-filter regex switch, mapped onto the draft's `kind`. Off (plain text)
    /// by default, so a filter is just "the word or phrase you type" unless the
    /// user opts this one filter into pattern matching.
    private var usesRegex: Binding<Bool> {
        Binding(
            get: { draft.kind == .regex },
            set: { draft.kind = $0 ? .regex : .plainText }
        )
    }

    private var invalidRegex: Bool {
        draft.kind == .regex
            && !draft.pattern.isEmpty
            && (try? NSRegularExpression(pattern: draft.pattern)) == nil
    }

    /// Whether the draft has edits not yet applied/saved (vs the synced baseline).
    private var isDirty: Bool { draft != baseline }

    private var placeholder: Text {
        switch draft.kind {
        case .plainText: Text("Word or phrase to hide", bundle: .module)
        case .regex: Text("Regular expression", bundle: .module)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(isOn: $draft.enabled) { Text("Enabled", bundle: .module) }
                    .labelsHidden()

                TextField(text: $draft.pattern, prompt: placeholder) {
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

            HStack(spacing: 12) {
                labeledPicker(caption: Text("In", bundle: .module), selection: $draft.matchTarget) {
                    ForEach(ArticleFilter.MatchTarget.allCases, id: \.self) { Text($0.title).tag($0) }
                }

                Spacer(minLength: 4)

                Toggle(isOn: usesRegex) { Text("Regex", bundle: .module) }
                    .toggleStyle(.button)
                    .accessibilityLabel(Text("Use a regular expression", bundle: .module))

                Toggle(isOn: $draft.caseSensitive) { Text(verbatim: "Aa") }
                    .toggleStyle(.button)
                    .accessibilityLabel(Text("Case sensitive", bundle: .module))
            }
            .font(.callout)

            footer
        }
        .padding(.vertical, 2)
        // An external update (a peer sync, or our own Save landing back through
        // the store) moves the baseline. Adopt it into the draft when the user
        // has no unsaved edits — this is what fills in a filter another device
        // just added/edited, live, without needing the row rebuilt. If the user
        // IS mid-edit, keep their draft (they'll Save it; last write wins).
        .onChange(of: filter) { _, new in
            if !isDirty { draft = new }
            baseline = new
        }
        // Live-count preview ONLY — never commits. Recomputes off the main actor
        // when the draft settles, so it previews a rule's effect without ever
        // re-filtering the list (that happens only on Save).
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let count = await matchCount(draft)
            guard !Task.isCancelled else { return }
            liveCount = count
        }
    }

    /// The status text plus a Save button that appears only when there are
    /// unsaved edits — tapping it is the sole thing that applies the filter.
    private var footer: some View {
        HStack(spacing: 8) {
            status
            Spacer(minLength: 8)
            if isDirty {
                Button { onChange(draft) } label: {
                    Text("Save", bundle: .module)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    /// The status line: an invalid-regex warning, a hint while empty, or the live
    /// "hides N stories" feedback so the user sees a rule's effect immediately.
    @ViewBuilder
    private var status: some View {
        if invalidRegex {
            Label { Text("Invalid regular expression", bundle: .module) } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.caption)
            .foregroundStyle(.orange)
        } else if draft.pattern.isEmpty {
            Text("Enter a word, phrase, or pattern to hide.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !draft.enabled {
            Text("Off — this filter isn't hiding anything.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let liveCount {
            Group {
                if liveCount == 1 {
                    Text("Hides 1 story", bundle: .module)
                } else {
                    Text("Hides \(liveCount) stories", bundle: .module)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func labeledPicker<Value: Hashable, Content: View>(
        caption: Text,
        selection: Binding<Value>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 5) {
            caption
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(selection: selection, content: content) { EmptyView() }
                .labelsHidden()
                .fixedSize()
        }
    }
}
