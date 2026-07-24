import Foundation

/// Minimal Google Gemini client for translation, over the network. Used when a
/// surface's `TranslationProvider` is `.gemini`. Streams with server-sent events
/// so callers get token-by-token output like the on-device path. The API key is
/// read from the Keychain per request and never persisted elsewhere.
public enum GeminiTranslator {
    public enum Model: String, Sendable, Codable {
        /// Fast, inexpensive default for ordinary article translation.
        case flashLite = "gemini-3.5-flash-lite"
        /// Stronger instruction following, used only when Lite produces an
        /// invalid translation. It has the same context/output limits as Lite.
        case flash = "gemini-3.6-flash"

        fileprivate var thinkingLevel: String {
            switch self {
            case .flashLite: "minimal"
            case .flash: "medium"
            }
        }
    }

    public struct Failure: Error {
        public enum Kind: Sendable {
            case missingCredential
            case blocked
            case incomplete
            case http
            case transport
        }

        public let kind: Kind
        public let message: String
        public let finishReason: String?

        init(_ kind: Kind, message: String, finishReason: String? = nil) {
            self.kind = kind
            self.message = message
            self.finishReason = finishReason
        }

        public var isLengthRelated: Bool {
            finishReason == "MAX_TOKENS" || finishReason == "LENGTH"
        }
    }

    public static let model = Model.flashLite.rawValue
    private static let endpoint = "https://generativelanguage.googleapis.com/v1beta/models"

    public static var isConfigured: Bool { GeminiCredential.hasKey }

    /// Streams a translation as cumulative snapshots (each element is the full text
    /// so far, so consumers replace rather than append). NOT `@MainActor`: the
    /// network receive, JSON parsing, and Keychain read all run off the main thread
    /// in a detached producer, so consuming it on the main actor only costs the
    /// quick per-snapshot UI update — the previous @MainActor version did all that
    /// parsing on main and stuttered scrolling. A blocked or non-STOP (truncated)
    /// response finishes the stream with a thrown error so the caller falls back.
    public static func stream(
        system: String,
        prompt: String,
        model: Model = .flashLite,
        timeout: TimeInterval = 60
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let bytes = try await openStream(
                        model: model, system: system, prompt: prompt, timeout: timeout
                    )
                    var full = ""
                    var finishReason: String?
                    var blockReason: String?
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, payload != "[DONE]", let data = payload.data(using: .utf8) else { continue }
                        let chunk = parse(data)
                        if let reason = chunk.blockReason { blockReason = reason }
                        if let reason = chunk.finishReason { finishReason = reason }
                        if let delta = chunk.text, !delta.isEmpty {
                            full += delta
                            continuation.yield(full)
                        }
                    }
                    if let blockReason {
                        throw Failure(.blocked, message: "blocked: \(blockReason)")
                    }
                    guard finishReason == "STOP" else {
                        throw Failure(
                            .incomplete,
                            message: "incomplete: \(finishReason ?? "no finishReason")",
                            finishReason: finishReason
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One-shot (non-streaming) generation — for the short helper calls (language
    /// detection, glossary) where streaming buys nothing.
    public static func complete(
        system: String,
        prompt: String,
        model: Model = .flashLite
    ) async throws -> String {
        let data = try await postForData(model: model, system: system, prompt: prompt)
        let result = parse(data)
        if let blockReason = result.blockReason {
            throw Failure(.blocked, message: "blocked: \(blockReason)")
        }
        guard result.finishReason == "STOP" else {
            throw Failure(
                .incomplete,
                message: "incomplete: \(result.finishReason ?? "no finishReason")",
                finishReason: result.finishReason
            )
        }
        return result.text ?? ""
    }

    // MARK: - Transport

    private static func openStream(
        model: Model,
        system: String,
        prompt: String,
        timeout: TimeInterval
    ) async throws -> URLSession.AsyncBytes {
        let request = try makeRequest(
            path: "\(model.rawValue):streamGenerateContent?alt=sse",
            system: system,
            prompt: prompt,
            model: model,
            timeout: timeout
        )
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw Failure(.transport, message: "No HTTP response")
            }
            guard http.statusCode == 200 else {
                var body = ""
                for try await line in bytes.lines { body += line }
                throw Failure(
                    .http,
                    message: "HTTP \(http.statusCode): \(String(body.prefix(300)))"
                )
            }
            return bytes
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(.transport, message: error.localizedDescription)
        }
    }

    private static func postForData(model: Model, system: String, prompt: String) async throws -> Data {
        let request = try makeRequest(
            path: "\(model.rawValue):generateContent",
            system: system,
            prompt: prompt,
            model: model,
            timeout: 60
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw Failure(.transport, message: "No HTTP response")
            }
            guard http.statusCode == 200 else {
                throw Failure(
                    .http,
                    message: "HTTP \(http.statusCode): \(String(String(data: data, encoding: .utf8)?.prefix(300) ?? ""))"
                )
            }
            return data
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(.transport, message: error.localizedDescription)
        }
    }

    private static func makeRequest(
        path: String,
        system: String,
        prompt: String,
        model: Model,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard let key = GeminiCredential.apiKey else {
            throw Failure(.missingCredential, message: "Missing Gemini API key")
        }
        guard let url = URL(string: "\(endpoint)/\(path)") else {
            throw Failure(.transport, message: "Bad URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = timeout
        // Gemini 3.x rejects the legacy candidateCount and is deprecating sampling
        // parameters. Translation determinism comes from the strict instructions.
        let generationConfig: [String: Any] = [
            "thinkingConfig": ["thinkingLevel": model.thinkingLevel],
        ]
        var payload: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": generationConfig,
        ]
        if !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["systemInstruction"] = ["parts": [["text": system]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    /// Pulls the text, finish reason, and any prompt block reason out of one
    /// GenerateContentResponse chunk.
    private static func parse(_ data: Data) -> (text: String?, finishReason: String?, blockReason: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }
        let blockReason = (object["promptFeedback"] as? [String: Any])?["blockReason"] as? String
        guard let candidate = (object["candidates"] as? [[String: Any]])?.first else {
            return (nil, nil, blockReason)
        }
        let finishReason = candidate["finishReason"] as? String
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        let text = parts?.compactMap { part -> String? in
            guard part["thought"] as? Bool != true else { return nil }
            return part["text"] as? String
        }.joined()
        return ((text?.isEmpty ?? true) ? nil : text, finishReason, blockReason)
    }
}
