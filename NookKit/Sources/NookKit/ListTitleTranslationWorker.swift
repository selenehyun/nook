import Foundation

/// The non-UI half of list-title translation. A run owns provider streaming,
/// validation/fallback, reveal gating, and typewriter pacing. Its consumer only
/// receives bounded, immutable presentation events and can therefore do a tiny
/// state assignment on the main actor.
actor ListTitleTranslationWorker {
    struct Request: Sendable {
        let source: String
        let languageName: String
        let provider: TranslationProvider
    }

    enum Event: Equatable, Sendable {
        case partial(String, TranslationProvider)
        case completed(String, TranslationProvider)
        case failed
    }

    typealias Backend = @Sendable (
        _ request: Request,
        _ onPartial: @escaping @Sendable (String) async -> Void
    ) async throws -> String?

    static let shared = ListTitleTranslationWorker()

    private let backend: Backend

    init(backend: Backend? = nil) {
        self.backend = backend ?? Self.liveBackend
    }

    /// Starts a self-contained run. The detached producer is deliberate: callers
    /// are MainActor coordinators, but no provider, parsing, validation, or pacing
    /// work is allowed to inherit their executor.
    func events(
        for request: Request,
        revealDelay: Duration = .milliseconds(340),
        frameInterval: Duration = .milliseconds(33)
    ) -> AsyncStream<Event> {
        let backend = self.backend
        return AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            let producer = Task.detached(priority: .userInitiated) {
                let emitter = ListTitleProgressEmitter(
                    continuation: continuation,
                    provider: request.provider,
                    revealDelay: revealDelay,
                    frameInterval: frameInterval
                )
                do {
                    let final = try await backend(request) { partial in
                        await emitter.emit(partial)
                    }
                    try Task.checkCancellation()
                    guard let final else {
                        continuation.yield(.failed)
                        continuation.finish()
                        return
                    }
                    let cleaned = final.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else {
                        continuation.yield(.failed)
                        continuation.finish()
                        return
                    }
                    await emitter.emit(cleaned)
                    continuation.yield(.completed(cleaned, request.provider))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.failed)
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }

    private static func liveBackend(
        _ request: Request,
        _ onPartial: @escaping @Sendable (String) async -> Void
    ) async throws -> String? {
        let keepTerms = NaturalTranslator.heuristicKeepTokens(request.source)
        do {
            let result = try await NaturalTranslator.streamTranslateBlockOffMain(
                request.source,
                into: request.languageName,
                keepTerms: keepTerms,
                provider: request.provider,
                onPartial: onPartial
            )
            try Task.checkCancellation()
            let final = result.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !final.isEmpty, !isEcho(final, request.source) {
                return final
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
        }

        // The structured model occasionally echoes a short, proper-noun-heavy
        // title. The plain fallback is still executed here, never by the UI actor;
        // the emitter types its bulk result at the same bounded cadence.
        guard let plain = await NaturalTranslator.translatePlainFallback(
            request.source,
            into: request.languageName,
            keepTerms: keepTerms,
            provider: request.provider
        ) else {
            return nil
        }
        try Task.checkCancellation()
        let final = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        return final.isEmpty || isEcho(final, request.source) ? nil : final
    }

    private nonisolated static func isEcho(_ output: String, _ source: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
                .lowercased()
        }
        return normalized(output) == normalized(source)
    }
}

/// Serializes cumulative snapshots into small, frame-bounded prefixes. This
/// actor is the back-pressure boundary: a provider can generate as quickly as it
/// likes without turning every token into a SwiftUI update.
private actor ListTitleProgressEmitter {
    private let continuation: AsyncStream<ListTitleTranslationWorker.Event>.Continuation
    private let provider: TranslationProvider
    private let revealDelay: Duration
    private let frameInterval: Duration
    private let startedAt = ContinuousClock.now
    private var lastEmission: ContinuousClock.Instant?
    private var displayed = ""

    init(
        continuation: AsyncStream<ListTitleTranslationWorker.Event>.Continuation,
        provider: TranslationProvider,
        revealDelay: Duration,
        frameInterval: Duration
    ) {
        self.continuation = continuation
        self.provider = provider
        self.revealDelay = revealDelay
        self.frameInterval = frameInterval
    }

    func emit(_ raw: String) async {
        guard !Task.isCancelled else { return }
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target != displayed else { return }

        await waitForReveal()
        guard !Task.isCancelled else { return }

        // Normal cumulative streams extend the previous value. Reveal at most
        // four characters per frame so even a provider that returns one bulk
        // snapshot retains the intended typewriter motion.
        if target.hasPrefix(displayed) {
            let characters = Array(target)
            var shown = Array(displayed).count
            while shown < characters.count, !Task.isCancelled {
                shown = min(characters.count, shown + 4)
                await waitForFrame()
                displayed = String(characters.prefix(shown))
                continuation.yield(.partial(displayed, provider))
            }
        } else {
            // A provider correction can replace an earlier prefix. Apply it in
            // one frame rather than synthesizing misleading delete/retype motion.
            await waitForFrame()
            displayed = target
            continuation.yield(.partial(displayed, provider))
        }
    }

    private func waitForReveal() async {
        let elapsed = startedAt.duration(to: .now)
        if elapsed < revealDelay {
            try? await Task.sleep(for: revealDelay - elapsed)
        }
    }

    private func waitForFrame() async {
        if let lastEmission {
            let elapsed = lastEmission.duration(to: .now)
            if elapsed < frameInterval {
                try? await Task.sleep(for: frameInterval - elapsed)
            }
        }
        lastEmission = .now
    }
}
