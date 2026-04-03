import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// LLM provider for Anthropic's Claude API (Messages endpoint).
///
/// Uses URLSession with SSE streaming. API key is injected at construction;
/// in production this comes from KeychainService via ProviderRegistry.
public struct ClaudeProvider: LLMProvider, Sendable {
    public let id = "anthropic"
    public let displayName = "Claude"

    private let apiKey: String
    private let baseURL: URL
    private let apiVersion: String

    public var isConfigured: Bool { !apiKey.isEmpty }

    public var availableModels: [LLMModel] {
        [
            LLMModel(
                id: "claude-opus-4-6",
                displayName: "Claude Opus 4.6",
                contextWindow: 200_000,
                inputCostPer1kTokens: 0.015,
                outputCostPer1kTokens: 0.075
            ),
            LLMModel(
                id: "claude-sonnet-4-6",
                displayName: "Claude Sonnet 4.6",
                contextWindow: 200_000,
                inputCostPer1kTokens: 0.003,
                outputCostPer1kTokens: 0.015
            ),
            LLMModel(
                id: "claude-haiku-4-5-20251001",
                displayName: "Claude Haiku 4.5",
                contextWindow: 200_000,
                inputCostPer1kTokens: 0.0008,
                outputCostPer1kTokens: 0.004
            ),
        ]
    }

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        apiVersion: String = "2023-06-01"
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.apiVersion = apiVersion
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

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Request Construction

    private func makeRequest(prompt: String, model: String, system: String?, stream: Bool) -> URLRequest {
        let url = baseURL.appendingPathComponent("v1/messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "stream": stream,
        ]

        if let system, !system.isEmpty {
            body["system"] = system
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Streaming Response

    private func streamResponse(
        request: URLRequest,
        model: String,
        startTime: Date,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.networkError(message: "Invalid response")
        }

        try checkHTTPStatus(httpResponse)

        var accumulatedText = ""
        var inputTokens = 0
        var outputTokens = 0

        for try await line in bytes.lines {
            try Task.checkCancellation()

            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))

            guard jsonString != "[DONE]",
                  let data = jsonString.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }

            switch type {
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                   let text = delta["text"] as? String {
                    accumulatedText += text
                    continuation.yield(.text(text))
                }

            case "message_delta":
                if let usage = event["usage"] as? [String: Any] {
                    outputTokens = usage["output_tokens"] as? Int ?? outputTokens
                }

            case "message_start":
                if let message = event["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    inputTokens = usage["input_tokens"] as? Int ?? 0
                }

            case "message_stop":
                let latency = Date().timeIntervalSince(startTime)
                let tokenUsage = TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
                let costEstimate = estimateCost(model: model, usage: tokenUsage)
                continuation.yield(.done(LLMResponse(
                    fullText: accumulatedText,
                    model: model,
                    tokenUsage: tokenUsage,
                    costEstimate: costEstimate,
                    latency: latency
                )))
                continuation.finish()
                return

            case "error":
                if let error = event["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    continuation.yield(.error(.serverError(message: message)))
                    continuation.finish()
                    return
                }

            default:
                break
            }
        }

        // Stream ended without message_stop
        if !accumulatedText.isEmpty {
            let latency = Date().timeIntervalSince(startTime)
            let tokenUsage = TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
            continuation.yield(.done(LLMResponse(
                fullText: accumulatedText,
                model: model,
                tokenUsage: tokenUsage,
                costEstimate: estimateCost(model: model, usage: tokenUsage),
                latency: latency
            )))
        }
        continuation.finish()
    }

    // MARK: - Non-Streaming Response

    private func nonStreamResponse(
        request: URLRequest,
        model: String,
        startTime: Date,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.networkError(message: "Invalid response")
        }

        try checkHTTPStatus(httpResponse)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.serverError(message: "Invalid JSON response")
        }

        let content = json["content"] as? [[String: Any]] ?? []
        let fullText = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()

        let usage = json["usage"] as? [String: Any] ?? [:]
        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0
        let tokenUsage = TokenUsage(inputTokens: inputTokens, outputTokens: outputTokens)
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
        case 200...299:
            return
        case 401:
            throw LLMError.authenticationFailed
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "retry-after")
                .flatMap(TimeInterval.init)
            throw LLMError.rateLimited(retryAfter: retryAfter)
        default:
            throw LLMError.serverError(message: "HTTP \(response.statusCode)")
        }
    }

    private func estimateCost(model: String, usage: TokenUsage) -> Double {
        guard let modelInfo = availableModels.first(where: { $0.id == model }) else { return 0 }
        let inputCost = Double(usage.inputTokens) / 1000.0 * modelInfo.inputCostPer1kTokens
        let outputCost = Double(usage.outputTokens) / 1000.0 * modelInfo.outputCostPer1kTokens
        return inputCost + outputCost
    }

    private func mapError(_ error: Error) -> LLMError {
        if let llmError = error as? LLMError { return llmError }
        if error is CancellationError { return .networkError(message: "Request cancelled") }
        return .networkError(message: error.localizedDescription)
    }
}
