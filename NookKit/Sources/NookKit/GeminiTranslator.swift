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

    public static var isConfigured: Bool { GeminiCredential.hasKey }

    /// Streams a translation. `onPartial` receives the cumulative text so callers
    /// replace (not append), matching the on-device streaming contract. Returns
    /// the final text. `@MainActor` so it can call a main-actor UI closure in order
    /// (the SSE loop only awaits — it never blocks the main thread).
    @MainActor
    public static func stream(system: String, prompt: String, onPartial: @escaping (String) -> Void) async throws -> String {
        let request = try makeRequest(path: "\(model):streamGenerateContent?alt=sse", system: system, prompt: prompt)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "No HTTP response") }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw Failure(message: "HTTP \(http.statusCode): \(String(body.prefix(300)))")
        }
        var full = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]", let data = payload.data(using: .utf8) else { continue }
            if let delta = extractText(data), !delta.isEmpty {
                full += delta
                onPartial(full)
            }
        }
        return full
    }

    /// One-shot (non-streaming) generation — for the short helper calls (language
    /// detection, glossary) where streaming buys nothing.
    public static func complete(system: String, prompt: String) async throws -> String {
        let request = try makeRequest(path: "\(model):generateContent", system: system, prompt: prompt)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "No HTTP response") }
        guard http.statusCode == 200 else {
            throw Failure(message: "HTTP \(http.statusCode): \(String(String(data: data, encoding: .utf8)?.prefix(300) ?? ""))")
        }
        return extractText(data) ?? ""
    }

    private static func makeRequest(path: String, system: String, prompt: String) throws -> URLRequest {
        guard let key = GeminiCredential.apiKey else { throw Failure(message: "Missing Gemini API key") }
        guard let url = URL(string: "\(endpoint)/\(path)") else { throw Failure(message: "Bad URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 60
        var payload: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            // temperature 0 → deterministic/faithful, matching the on-device greedy
            // choice (same input → same output).
            "generationConfig": ["temperature": 0, "candidateCount": 1],
        ]
        if !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["systemInstruction"] = ["parts": [["text": system]]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    /// Pulls the concatenated text out of one GenerateContentResponse chunk.
    private static func extractText(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = object["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }
}
