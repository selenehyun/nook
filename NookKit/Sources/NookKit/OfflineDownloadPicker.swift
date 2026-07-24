import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Lets the user pick which articles from the current source to save for offline
/// reading. Shared by both apps: macOS presents it from the article-list toolbar,
/// iOS from Offline settings (where offline saving lives).
///
/// Selection UX (a priority here):
/// - Filter with an Unread/All toggle and a search field to find articles fast.
/// - Range-select: on macOS, Shift-click extends selection from the last-clicked
///   row to the clicked one; on iOS, press a checkbox and drag (Photos-style) to
///   paint a range that tracks your finger, row for row.
///
/// Everything is keyed by article id (not row index) so a cheap re-render during
/// a drag never re-allocates an index array, and finger→row hit-testing uses
/// global coordinates so the painted range stays exactly under the finger.
///
/// Localised via `.module`.
public struct OfflineDownloadPicker: View {
    private let store: ReaderStore
    private let onDone: () -> Void

    private enum Scope: Hashable { case unread, all }

    @State private var selection: Set<Article.ID> = []
    @State private var scope: Scope = .all
    @State private var searchText = ""
    /// Anchor row for macOS Shift-click range selection, kept as an id (not an
    /// index) so it stays valid when the filter or search changes the list.
    @State private var anchorID: Article.ID?

    /// Filtered list, cached so the O(n) locale-aware filter runs only when its
    /// inputs change — not several times per render / per keystroke.
    @State private var displayedCache: [Article] = []

    // iOS drag-to-select state (a snapshot taken once when the drag begins).
    @State private var rowFrames: [Article.ID: CGRect] = [:]
    @State private var dragAnchorID: Article.ID?
    @State private var dragSnapshot: Set<Article.ID> = []
    @State private var dragTargetSelected = false
    @State private var dragIDs: [Article.ID] = []
    @State private var dragIndexByID: [Article.ID: Int] = [:]
    /// Auto-resets to false when the drag gesture ends OR is cancelled (unlike
    /// `onEnded`, which a cancelled/interrupted gesture can skip), so drag state
    /// is always cleared and list scrolling is re-enabled.
    @GestureState private var isDragging = false

    public init(store: ReaderStore, onDone: @escaping () -> Void) {
        self.store = store
        self.onDone = onDone
    }

    private var displayed: [Article] { displayedCache }

    private func computeDisplayed() -> [Article] {
        var items = store.visibleArticles.filter { !store.isOfflineSaved($0.id) }
        if scope == .unread { items = items.filter { !$0.isRead } }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            items = items.filter { article in
                article.title.localizedStandardContains(query)
                    || (store.feed(for: article.feedID)?.displayTitle.localizedStandardContains(query) ?? false)
            }
        }
        return items
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { displayedCache = computeDisplayed() }
        .onChange(of: scope) { _, _ in displayedCache = computeDisplayed() }
        .onChange(of: searchText) { _, _ in displayedCache = computeDisplayed() }
        .onChange(of: store.visibleArticles) { _, _ in displayedCache = computeDisplayed() }
        // A cancelled/interrupted drag skips onEnded; the gesture-state flip
        // guarantees drag state is reset (and scrolling re-enabled) afterwards.
        .onChange(of: isDragging) { _, active in if !active { dragEnded() } }
    }

    // MARK: - Header (filters + search)

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download for Offline", bundle: .module).font(.headline)
                    Text(store.selectedSourceTitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !displayed.isEmpty {
                    Button(action: toggleAll) {
                        Text(allDisplayedSelected ? "Deselect All" : "Select All", bundle: .module)
                    }
                }
            }

            Picker("", selection: $scope) {
                Text("Unread", bundle: .module).tag(Scope.unread)
                Text("All", bundle: .module).tag(Scope.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(text: $searchText) { Text("Search", bundle: .module) }
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(16)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if displayed.isEmpty {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle").font(.system(size: 36)).foregroundStyle(.secondary)
                Text(emptyMessage, bundle: .module)
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
            Spacer()
        } else {
            List {
                ForEach(displayed) { article in
                    row(article)
                }
            }
            .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
            #if os(iOS)
            // While a checkbox drag is active, turn off list scrolling so the
            // scroll gesture can't cancel or fight our paint gesture — this keeps
            // the drag glued to the finger the whole way down the list.
            .scrollDisabled(isDragging)
            #endif
        }
    }

    private var emptyMessage: LocalizedStringKey {
        searchText.isEmpty && scope == .all
            ? "Everything here is already saved for offline."
            : "No article matches."
    }

    private func row(_ article: Article) -> some View {
        Button {
            rowTapped(article.id)
        } label: {
            HStack(spacing: 10) {
                checkbox(for: article.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(article.title).lineLimit(2)
                    Text(store.feed(for: article.feedID)?.displayTitle ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: RowFrameKey.self, value: [article.id: proxy.frame(in: .global)])
            }
        )
        #endif
    }

    private func checkbox(for id: Article.ID) -> some View {
        let selected = selection.contains(id)
        let image = Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(selected ? Color.accentColor : .secondary)
            .imageScale(.large)
        #if os(iOS)
        return image
            .contentShape(Rectangle())
            // Touch the checkbox and drag to paint a range (Photos-style). It
            // activates on touch-down (minimumDistance 0) so `isDragging` flips
            // before any movement — disabling list scrolling immediately (see the
            // List), so the scroll gesture can never steal the drag. A touch with
            // no movement paints a range of one (a single toggle). Dragging
            // elsewhere on a row still scrolls, since only the checkbox drags. All
            // coordinates are global, so the painted row sits exactly under the
            // finger.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { value in dragChanged(startID: id, location: value.location) }
                    .onEnded { _ in dragEnded() }
            )
        #else
        return image
        #endif
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(role: .cancel, action: onDone) { Text("Cancel", bundle: .module) }
            Spacer()
            Button(action: download) { Text("Download \(selection.count)", bundle: .module) }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
        }
        .padding(16)
    }

    // MARK: - Selection

    private var allDisplayedSelected: Bool {
        let ids = displayed
        return !ids.isEmpty && ids.allSatisfy { selection.contains($0.id) }
    }

    private func toggleAll() {
        let ids = displayed.map(\.id)
        if allDisplayedSelected {
            for id in ids { selection.remove(id) }
        } else {
            for id in ids { selection.insert(id) }
        }
    }

    /// A row was clicked. On macOS a Shift-click paints the range from the anchor
    /// to here (by id, so it survives filtering); otherwise a single toggle.
    private func rowTapped(_ id: Article.ID) {
        #if os(macOS)
        let shift = NSEvent.modifierFlags.contains(.shift)
        #else
        let shift = false
        #endif

        let ids = displayed.map(\.id)
        if shift, let anchorID, let ai = ids.firstIndex(of: anchorID), let ci = ids.firstIndex(of: id) {
            let target = !selection.contains(id)
            for i in min(ai, ci)...max(ai, ci) {
                if target { selection.insert(ids[i]) } else { selection.remove(ids[i]) }
            }
        } else {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        }
        anchorID = id
    }

    // MARK: - iOS drag-to-select

    private func dragChanged(startID: Article.ID, location: CGPoint) {
        if dragAnchorID == nil {
            // First event: snapshot the list and selection, and decide (from the
            // pressed row's toggled state) whether this drag selects or deselects.
            let ids = displayed.map(\.id)
            dragIDs = ids
            dragIndexByID = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            dragSnapshot = selection
            dragAnchorID = startID
            dragTargetSelected = !selection.contains(startID)
            anchorID = startID
        }
        guard let anchorID = dragAnchorID,
              let ai = dragIndexByID[anchorID] else { return }
        let currentID = rowID(atY: location.y) ?? startID
        guard let ci = dragIndexByID[currentID] else { return }
        applyRange(lo: min(ai, ci), hi: max(ai, ci))
    }

    private func applyRange(lo: Int, hi: Int) {
        guard lo >= 0, hi < dragIDs.count else { return }
        var next = dragSnapshot
        for i in lo...hi {
            let id = dragIDs[i]
            if dragTargetSelected { next.insert(id) } else { next.remove(id) }
        }
        selection = next
    }

    private func dragEnded() {
        dragAnchorID = nil
        dragIDs = []
        dragIndexByID = [:]
        dragSnapshot = []
    }

    /// The id of the row whose (global) frame contains `y`, snapping to the
    /// nearest row's center on a miss so the endpoint tracks the finger past the
    /// first/last row or across any gap.
    private func rowID(atY y: CGFloat) -> Article.ID? {
        guard !rowFrames.isEmpty else { return nil }
        if let hit = rowFrames.first(where: { $0.value.minY <= y && y <= $0.value.maxY })?.key {
            return hit
        }
        return rowFrames.min(by: { abs($0.value.midY - y) < abs($1.value.midY - y) })?.key
    }

    // MARK: - Commit

    private func download() {
        let chosen = store.visibleArticles.filter { selection.contains($0.id) && !store.isOfflineSaved($0.id) }
        store.downloadOffline(chosen)
        onDone()
    }
}

/// Collects each row's global frame so the iOS drag-to-select can map a finger
/// position to a row. Keyed by article id (stable across re-renders).
private struct RowFrameKey: PreferenceKey {
    static let defaultValue: [Article.ID: CGRect] = [:]
    static func reduce(value: inout [Article.ID: CGRect], nextValue: () -> [Article.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
