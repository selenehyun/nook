import Foundation
import Testing
@testable import NookKit

@Suite("List title translation worker")
struct ListTitleTranslationWorkerTests {
    @Test("Provider work stays off the UI thread and text waits for reveal")
    func separatesWorkFromUIAndGatesTyping() async {
        let probe = WorkProbe()
        let worker = ListTitleTranslationWorker { _, onPartial in
            await probe.markStarted()
            // Deliberately occupy the translation executor. If this inherited
            // MainActor, the responsiveness assertion below would take ~120 ms.
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(120))
            while ContinuousClock.now < deadline {}
            await onPartial("번역된 제목입니다")
            return "번역된 제목입니다"
        }
        let request = ListTitleTranslationWorker.Request(
            source: "A translated title",
            languageName: "Korean",
            provider: .gemini
        )

        let clock = ContinuousClock()
        let started = clock.now
        let stream = await worker.events(
            for: request,
            revealDelay: .milliseconds(40),
            frameInterval: .milliseconds(5)
        )
        let collector = Task {
            var events: [ListTitleTranslationWorker.Event] = []
            var firstPartialElapsed: Duration?
            for await event in stream {
                if firstPartialElapsed == nil, case .partial = event {
                    firstPartialElapsed = started.duration(to: clock.now)
                }
                events.append(event)
            }
            return (events, firstPartialElapsed)
        }
        while !(await probe.started) {
            await Task.yield()
        }

        let mainCheckStarted = clock.now
        await MainActor.run {}
        let mainActorLatency = mainCheckStarted.duration(to: clock.now)
        let (events, firstPartialElapsed) = await collector.value

        #expect(mainActorLatency < .milliseconds(40))
        #expect(firstPartialElapsed ?? .zero >= .milliseconds(35))
        #expect(events.last == .completed("번역된 제목입니다", .gemini))
    }

    @Test("Bulk output is paced into bounded cumulative prefixes")
    func pacesBulkOutput() async {
        let final = "abcdefghijklmnop"
        let worker = ListTitleTranslationWorker { _, _ in final }
        let request = ListTitleTranslationWorker.Request(
            source: "source",
            languageName: "English",
            provider: .appleIntelligence
        )
        let stream = await worker.events(
            for: request,
            revealDelay: .zero,
            frameInterval: .milliseconds(4)
        )
        var partials: [String] = []
        var terminal: ListTitleTranslationWorker.Event?
        for await event in stream {
            switch event {
            case .partial(let text, _):
                partials.append(text)
            case .completed, .failed:
                terminal = event
            }
        }

        #expect(partials.count == 4)
        #expect(partials.map(\.count) == [4, 8, 12, 16])
        #expect(terminal == .completed(final, .appleIntelligence))
    }

    @Test("A failed backend terminates without leaving a translated result")
    func reportsFailure() async {
        let worker = ListTitleTranslationWorker { _, _ in nil }
        let request = ListTitleTranslationWorker.Request(
            source: "source",
            languageName: "Korean",
            provider: .gemini
        )
        let stream = await worker.events(
            for: request,
            revealDelay: .zero,
            frameInterval: .zero
        )
        var events: [ListTitleTranslationWorker.Event] = []
        for await event in stream {
            events.append(event)
        }
        #expect(events == [.failed])
    }
}

private actor WorkProbe {
    private(set) var started = false

    func markStarted() {
        started = true
    }
}
