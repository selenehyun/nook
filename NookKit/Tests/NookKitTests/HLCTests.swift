import Foundation
import Testing
@testable import NookKit

@Suite("HybridLogicalClock")
struct HLCTests {
    @Test("next() is strictly greater than the previous clock")
    func nextIsStrictlyGreater() {
        let t0 = HLC.zero
        let t1 = HLC.next(after: t0, node: "A", now: Date(timeIntervalSince1970: 1000))
        #expect(t1 > t0)
    }

    @Test("Same wall-clock instant bumps the counter monotonically")
    func sameInstantBumpsCounter() {
        let now = Date(timeIntervalSince1970: 1000)
        let t1 = HLC.next(after: .zero, node: "A", now: now)
        let t2 = HLC.next(after: t1, node: "A", now: now)
        let t3 = HLC.next(after: t2, node: "A", now: now)
        #expect(t1 < t2)
        #expect(t2 < t3)
        #expect(t2.physicalMillis == t1.physicalMillis)
        #expect(t2.counter == t1.counter + 1)
    }

    @Test("A rewound wall clock never regresses the issued clock")
    func rewoundClockDoesNotRegress() {
        let later = HLC.next(after: .zero, node: "A", now: Date(timeIntervalSince1970: 2000))
        // Wall clock jumps backwards on the next issue.
        let next = HLC.next(after: later, node: "A", now: Date(timeIntervalSince1970: 1000))
        #expect(next > later)
        #expect(next.physicalMillis == later.physicalMillis)
        #expect(next.counter == later.counter + 1)
    }

    @Test("witnessed() absorbs a higher observed clock")
    func witnessedAbsorbsHigher() {
        let local = Fixture.hlc(1000, node: "A")
        let remote = Fixture.hlc(2000, node: "B")
        #expect(local.witnessed(remote) == remote)
        #expect(remote.witnessed(local) == remote)

        // After witnessing, the next local issue beats the observed remote.
        let advanced = local.witnessed(remote)
        let issued = HLC.next(after: advanced, node: "A", now: Date(timeIntervalSince1970: 1))
        #expect(issued > remote)
    }

    @Test("Ordering breaks ties by node id")
    func tieBreaksByNode() {
        let a = Fixture.hlc(1000, 5, node: "A")
        let b = Fixture.hlc(1000, 5, node: "B")
        #expect(a < b)
    }

    @Test("HLC round-trips through JSON")
    func codableRoundTrip() throws {
        let original = Fixture.hlc(1_720_000_000_000, 7, node: "device-1")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HLC.self, from: data)
        #expect(decoded == original)
    }
}
