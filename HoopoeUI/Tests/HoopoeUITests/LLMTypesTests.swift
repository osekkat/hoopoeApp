import XCTest
@testable import HoopoeUI

/// Tests for LLM shared types: LLMError, LLMEvent, TokenUsage, LLMModel.
final class LLMTypesTests: XCTestCase {

    // MARK: - LLMError

    func testErrorDescriptionAuthenticationFailed() {
        let error = LLMError.authenticationFailed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("api key"))
    }

    func testErrorDescriptionRateLimitedWithRetryAfter() {
        let error = LLMError.rateLimited(retryAfter: 30)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("30"))
    }

    func testErrorDescriptionRateLimitedWithoutRetryAfter() {
        let error = LLMError.rateLimited(retryAfter: nil)
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("rate limit"))
    }

    func testErrorDescriptionContextTooLong() {
        let error = LLMError.contextTooLong
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("context"))
    }

    func testErrorDescriptionNetworkError() {
        let error = LLMError.networkError(message: "Connection reset")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Connection reset"))
    }

    func testErrorDescriptionServerError() {
        let error = LLMError.serverError(message: "HTTP 500")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("HTTP 500"))
    }

    // MARK: - LLMError Equatable

    func testErrorEquality() {
        XCTAssertEqual(LLMError.authenticationFailed, LLMError.authenticationFailed)
        XCTAssertEqual(LLMError.contextTooLong, LLMError.contextTooLong)
        XCTAssertEqual(
            LLMError.rateLimited(retryAfter: 5),
            LLMError.rateLimited(retryAfter: 5)
        )
        XCTAssertNotEqual(
            LLMError.rateLimited(retryAfter: 5),
            LLMError.rateLimited(retryAfter: 10)
        )
        XCTAssertNotEqual(
            LLMError.authenticationFailed,
            LLMError.contextTooLong
        )
    }

    // MARK: - TokenUsage

    func testTokenUsageTotalTokens() {
        let usage = TokenUsage(inputTokens: 100, outputTokens: 50)
        XCTAssertEqual(usage.totalTokens, 150)
    }

    func testTokenUsageZero() {
        let zero = TokenUsage.zero
        XCTAssertEqual(zero.inputTokens, 0)
        XCTAssertEqual(zero.outputTokens, 0)
        XCTAssertEqual(zero.totalTokens, 0)
    }

    func testTokenUsageEquality() {
        let a = TokenUsage(inputTokens: 10, outputTokens: 20)
        let b = TokenUsage(inputTokens: 10, outputTokens: 20)
        let c = TokenUsage(inputTokens: 10, outputTokens: 30)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - LLMEvent

    func testEventEquality() {
        XCTAssertEqual(LLMEvent.text("hello"), LLMEvent.text("hello"))
        XCTAssertNotEqual(LLMEvent.text("hello"), LLMEvent.text("world"))

        let response = LLMResponse(fullText: "test", model: "m")
        XCTAssertEqual(LLMEvent.done(response), LLMEvent.done(response))

        XCTAssertEqual(
            LLMEvent.error(.authenticationFailed),
            LLMEvent.error(.authenticationFailed)
        )
        XCTAssertNotEqual(
            LLMEvent.text("x"),
            LLMEvent.error(.contextTooLong)
        )
    }

    // MARK: - LLMModel

    func testModelIdentifiable() {
        let model = LLMModel(
            id: "test-model",
            displayName: "Test",
            contextWindow: 100_000,
            inputCostPer1kTokens: 0.01,
            outputCostPer1kTokens: 0.03
        )
        XCTAssertEqual(model.id, "test-model")
    }

    func testModelHashable() {
        let a = LLMModel(id: "a", displayName: "A", contextWindow: 1000, inputCostPer1kTokens: 0, outputCostPer1kTokens: 0)
        let b = LLMModel(id: "a", displayName: "A", contextWindow: 1000, inputCostPer1kTokens: 0, outputCostPer1kTokens: 0)
        let c = LLMModel(id: "c", displayName: "C", contextWindow: 1000, inputCostPer1kTokens: 0, outputCostPer1kTokens: 0)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)

        var set: Set<LLMModel> = [a, b, c]
        XCTAssertEqual(set.count, 2, "Set should deduplicate equal models")
    }
}

/// Tests for ProviderRegistry.
@MainActor
final class ProviderRegistryTests: XCTestCase {

    func testRegisterAndLookupProvider() {
        let registry = ProviderRegistry()
        let provider = StubProvider(id: "test", configured: true)

        registry.register(provider)

        XCTAssertNotNil(registry.provider(for: "test"))
        XCTAssertEqual(registry.configuredProviders.count, 1)
    }

    func testRegisterUnconfiguredProviderRemovesIt() {
        let registry = ProviderRegistry()
        let configured = StubProvider(id: "test", configured: true)
        let unconfigured = StubProvider(id: "test", configured: false)

        registry.register(configured)
        XCTAssertEqual(registry.configuredProviders.count, 1)

        registry.register(unconfigured)
        XCTAssertEqual(registry.configuredProviders.count, 0)
        XCTAssertNil(registry.provider(for: "test"))
    }

    func testUnregisterProvider() {
        let registry = ProviderRegistry()
        registry.register(StubProvider(id: "a", configured: true))
        registry.register(StubProvider(id: "b", configured: true))

        XCTAssertEqual(registry.configuredProviders.count, 2)

        registry.unregister(id: "a")
        XCTAssertEqual(registry.configuredProviders.count, 1)
        XCTAssertNil(registry.provider(for: "a"))
        XCTAssertNotNil(registry.provider(for: "b"))
    }

    func testReplaceProviders() {
        let registry = ProviderRegistry()
        registry.register(StubProvider(id: "old", configured: true))

        registry.replaceProviders(with: [
            StubProvider(id: "new1", configured: true),
            StubProvider(id: "new2", configured: true),
            StubProvider(id: "unconfigured", configured: false),
        ])

        XCTAssertNil(registry.provider(for: "old"))
        XCTAssertNotNil(registry.provider(for: "new1"))
        XCTAssertNotNil(registry.provider(for: "new2"))
        XCTAssertNil(registry.provider(for: "unconfigured"))
        XCTAssertEqual(registry.configuredProviders.count, 2)
    }

    func testAllModelsAggregatesAcrossProviders() {
        let registry = ProviderRegistry()
        registry.register(StubProvider(id: "a", configured: true, modelCount: 2))
        registry.register(StubProvider(id: "b", configured: true, modelCount: 3))

        XCTAssertEqual(registry.allModels.count, 5)
    }
}

// MARK: - Stub Provider

private struct StubProvider: LLMProvider, Sendable {
    let id: String
    let displayName: String
    let isConfigured: Bool
    let availableModels: [LLMModel]

    init(id: String, configured: Bool, modelCount: Int = 1) {
        self.id = id
        self.displayName = id.capitalized
        self.isConfigured = configured
        self.availableModels = (0..<modelCount).map { i in
            LLMModel(
                id: "\(id)-model-\(i)",
                displayName: "\(id) Model \(i)",
                contextWindow: 100_000,
                inputCostPer1kTokens: 0.01,
                outputCostPer1kTokens: 0.03
            )
        }
    }

    func send(
        prompt: String,
        model: String,
        system: String?,
        stream: Bool
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.done(LLMResponse(fullText: "stub", model: model)))
            continuation.finish()
        }
    }
}
