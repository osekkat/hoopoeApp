import Foundation

// MARK: - Event Stream

/// Events emitted during an LLM streaming response.
public enum LLMEvent: Equatable, Sendable {
    /// A chunk of text received during streaming.
    case text(String)

    /// The response is complete.
    case done(LLMResponse)

    /// The provider emitted a normalized API error event.
    case error(LLMError)
}

// MARK: - Response

/// The complete result of an LLM request.
public struct LLMResponse: Equatable, Sendable {
    /// The full accumulated response text.
    public let fullText: String

    /// The model that generated this response.
    public let model: String

    /// Token usage statistics.
    public let tokenUsage: TokenUsage

    /// Estimated cost in USD. Phase 0 providers may omit this when unavailable.
    public let costEstimate: Double?

    /// Wall-clock latency from request to final token, expressed in seconds.
    public let latency: TimeInterval?

    public init(
        fullText: String,
        model: String,
        tokenUsage: TokenUsage = .zero,
        costEstimate: Double? = nil,
        latency: TimeInterval? = nil
    ) {
        self.fullText = fullText
        self.model = model
        self.tokenUsage = tokenUsage
        self.costEstimate = costEstimate
        self.latency = latency
    }
}

// MARK: - Token Usage

/// Token consumption for a single request.
public struct TokenUsage: Codable, Equatable, Sendable {
    public static let zero = Self(inputTokens: 0, outputTokens: 0)

    public let inputTokens: Int
    public let outputTokens: Int

    public var totalTokens: Int { inputTokens + outputTokens }

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}
