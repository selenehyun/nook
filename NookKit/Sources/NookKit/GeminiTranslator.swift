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

    /// How to keep "thinking" (which adds seconds of first-token latency and is not
    /// needed for translation) to a minimum. The correct field differs by model
    /// generation — Gemini 3.x uses `thinkingLevel`, 2.5 uses `thinkingBudget` — so
    /// we try them in order and latch onto whichever the model accepts, retrying on
    /// a 400 so translation never breaks regardless of which model the alias maps to.
    private static let thinkingStrategyCount = 3
    nonisolated(unsafe) private static var thinkingStrategyIndex = 0

    /// The `thinkingConfig` for a strategy: 0 = Gemini 3.x `thinkingLevel: low`,
    /// 1 = Gemini 2.5 `thinkingBudget: 0`, else the model default (no field).
    private static func thinkingConfig(forStrategy index: Int) -> [String: Any]? {
        switch index {
        case 0: return ["thinkingLevel": "low"]
        case 1: return ["thinkingBudget": 0]
        default: return nil
        }
    }

    public static var isConfigured: Bool { GeminiCredential.hasKey }

    /// Streams a translation as cumulative snapshots (each element is the full text
    /// so far, so consumers replace rather than append). NOT `@MainActor`: the
    /// network receive, JSON parsing, and Keychain read all run off the main thread
    /// in a detached producer, so consuming it on the main actor only costs the
    /// quick per-snapshot UI update — the previous @MainActor version did all that
    /// parsing on main and stuttered scrolling. A blocked or non-STOP (truncated)
    /// response finishes the stream with a thrown error so the caller falls back.
    public static func stream(system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
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
                            continuation.yield(full)
                        }
                    }
                    if let blockReason { throw Failure(message: "blocked: \(blockReason)") }
                    guard finishReason == "STOP" else { throw Failure(message: "incomplete: \(finishReason ?? "no finishReason")") }
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
    public static func complete(system: String, prompt: String) async throws -> String {
        let data = try await postForData(path: "\(model):generateContent", system: system, prompt: prompt)
        let result = parse(data)
        if let blockReason = result.blockReason { throw Failure(message: "blocked: \(blockReason)") }
        guard result.finishReason == "STOP" else { throw Failure(message: "incomplete: \(result.finishReason ?? "no finishReason")") }
        return result.text ?? ""
    }

    // MARK: - Transport (with thinking-config self-healing retry)

    /// Opens an SSE byte stream, validating the status. On a 400 (e.g. the model
    /// doesn't accept the current thinking field) it advances to the next thinking
    /// strategy and retries, latching onto whichever the model accepts.
    private static func openStream(path: String, system: String, prompt: String) async throws -> URLSession.AsyncBytes {
        for index in thinkingStrategyIndex..<thinkingStrategyCount {
            let request = try makeRequest(path: path, system: system, prompt: prompt, thinkingConfig: thinkingConfig(forStrategy: index))
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure(message: "No HTTP response") }
            if http.statusCode == 200 { thinkingStrategyIndex = index; return bytes }
            if http.statusCode == 400 { thinkingStrategyIndex = index + 1; continue }
            var body = ""
            for try await line in bytes.lines { body += line }
            throw Failure(message: "HTTP \(http.statusCode): \(String(body.prefix(300)))")
        }
        throw Failure(message: "Request failed")
    }

    private static func postForData(path: String, system: String, prompt: String) async throws -> Data {
        for index in thinkingStrategyIndex..<thinkingStrategyCount {
            let request = try makeRequest(path: path, system: system, prompt: prompt, thinkingConfig: thinkingConfig(forStrategy: index))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure(message: "No HTTP response") }
            if http.statusCode == 200 { thinkingStrategyIndex = index; return data }
            if http.statusCode == 400 { thinkingStrategyIndex = index + 1; continue }
            throw Failure(message: "HTTP \(http.statusCode): \(String(String(data: data, encoding: .utf8)?.prefix(300) ?? ""))")
        }
        throw Failure(message: "Request failed")
    }

    private static func makeRequest(path: String, system: String, prompt: String, thinkingConfig: [String: Any]?) throws -> URLRequest {
        guard let key = GeminiCredential.apiKey else { throw Failure(message: "Missing Gemini API key") }
        guard let url = URL(string: "\(endpoint)/\(path)") else { throw Failure(message: "Bad URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 60
        // temperature 0 → deterministic/faithful, matching the on-device greedy choice.
        var generationConfig: [String: Any] = ["temperature": 0, "candidateCount": 1]
        if let thinkingConfig { generationConfig["thinkingConfig"] = thinkingConfig }
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
