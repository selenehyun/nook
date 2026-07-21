import SwiftUI
import UIKit

/// The launch animation: the app icon's twig layers drop in from above, one by
/// one under gravity, and settle into the nest — matching the twigs' real
/// geometry from AppIcon.icon (each a rotated rounded rectangle on the 1024pt
/// canvas). Rendered natively so it can animate; the launch screen stays static.
struct NestAssemblyView: View {
    /// On-screen size of the 1024pt icon canvas.
    var size: CGFloat = 150
    /// Flip to true to drop the twigs in.
    var assembled: Bool

    fileprivate struct Twig: Identifiable {
        let id: Int
        let x, y, w, h, rx, rotation, tx, ty: CGFloat
        let color: Color
    }

    // Twig geometry (AppIcon.icon SVG layers) + per-layer fill/translation
    // (icon.json), on the 1024pt canvas. Ordered back-to-front so the ZStack
    // and the drop stagger build the nest up naturally. fileprivate so the tab
    // glyph below can reuse the exact same geometry.
    fileprivate static let twigs: [Twig] = [
        Twig(id: 0, x: 455, y: 671.174, w: 532.752, h: 60.7009, rx: 30.3504, rotation: -38.5727, tx: 0, ty: 0,
             color: Color(.displayP3, red: 0.52707, green: 0.34104, blue: 0.16485)),
        Twig(id: 1, x: 176.275, y: 619, w: 462.978, h: 74, rx: 37, rotation: 2.5362, tx: 0, ty: 0,
             color: Color(.displayP3, red: 0.33131, green: 0.18300, blue: 0.12426)),
        Twig(id: 2, x: 248, y: 683.56, w: 708.947, h: 74, rx: 37, rotation: -22.5819, tx: 0, ty: 0,
             color: Color(.displayP3, red: 0.39857, green: 0.26728, blue: 0.07585)),
        Twig(id: 3, x: 133.696, y: 390, w: 664.22, h: 74, rx: 37, rotation: 32.4414, tx: 0, ty: 0,
             color: Color(.displayP3, red: 0.47398, green: 0.28733, blue: 0.14062)),
        Twig(id: 4, x: 110.209, y: 495, w: 701.451, h: 74, rx: 37, rotation: 11.8602, tx: 21.457819, ty: 1.551876,
             color: Color(.displayP3, red: 0.36629, green: 0.22432, blue: 0.08458)),
        Twig(id: 5, x: 359, y: 704.858, w: 571.721, h: 74, rx: 37, rotation: -17.5522, tx: -34.267837, ty: -13.052022,
             color: Color(.displayP3, red: 0.28234, green: 0.23103, blue: 0.12362)),
    ]

    // The twigs' rotated bounding box isn't centered on the 1024pt canvas — its
    // center sits at (512.5, 573.9), i.e. ~62pt low. Shift the whole group by
    // this so the assembled nest lands dead-center.
    fileprivate static let centerDX: CGFloat = 512 - 512.5
    fileprivate static let centerDY: CGFloat = 512 - 573.88

    var body: some View {
        let k = size / 1024
        ZStack(alignment: .topLeading) {
            // Pin the coordinate box to size×size with a top-leading origin, so
            // the twig offsets below are measured from the frame's top-left
            // (otherwise the ZStack shrinks to the twigs' layout frames and the
            // whole group renders off-center).
            Color.clear.frame(width: size, height: size)

            ForEach(Self.twigs) { twig in
                RoundedRectangle(cornerRadius: twig.rx * k, style: .continuous)
                    .fill(twig.color)
                    .opacity(0.8)
                    .frame(width: twig.w * k, height: twig.h * k)
                    .rotationEffect(.degrees(twig.rotation), anchor: .topLeading)
                    // Start well above the screen; drop to the resting spot.
                    .offset(
                        x: (twig.x + twig.tx + Self.centerDX) * k,
                        y: (twig.y + twig.ty + Self.centerDY) * k + (assembled ? 0 : -size * 5)
                    )
                    .animation(
                        .spring(response: 0.5, dampingFraction: 0.62)
                            .delay(Double(twig.id) * 0.09),
                        value: assembled
                    )
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    /// Roughly how long the full drop-and-settle takes.
    static var duration: Double { Double(twigs.count) * 0.09 + 0.6 }
}

/// The nest mark drawn statically as a single-color silhouette, from the same
/// twig geometry as the icon/splash. The twigs are thin, so a stroked "outline"
/// would vanish at tab size — instead it's a filled silhouette and the tab bar's
/// tint (secondary when unselected, accent when selected) carries the state, the
/// standard treatment for a custom template glyph.
private struct NestGlyphView: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 1024, height: 1024)
            ForEach(NestAssemblyView.twigs) { twig in
                RoundedRectangle(cornerRadius: 37, style: .continuous)
                    .fill(Color.black)
                    .frame(width: twig.w, height: twig.h)
                    .rotationEffect(.degrees(twig.rotation), anchor: .topLeading)
                    .offset(
                        x: twig.x + twig.tx + NestAssemblyView.centerDX,
                        y: twig.y + twig.ty + NestAssemblyView.centerDY
                    )
            }
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Bottom-tab glyphs rendered once to template `UIImage`s. Going through
/// pre-rendered rasters (rather than `.tabItem { Image(systemName:) }`) is what
/// lets us control outline-vs-fill: the iOS 26 tab bar force-fills symbol-named
/// items, but it can't re-fill a raster. All are templates so the bar tints them
/// (secondary when unselected, accent when selected). Main-actor: `ImageRenderer`
/// and `UIImage(systemName:)` sizing run there.
@MainActor
enum TabGlyph {
    /// An SF Symbol rasterized as a template image at roughly the size the tab bar
    /// renders its native symbols (a custom image isn't auto-scaled by the bar, so
    /// the point size here is the size shown — keep it near the ~18pt native glyph
    /// so these icons stay their original size).
    static func symbol(_ name: String) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        return (UIImage(systemName: name, withConfiguration: config) ?? UIImage())
            .withRenderingMode(.alwaysTemplate)
    }

    /// The nest mark, trimmed to its content then redrawn into a fixed point-size
    /// context so the tab icon is a sane size (never the raw render canvas, which
    /// blew up to hundreds of points and covered the whole bar).
    static let nest: UIImage = {
        let glyph = NestGlyphView().scaleEffect(0.5).frame(width: 512, height: 512)
        let renderer = ImageRenderer(content: glyph)
        renderer.scale = 3
        let full = renderer.uiImage ?? UIImage()
        let source = full.nk_trimmingTransparentEdges() ?? full

        // Target ~24pt tall (like the symbols), capped in width so the wide nest
        // can't grow past a normal icon footprint. UIGraphicsImageRenderer output
        // is guaranteed to be this point size regardless of source pixels.
        // Taller than the ~18pt symbols so the nest reads as the primary tab, with
        // a generous width cap (it's a wide mark, so a tight cap would squash its
        // height and make it look smaller than the others again).
        let aspect = source.size.height > 0 ? source.size.width / source.size.height : 1
        let maxWidth: CGFloat = 52
        var size = CGSize(width: 24 * aspect, height: 24)
        if size.width > maxWidth { size = CGSize(width: maxWidth, height: maxWidth / max(aspect, 0.01)) }

        let resized = UIGraphicsImageRenderer(size: size).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.withRenderingMode(.alwaysTemplate)
    }()
}

private extension UIImage {
    /// Crops fully-transparent margins, so a glyph drawn small inside a large
    /// canvas becomes a tight image that the tab bar can scale up to fill.
    func nk_trimmingTransparentEdges() -> UIImage? {
        guard let cg = cgImage else { return nil }
        let width = cg.width, height = cg.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width where pixels[row + x * 4 + 3] > 10 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: scale, orientation: .up)
    }
}
