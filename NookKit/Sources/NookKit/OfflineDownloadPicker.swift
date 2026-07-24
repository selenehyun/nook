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
///   paint a range as your finger moves.
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

    // iOS drag-to-select state.
    @State private var rowFrames: [Int: CGRect] = [:]
    @State private var dragAnchor: Int?
    @State private var dragSnapshot: Set<Article.ID> = []
    @State private var dragTargetSelected = false
    @State private var dragIDs: [Article.ID] = []
    /// Auto-resets to false when the drag gesture ends OR is cancelled (unlike
    /// `onEnded`, which a cancelled/interrupted gesture can skip), so drag state
    /// is always cleared before the next drag.
    @GestureState private var isDragging = false

    private let coordinateSpace = "offlineDownloadPicker"

    public init(store: ReaderStore, onDone: @escaping () -> Void) {
        self.store = store
        self.onDone = onDone
    }

    /// The current source's not-yet-saved articles, after the Unread/All filter
    /// and the search query. Reads the cache (recomputed only on input changes).
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
        // guarantees the drag state is reset before the next one.
        .onChange(of: isDragging) { _, active in if !active { dragEnded() } }
    }

    // MARK: - Header (filters + search)

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download for Offline", bundle: .module)
                        .font(.headline)
                    Text(store.selectedSourceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                TextField(text: $searchText) {
                    Text("Search", bundle: .module)
                }
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
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, article in
                    row(article, index: index)
                }
            }
            .coordinateSpace(name: coordinateSpace)
            .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
            #if os(iOS)
            // While a checkbox drag is active, turn off list scrolling so the
            // scroll gesture can't cancel our paint gesture — this is what keeps
            // the drag tracking the finger the whole way down the list, instead
            // of dying the moment it leaves the checkbox.
            .scrollDisabled(isDragging)
            #endif
        }
    }

    private var emptyMessage: LocalizedStringKey {
        searchText.isEmpty && scope == .all
            ? "Everything here is already saved for offline."
            : "No article matches."
    }

    private func row(_ article: Article, index: Int) -> some View {
        Button {
            rowTapped(index)
        } label: {
            HStack(spacing: 10) {
                checkbox(for: article.id, index: index)
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
                Color.clear.preference(key: RowFrameKey.self, value: [index: proxy.frame(in: .named(coordinateSpace))])
            }
        )
        #endif
    }

    private func checkbox(for id: Article.ID, index: Int) -> some View {
        let image = Image(systemName: selection.contains(id) ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(selection.contains(id) ? Color.accentColor : .secondary)
            .imageScale(.large)
        #if os(iOS)
        return image
            .contentShape(Rectangle())
            // Press the checkbox and drag to paint a range (Photos-style). The
            // gesture activates on touch-down (minimumDistance 0) so `isDragging`
            // flips before any movement — that immediately disables list scrolling
            // (see the List), so the scroll gesture can never steal the drag as
            // the finger moves across rows. A touch with no movement just toggles
            // this one row (a range of one). Dragging elsewhere on the row still
            // scrolls, since only the checkbox carries this gesture.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged { value in dragChanged(startIndex: index, location: value.location) }
                    .onEnded { _ in dragEnded() }
            )
        #else
        return image
        #endif
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(role: .cancel, action: onDone) {
                Text("Cancel", bundle: .module)
            }
            Spacer()
            Button(action: download) {
                Text("Download \(selection.count)", bundle: .module)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty)
        }
        .padding(16)
    }

    // MARK: - Selection logic

    private var allDisplayedSelected: Bool {
        let ids = displayed.map(\.id)
        return !ids.isEmpty && ids.allSatisfy { selection.contains($0) }
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
    /// to here; otherwise it's a single toggle that resets the anchor.
    private func rowTapped(_ index: Int) {
        let ids = displayed.map(\.id)
        guard index < ids.count else { return }
        let id = ids[index]

        #if os(macOS)
        let shift = NSEvent.modifierFlags.contains(.shift)
        #else
        let shift = false
        #endif

        // Resolve the anchor's CURRENT position (it may have moved as the list was
        // filtered/searched); if it's no longer visible, fall back to a single
        // toggle rather than painting a stale range.
        if shift, let anchorID, let anchor = ids.firstIndex(of: anchorID) {
            // The clicked row's NEW state is painted across the whole range.
            let target = !selection.contains(id)
            for i in min(anchor, index)...max(anchor, index) where i < ids.count {
                if target { selection.insert(ids[i]) } else { selection.remove(ids[i]) }
            }
        } else {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        }
        anchorID = id
    }

    // MARK: - iOS drag-to-select

    private func dragChanged(startIndex: Int, location: CGPoint) {
        if dragAnchor == nil {
            // First movement: anchor on the pressed checkbox, snapshot the current
            // selection, and decide whether we're selecting or deselecting based on
            // the anchor's toggled state.
            dragAnchor = startIndex
            dragIDs = displayed.map(\.id)
            dragSnapshot = selection
            let pressedID = dragIDs.indices.contains(startIndex) ? dragIDs[startIndex] : nil
            dragTargetSelected = pressedID.map { !selection.contains($0) } ?? true
            anchorID = pressedID
        }
        guard let anchor = dragAnchor else { return }
        let current = rowIndex(atY: location.y) ?? anchor
        applyDragRange(anchor: anchor, current: current)
    }

    private func applyDragRange(anchor: Int, current: Int) {
        var next = dragSnapshot
        let lo = min(anchor, current), hi = max(anchor, current)
        guard lo >= 0, hi < dragIDs.count else { return }
        for i in lo...hi {
            let id = dragIDs[i]
            if dragTargetSelected { next.insert(id) } else { next.remove(id) }
        }
        selection = next
    }

    private func dragEnded() {
        dragAnchor = nil
        dragIDs = []
        dragSnapshot = []
    }

    /// The displayed-row index whose frame contains `y`, clamped to the nearest
    /// row when the finger is dragged above the first or below the last row.
    private func rowIndex(atY y: CGFloat) -> Int? {
        guard !rowFrames.isEmpty else { return nil }
        if let hit = rowFrames.first(where: { $0.value.minY <= y && y <= $0.value.maxY })?.key {
            return hit
        }
        // No exact hit (a gap between rows, or above/below the list): snap to the
        // row whose center is nearest, so the range endpoint tracks the finger.
        return rowFrames.min(by: { abs($0.value.midY - y) < abs($1.value.midY - y) })?.key
    }

    // MARK: - Commit

    private func download() {
        let chosen = store.visibleArticles.filter { selection.contains($0.id) && !store.isOfflineSaved($0.id) }
        store.downloadOffline(chosen)
        onDone()
    }
}

/// Collects each displayed row's frame (in the picker's coordinate space) so the
/// iOS drag-to-select can map a finger position to a row.
private struct RowFrameKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
