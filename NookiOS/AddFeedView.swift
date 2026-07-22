import NookKit
import SwiftUI
import UIKit

/// Adds a feed by URL. Nook validates and fetches it first, then dismisses only
/// after the feed has actually been accepted.
struct AddFeedView: View {
    var folders: [String]
    /// When true (opened from the tutorial), show a one-tap paste button and a
    /// guiding hint so the user can drop in the feed they just copied.
    var tutorialPaste: Bool = false
    var onAdd: (String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var feedURL = ""
    @State private var folderChoice: FolderChoice = .topLevel
    @State private var newFolderName = ""
    @State private var isSubmitting = false
    @State private var submissionError: String?
    @FocusState private var focused: Bool

    private enum FolderChoice: Hashable {
        case topLevel
        case existing(String)
        case newFolder
    }

    private var trimmedFeedURL: String {
        feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNewFolderName: String {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedFolder: String {
        switch folderChoice {
        case .topLevel:
            return ""
        case .existing(let folder):
            return folder
        case .newFolder:
            return trimmedNewFolderName
        }
    }

    private var canSubmit: Bool {
        !trimmedFeedURL.isEmpty
            && !isSubmitting
            && (folderChoice != .newFolder || !trimmedNewFolderName.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/feed.xml", text: $feedURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focused)
                        .disabled(isSubmitting)
                        .onSubmit(add)

                    if tutorialPaste {
                        Button {
                            if let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !pasted.isEmpty {
                                feedURL = pasted
                            }
                        } label: {
                            Label("Paste Copied Link", systemImage: "doc.on.clipboard")
                        }
                        .disabled(isSubmitting)
                    }
                } footer: {
                    if tutorialPaste {
                        Text("Paste the Hacker News link you copied, then tap Add.")
                    }
                }
                Section {
                    Picker("Folder", selection: $folderChoice) {
                        Text("Top Level").tag(FolderChoice.topLevel)
                        ForEach(folders, id: \.self) { folder in
                            Text(folder).tag(FolderChoice.existing(folder))
                        }
                        Text("New Folder…").tag(FolderChoice.newFolder)
                    }
                    .pickerStyle(.menu)

                    if folderChoice == .newFolder {
                        TextField("Folder Name", text: $newFolderName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    if isSubmitting {
                        Label {
                            Text("Checking RSS/Atom feed…")
                        } icon: {
                            ProgressView()
                        }
                        .labelStyle(.titleAndIcon)
                    } else if let submissionError {
                        Label {
                            Text(submissionError)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.red)
                    } else {
                        Text("Paste an RSS or Atom feed URL, or a website address. Nook will check it before closing.")
                    }
                }
            }
            .navigationTitle("Add Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: add) {
                        if isSubmitting {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Checking…")
                            }
                        } else {
                            Text("Add")
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .task { focused = true }
            .onChange(of: feedURL) { _, _ in
                if submissionError != nil { submissionError = nil }
            }
            .onChange(of: folderChoice) { _, _ in
                if submissionError != nil { submissionError = nil }
            }
            .onChange(of: newFolderName) { _, _ in
                if submissionError != nil { submissionError = nil }
            }
        }
    }

    private func add() {
        guard canSubmit else { return }
        let feedURL = trimmedFeedURL
        let folder = selectedFolder
        isSubmitting = true
        submissionError = nil

        Task {
            do {
                try await onAdd(feedURL, folder)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    submissionError = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }
}
