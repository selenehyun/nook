import SwiftUI

/// A thin Safari-style page-load bar for the in-app browser. It fills from left
/// to right with the web view's estimated progress and fades out once the load
/// finishes (or hasn't started), keeping a constant 2pt height so it never
/// shifts the layout below the header.
public struct WebLoadingBar: View {
    private let progress: Double

    public init(progress: Double) {
        self.progress = progress
    }

    private var isLoading: Bool { progress > 0 && progress < 1 }

    public var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: geometry.size.width * progress)
                .opacity(isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: progress)
                .animation(.easeOut(duration: 0.25), value: isLoading)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}
