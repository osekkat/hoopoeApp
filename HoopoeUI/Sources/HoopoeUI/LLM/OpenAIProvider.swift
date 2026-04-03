import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// LLM provider for OpenAI's Chat Completions API.
///
/// Supports GPT-4o, GPT-4.1, and o-series models via SSE streaming.
public struct OpenAIProvider: LLMProvider, Sendable {
    public let id = "openai"
    public let displayName = "GPT"

    private let apiKey: String
    private let baseURL: URL

    public var isConfigured: Bool { !apiKey.isEmpty }

    public var availableModels: [LLMModel] {
        [
            LLMModel(
                id: "gpt-4.1",
                displayName: "GPT-4.1",
                contextWindow: 1_000_000,
                inputCostPer1kTokens: 0.002,
                outputCostPer1kTokens: 0.008
            ),
            LLMModel(
                id: "gpt-4o",
                displayName: "GPT-4o",
                contextWindow: 128_000,
                inputCostPer1kTokens: 0.0025,
                outputCostPer1kTokens: 0.01
            ),
            LLMModel(
                id: "o3",
                displayName: "o3",
                contextWindow: 200_000,
                inputCostPer1kTokens: 0.01,
                outputCostPer1kTokens: 0.04
            ),
        ]
    }

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.openai.com")!
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
                    let request = makeRequest(prompt: prompt, model: model, system: system, stream: stream)

                    if stream {
                        try await streamResponse(request: request, model: model, startTime: startTime, continuation: continuation)
                    } else {
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

    // MARK: - Request

    private func makeRequest(prompt: String, model: String, system: String?, stream: Bool) -> URLRequest {
        let url = baseURL.appendingPathComponent("/v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: String]] = []
        if let system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream,
        ]

        if stream {
            body["stream_options"] = ["include_usage": true]
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
            guard json != "[DONE]",
                  let data = json.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // Usage in final chunk
            if let usage = chunk["usage"] as? [String: Any] {
                inputTokens = usage["prompt_tokens"] as? Int ?? inputTokens
                outputTokens = usage["completion_tokens"] as? Int ?? outputTokens
            }

            // Delta content
            if let choices = chunk["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let content = delta["content"] as? String {
                accumulatedText += content
                continuation.yield(.text(content))
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

        let choices = json["choices"] as? [[String: Any]] ?? []
        let fullText = choices.first
            .flatMap { $0["message"] as? [String: Any] }
            .flatMap { $0["content"] as? String } ?? ""

        let usage = json["usage"] as? [String: Any] ?? [:]
        let tokenUsage = TokenUsage(
            inputTokens: usage["prompt_tokens"] as? Int ?? 0,
            outputTokens: usage["completion_tokens"] as? Int ?? 0
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
        case 401: throw LLMError.authenticationFailed
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
