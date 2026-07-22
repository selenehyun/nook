import CoreGraphics
import Foundation

// Prints the CGWindowID of Nook's largest on-screen, normal-layer window, so
// `screencapture -l<id>` can grab just that window (with its drop shadow).
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
var best: (id: Int, area: CGFloat)?
for w in list {
    guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "Nook" else { continue }
    guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
    guard let num = w[kCGWindowNumber as String] as? Int else { continue }
    guard let b = w[kCGWindowBounds as String] as? [String: Any],
          let width = b["Width"] as? CGFloat, let height = b["Height"] as? CGFloat else { continue }
    let area = width * height
    if best == nil || area > best!.area { best = (num, area) }
}
if let best { print(best.id) }
