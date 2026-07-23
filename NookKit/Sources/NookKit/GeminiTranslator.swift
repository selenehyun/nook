import Foundation

/// Minimal Google Gemini client for translation, over the network. Used when a
/// surface's `TranslationProvider` is `.gemini`. Streams with server-sent events
/// so callers get token-by-token output like the on-device path. The API key is
/// read from the Keychain per request and never persisted elsewhere.
public enum GeminiTranslator {
    public struct Failure: Error { public let message: String }

    /// The `-latest` alias tracks the newest GA Flash model automatically, so the
    /// app follows Google's current latest Flash without a code change.
    public static let model = "gemini-flash-latest"
    private static let endpoint = "https://generativelanguage.googleapis.com/v1beta/models"

    /// Whether the model accepts `thinkingConfig.thinkingBudget = 0` (disable
    /// "thinking"). We try to disable it — translation needs no reasoning and it
    /// adds seconds per request — but if a model rejects the field (400), we latch
    /// this off for the session and retry without it, so translation never breaks.
    nonisolated(unsafe) private static var thinkingDisableSupported = true

    public static var isConfigured: Bool { GeminiCredential.hasKey }

    /// Streams a translation. `onPartial` receives the cumulative text so callers
    /// replace (not append), matching the on-device streaming contract. Returns
    /// the final text. `@MainActor` so it can call a main-actor UI closure in order
    /// (the SSE loop only awaits — it never blocks the main thread).
    @MainActor
    public static func stream(system: String, prompt: String, onPartial: @escaping (String) -> Void) async throws -> String {
        let bytes = try await openStream(path: "\(model):streamGenerateContent?alt=sse", system: system, prompt: prompt)
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
                onPartial(full)
            }
        }
        // Reject a blocked, truncated, or abnormally-ended response so the caller
        // falls back instead of showing a partial translation as if complete.
        if let blockReason { throw Failure(message: "blocked: \(blockReason)") }
        guard finishReason == "STOP" else { throw Failure(message: "incomplete: \(finishReason ?? "no finishReason")") }
        return full
    }

    /// One-shot (non-streaming) generation — for the short helper calls (language
    /// detection, glossary) where streaming buys nothing.
    public static func complete(system: String, prompt: String) async throws -> String {
        let data = try await postForData(path: "\(model):generateContent", system: system, prompt: prompt)
        let result = parse(data)
        if let blockReason = result.blockReason { throw Failure(message: "blocked: \(blockReason)") }
        guard result.finishReason == "STOP" else { throw Failure(message: "incomplete: \(result.finishReason ?? "no finishReason")") }
        return result.text ?? ""
    }

    // MARK: - Transport (with thinking-config self-healing retry)

    /// Opens an SSE byte stream, validating the status. If the model rejects the
    /// thinking-disable field (400), latch it off and retry once without it.
    private static func openStream(path: String, system: String, prompt: String) async throws -> URLSession.AsyncBytes {
        for includeThinkingDisable in thinkingAttempts() {
            let request = try makeRequest(path: path, system: system, prompt: prompt, disableThinking: includeThinkingDisable)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure(message: "No HTTP response") }
            if http.statusCode == 200 { return bytes }
            if http.statusCode == 400, includeThinkingDisable {
                thinkingDisableSupported = false
                continue   // retry without the thinking-disable field
            }
            var body = ""
            for try await line in bytes.lines { body += line }
            throw Failure(message: "HTTP \(http.statusCode): \(String(body.prefix(300)))")
        }
        throw Failure(message: "Request failed")
    }

    private static func postForData(path: String, system: String, prompt: String) async throws -> Data {
        for includeThinkingDisable in thinkingAttempts() {
            let request = try makeRequest(path: path, system: system, prompt: prompt, disableThinking: includeThinkingDisable)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure(message: "No HTTP response") }
            if http.statusCode == 200 { return data }
            if http.statusCode == 400, includeThinkingDisable {
                thinkingDisableSupported = false
                continue
            }
            throw Failure(message: "HTTP \(http.statusCode): \(String(String(data: data, encoding: .utf8)?.prefix(300) ?? ""))")
        }
        throw Failure(message: "Request failed")
    }

    /// Attempt order: prefer disabling thinking; fall back to leaving it on. Once
    /// the model has rejected the field this session, only the "on" attempt runs.
    private static func thinkingAttempts() -> [Bool] {
        thinkingDisableSupported ? [true, false] : [false]
    }

    private static func makeRequest(path: String, system: String, prompt: String, disableThinking: Bool) throws -> URLRequest {
        guard let key = GeminiCredential.apiKey else { throw Failure(message: "Missing Gemini API key") }
        guard let url = URL(string: "\(endpoint)/\(path)") else { throw Failure(message: "Bad URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 60
        // temperature 0 → deterministic/faithful, matching the on-device greedy
        // choice (same input → same output).
        var generationConfig: [String: Any] = ["temperature": 0, "candidateCount": 1]
        if disableThinking {
            // thinkingBudget 0 disables Flash "thinking": translation needs no
            // reasoning, and thinking adds seconds of latency to every request.
            generationConfig["thinkingConfig"] = ["thinkingBudget": 0]
        }
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
        let text = parts?.compactMap { $0["text"] as? String }.joined()
        return ((text?.isEmpty ?? true) ? nil : text, finishReason, blockReason)
    }
}
