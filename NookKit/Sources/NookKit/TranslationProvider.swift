import Foundation
import Security

/// Which model backs translation. Chosen per surface (the reader and the article
/// list are set independently), so a user can, say, use Apple Intelligence for
/// on-device title translation and Gemini for full articles.
public enum TranslationProvider: String, Sendable, CaseIterable {
    /// On-device Apple Intelligence (Foundation Models). Private, offline, free.
    case appleIntelligence
    /// Google Gemini over the network (needs an API key; content leaves the device).
    case gemini
}

/// Per-surface provider selection, stored in local `UserDefaults` (never synced).
/// The Gemini API key lives in the Keychain instead (see `GeminiCredential`).
public enum TranslationSettings {
    /// Provider for the full-article reader translation.
    public static let readerProviderKey = "readerTranslationProvider"
    /// Provider for the article-list title auto-translation.
    public static let titleProviderKey = "titleTranslationProvider"
    /// Provider for AI-based article categorization.
    public static let categoryProviderKey = "categoryClassificationProvider"
    /// A non-secret mirror of "a Gemini key is stored", in `UserDefaults` so
    /// SwiftUI (`@AppStorage`) can react when the key is saved/cleared. The key
    /// itself stays in the Keychain (`GeminiCredential`).
    public static let geminiKeyConfiguredKey = "geminiKeyConfigured"

    public static func readerProvider() -> TranslationProvider { provider(forKey: readerProviderKey) }
    public static func titleProvider() -> TranslationProvider { provider(forKey: titleProviderKey) }
    public static func categoryProvider() -> TranslationProvider { provider(forKey: categoryProviderKey) }

    private static func provider(forKey key: String) -> TranslationProvider {
        TranslationProvider(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .appleIntelligence
    }
}

/// The Gemini API key, stored ONLY in this device's Keychain — never in
/// `UserDefaults`, the sync folder, or iCloud Keychain. `ThisDeviceOnly`
/// accessibility keeps it off backups and other devices, satisfying "the key is
/// stored only in the app and never synced".
public enum GeminiCredential {
    private static let service = "com.nook.translation.gemini"
    private static let account = "apiKey"

    public static var apiKey: String? {
        var query: [String: Any] = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    public static var hasKey: Bool { apiKey != nil }

    /// Stores (or, with nil/empty, clears) the key. Always device-only. The
    /// observable "configured" flag reflects the ACTUAL stored state (a failed
    /// write leaves no key and the flag false), never just the input.
    @discardableResult
    public static func setAPIKey(_ key: String?) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var stored = false
        if !trimmed.isEmpty, let data = trimmed.data(using: .utf8) {
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            stored = SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
        }
        UserDefaults.standard.set(stored, forKey: TranslationSettings.geminiKeyConfiguredKey)
        return stored
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
