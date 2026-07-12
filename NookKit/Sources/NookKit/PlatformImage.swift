import SwiftUI

#if canImport(AppKit)
import AppKit

/// The platform's bitmap image type (`NSImage` on macOS, `UIImage` on iOS).
public typealias PlatformImage = NSImage

extension NSImage {
    /// A normalized PNG representation, so favicons cache in a consistent
    /// format regardless of source (ICO, PNG, …). Mirrors `UIImage.pngData()`.
    public func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
#elseif canImport(UIKit)
import UIKit

public typealias PlatformImage = UIImage
// `UIImage.pngData()` already exists.
#endif

extension Image {
    /// Builds a SwiftUI `Image` from a platform image without the caller
    /// needing `#if` around `nsImage:` / `uiImage:`.
    public init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// Decodes image data into a platform image. Lets callers avoid importing
/// AppKit/UIKit just to build an image.
public func makePlatformImage(data: Data) -> PlatformImage? {
    PlatformImage(data: data)
}
