import SwiftUI

/// The launch animation: the app icon's twig layers drop in from above, one by
/// one under gravity, and settle into the nest — matching the twigs' real
/// geometry from AppIcon.icon (each a rotated rounded rectangle on the 1024pt
/// canvas). Rendered natively so it can animate; the launch screen stays static.
struct NestAssemblyView: View {
    /// On-screen size of the 1024pt icon canvas.
    var size: CGFloat = 150
    /// Flip to true to drop the twigs in.
    var assembled: Bool

    private struct Twig: Identifiable {
        let id: Int
        let x, y, w, h, rx, rotation, tx, ty: CGFloat
        let color: Color
    }

    // Twig geometry (AppIcon.icon SVG layers) + per-layer fill/translation
    // (icon.json), on the 1024pt canvas. Ordered back-to-front so the ZStack
    // and the drop stagger build the nest up naturally.
    private static let twigs: [Twig] = [
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
    private static let centerDX: CGFloat = 512 - 512.5
    private static let centerDY: CGFloat = 512 - 573.88

    var body: some View {
        let k = size / 1024
        ZStack(alignment: .topLeading) {
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
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    /// Roughly how long the full drop-and-settle takes.
    static var duration: Double { Double(twigs.count) * 0.09 + 0.6 }
}
