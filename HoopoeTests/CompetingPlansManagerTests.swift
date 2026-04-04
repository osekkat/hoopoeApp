import XCTest
@testable import Hoopoe
@testable import HoopoeUI

/// Tests for CompetingPlansManager — the parallel multi-model plan generation engine.
///
/// Uses a MockLLMProvider that returns controlled AsyncThrowingStream responses
/// to verify parallel execution, partial failure handling, cancellation, and
/// result aggregation without hitting real APIs.
@MainActor
final class CompetingPlansManagerTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState() {
        let manager = CompetingPlansManager()
        XCTAssertTrue(manager.results.isEmpty)
        XCTAssertFalse(manager.isRunning)
        XCTAssertEqual(manager.completedCount, 0)
        XCTAssertEqual(manager.totalCost, 0)
        XCTAssertTrue(manager.allFinished)
        XCTAssertTrue(manager.successfulResults.isEmpty)
    }

    // MARK: - Parallel Execution

    func testStartCreatesResultSlotsForAllProviders() async {
        let registry = makeRegistry(providerCount: 3)
        let manager = CompetingPlansManager()

        manager.startCompetingRequests(
            prompt: "Test prompt",
            system: "System",
            registry: registry
        )

        // Should have one result per (provider, model) pair
        XCTAssertEqual(manager.results.count, 3)
        XCTAssertTrue(manager.isRunning)

        // Each result should have correct provider info
        for (i, result) in manager.results.enumerated() {
            XCTAssertEqual(result.providerName, "Mock\(i)")
            XCTAssertEqual(result.modelName, "model-\(i)")
        }

        manager.cancel()
    }

    func testAllProvidersCompleteSuccessfully() async throws {
        let providers = (0..<3).map { i in
            MockLLMProvider(
                id: "mock\(i)",
                displayName: "Mock\(i)",
                modelID: "model-\(i)",
                modelName: "model-\(i)",
                behavior: .succeedWith("Plan from provider \(i)")
            )
        }
        let registry = makeRegistry(with: providers)
        let manager = CompetingPlansManager()

        manager.startCompetingRequests(
            prompt: "Test prompt",
            system: nil,
            registry: registry
        )

        // Wait for all to complete
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertFalse(manager.isRunning)
        XCTAssertTrue(manager.allFinished)
        XCTAssertEqual(manager.successfulResults.count, 3)

        for (i, result) in manager.results.enumerated() {
            XCTAssertEqual(result.completedText, "Plan from provider \(i)")
            XCTAssertTrue(result.isComplete)
        }
    }

    // MARK: - Partial Failure

    func testPartialFailureIsolated() async throws {
        let providers: [MockLLMProvider] = [
            MockLLMProvider(
                id: "ok1", displayName: "OK1", modelID: "m1", modelName: "m1",
                behavior: .succeedWith("Good plan 1")
            ),
            MockLLMProvider(
                id: "fail", displayName: "Fail", modelID: "m2", modelName: "m2",
                behavior: .failWith("Auth error")
            ),
            MockLLMProvider(
                id: "ok2", displayName: "OK2", modelID: "m3", modelName: "m3",
                behavior: .succeedWith("Good plan 2")
            ),
        ]
        let registry = makeRegistry(with: providers)
        let manager = CompetingPlansManager()

        manager.startCompetingRequests(
            prompt: "Test",
            system: nil,
            registry: registry
        )

        try await Task.sleep(for: .milliseconds(500))

        XCTAssertFalse(manager.isRunning)
        XCTAssertTrue(manager.allFinished)
        XCTAssertEqual(manager.successfulResults.count, 2)
        XCTAssertEqual(manager.completedCount, 3) // all finished (2 success + 1 fail)

        // Verify the failed provider
        let failedResult = manager.results.first(where: { $0.providerID == "fail" })
        XCTAssertNotNil(failedResult)
        XCTAssertTrue(failedResult!.isFailed)
        XCTAssertEqual(failedResult!.errorMessage, "Auth error")

        // Verify successful providers
        let okResults = manager.results.filter(\.isComplete)
        XCTAssertEqual(okResults.count, 2)
    }

    // MARK: - Cancellation

    func testCancelStopsAllProviders() async throws {
        let providers = (0..<3).map { i in
            MockLLMProvider(
                id: "slow\(i)", displayName: "Slow\(i)", modelID: "m\(i)", modelName: "m\(i)",
                behavior: .slow(delayMS: 2000, text: "Slow plan \(i)")
            )
        }
        let registry = makeRegistry(with: providers)
        let manager = CompetingPlansManager()

        manager.startCompetingRequests(prompt: "Test", system: nil, registry: registry)
        XCTAssertTrue(manager.isRunning)

        // Cancel after a brief delay
        try await Task.sleep(for: .milliseconds(100))
        manager.cancel()

        XCTAssertFalse(manager.isRunning)
        // All active results should be cancelled
        for result in manager.results where result.isActive {
            XCTFail("Expected no active results after cancel, found: \(result.id)")
        }
    }

    // MARK: - Empty Registry

    func testEmptyRegistryNoOp() {
        let registry = ProviderRegistry()
        let manager = CompetingPlansManager()

        manager.startCompetingRequests(prompt: "Test", system: nil, registry: registry)

        XCTAssertTrue(manager.results.isEmpty)
        XCTAssertFalse(manager.isRunning)
    }

    // MARK: - Cost Aggregation

    func testTotalCostAggregation() async throws {
        let providers = (0..<2).map { i in
            MockLLMProvider(
                id: "p\(i)", displayName: "P\(i)", modelID: "m\(i)", modelName: "m\(i)",
                behavior: .succeedWithCost("Plan \(i)", cost: Double(i + 1) * 0.01)
            )
        }
        let registry = makeRegistry(with: providers)
        let manager = CompetingPlansManager()

        manager.startCompetingRequests(prompt: "Test", system: nil, registry: registry)
        try await Task.sleep(for: .milliseconds(500))

        // 0.01 + 0.02 = 0.03
        XCTAssertEqual(manager.totalCost, 0.03, accuracy: 0.001)
    }

    // MARK: - Streaming Text Accumulation

    func testStreamingTextAccumulates() async throws {
        let providers = [
            MockLLMProvider(
                id: "stream", displayName: "Stream", modelID: "m1", modelName: "m1",
                behavior: .streamChunks(["Hello ", "world ", "plan"])
            ),
        ]
        let registry = makeRegistry(with: providers)
        let manager = CompetingPlansManager()

        manager.startCompetingRequests(prompt: "Test", system: nil, registry: registry)
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(manager.results.first?.completedText, "Hello world plan")
    }

    // MARK: - ProviderResult Properties

    func testProviderResultPhaseProperties() {
        var result = CompetingPlansManager.ProviderResult(
            id: "test", providerID: "p", providerName: "P",
            modelID: "m", modelName: "M", providerIcon: "cpu"
        )

        // Waiting
        result.phase = .waiting
        XCTAssertTrue(result.isActive)
        XCTAssertFalse(result.isComplete)
        XCTAssertFalse(result.isFailed)
        XCTAssertNil(result.completedText)
        XCTAssertNil(result.errorMessage)

        // Streaming
        result.phase = .streaming
        XCTAssertTrue(result.isActive)

        // Completed
        result.phase = .completed(text: "Done")
        XCTAssertFalse(result.isActive)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.completedText, "Done")

        // Failed
        result.phase = .failed("Oops")
        XCTAssertFalse(result.isActive)
        XCTAssertTrue(result.isFailed)
        XCTAssertEqual(result.errorMessage, "Oops")

        // Cancelled
        result.phase = .cancelled
        XCTAssertFalse(result.isActive)
    }

    // MARK: - Restart Clears Previous Results

    func testRestartClearsPreviousResults() async throws {
        let providers = [
            MockLLMProvider(
                id: "p1", displayName: "P1", modelID: "m1", modelName: "m1",
                behavior: .succeedWith("First run")
            ),
        ]
        let registry = makeRegistry(with: providers)
        let manager = CompetingPlansManager()

        // First run
        manager.startCompetingRequests(prompt: "Test", system: nil, registry: registry)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(manager.results.count, 1)
        XCTAssertEqual(manager.results.first?.completedText, "First run")

        // Second run — should clear and restart
        let providers2 = [
            MockLLMProvider(
                id: "p1", displayName: "P1", modelID: "m1", modelName: "m1",
                behavior: .succeedWith("Second run")
            ),
        ]
        let registry2 = makeRegistry(with: providers2)
        manager.startCompetingRequests(prompt: "Test", system: nil, registry: registry2)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(manager.results.count, 1)
        XCTAssertEqual(manager.results.first?.completedText, "Second run")
    }

    // MARK: - Section Highlighting

    func testParseSectionsSplitsMarkdownByHeading() {
        let markdown = """
        Intro summary

        # Architecture
        Use a modular shell.

        ## Testing
        Add regression coverage.
        """

        let sections = CompetingPlansManager.parseSections(from: markdown)

        XCTAssertEqual(sections.map(\.title), ["Overview", "Architecture", "Testing"])
        XCTAssertEqual(sections[0].plainText, "Intro summary")
        XCTAssertEqual(sections[1].bodyMarkdown, "Use a modular shell.")
        XCTAssertEqual(sections[2].level, 2)
    }

    func testToggleHighlightAddsAndRemovesSection() {
        let manager = CompetingPlansManager()
        var result = CompetingPlansManager.ProviderResult(
            id: "anthropic::opus",
            providerID: "anthropic",
            providerName: "Anthropic",
            modelID: "opus",
            modelName: "Opus",
            providerIcon: "brain"
        )
        result.phase = .completed(text: "# Architecture\nUse a modular shell.")
        manager.results = [result]

        let section = manager.sections(for: result)[0]
        XCTAssertFalse(manager.hasHighlights)

        manager.toggleHighlight(for: result, section: section)

        XCTAssertTrue(manager.hasHighlights)
        XCTAssertEqual(manager.highlights.count, 1)
        XCTAssertEqual(manager.highlights[0].sectionTitle, "Architecture")
        XCTAssertEqual(manager.highlights[0].providerName, "Anthropic")

        manager.toggleHighlight(for: result, section: section)

        XCTAssertFalse(manager.hasHighlights)
        XCTAssertTrue(manager.highlights.isEmpty)
    }

    func testSynthesisHighlightsPromptIncludesGroupedContextAndNotes() {
        let manager = CompetingPlansManager()

        var first = CompetingPlansManager.ProviderResult(
            id: "anthropic::opus",
            providerID: "anthropic",
            providerName: "Anthropic",
            modelID: "opus",
            modelName: "Opus",
            providerIcon: "brain"
        )
        first.phase = .completed(text: "# Architecture\nUse a modular shell.")

        var second = CompetingPlansManager.ProviderResult(
            id: "openai::gpt",
            providerID: "openai",
            providerName: "OpenAI",
            modelID: "gpt",
            modelName: "GPT",
            providerIcon: "sparkles"
        )
        second.phase = .completed(text: "# Testing\nAdd regression coverage.")

        manager.results = [first, second]

        let firstSection = manager.sections(for: first)[0]
        let secondSection = manager.sections(for: second)[0]
        manager.toggleHighlight(for: first, section: firstSection)
        manager.toggleHighlight(for: second, section: secondSection)
        manager.updateHighlightNote(id: manager.highlights[0].id, note: "Prefer this structure.")

        let prompt = manager.synthesisHighlightsPrompt()

        XCTAssertTrue(prompt.contains("Anthropic (Opus)"))
        XCTAssertTrue(prompt.contains("OpenAI (GPT)"))
        XCTAssertTrue(prompt.contains("#### Architecture"))
        XCTAssertTrue(prompt.contains("#### Testing"))
        XCTAssertTrue(prompt.contains("Use a modular shell."))
        XCTAssertTrue(prompt.contains("Prefer this structure."))
    }

    func testStartCompetingRequestsClearsExistingHighlights() {
        let manager = CompetingPlansManager()
        var result = CompetingPlansManager.ProviderResult(
            id: "anthropic::opus",
            providerID: "anthropic",
            providerName: "Anthropic",
            modelID: "opus",
            modelName: "Opus",
            providerIcon: "brain"
        )
        result.phase = .completed(text: "# Architecture\nUse a modular shell.")
        manager.results = [result]
        manager.toggleHighlight(for: result, section: manager.sections(for: result)[0])
        XCTAssertTrue(manager.hasHighlights)

        manager.startCompetingRequests(prompt: "Regenerate", system: nil, registry: ProviderRegistry())

        XCTAssertFalse(manager.hasHighlights)
    }

    // MARK: - Helpers

    private func makeRegistry(providerCount: Int) -> ProviderRegistry {
        let providers = (0..<providerCount).map { i in
            MockLLMProvider(
                id: "mock\(i)",
                displayName: "Mock\(i)",
                modelID: "model-\(i)",
                modelName: "model-\(i)",
                behavior: .succeedWith("Plan \(i)")
            )
        }
        return makeRegistry(with: providers)
    }

    private func makeRegistry(with providers: [MockLLMProvider]) -> ProviderRegistry {
        let registry = ProviderRegistry()
        for provider in providers {
            registry.register(provider)
        }
        return registry
    }
}

// MARK: - Mock LLM Provider

/// Test double for LLMProvider with configurable behavior.
struct MockLLMProvider: LLMProvider, Sendable {
    enum Behavior: Sendable {
        case succeedWith(String)
        case succeedWithCost(String, cost: Double)
        case failWith(String)
        case slow(delayMS: Int, text: String)
        case streamChunks([String])
    }

    let id: String
    let displayName: String
    let isConfigured: Bool = true
    let availableModels: [LLMModel]
    let behavior: Behavior

    init(id: String, displayName: String, modelID: String, modelName: String, behavior: Behavior) {
        self.id = id
        self.displayName = displayName
        self.behavior = behavior
        self.availableModels = [
            LLMModel(
                id: modelID,
                displayName: modelName,
                contextWindow: 200_000,
                inputCostPer1kTokens: 0.01,
                outputCostPer1kTokens: 0.03
            ),
        ]
    }

    func send(
        prompt: String,
        model: String,
        system: String?,
        stream: Bool
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        let behavior = self.behavior
        return AsyncThrowingStream { continuation in
            Task {
                switch behavior {
                case .succeedWith(let text):
                    continuation.yield(.text(text))
                    let response = LLMResponse(
                        fullText: text,
                        model: model,
                        tokenUsage: TokenUsage(inputTokens: 100, outputTokens: 200),
                        costEstimate: nil,
                        latency: 0.5
                    )
                    continuation.yield(.done(response))
                    continuation.finish()

                case .succeedWithCost(let text, let cost):
                    continuation.yield(.text(text))
                    let response = LLMResponse(
                        fullText: text,
                        model: model,
                        tokenUsage: TokenUsage(inputTokens: 100, outputTokens: 200),
                        costEstimate: cost,
                        latency: 0.5
                    )
                    continuation.yield(.done(response))
                    continuation.finish()

                case .failWith(let message):
                    continuation.yield(.error(.serverError(message: message)))
                    continuation.finish()

                case .slow(let delayMS, let text):
                    try? await Task.sleep(for: .milliseconds(delayMS))
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }
                    continuation.yield(.text(text))
                    let response = LLMResponse(
                        fullText: text,
                        model: model,
                        tokenUsage: TokenUsage(inputTokens: 100, outputTokens: 200),
                        costEstimate: nil,
                        latency: Double(delayMS) / 1000.0
                    )
                    continuation.yield(.done(response))
                    continuation.finish()

                case .streamChunks(let chunks):
                    var accumulated = ""
                    for chunk in chunks {
                        try? await Task.sleep(for: .milliseconds(50))
                        guard !Task.isCancelled else {
                            continuation.finish()
                            return
                        }
                        accumulated += chunk
                        continuation.yield(.text(chunk))
                    }
                    let response = LLMResponse(
                        fullText: accumulated,
                        model: model,
                        tokenUsage: TokenUsage(inputTokens: 50, outputTokens: 150),
                        costEstimate: nil,
                        latency: 0.15
                    )
                    continuation.yield(.done(response))
                    continuation.finish()
                }
            }
        }
    }
}
