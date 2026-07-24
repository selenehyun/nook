import CoreGraphics
import Testing
@testable import NookKit

@Suite("Reader swipe navigation")
struct ReaderSwipeNavigationTests {
    @Test("Bottom affordance uses hysteresis around its reveal boundary")
    func bottomPullEngagementHysteresis() {
        var engaged = false

        engaged = ReaderPullEngagementPolicy.isEngaged(currentlyEngaged: engaged, bottomPull: 23.9)
        #expect(!engaged)

        engaged = ReaderPullEngagementPolicy.isEngaged(currentlyEngaged: engaged, bottomPull: 24)
        #expect(engaged)

        engaged = ReaderPullEngagementPolicy.isEngaged(currentlyEngaged: engaged, bottomPull: 12)
        #expect(engaged)

        engaged = ReaderPullEngagementPolicy.isEngaged(currentlyEngaged: engaged, bottomPull: 8)
        #expect(!engaged)
    }

    @Test("A released pull always disengages")
    func releasedPullDisengages() {
        #expect(!ReaderPullEngagementPolicy.isEngaged(currentlyEngaged: true, bottomPull: 0))
    }
}
