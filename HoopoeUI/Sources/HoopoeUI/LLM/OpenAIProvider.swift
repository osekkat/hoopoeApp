import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// LLM provider for OpenAI's Chat Completions API.
///
/// Uses URLSession with SSE streaming. API key is injected at construction;
/// in production this comes from KeychainService via ProviderRegistry.
public struct OpenAIProvider: LLMProvider, Sendable {
    public let id = "openai"
    public let displayName = "OpenAI"

    private let apiKey: String
    private let baseURL: URL

    public var isConfigured: Bool { !apiKey.isEmpty }

    public var availableModels: [LLMModel] {
        [
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
                inputCostPer1kTokens: 0.002,
                outputCostPer1kTokens: 0.008
            ),
            LLMModel(
                id: "o4-mini",
                displayName: "o4-mini",
                contextWindow: 200_000,
                inputCostPer1kTokens: 0.0011,
                outputCostPer1kTokens: 0.0044
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
                        try await streamResponse(
                            request: request,
                            model: model,
                            startTime: startTime,
                            continuation: continuation
                        )
                    } else {
                        try await nonStreamResponse(
                            request: request,
                            model: model,
                            startTime: startTime,
                            continuation: continuation
                        )
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
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: Any]] = []
        if let system, !system.isEmpty {
            messages.append([
                "role": "system",
                "content": system,
            ])
        }
        messages.append([
            "role": "user",
            "content": prompt,
        ])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream,
        ]

        if stream {
            body["stream_options"] = ["include_usage": true]
        }

        if isReasoningModel(model) {
            body["reasoning_effort"] = "medium"
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
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]" else { continue }

            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }

            if let error = event["error"] as? [String: Any],
               let message = error["message"] as? String {
                continuation.yield(.error(.serverError(message: message)))
                continuation.finish()
                return
            }

            if let usage = event["usage"] as? [String: Any] {
                inputTokens = usage["prompt_tokens"] as? Int ?? inputTokens
                outputTokens = usage["completion_tokens"] as? Int ?? outputTokens
            }

            let choices = event["choices"] as? [[String: Any]] ?? []
            for choice in choices {
                if let delta = choice["delta"] as? [String: Any] {
                    if let text = delta["content"] as? String, !text.isEmpty {
                        accumulatedText += text
                        continuation.yield(.text(text))
                    } else if let contentParts = delta["content"] as? [[String: Any]] {
                        for part in contentParts {
                            guard let text = part["text"] as? String, !text.isEmpty else { continue }
                            accumulatedText += text
                            continuation.yield(.text(text))
                        }
                    }
                }
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

        try checkHTTPStatus(httpResponse, responseBody: data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.serverError(message: "Invalid JSON response")
        }

        let choices = json["choices"] as? [[String: Any]] ?? []
        let fullText = choices.compactMap { choice -> String? in
            guard let message = choice["message"] as? [String: Any] else { return nil }
            return message["content"] as? String
        }.joined()

        let usage = json["usage"] as? [String: Any] ?? [:]
        let inputTokens = usage["prompt_tokens"] as? Int ?? 0
        let outputTokens = usage["completion_tokens"] as? Int ?? 0
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

    private func checkHTTPStatus(_ response: HTTPURLResponse, responseBody: Data? = nil) throws {
        switch response.statusCode {
        case 200 ... 299:
            return
        case 401:
            throw LLMError.authenticationFailed
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "retry-after")
                .flatMap(TimeInterval.init)
            throw LLMError.rateLimited(retryAfter: retryAfter)
        case 400:
            if let responseBody,
               let bodyString = String(data: responseBody, encoding: .utf8),
               bodyString.localizedCaseInsensitiveContains("context") {
                throw LLMError.contextTooLong
            }
            fallthrough
        default:
            let message: String
            if let responseBody,
               let bodyString = String(data: responseBody, encoding: .utf8),
               !bodyString.isEmpty {
                message = bodyString
            } else {
                message = "HTTP \(response.statusCode)"
            }
            throw LLMError.serverError(message: message)
        }
    }

    private func estimateCost(model: String, usage: TokenUsage) -> Double {
        guard let modelInfo = availableModels.first(where: { $0.id == model }) else { return 0 }
        let inputCost = Double(usage.inputTokens) / 1000.0 * modelInfo.inputCostPer1kTokens
        let outputCost = Double(usage.outputTokens) / 1000.0 * modelInfo.outputCostPer1kTokens
        return inputCost + outputCost
    }

    private func isReasoningModel(_ model: String) -> Bool {
        model.hasPrefix("o")
    }

    private func mapError(_ error: Error) -> LLMError {
        if let llmError = error as? LLMError { return llmError }
        if error is CancellationError { return .networkError(message: "Request cancelled") }
        return .networkError(message: error.localizedDescription)
    }
}
