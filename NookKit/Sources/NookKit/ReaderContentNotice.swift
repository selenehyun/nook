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
