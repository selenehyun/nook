import Foundation

/// A Last-Writer-Wins register: a single value stamped with the `HLC` at which
/// it was written. Merging two registers is a pure, commutative, associative,
/// idempotent pick of the one with the greater clock — the CRDT primitive that
/// lets Nook merge concurrent edits from any number of devices in any order and
/// always converge to the same result.
public struct LWWRegister<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var value: Value
    public var hlc: HLC

    enum CodingKeys: String, CodingKey {
        case value = "v"
        case hlc = "t"
    }

    public init(value: Value, hlc: HLC) {
        self.value = value
        self.hlc = hlc
    }

    /// Returns whichever register was written later. Ties resolve by the HLC's
    /// device tie-breaker, so the merge is deterministic regardless of argument
    /// order.
    public func merged(with other: LWWRegister<Value>) -> LWWRegister<Value> {
        other.hlc > hlc ? other : self
    }
}

/// Merges two optional registers of the same field. A missing register means
/// "this device never wrote this field", so the present one always wins; when
/// both are present the later-clocked value wins.
func mergeRegisters<Value>(
    _ lhs: LWWRegister<Value>?,
    _ rhs: LWWRegister<Value>?
) -> LWWRegister<Value>? {
    switch (lhs, rhs) {
    case (nil, nil): nil
    case (let value?, nil): value
    case (nil, let value?): value
    case (let a?, let b?): a.merged(with: b)
    }
}
