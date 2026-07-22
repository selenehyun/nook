import SwiftUI

/// Shown in the native reader while reader-mode content is being extracted from
/// the article page. Keeps the surface from flashing the RSS body first.
public struct ReaderLoadingPlaceholder: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading reader view…", bundle: .module)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 40)
    }
}

/// Shown above the saved copy whenever the reader can't show the original —
/// whether extraction failed or the page is gone (404/410). One notice for both
/// so the reader looks the same however it got here: it explains the saved copy
/// is shown and offers Try Again and Delete.
public struct ReaderUnavailableNotice: View {
    private let onRetry: () -> Void
    private let onDelete: () -> Void

    public init(onRetry: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.onRetry = onRetry
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Can't show the original", bundle: .module)
                        .font(.subheadline.weight(.semibold))
                    Text("Showing the saved copy. If the article was removed from the source, you can delete it.", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button(action: onRetry) {
                    Text("Try Again", bundle: .module)
                }
                .buttonStyle(.bordered)
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Article", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
