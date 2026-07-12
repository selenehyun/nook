import NookKit
import SwiftUI

/// Adds a feed by URL. Nook fetches it right away; the sheet dismisses on submit
/// and the feed appears in the sidebar once fetched.
struct AddFeedView: View {
    var onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var feedURL = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/feed.xml", text: $feedURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focused)
                        .onSubmit(add)
                } footer: {
                    Text("Paste an RSS or Atom feed URL, or a website address — Nook will find the feed.")
                }
            }
            .navigationTitle("Add Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add)
                        .disabled(feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task { focused = true }
        }
    }

    private func add() {
        let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        dismiss()
    }
}
