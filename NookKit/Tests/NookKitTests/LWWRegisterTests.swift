import Foundation
import Testing
@testable import NookKit

@Suite("LWWRegister")
struct LWWRegisterTests {
    private func reg(_ value: Bool, _ millis: Int64, node: String = "n") -> LWWRegister<Bool> {
        LWWRegister(value: value, hlc: Fixture.hlc(millis, node: node))
    }

    @Test("Merge picks the later-clocked value")
    func mergePicksLater() {
        let earlier = reg(true, 1000)
        let later = reg(false, 2000)
        #expect(earlier.merged(with: later).value == false)
        #expect(later.merged(with: earlier).value == false)
    }

    @Test("Merge is commutative")
    func commutative() {
        let a = reg(true, 1000, node: "A")
        let b = reg(false, 3000, node: "B")
        #expect(a.merged(with: b) == b.merged(with: a))
    }

    @Test("Merge is idempotent")
    func idempotent() {
        let a = reg(true, 1000)
        #expect(a.merged(with: a) == a)
    }

    @Test("Merge is associative")
    func associative() {
        let a = reg(true, 1000, node: "A")
        let b = reg(false, 2000, node: "B")
        let c = reg(true, 3000, node: "C")
        let left = a.merged(with: b).merged(with: c)
        let right = a.merged(with: b.merged(with: c))
        #expect(left == right)
    }

    @Test("mergeRegisters keeps the present side when one is nil")
    func mergeOptionalPrefersPresent() {
        let present = reg(true, 1000)
        #expect(mergeRegisters(present, nil) == present)
        #expect(mergeRegisters(nil, present) == present)
        #expect(mergeRegisters(Optional<LWWRegister<Bool>>.none, nil) == nil)
    }
}
