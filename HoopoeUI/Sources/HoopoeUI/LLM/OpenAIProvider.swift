import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

typealias OpenAISleepHandler = @Sendable (TimeInterval) async throws -> Void

protocol OpenAIHTTPSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func stream(for request: URLRequest) async throws -> OpenAIHTTPStreamResponse
}

struct OpenAIHTTPStreamResponse: Sendable {
    let response: URLResponse
    let errorBody: Data?
    let lines: AsyncThrowingStream<String, Error>
}

extension URLSession: OpenAIHTTPSession {
    func stream(for request: URLRequest) async throws -> OpenAIHTTPStreamResponse {
        let (bytes, response) = try await bytes(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200 ... 299).contains(httpResponse.statusCode) {
            var errorBody = Data()
            for try await byte in bytes {
                errorBody.append(byte)
            }

            return OpenAIHTTPStreamResponse(
                response: response,
                errorBody: errorBody,
                lines: AsyncThrowingStream { continuation in
                    continuation.finish()
                }
            )
        }

        return OpenAIHTTPStreamResponse(
            response: response,
            errorBody: nil,
            lines: AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await line in bytes.lines {
                            continuation.yield(line)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }

                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                }
            }
        )
    }
}

/// LLM provider for OpenAI's Chat Completions API.
///
/// Uses URLSession with SSE streaming. API key is injected at construction;
/// in production this comes from KeychainService via ProviderRegistry.
public struct OpenAIProvider: LLMProvider, Sendable {
    public let id = "openai"
    public let displayName = "OpenAI"

    private let apiKey: String
    private let baseURL: URL
    private let session: any OpenAIHTTPSession
    private let sleepHandler: OpenAISleepHandler

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
        self.init(
            apiKey: apiKey,
            baseURL: baseURL,
            session: URLSession.shared,
            sleepHandler: Self.defaultSleep
        )
    }

    init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.openai.com")!,
        session: any OpenAIHTTPSession,
        sleepHandler: @escaping OpenAISleepHandler = Self.defaultSleep
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.sleepHandler = sleepHandler
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
                    try await executeWithRetry(
                        prompt: prompt,
                        model: model,
                        system: system,
                        stream: stream,
                        continuation: continuation
                    )
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

    private func executeWithRetry(
        prompt: String,
        model: String,
        system: String?,
        stream: Bool,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        let maxAttempts = 3
        var attempt = 0
        let startTime = Date()

        while true {
            let request = makeRequest(prompt: prompt, model: model, system: system, stream: stream)

            do {
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
                return
            } catch let error as LLMError {
                guard case let .rateLimited(retryAfter) = error, attempt < maxAttempts - 1 else {
                    throw error
                }

                attempt += 1
                try await sleepForRetry(seconds: retryDelaySeconds(retryAfter: retryAfter, attempt: attempt))
            } catch {
                throw error
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
        let streamResponse = try await session.stream(for: request)
        let response = streamResponse.response

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.networkError(message: "Invalid response")
        }

        if !(200 ... 299).contains(httpResponse.statusCode) {
            try checkHTTPStatus(httpResponse, responseBody: streamResponse.errorBody)
        }

        var accumulatedText = ""
        var inputTokens = 0
        var outputTokens = 0

        for try await line in streamResponse.lines {
            try Task.checkCancellation()

            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard payload != "[DONE]" else { break }

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
                    for text in textSegments(from: delta["content"]) {
                        accumulatedText += text
                        continuation.yield(.text(text))
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
        let (data, response) = try await session.data(for: request)

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
            return textSegments(from: message["content"]).joined()
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
            if let bodyString = errorResponseMessage(from: responseBody),
               bodyString.localizedCaseInsensitiveContains("context") {
                throw LLMError.contextTooLong
            }
            fallthrough
        default:
            let message: String
            if let bodyString = errorResponseMessage(from: responseBody),
               !bodyString.isEmpty {
                message = bodyString
            } else {
                message = "HTTP \(response.statusCode)"
            }
            throw LLMError.serverError(message: message)
        }
    }

    private func errorResponseMessage(from responseBody: Data?) -> String? {
        guard let responseBody, !responseBody.isEmpty else {
            return nil
        }

        if let json = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }

        return String(data: responseBody, encoding: .utf8)
    }

    private func textSegments(from content: Any?) -> [String] {
        if let text = content as? String, !text.isEmpty {
            return [text]
        }

        guard let contentParts = content as? [[String: Any]] else {
            return []
        }

        return contentParts.compactMap { part in
            if let text = part["text"] as? String, !text.isEmpty {
                return text
            }

            if let textObject = part["text"] as? [String: Any],
               let value = textObject["value"] as? String,
               !value.isEmpty {
                return value
            }

            return nil
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

    private func retryDelaySeconds(retryAfter: TimeInterval?, attempt: Int) -> TimeInterval {
        if let retryAfter, retryAfter > 0 {
            return retryAfter
        }

        return min(pow(2, Double(attempt)), 8)
    }

    private func sleepForRetry(seconds: TimeInterval) async throws {
        try await sleepHandler(seconds)
    }

    private func mapError(_ error: Error) -> LLMError {
        if let llmError = error as? LLMError { return llmError }
        if error is CancellationError { return .networkError(message: "Request cancelled") }
        return .networkError(message: error.localizedDescription)
    }

    private static func defaultSleep(seconds: TimeInterval) async throws {
        let nanoseconds = UInt64(max(seconds, 0) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
