import Testing
@testable import NookKit

@Suite("List row height invalidation")
struct ExpandRevealInvalidationTests {
    @Test("A newly inserted row invalidates for every distinct reveal frame")
    func revealFramesInvalidateAfterInitialLayout() {
        var tracker = ListRowHeightInvalidationTracker()

        let initialLayout = tracker.consume(progress: 0, layoutRevision: 0)
        let firstRevealFrame = tracker.consume(progress: 0.25, layoutRevision: 0)
        let duplicateRevealFrame = tracker.consume(progress: 0.25, layoutRevision: 0)
        let finalRevealFrame = tracker.consume(progress: 1, layoutRevision: 0)

        #expect(!initialLayout)
        #expect(firstRevealFrame)
        #expect(!duplicateRevealFrame)
        #expect(finalRevealFrame)
    }

    @Test("Streaming line growth and category changes invalidate at full reveal")
    func surroundingContentChangesInvalidate() {
        var tracker = ListRowHeightInvalidationTracker()

        let initialLayout = tracker.consume(progress: 1, layoutRevision: 10)
        let streamedLineGrowth = tracker.consume(progress: 1, layoutRevision: 11)
        let duplicateRevision = tracker.consume(progress: 1, layoutRevision: 11)
        let categoryChange = tracker.consume(progress: 1, layoutRevision: 12)

        #expect(!initialLayout)
        #expect(streamedLineGrowth)
        #expect(!duplicateRevision)
        #expect(categoryChange)
    }
}
