import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// LLM provider for Google's Gemini API (generateContent endpoint).
///
/// Uses the REST API with SSE streaming via `alt=sse`.
public struct GeminiProvider: LLMProvider, Sendable {
    public let id = "google"
    public let displayName = "Gemini"

    private let apiKey: String
    private let baseURL: URL

    public var isConfigured: Bool { !apiKey.isEmpty }

    public var availableModels: [LLMModel] {
        [
            LLMModel(
                id: "gemini-2.5-pro",
                displayName: "Gemini 2.5 Pro",
                contextWindow: 1_000_000,
                inputCostPer1kTokens: 0.00125,
                outputCostPer1kTokens: 0.01
            ),
            LLMModel(
                id: "gemini-2.5-flash",
                displayName: "Gemini 2.5 Flash",
                contextWindow: 1_000_000,
                inputCostPer1kTokens: 0.00015,
                outputCostPer1kTokens: 0.0006
            ),
        ]
    }

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
    }

    public func send(
        prompt: String,
        model: String,
        system: String?,
        stream: Bool
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let startTime = Date()

                    if stream {
                        let request = makeStreamRequest(prompt: prompt, model: model, system: system)
                        try await streamResponse(request: request, model: model, startTime: startTime, continuation: continuation)
                    } else {
                        let request = makeRequest(prompt: prompt, model: model, system: system)
                        try await nonStreamResponse(request: request, model: model, startTime: startTime, continuation: continuation)
                    }
                } catch {
                    continuation.yield(.error(mapError(error)))
                    continuation.finish()
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Request Construction

    private func makeRequest(prompt: String, model: String, system: String?) -> URLRequest {
        let url = baseURL.appendingPathComponent("v1beta/models/\(model):generateContent")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ]
        ]

        if let system, !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func makeStreamRequest(prompt: String, model: String, system: String?) -> URLRequest {
        let url = baseURL.appendingPathComponent("v1beta/models/\(model):streamGenerateContent")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "alt", value: "sse"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "contents": [
                ["parts": [["text": prompt]]]
            ]
        ]

        if let system, !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Streaming

    private func streamResponse(
        request: URLRequest,
        model: String,
        startTime: Date,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError(message: "Invalid response")
        }
        try checkHTTPStatus(http)

        var accumulatedText = ""
        var inputTokens = 0
        var outputTokens = 0

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let json = String(line.dropFirst(6))

            guard let data = json.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // Extract text from candidates
            if let candidates = chunk["candidates"] as? [[String: Any]],
               let content = candidates.first?["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String {
                        accumulatedText += text
                        continuation.yield(.text(text))
                    }
                }
            }

            // Usage metadata
            if let metadata = chunk["usageMetadata"] as? [String: Any] {
                inputTokens = metadata["promptTokenCount"] as? Int ?? inputTokens
                outputTokens = metadata["candidatesTokenCount"] as? Int ?? outputTokens
            }
        }

        let latency = Date().timeIntervalSince(startTime)
        let tokenUsage = TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
        continuation.yield(.done(LLMResponse(
            fullText: accumulatedText,
            model: model,
            tokenUsage: tokenUsage,
            costEstimate: estimateCost(model: model, usage: tokenUsage),
            latency: latency
        )))
        continuation.finish()
    }

    // MARK: - Non-Streaming

    private func nonStreamResponse(
        request: URLRequest,
        model: String,
        startTime: Date,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError(message: "Invalid response")
        }
        try checkHTTPStatus(http)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.serverError(message: "Invalid JSON response")
        }

        let candidates = json["candidates"] as? [[String: Any]] ?? []
        let fullText = candidates.first
            .flatMap { $0["content"] as? [String: Any] }
            .flatMap { $0["parts"] as? [[String: Any]] }?
            .compactMap { $0["text"] as? String }
            .joined() ?? ""

        let metadata = json["usageMetadata"] as? [String: Any] ?? [:]
        let tokenUsage = TokenUsage(
            inputTokens: metadata["promptTokenCount"] as? Int ?? 0,
            outputTokens: metadata["candidatesTokenCount"] as? Int ?? 0
        )
        let latency = Date().timeIntervalSince(startTime)

        continuation.yield(.done(LLMResponse(
            fullText: fullText,
            model: model,
            tokenUsage: tokenUsage,
            costEstimate: estimateCost(model: model, usage: tokenUsage),
            latency: latency
        )))
        continuation.finish()
    }

    // MARK: - Helpers

    private func checkHTTPStatus(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200...299: return
        case 401, 403: throw LLMError.authenticationFailed
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            throw LLMError.rateLimited(retryAfter: retryAfter)
        default:
            throw LLMError.serverError(message: "HTTP \(response.statusCode)")
        }
    }

    private func estimateCost(model: String, usage: TokenUsage) -> Double {
        guard let info = availableModels.first(where: { $0.id == model }) else { return 0 }
        return Double(usage.inputTokens) / 1000 * info.inputCostPer1kTokens
             + Double(usage.outputTokens) / 1000 * info.outputCostPer1kTokens
    }

    private func mapError(_ error: Error) -> LLMError {
        if let e = error as? LLMError { return e }
        return .networkError(message: error.localizedDescription)
    }
}
