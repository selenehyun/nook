import Foundation

/// Per-device user-state shard — the heart of Nook's Git-like sync. Each device
/// writes only its own shard file (`.nook/state/<deviceID>.json`), so no two
/// devices ever write the same file and write conflicts simply cannot happen.
///
/// A shard holds only the small, user-authored *state* that used to get clobbered
/// on sync — read/starred flags, a feed's folder and view-mode overrides, folder
/// existence, and feed deletions — each as an `LWWRegister` stamped with the HLC
/// at which this device set it. Heavy, regenerable content (article bodies, feed
/// titles/URLs) lives in per-device content shards and is never duplicated here.
///
/// Reading the library merges every shard field-by-field via `materialize`,
/// picking the highest-HLC writer per field. That merge is order-independent and
/// idempotent, so every device converges on the same state and a read on one
/// device can never erase a read on another.
public struct DeviceStateDocument: Codable, Sendable, Equatable {
    /// Per-article user state. Registers are absent until this device changes them.
    public struct ArticleState: Codable, Sendable, Equatable {
        public var isRead: LWWRegister<Bool>?
        public var isStarred: LWWRegister<Bool>?
        /// Set once the article has been surfaced in the foreground list on some
        /// device. Syncs like read/starred so an article you already saw on one
        /// device never fires a "new article" notification on another. Distinct
        /// from `isRead`: you can see a title in the list without reading it.
        public var seen: LWWRegister<Bool>?
        /// User deletion of a single article (a tombstone, so it syncs and a
        /// baseline that still carries the article can't resurrect it). Used when
        /// the original is gone (e.g. a 404) but the local copy lingers in the list.
        public var tombstone: LWWRegister<Bool>?
        /// Category ids assigned to this article (keyword / AI / manual). Whole-
        /// list LWW: an assignment change replaces the set, resolved by HLC.
        public var categories: LWWRegister<[String]>?

        public init(
            isRead: LWWRegister<Bool>? = nil,
            isStarred: LWWRegister<Bool>? = nil,
            seen: LWWRegister<Bool>? = nil,
            tombstone: LWWRegister<Bool>? = nil,
            categories: LWWRegister<[String]>? = nil
        ) {
            self.isRead = isRead
            self.isStarred = isStarred
            self.seen = seen
            self.tombstone = tombstone
            self.categories = categories
        }

        var isEmpty: Bool { isRead == nil && isStarred == nil && seen == nil && tombstone == nil && categories == nil }

        func merged(with other: ArticleState) -> ArticleState {
            ArticleState(
                isRead: mergeRegisters(isRead, other.isRead),
                isStarred: mergeRegisters(isStarred, other.isStarred),
                seen: mergeRegisters(seen, other.seen),
                tombstone: mergeRegisters(tombstone, other.tombstone),
                categories: mergeRegisters(categories, other.categories)
            )
        }
    }

    /// Per-feed user state: the folder it lives in, its reading-view override,
    /// and whether the user deleted it (a tombstone so the deletion syncs).
    public struct FeedState: Codable, Sendable, Equatable {
        public var category: LWWRegister<String>?
        public var preferredViewMode: LWWRegister<ReaderViewMode?>?
        public var customTitle: LWWRegister<String?>?
        public var tombstone: LWWRegister<Bool>?
        /// The feed's identity/content, so its membership is CRDT state (not just
        /// a baseline-file entry that a peer's overwrite could drop).
        public var seed: LWWRegister<FeedSeed>?

        public init(
            category: LWWRegister<String>? = nil,
            preferredViewMode: LWWRegister<ReaderViewMode?>? = nil,
            customTitle: LWWRegister<String?>? = nil,
            tombstone: LWWRegister<Bool>? = nil,
            seed: LWWRegister<FeedSeed>? = nil
        ) {
            self.category = category
            self.preferredViewMode = preferredViewMode
            self.customTitle = customTitle
            self.tombstone = tombstone
            self.seed = seed
        }

        var isEmpty: Bool {
            category == nil && preferredViewMode == nil && customTitle == nil
                && tombstone == nil && seed == nil
        }

        func merged(with other: FeedState) -> FeedState {
            FeedState(
                category: mergeRegisters(category, other.category),
                preferredViewMode: mergeRegisters(preferredViewMode, other.preferredViewMode),
                customTitle: mergeRegisters(customTitle, other.customTitle),
                tombstone: mergeRegisters(tombstone, other.tombstone),
                seed: mergeRegisters(seed, other.seed)
            )
        }
    }

    /// Per-filter user state, keyed by filter id. Each filter syncs on its own —
    /// mirroring `FeedState` — so two devices adding or editing *different*
    /// filters concurrently both survive (a whole-list register would keep only
    /// the later writer's list). `value` carries the filter's content (including
    /// its display `order`); `tombstone` records a deletion so it propagates.
    public struct FilterState: Codable, Sendable, Equatable {
        public var value: LWWRegister<ArticleFilter>?
        public var tombstone: LWWRegister<Bool>?

        public init(value: LWWRegister<ArticleFilter>? = nil, tombstone: LWWRegister<Bool>? = nil) {
            self.value = value
            self.tombstone = tombstone
        }

        func merged(with other: FilterState) -> FilterState {
            FilterState(
                value: mergeRegisters(value, other.value),
                tombstone: mergeRegisters(tombstone, other.tombstone)
            )
        }
    }

    /// Per-category definition state, keyed by category id — the same per-item
    /// CRDT as `FilterState`, so two devices adding/editing different categories
    /// concurrently both survive and a deletion (`tombstone`) propagates.
    public struct CategoryState: Codable, Sendable, Equatable {
        public var value: LWWRegister<ArticleCategory>?
        public var tombstone: LWWRegister<Bool>?

        public init(value: LWWRegister<ArticleCategory>? = nil, tombstone: LWWRegister<Bool>? = nil) {
            self.value = value
            self.tombstone = tombstone
        }

        func merged(with other: CategoryState) -> CategoryState {
            CategoryState(
                value: mergeRegisters(value, other.value),
                tombstone: mergeRegisters(tombstone, other.tombstone)
            )
        }
    }

    public static let currentSchema = 1

    public var schema: Int
    public var deviceID: String
    /// Monotonic diagnostic/publish generation. Older decoders safely ignore it.
    public var generation: UInt64
    /// The last HLC this device issued, persisted so the clock survives relaunch
    /// and keeps advancing monotonically.
    public var clock: HLC
    /// Wall-clock stamp of the last write to this shard. Diagnostics and
    /// stale-device garbage collection only; never used for merge ordering.
    public var updatedAt: Date
    public var articleState: [Article.ID: ArticleState]
    public var feedState: [Feed.ID: FeedState]
    /// Folder existence as an add/remove LWW: `true` = created, `false` = removed.
    public var folders: [String: LWWRegister<Bool>]
    /// User article filters, keyed by filter id — each syncs independently (see
    /// `FilterState`). Named `filterStates` (not the old `filters`) so shards
    /// written by the earlier whole-list version decode cleanly: their stale
    /// `filters` key is simply ignored, and no real filter data predates this.
    public var filterStates: [String: FilterState]
    /// User category definitions, keyed by category id (per-item CRDT, see
    /// `CategoryState`). Optional-decoded so older shards without it load cleanly.
    public var categoryStates: [String: CategoryState]

    public init(
        deviceID: String,
        clock: HLC = .zero,
        updatedAt: Date = Date(),
        articleState: [Article.ID: ArticleState] = [:],
        feedState: [Feed.ID: FeedState] = [:],
        folders: [String: LWWRegister<Bool>] = [:],
        filterStates: [String: FilterState] = [:],
        categoryStates: [String: CategoryState] = [:]
    ) {
        self.schema = Self.currentSchema
        self.deviceID = deviceID
        self.generation = 0
        self.clock = clock
        self.updatedAt = updatedAt
        self.articleState = articleState
        self.feedState = feedState
        self.folders = folders
        self.filterStates = filterStates
        self.categoryStates = categoryStates
    }

    enum CodingKeys: String, CodingKey {
        case schema, deviceID, generation, clock, updatedAt, articleState, feedState, folders, filterStates, categoryStates
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema
        deviceID = try container.decode(String.self, forKey: .deviceID)
        generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
        clock = try container.decodeIfPresent(HLC.self, forKey: .clock) ?? .zero
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        articleState = try container.decodeIfPresent([Article.ID: ArticleState].self, forKey: .articleState) ?? [:]
        feedState = try container.decodeIfPresent([Feed.ID: FeedState].self, forKey: .feedState) ?? [:]
        folders = try container.decodeIfPresent([String: LWWRegister<Bool>].self, forKey: .folders) ?? [:]
        filterStates = try container.decodeIfPresent([String: FilterState].self, forKey: .filterStates) ?? [:]
        categoryStates = try container.decodeIfPresent([String: CategoryState].self, forKey: .categoryStates) ?? [:]
    }
}

// MARK: - Recording local mutations

extension DeviceStateDocument {
    /// One-time v1 → v2 bridge for user state that used to live only in the
    /// content baseline. Existing registers are never replaced.
    @discardableResult
    public mutating func seedLegacyUserState(
        from library: ReaderLibrary,
        whereMissingFrom observedShards: [DeviceStateDocument] = [],
        after initialClock: HLC,
        node: String
    ) -> HLC {
        var nextClock = initialClock
        let observed = Self.mergedState(from: observedShards + [self])
        func tick() -> HLC {
            nextClock = HLC.next(after: nextClock, node: node)
            return nextClock
        }
        for feed in library.feeds {
            let existing = observed.feeds[feed.id]
            if existing?.category == nil { setFeedCategory(feed.id, feed.category, hlc: tick()) }
            if existing?.preferredViewMode == nil, feed.preferredViewMode != nil {
                setFeedViewMode(feed.id, feed.preferredViewMode, hlc: tick())
            }
            if existing?.customTitle == nil, feed.customTitle != nil {
                setFeedTitle(feed.id, feed.customTitle, hlc: tick())
            }
            if existing?.seed == nil { setFeedSeed(feed.id, FeedSeed(from: feed), hlc: tick()) }
        }
        for article in library.articles {
            let existing = observed.articles[article.id]
            if existing?.isRead == nil { setArticleRead(article.id, article.isRead, hlc: tick()) }
            if existing?.isStarred == nil { setArticleStarred(article.id, article.isStarred, hlc: tick()) }
        }
        let names = Set(library.folders + library.feeds.map(\.folderName).filter { !$0.isEmpty })
        for name in names where observed.folders[name] == nil { setFolderPresent(name, true, hlc: tick()) }
        clock = nextClock
        return nextClock
    }

    public mutating func setArticleRead(_ id: Article.ID, _ value: Bool, hlc: HLC) {
        var state = articleState[id] ?? ArticleState()
        state.isRead = LWWRegister(value: value, hlc: hlc)
        articleState[id] = state
    }

    public mutating func setArticleStarred(_ id: Article.ID, _ value: Bool, hlc: HLC) {
        var state = articleState[id] ?? ArticleState()
        state.isStarred = LWWRegister(value: value, hlc: hlc)
        articleState[id] = state
    }

    public mutating func setArticleSeen(_ id: Article.ID, _ value: Bool, hlc: HLC) {
        var state = articleState[id] ?? ArticleState()
        state.seen = LWWRegister(value: value, hlc: hlc)
        articleState[id] = state
    }

    public mutating func setArticleTombstone(_ id: Article.ID, _ deleted: Bool, hlc: HLC) {
        var state = articleState[id] ?? ArticleState()
        state.tombstone = LWWRegister(value: deleted, hlc: hlc)
        articleState[id] = state
    }

    public mutating func setArticleCategories(_ id: Article.ID, _ value: [String], hlc: HLC) {
        var state = articleState[id] ?? ArticleState()
        state.categories = LWWRegister(value: value, hlc: hlc)
        articleState[id] = state
    }

    public mutating func setFeedCategory(_ id: Feed.ID, _ value: String, hlc: HLC) {
        var state = feedState[id] ?? FeedState()
        state.category = LWWRegister(value: value, hlc: hlc)
        feedState[id] = state
    }

    public mutating func setFeedViewMode(_ id: Feed.ID, _ value: ReaderViewMode?, hlc: HLC) {
        var state = feedState[id] ?? FeedState()
        state.preferredViewMode = LWWRegister(value: value, hlc: hlc)
        feedState[id] = state
    }

    public mutating func setFeedTitle(_ id: Feed.ID, _ value: String?, hlc: HLC) {
        var state = feedState[id] ?? FeedState()
        state.customTitle = LWWRegister(value: value, hlc: hlc)
        feedState[id] = state
    }

    public mutating func setFeedTombstone(_ id: Feed.ID, _ deleted: Bool, hlc: HLC) {
        var state = feedState[id] ?? FeedState()
        state.tombstone = LWWRegister(value: deleted, hlc: hlc)
        feedState[id] = state
    }

    public mutating func setFeedSeed(_ id: Feed.ID, _ seed: FeedSeed, hlc: HLC) {
        var state = feedState[id] ?? FeedState()
        state.seed = LWWRegister(value: seed, hlc: hlc)
        feedState[id] = state
    }

    public mutating func setFolderPresent(_ name: String, _ present: Bool, hlc: HLC) {
        folders[name] = LWWRegister(value: present, hlc: hlc)
    }

    public mutating func setFilter(_ id: String, _ value: ArticleFilter, hlc: HLC) {
        var state = filterStates[id] ?? FilterState()
        state.value = LWWRegister(value: value, hlc: hlc)
        filterStates[id] = state
    }

    public mutating func setFilterTombstone(_ id: String, _ deleted: Bool, hlc: HLC) {
        var state = filterStates[id] ?? FilterState()
        state.tombstone = LWWRegister(value: deleted, hlc: hlc)
        filterStates[id] = state
    }

    public mutating func setCategory(_ id: String, _ value: ArticleCategory, hlc: HLC) {
        var state = categoryStates[id] ?? CategoryState()
        state.value = LWWRegister(value: value, hlc: hlc)
        categoryStates[id] = state
    }

    public mutating func setCategoryTombstone(_ id: String, _ deleted: Bool, hlc: HLC) {
        var state = categoryStates[id] ?? CategoryState()
        state.tombstone = LWWRegister(value: deleted, hlc: hlc)
        categoryStates[id] = state
    }

    /// The greatest clock anywhere in this shard, so a device loading peers'
    /// shards can advance its own clock past everything it has observed.
    public var maxObservedHLC: HLC {
        var result = clock
        func fold(_ hlc: HLC?) { if let hlc, hlc > result { result = hlc } }
        for state in articleState.values {
            fold(state.isRead?.hlc)
            fold(state.isStarred?.hlc)
            fold(state.seen?.hlc)
            fold(state.categories?.hlc)
        }
        for state in feedState.values {
            fold(state.category?.hlc)
            fold(state.preferredViewMode?.hlc)
            fold(state.customTitle?.hlc)
            fold(state.tombstone?.hlc)
            fold(state.seed?.hlc)
        }
        for register in folders.values { fold(register.hlc) }
        for state in filterStates.values {
            fold(state.value?.hlc)
            fold(state.tombstone?.hlc)
        }
        for state in categoryStates.values {
            fold(state.value?.hlc)
            fold(state.tombstone?.hlc)
        }
        return result
    }
}

// MARK: - Merge / materialize

extension DeviceStateDocument {
    /// Folds every shard into a single merged view of user state, field-by-field
    /// by highest HLC. Pure and order-independent.
    static func mergedState(
        from shards: [DeviceStateDocument]
    ) -> (articles: [Article.ID: ArticleState], feeds: [Feed.ID: FeedState], folders: [String: LWWRegister<Bool>], filters: [String: FilterState], categories: [String: CategoryState]) {
        var articles: [Article.ID: ArticleState] = [:]
        var feeds: [Feed.ID: FeedState] = [:]
        var folders: [String: LWWRegister<Bool>] = [:]
        var filters: [String: FilterState] = [:]
        var categories: [String: CategoryState] = [:]
        for shard in shards {
            for (id, state) in shard.articleState {
                articles[id] = articles[id].map { $0.merged(with: state) } ?? state
            }
            for (id, state) in shard.feedState {
                feeds[id] = feeds[id].map { $0.merged(with: state) } ?? state
            }
            for (name, register) in shard.folders {
                folders[name] = mergeRegisters(folders[name], register)
            }
            for (id, state) in shard.filterStates {
                filters[id] = filters[id].map { $0.merged(with: state) } ?? state
            }
            for (id, state) in shard.categoryStates {
                categories[id] = categories[id].map { $0.merged(with: state) } ?? state
            }
        }
        return (articles, feeds, folders, filters, categories)
    }

    /// Produces the effective library the app should show: the regenerable
    /// content `base` (feeds, article bodies) with merged user state applied on
    /// top. Deleted feeds and their articles are dropped; read/starred/folder/
    /// view-mode overrides win over the baseline when a shard recorded them.
    ///
    /// Pure and `nonisolated` so it can run off the main actor for large
    /// libraries.
    public nonisolated static func materialize(
        base: ReaderLibrary,
        shards: [DeviceStateDocument]
    ) -> ReaderLibrary {
        let merged = mergedState(from: shards)

        // Feed membership: baseline ∪ shard-seeded, minus tombstoned. Resolve each
        // candidate id to a Feed with its state applied.
        let baseByID = Dictionary(base.feeds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var orderedIDs = base.feeds.map(\.id)
        orderedIDs.append(contentsOf: merged.feeds.keys.filter { baseByID[$0] == nil }.sorted())

        var resolved: [Feed.ID: Feed] = [:]
        var deletedFeedIDs: Set<Feed.ID> = []
        for id in orderedIDs {
            let state = merged.feeds[id]
            if state?.tombstone?.value == true { deletedFeedIDs.insert(id); continue }
            guard let feed = baseByID[id] ?? state?.seed?.value.makeFeed() else { continue }
            resolved[id] = feed
        }

        // Collapse feeds that are the same subscription under trivially-different
        // URLs (trailing slash, casing, a discovery artifact) into one canonical
        // feed. feed.id has historically been the raw feed URL, so a feed fetched
        // or added slightly differently across devices/versions split into separate
        // ids — duplicating its articles and orphaning some under a feed id with no
        // entity ("Unknown Feed"). The canonical id is the lexicographically
        // smallest alias id (deterministic across devices, not dependent on
        // dictionary/order), and the feed's user state (category / title / view
        // mode / tombstone) is merged field-wise across the whole alias group by
        // HLC. This heals every device on load and converges, without rewriting
        // the stored (grow-only) shards.
        var aliasesByKey: [String: [Feed.ID]] = [:]
        for id in orderedIDs where resolved[id] != nil {
            aliasesByKey[resolved[id]!.feedURL.feedIdentityKey, default: []].append(id)
        }
        var canonicalFeedID: [Feed.ID: Feed.ID] = [:]
        var feeds: [Feed] = []
        var emittedKeys = Set<String>()
        for id in orderedIDs {
            guard let feed = resolved[id] else { continue }
            let key = feed.feedURL.feedIdentityKey
            guard emittedKeys.insert(key).inserted else { continue }
            let aliases = aliasesByKey[key]!.sorted()
            let canonical = aliases.first!
            for alias in aliases { canonicalFeedID[alias] = canonical }

            var groupState: FeedState?
            for alias in aliases {
                if let s = merged.feeds[alias] { groupState = groupState.map { $0.merged(with: s) } ?? s }
            }
            if groupState?.tombstone?.value == true {
                for alias in aliases { deletedFeedIDs.insert(alias) }
                continue
            }
            var canonFeed = resolved[canonical] ?? feed
            canonFeed.id = canonical
            if let category = groupState?.category?.value { canonFeed.category = category }
            if let viewMode = groupState?.preferredViewMode { canonFeed.preferredViewMode = viewMode.value }
            if let customTitle = groupState?.customTitle { canonFeed.customTitle = customTitle.value }
            feeds.append(canonFeed)
        }
        let liveFeedIDs = Set(feeds.map(\.id))

        // Articles. The split copies of one article (same subscription fetched
        // under alias feed urls) are grouped by the canonical feed + the item seed
        // (the guid/link — the article id minus its own "feedID#" prefix), NOT by
        // URL, so genuinely different items that share a URL (syndication, or feeds
        // whose items fall back to the site URL) are never merged. The
        // representative is the min-id copy (deterministic); user state is merged
        // field-wise across the copies by HLC (so an explicit newer "unread" wins).
        func seed(of article: Article) -> String {
            let prefix = article.feedID + "#"
            return article.id.hasPrefix(prefix) ? String(article.id.dropFirst(prefix.count)) : article.id
        }
        var repByCanon: [String: Article] = [:]
        var stateByCanon: [String: ArticleState] = [:]
        var canonOrder: [String] = []
        var orphans: [Article] = []
        for article in base.articles {
            if deletedFeedIDs.contains(article.feedID) { continue }
            guard let canonicalFeed = canonicalFeedID[article.feedID], liveFeedIDs.contains(canonicalFeed) else {
                orphans.append(article)
                continue
            }
            let canonID = canonicalFeed + "#" + seed(of: article)
            if let s = merged.articles[article.id] {
                stateByCanon[canonID] = stateByCanon[canonID].map { $0.merged(with: s) } ?? s
            }
            if let existing = repByCanon[canonID] {
                if article.id < existing.id {
                    var rep = article; rep.feedID = canonicalFeed
                    repByCanon[canonID] = rep
                }
            } else {
                var rep = article; rep.feedID = canonicalFeed
                repByCanon[canonID] = rep
                canonOrder.append(canonID)
            }
        }

        var articles: [Article] = []
        articles.reserveCapacity(canonOrder.count)
        var liveIndexByURL: [String: [Int]] = [:]
        var canonIDByIndex: [Int: String] = [:]
        for canonID in canonOrder {
            guard var article = repByCanon[canonID] else { continue }
            let state = stateByCanon[canonID]
            if state?.tombstone?.value == true { continue }
            if let isRead = state?.isRead?.value { article.isRead = isRead }
            if let isStarred = state?.isStarred?.value { article.isStarred = isStarred }
            if let categories = state?.categories?.value { article.categories = categories }
            let idx = articles.count
            articles.append(article)
            liveIndexByURL[article.url.feedIdentityKey, default: []].append(idx)
            canonIDByIndex[idx] = canonID
        }

        // Orphans: an article whose feed entity isn't present (e.g. a ".../feed/feed"
        // discovery artifact). Absorb it into a live article ONLY when its URL
        // matches exactly one — a confirmed duplicate — merging its state (HLC LWW)
        // so no read/starred is lost. A unique or ambiguous orphan is kept as-is
        // rather than dropped, so genuinely-unique content is never hidden.
        var removedIndices = Set<Int>()
        for article in orphans.sorted(by: { $0.id < $1.id }) {
            let state = merged.articles[article.id]
            let matches = (liveIndexByURL[article.url.feedIdentityKey] ?? []).filter { !removedIndices.contains($0) }
            if matches.count == 1, let s = state {
                let idx = matches[0]
                let canonID = canonIDByIndex[idx]!
                let mergedState = stateByCanon[canonID].map { $0.merged(with: s) } ?? s
                stateByCanon[canonID] = mergedState
                if mergedState.tombstone?.value == true { removedIndices.insert(idx); continue }
                if let isRead = mergedState.isRead?.value { articles[idx].isRead = isRead }
                if let isStarred = mergedState.isStarred?.value { articles[idx].isStarred = isStarred }
                if let categories = mergedState.categories?.value { articles[idx].categories = categories }
            } else if matches.isEmpty {
                if state?.tombstone?.value == true { continue }
                var kept = article
                if let isRead = state?.isRead?.value { kept.isRead = isRead }
                if let isStarred = state?.isStarred?.value { kept.isStarred = isStarred }
                if let categories = state?.categories?.value { kept.categories = categories }
                articles.append(kept)
            }
        }
        if !removedIndices.isEmpty {
            articles = articles.enumerated().filter { !removedIndices.contains($0.offset) }.map(\.element)
        }

        // Folders: baseline explicit folders adjusted by add/remove registers.
        var folders = Set(base.folders)
        for (name, register) in merged.folders {
            if register.value { folders.insert(name) } else { folders.remove(name) }
        }

        // Filters: emit every non-tombstoned filter, sorted by (order, id) so the
        // list is stable and converges across devices despite the per-item map
        // being unordered.
        let filters = merged.filters
            .compactMap { _, state -> ArticleFilter? in
                guard state.tombstone?.value != true else { return nil }
                return state.value?.value
            }
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }

        // Categories: same per-item build as filters.
        let categories = merged.categories
            .compactMap { _, state -> ArticleCategory? in
                guard state.tombstone?.value != true else { return nil }
                return state.value?.value
            }
            .sorted { ($0.order, $0.id) < ($1.order, $1.id) }

        return ReaderLibrary(
            feeds: feeds,
            articles: articles,
            lastRefreshedAt: base.lastRefreshedAt,
            folders: Array(folders),
            filters: filters,
            categories: categories
        )
    }
}
