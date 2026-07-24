import SwiftUI

/// Offline-caching settings, shared by both apps: how long downloads are kept
/// (auto-expiry), a storage readout, and a "remove all" button. Each host embeds
/// it in its own `Section` ("Offline"). The list of saved articles itself lives
/// in the sidebar's "Downloaded" source (with per-article removal), so this is
/// just the bulk controls. Localised via `.module`.
public struct OfflineSettingsContent: View {
    private let store: ReaderStore
    @AppStorage(ReaderStore.offlineExpiryKey) private var expiryRaw = OfflineExpiry.twoWeeks.rawValue
    @State private var confirmingClear = false

    public init(store: ReaderStore) {
        self.store = store
    }

    private var count: Int { store.count(for: .offline) }

    private var storageSummary: String {
        ByteCountFormatter.string(fromByteCount: Int64(store.offlineTotalBytes), countStyle: .file)
    }

    public var body: some View {
        Picker(selection: $expiryRaw) {
            ForEach(OfflineExpiry.allCases) { option in
                Text(option.title).tag(option.rawValue)
            }
        } label: {
            Text("Auto-remove downloads", bundle: .module)
        }
        .onChange(of: expiryRaw) { _, _ in store.purgeExpiredOffline() }

        LabeledContent {
            if count > 0 {
                Text(verbatim: storageSummary)
            } else {
                Text("None", bundle: .module)
            }
        } label: {
            if count == 1 {
                Text("1 article downloaded", bundle: .module)
            } else {
                Text("\(count) articles downloaded", bundle: .module)
            }
        }

        Button(role: .destructive) {
            confirmingClear = true
        } label: {
            Text("Remove All Downloads", bundle: .module)
        }
        .disabled(count == 0)
        .confirmationDialog(
            Text("Remove All Downloads", bundle: .module),
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                store.clearOfflineCache()
            } label: {
                Text("Remove All Downloads", bundle: .module)
            }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("Deletes every article saved for offline reading on this device.", bundle: .module)
        }

        Text("Save an article for offline from its context menu (or swipe), or use Download for Offline to save a whole list. Saved articles open instantly without a connection and are kept on this device only.", bundle: .module)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
