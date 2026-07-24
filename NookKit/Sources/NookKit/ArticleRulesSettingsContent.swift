import SwiftUI

public extension Color {
    /// A color from a "#RRGGBB" string (Nook category badges). Falls back to gray.
    init(nookHex hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value), cleaned.count == 6 else {
            self = .gray
            return
        }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// The "Article Rules" settings body, shared by both apps: manage categories
/// (name, color, keyword rules, hide), turn on AI categorization (Apple
/// Intelligence by default, Gemini opt-in with a cost warning + key), and run a
/// one-off migration that classifies existing articles. Each host embeds it in
/// its own `Section`/`Form`/`List`. Localised via `.module`.
public struct ArticleRulesSettingsContent: View {
    private let store: ReaderStore

    @AppStorage(ReaderStore.aiCategorizationEnabledKey) private var aiEnabled = false
    @AppStorage(TranslationSettings.categoryProviderKey) private var categoryProvider = TranslationProvider.appleIntelligence.rawValue
    @AppStorage(TranslationSettings.geminiKeyConfiguredKey) private var geminiKeyConfigured = false

    @State private var keyInput = ""
    @State private var confirmingGemini = false
    @State private var confirmingMigrate = false

    public init(store: ReaderStore) {
        self.store = store
    }

    private var usesGemini: Bool { categoryProvider == TranslationProvider.gemini.rawValue }

    public var body: some View {
        categoriesSection
        aiSection
        migrationSection
    }

    // MARK: - Categories

    @ViewBuilder
    private var categoriesSection: some View {
        ForEach(store.categories) { category in
            CategoryRow(
                category: category,
                onChange: { store.updateCategory($0) },
                onDelete: { store.removeCategory(id: category.id) }
            )
        }

        Button {
            store.addCategory()
        } label: {
            Label { Text("Add Category", bundle: .module) } icon: { Image(systemName: "plus") }
        }

        Text("Add keywords to a category to auto-tag matching articles (e.g. \"WWDC\" → Apple). Turn on AI below to also classify by meaning. Only new articles are tagged automatically; use Classify Existing Articles for the rest.", bundle: .module)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - AI

    @ViewBuilder
    private var aiSection: some View {
        Toggle(isOn: aiToggle) {
            Text("Categorize with AI", bundle: .module)
            Text("Classifies articles into your categories by meaning, on top of keyword rules.", bundle: .module)
        }
        .confirmationDialog(
            Text("Use Gemini for categorization?", bundle: .module),
            isPresented: $confirmingGemini,
            titleVisibility: .visible
        ) {
            Button {
                aiEnabled = true
                categoryProvider = TranslationProvider.gemini.rawValue
            } label: {
                Text("Use Gemini", bundle: .module)
            }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("Gemini classifies over the network and may cost money; article text is sent to Google. Apple Intelligence stays on device and free.", bundle: .module)
        }

        if aiEnabled {
            Picker(selection: providerBinding) {
                Text("Apple Intelligence", bundle: .module).tag(TranslationProvider.appleIntelligence.rawValue)
                Text("Gemini", bundle: .module).tag(TranslationProvider.gemini.rawValue)
            } label: {
                Text("AI provider", bundle: .module)
            }

            if usesGemini {
                geminiKeyControls
                Text("Gemini runs over the network and may incur cost. Article text is sent to Google. Your key is stored only on this device.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Enabling AI while Gemini is already the provider asks for consent first.
    private var aiToggle: Binding<Bool> {
        Binding(
            get: { aiEnabled },
            set: { newValue in
                if newValue, usesGemini {
                    confirmingGemini = true   // gate on consent
                } else {
                    aiEnabled = newValue
                }
            }
        )
    }

    /// Switching the provider TO Gemini asks for consent first (cost/privacy), so
    /// the warning can't be bypassed by enabling AI on Apple then flipping the
    /// picker. The dialog applies Gemini; cancelling leaves the current provider.
    private var providerBinding: Binding<String> {
        Binding(
            get: { categoryProvider },
            set: { newValue in
                if newValue == TranslationProvider.gemini.rawValue, categoryProvider != TranslationProvider.gemini.rawValue {
                    confirmingGemini = true
                } else {
                    categoryProvider = newValue
                }
            }
        )
    }

    @ViewBuilder
    private var geminiKeyControls: some View {
        SecureField(text: $keyInput) { Text("Gemini API key", bundle: .module) }
            .textContentType(.password)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif

        HStack {
            Button {
                GeminiCredential.setAPIKey(keyInput)
            } label: {
                Text("Save Key", bundle: .module)
            }
            .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if geminiKeyConfigured {
                Button(role: .destructive) {
                    GeminiCredential.setAPIKey(nil)
                    keyInput = ""
                } label: {
                    Text("Clear Key", bundle: .module)
                }
            }
        }

        (geminiKeyConfigured
            ? Text("A Gemini API key is saved on this device.", bundle: .module)
            : Text("No Gemini API key saved yet.", bundle: .module))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Migration

    @ViewBuilder
    private var migrationSection: some View {
        if let progress = store.categorizeAllProgress {
            HStack {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                Text("\(progress.completed)/\(progress.total)").font(.caption).monospacedDigit()
                Button(role: .cancel) { store.cancelClassifyAll() } label: { Text("Stop", bundle: .module) }
            }
        } else {
            Button {
                confirmingMigrate = true
            } label: {
                Label { Text("Classify Existing Articles", bundle: .module) } icon: { Image(systemName: "sparkles.rectangle.stack") }
            }
            .disabled(store.categories.isEmpty)
            .confirmationDialog(
                Text("Classify Existing Articles", bundle: .module),
                isPresented: $confirmingMigrate,
                titleVisibility: .visible
            ) {
                // Keyword rules always apply; these choose the AI provider for the
                // run. A Gemini user can run this pass on Apple Intelligence to
                // avoid cost.
                if usesGemini {
                    Button { store.classifyAllExisting(provider: .appleIntelligence) } label: {
                        Text("Use Apple Intelligence", bundle: .module)
                    }
                    Button { store.classifyAllExisting(provider: .gemini) } label: {
                        Text("Use Gemini (may cost)", bundle: .module)
                    }
                } else {
                    Button { store.classifyAllExisting(provider: .appleIntelligence) } label: {
                        Text("Classify", bundle: .module)
                    }
                }
                Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
            } message: {
                Text("Tags your existing articles with keyword rules and AI. With many articles it can take a while; Gemini may cost money.", bundle: .module)
            }

            Text("Only new articles are tagged automatically. Use this to catch up your existing articles.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One editable category. Draft/commit like the filter rows: edits stay local and
/// apply on Save, so typing a name/keywords never re-classifies per keystroke.
private struct CategoryRow: View {
    let category: ArticleCategory
    let onChange: (ArticleCategory) -> Void
    let onDelete: () -> Void

    @State private var draft: ArticleCategory
    @State private var baseline: ArticleCategory

    init(category: ArticleCategory, onChange: @escaping (ArticleCategory) -> Void, onDelete: @escaping () -> Void) {
        self.category = category
        self.onChange = onChange
        self.onDelete = onDelete
        _draft = State(initialValue: category)
        _baseline = State(initialValue: category)
    }

    private var isDirty: Bool { draft != baseline }

    private var keywordsText: Binding<String> {
        Binding(
            get: { draft.keywords.joined(separator: ", ") },
            set: { draft.keywords = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                colorMenu
                TextField(text: $draft.name, prompt: Text("Category name", bundle: .module)) {
                    Text("Name", bundle: .module)
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Delete category", bundle: .module))
            }

            TextField(text: keywordsText, prompt: Text("Keywords, comma-separated", bundle: .module)) {
                Text("Keywords", bundle: .module)
            }
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
            .font(.callout)

            HStack(spacing: 12) {
                Picker(selection: $draft.keywordMatchTarget) {
                    ForEach(ArticleFilter.MatchTarget.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: { Text("Match in", bundle: .module) }
                .labelsHidden()
                .fixedSize()

                Toggle(isOn: $draft.keywordCaseSensitive) { Text(verbatim: "Aa") }
                    .toggleStyle(.button)
                    .accessibilityLabel(Text("Case sensitive", bundle: .module))

                Spacer(minLength: 4)

                Toggle(isOn: $draft.hidden) { Text("Hide", bundle: .module) }
                    .toggleStyle(.button)
                    .accessibilityLabel(Text("Hide articles in this category", bundle: .module))

                if isDirty {
                    Button { onChange(draft) } label: { Text("Save", bundle: .module) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 2)
        .onChange(of: category) { _, new in
            if !isDirty { draft = new }
            baseline = new
        }
    }

    private var colorMenu: some View {
        Menu {
            ForEach(ArticleCategory.defaultPalette, id: \.self) { hex in
                Button {
                    draft.colorHex = hex
                } label: {
                    Label { Text(verbatim: hex) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(nookHex: hex)) }
                }
            }
        } label: {
            Circle().fill(Color(nookHex: draft.colorHex)).frame(width: 18, height: 18)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(Text("Category color", bundle: .module))
    }
}

/// Compact colored category chips for an article-list row. Given the already-
/// resolved category definitions (see `ReaderStore.categories(forArticle:)`).
public struct CategoryBadges: View {
    private let categories: [ArticleCategory]

    public init(_ categories: [ArticleCategory]) {
        self.categories = categories
    }

    public var body: some View {
        if !categories.isEmpty {
            HStack(spacing: 4) {
                ForEach(categories) { category in
                    Text(category.name)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(Color(nookHex: category.colorHex))
                        .background(Color(nookHex: category.colorHex).opacity(0.16), in: Capsule())
                }
            }
        }
    }
}

/// A menu of the user's categories, each toggling on/off for an article — the
/// quick per-article editor used from list/reader context menus.
public struct CategoryMenuItems: View {
    private let store: ReaderStore
    private let article: Article

    public init(store: ReaderStore, article: Article) {
        self.store = store
        self.article = article
    }

    public var body: some View {
        if store.categories.isEmpty {
            Text("No categories — add some in Article Rules", bundle: .module)
        } else {
            // Read the live assignment from the store (not the captured `article`),
            // so checkmarks are correct even if a menu is kept open across taps.
            let assigned = Set(store.articles.first(where: { $0.id == article.id })?.categories ?? article.categories)
            ForEach(store.categories) { category in
                Button {
                    store.toggleCategory(category.id, forArticle: article.id)
                } label: {
                    if assigned.contains(category.id) {
                        Label(category.name, systemImage: "checkmark")
                    } else {
                        Text(category.name)
                    }
                }
            }
        }
    }
}

/// Per-article category editor: toggle each category on/off for the article.
/// Presented from the reader / list context menu.
public struct CategoryPicker: View {
    private let store: ReaderStore
    private let articleID: Article.ID
    private let onDone: () -> Void

    public init(store: ReaderStore, articleID: Article.ID, onDone: @escaping () -> Void) {
        self.store = store
        self.articleID = articleID
        self.onDone = onDone
    }

    private var assigned: [String] {
        store.articles.first(where: { $0.id == articleID })?.categories ?? []
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Categories", bundle: .module).font(.headline)
                Spacer()
                Button(action: onDone) { Text("Done", bundle: .module) }
            }
            .padding(16)
            Divider()

            if store.categories.isEmpty {
                Spacer()
                Text("No categories yet. Add some in Settings › Article Rules.", bundle: .module)
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
                Spacer()
            } else {
                List {
                    ForEach(store.categories) { category in
                        Button {
                            toggle(category.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: assigned.contains(category.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(assigned.contains(category.id) ? Color(nookHex: category.colorHex) : .secondary)
                                Circle().fill(Color(nookHex: category.colorHex)).frame(width: 10, height: 10)
                                Text(category.name.isEmpty ? String(localized: "Untitled", bundle: .module) : category.name)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggle(_ id: String) {
        var next = assigned
        if let idx = next.firstIndex(of: id) { next.remove(at: idx) } else { next.append(id) }
        store.setArticleCategories(articleID: articleID, next)
    }
}
