import Foundation

// MARK: - Provider Protocol

/// A provider capable of sending prompts to an LLM and streaming back responses.
///
/// Implementations must be `Sendable` since API calls execute off the main actor.
/// In Phase 2+, Swift-side providers will be replaced by the Rust engine's `ProviderTrait`.
public protocol LLMProvider: Sendable {
    /// Unique identifier for this provider (e.g., "anthropic", "openai", "google").
    var id: String { get }

    /// Human-readable name (e.g., "Claude", "GPT", "Gemini").
    var displayName: String { get }

    /// Whether the provider has a valid API key configured.
    var isConfigured: Bool { get }

    /// Models available from this provider.
    var availableModels: [LLMModel] { get }

    /// Send a single-shot prompt and stream the response.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt text.
    ///   - model: The provider-specific model identifier to use.
    ///   - system: Optional system prompt.
    ///   - stream: Whether the provider should stream partial tokens.
    /// - Returns: An async stream of `LLMEvent` values.
    func send(
        prompt: String,
        model: String,
        system: String?,
        stream: Bool
    ) -> AsyncThrowingStream<LLMEvent, Error>
}

// MARK: - Model

/// Describes an LLM model offered by a provider.
public struct LLMModel: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let contextWindow: Int
    public let inputCostPer1kTokens: Double
    public let outputCostPer1kTokens: Double

    public init(
        id: String,
        displayName: String,
        contextWindow: Int,
        inputCostPer1kTokens: Double,
        outputCostPer1kTokens: Double
    ) {
        self.id = id
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.inputCostPer1kTokens = inputCostPer1kTokens
        self.outputCostPer1kTokens = outputCostPer1kTokens
    }
}
