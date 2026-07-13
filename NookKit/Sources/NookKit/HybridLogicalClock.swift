import Foundation

/// A Hybrid Logical Clock timestamp — the "commit id" that orders every change
/// in Nook's Git-like sync. It pairs a wall-clock reading with a logical
/// counter so events are globally, deterministically orderable even when device
/// clocks disagree or run backward.
///
/// Ordering is lexicographic over `(physicalMillis, counter, node)`. The `node`
/// (device id) is only a tie-breaker so two devices that stamp the exact same
/// physical time and counter still resolve to one deterministic winner.
public struct HLC: Comparable, Hashable, Codable, Sendable {
    /// Wall-clock component in milliseconds since the Unix epoch, clamped so it
    /// never moves backward relative to a previously issued clock.
    public var physicalMillis: Int64
    /// Monotonic counter that breaks ties when two events share the same
    /// `physicalMillis` (e.g. many mutations within one millisecond, or a
    /// stalled/rewound wall clock).
    public var counter: UInt32
    /// The device that issued this clock. Pure tie-breaker for ordering.
    public var node: String

    enum CodingKeys: String, CodingKey {
        case physicalMillis = "p"
        case counter = "c"
        case node = "id"
    }

    public init(physicalMillis: Int64, counter: UInt32, node: String) {
        self.physicalMillis = physicalMillis
        self.counter = counter
        self.node = node
    }

    /// The lowest possible clock — a sensible "nothing recorded yet" seed.
    public static let zero = HLC(physicalMillis: 0, counter: 0, node: "")

    public static func < (lhs: HLC, rhs: HLC) -> Bool {
        if lhs.physicalMillis != rhs.physicalMillis {
            return lhs.physicalMillis < rhs.physicalMillis
        }
        if lhs.counter != rhs.counter {
            return lhs.counter < rhs.counter
        }
        return lhs.node < rhs.node
    }
}

extension HLC {
    private static func millis(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Issues a new clock for a local write on `node`, guaranteed strictly
    /// greater than `previous`. Uses the wall clock when it has advanced, but
    /// never regresses: a skewed or rewound clock just bumps the counter
    /// instead, so issued clocks stay strictly monotonic.
    ///
    /// Before issuing a write, the caller should first fold in every clock it
    /// has observed (see `witnessed(_:)`) so its stamp also beats another
    /// device's most recent edit to the same field.
    public static func next(after previous: HLC, node: String, now: Date = Date()) -> HLC {
        let wall = millis(from: now)
        let physical = max(wall, previous.physicalMillis)
        let counter: UInt32 = physical == previous.physicalMillis ? previous.counter &+ 1 : 0
        return HLC(physicalMillis: physical, counter: counter, node: node)
    }

    /// Advances a local clock to account for a clock observed from another
    /// device, so the next issued clock will exceed it. This is the "receive"
    /// half of an HLC: the local clock absorbs the maximum of what it has seen.
    public func witnessed(_ observed: HLC) -> HLC {
        observed > self ? observed : self
    }
}
