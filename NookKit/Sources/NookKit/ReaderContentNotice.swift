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

/// Shown above the original content when reader-mode extraction fails, so the
/// user understands they're seeing the feed's original content, not reader mode.
public struct ReaderFallbackNotice: View {
    private let onRetry: () -> Void

    public init(onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Showing original content", bundle: .module)
                    .font(.subheadline.weight(.semibold))
                Text("Reader view couldn't be loaded for this article.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                onRetry()
            } label: {
                Text("Try Again", bundle: .module)
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Shown when the article's original page is gone (HTTP 404/410): the source no
/// longer has it, so offer to delete the lingering local copy (or retry).
public struct ReaderGoneNotice: View {
    private let onDelete: () -> Void
    private let onRetry: () -> Void

    public init(onDelete: @escaping () -> Void, onRetry: @escaping () -> Void) {
        self.onDelete = onDelete
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Original no longer available", bundle: .module)
                        .font(.subheadline.weight(.semibold))
                    Text("The source returned “not found”, so this article was likely removed. You can delete it from your list.", bundle: .module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Article", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button(action: onRetry) {
                    Text("Try Again", bundle: .module)
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
