import SwiftUI

/// The rows for choosing the translation backend per surface and entering a
/// Gemini API key. Shared by both apps; each embeds it in its own Section (iOS
/// `List`, macOS `Form`). Localized via `.module`.
public struct TranslationEngineSettingsContent: View {
    @AppStorage(TranslationSettings.readerProviderKey) private var readerProvider = TranslationProvider.appleIntelligence.rawValue
    @AppStorage(TranslationSettings.titleProviderKey) private var titleProvider = TranslationProvider.appleIntelligence.rawValue
    @AppStorage(TranslationSettings.geminiKeyConfiguredKey) private var geminiKeyConfigured = false
    @State private var keyInput = ""

    public init() {}

    private var usesGemini: Bool {
        readerProvider == TranslationProvider.gemini.rawValue || titleProvider == TranslationProvider.gemini.rawValue
    }

    public var body: some View {
        Picker(selection: $readerProvider) { providerOptions } label: {
            Text("Full-article reader", bundle: .module)
        }
        Picker(selection: $titleProvider) { providerOptions } label: {
            Text("Article list titles", bundle: .module)
        }

        if usesGemini {
            SecureField(text: $keyInput) {
                Text("Gemini API key", bundle: .module)
            }
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

            Text("Your key is stored only on this device and is never synced. When Gemini is selected, article text is sent to Google to translate it.", bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var providerOptions: some View {
        Text("Apple Intelligence", bundle: .module).tag(TranslationProvider.appleIntelligence.rawValue)
        Text("Gemini", bundle: .module).tag(TranslationProvider.gemini.rawValue)
    }
}
