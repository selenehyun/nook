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

        public init(isRead: LWWRegister<Bool>? = nil, isStarred: LWWRegister<Bool>? = nil) {
            self.isRead = isRead
            self.isStarred = isStarred
        }

        var isEmpty: Bool { isRead == nil && isStarred == nil }

        func merged(with other: ArticleState) -> ArticleState {
            ArticleState(
                isRead: mergeRegisters(isRead, other.isRead),
                isStarred: mergeRegisters(isStarred, other.isStarred)
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

    public init(
        deviceID: String,
        clock: HLC = .zero,
        updatedAt: Date = Date(),
        articleState: [Article.ID: ArticleState] = [:],
        feedState: [Feed.ID: FeedState] = [:],
        folders: [String: LWWRegister<Bool>] = [:]
    ) {
        self.schema = Self.currentSchema
        self.deviceID = deviceID
        self.generation = 0
        self.clock = clock
        self.updatedAt = updatedAt
        self.articleState = articleState
        self.feedState = feedState
        self.folders = folders
    }

    enum CodingKeys: String, CodingKey {
        case schema, deviceID, generation, clock, updatedAt, articleState, feedState, folders
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

    /// The greatest clock anywhere in this shard, so a device loading peers'
    /// shards can advance its own clock past everything it has observed.
    public var maxObservedHLC: HLC {
        var result = clock
        func fold(_ hlc: HLC?) { if let hlc, hlc > result { result = hlc } }
        for state in articleState.values {
            fold(state.isRead?.hlc)
            fold(state.isStarred?.hlc)
        }
        for state in feedState.values {
            fold(state.category?.hlc)
            fold(state.preferredViewMode?.hlc)
            fold(state.customTitle?.hlc)
            fold(state.tombstone?.hlc)
            fold(state.seed?.hlc)
        }
        for register in folders.values { fold(register.hlc) }
        return result
    }
}

// MARK: - Merge / materialize

extension DeviceStateDocument {
    /// Folds every shard into a single merged view of user state, field-by-field
    /// by highest HLC. Pure and order-independent.
    static func mergedState(
        from shards: [DeviceStateDocument]
    ) -> (articles: [Article.ID: ArticleState], feeds: [Feed.ID: FeedState], folders: [String: LWWRegister<Bool>]) {
        var articles: [Article.ID: ArticleState] = [:]
        var feeds: [Feed.ID: FeedState] = [:]
        var folders: [String: LWWRegister<Bool>] = [:]
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
        }
        return (articles, feeds, folders)
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

        // Feeds: the membership is the union of the baseline's feeds and any a
        // shard seeded (added on a device but perhaps not yet in this baseline),
        // minus the tombstoned ones — so a feed can't be lost to a baseline-file
        // overwrite, and a re-add (newer seed/untombstone) beats an old delete.
        // Baseline order is preserved; seed-only feeds append deterministically.
        let baseByID = Dictionary(base.feeds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var orderedIDs = base.feeds.map(\.id)
        orderedIDs.append(contentsOf: merged.feeds.keys.filter { baseByID[$0] == nil }.sorted())

        var deletedFeedIDs: Set<Feed.ID> = []
        var feeds: [Feed] = []
        feeds.reserveCapacity(orderedIDs.count)
        for id in orderedIDs {
            let state = merged.feeds[id]
            if state?.tombstone?.value == true {
                deletedFeedIDs.insert(id)
                continue
            }
            guard var feed = baseByID[id] ?? state?.seed?.value.makeFeed() else { continue }
            if let category = state?.category?.value { feed.category = category }
            if let viewMode = state?.preferredViewMode { feed.preferredViewMode = viewMode.value }
            if let customTitle = state?.customTitle { feed.customTitle = customTitle.value }
            feeds.append(feed)
        }

        // Articles: drop those orphaned by a deleted feed, apply read/starred.
        var articles: [Article] = []
        articles.reserveCapacity(base.articles.count)
        for var article in base.articles where !deletedFeedIDs.contains(article.feedID) {
            let state = merged.articles[article.id]
            if let isRead = state?.isRead?.value { article.isRead = isRead }
            if let isStarred = state?.isStarred?.value { article.isStarred = isStarred }
            articles.append(article)
        }

        // Folders: baseline explicit folders adjusted by add/remove registers.
        var folders = Set(base.folders)
        for (name, register) in merged.folders {
            if register.value { folders.insert(name) } else { folders.remove(name) }
        }

        return ReaderLibrary(
            feeds: feeds,
            articles: articles,
            lastRefreshedAt: base.lastRefreshedAt,
            folders: Array(folders)
        )
    }
}
