import XCTest
@testable import Hoopoe

/// Tests for ConvergenceVersionPairMetrics (computation) and ConvergenceTracker (UI wrapper).
///
/// The core metric types and computation logic live in PlanDocument.swift.
/// These tests validate both the metric math and the tracker integration.
final class ConvergenceMetricsTests: XCTestCase {

    // MARK: - ConvergenceVersionPairMetrics — Size Delta

    func testSizeDeltaIdenticalContent() {
        let metrics = makeMetrics(previous: "hello world", current: "hello world")
        XCTAssertEqual(metrics.sizeDelta, 0.0, accuracy: 0.001)
    }

    func testSizeDeltaDoubled() {
        // Previous: 2 words, Current: 4 words → delta = |4 - 2| / 2 = 1.0
        let metrics = makeMetrics(previous: "hello world", current: "hello world foo bar")
        XCTAssertEqual(metrics.sizeDelta, 1.0, accuracy: 0.001)
    }

    func testSizeDeltaHalved() {
        // Previous: 4 words, Current: 2 words → delta = |2 - 4| / 4 = 0.5
        let metrics = makeMetrics(previous: "one two three four", current: "one two")
        XCTAssertEqual(metrics.sizeDelta, 0.5, accuracy: 0.001)
    }

    func testSizeDeltaBothEmpty() {
        let metrics = makeMetrics(previous: "", current: "")
        XCTAssertEqual(metrics.sizeDelta, 0.0, accuracy: 0.001)
    }

    func testSizeDeltaPreviousEmpty() {
        let metrics = makeMetrics(previous: "", current: "hello")
        XCTAssertEqual(metrics.sizeDelta, 1.0, accuracy: 0.001)
    }

    // MARK: - ConvergenceVersionPairMetrics — Change Velocity

    func testChangeVelocityIdenticalContent() {
        let metrics = makeMetrics(
            previous: "line one\nline two\nline three",
            current: "line one\nline two\nline three"
        )
        XCTAssertEqual(metrics.changeVelocity, 0.0, accuracy: 0.001)
    }

    func testChangeVelocityCompletelyDifferent() {
        let metrics = makeMetrics(
            previous: "alpha\nbeta\ngamma",
            current: "one\ntwo\nthree"
        )
        // All lines changed → velocity should be 1.0
        XCTAssertEqual(metrics.changeVelocity, 1.0, accuracy: 0.001)
    }

    func testChangeVelocityPartialChange() {
        let metrics = makeMetrics(
            previous: "line one\nline two\nline three\nline four",
            current: "line one\nmodified\nline three\nline four"
        )
        // 1 removal + 1 insertion = 2 changes / 4 lines = 0.5
        XCTAssertEqual(metrics.changeVelocity, 0.5, accuracy: 0.001)
    }

    // MARK: - ConvergenceVersionPairMetrics — Content Similarity

    func testJaccardIdenticalContent() {
        let metrics = makeMetrics(previous: "hello world", current: "hello world")
        XCTAssertEqual(metrics.contentSimilarity, 1.0, accuracy: 0.001)
    }

    func testJaccardCompletelyDifferent() {
        let metrics = makeMetrics(previous: "alpha beta gamma", current: "one two three")
        XCTAssertEqual(metrics.contentSimilarity, 0.0, accuracy: 0.001)
    }

    func testJaccardBothEmpty() {
        let metrics = makeMetrics(previous: "", current: "")
        XCTAssertEqual(metrics.contentSimilarity, 1.0, accuracy: 0.001, "Both empty should be 1.0")
    }

    func testJaccardCaseInsensitive() {
        let metrics = makeMetrics(previous: "Hello World", current: "hello world")
        XCTAssertEqual(metrics.contentSimilarity, 1.0, accuracy: 0.001)
    }

    // MARK: - ConvergenceVersionPairMetrics — Composite Score

    func testCompositeScoreIdenticalContent() {
        let metrics = makeMetrics(previous: "hello world", current: "hello world")
        XCTAssertEqual(metrics.compositeScore, 1.0, accuracy: 0.001)
    }

    func testCompositeScoreCompletelyDifferent() {
        let metrics = makeMetrics(
            previous: "alpha beta gamma delta",
            current: "one two three four five six"
        )
        // Very different content → low score
        XCTAssertLessThan(metrics.compositeScore, 0.3)
    }

    func testCompositeScoreRangeIsZeroToOne() {
        let identical = makeMetrics(previous: "test", current: "test")
        let different = makeMetrics(previous: "alpha", current: "beta gamma delta")
        XCTAssertGreaterThanOrEqual(identical.compositeScore, 0.0)
        XCTAssertLessThanOrEqual(identical.compositeScore, 1.0)
        XCTAssertGreaterThanOrEqual(different.compositeScore, 0.0)
        XCTAssertLessThanOrEqual(different.compositeScore, 1.0)
    }

    // MARK: - ConvergenceWeights

    func testDefaultWeightsSumToOne() {
        let w = ConvergenceWeights.default
        let sum = w.sizeDeltaWeight + w.similarityWeight + w.velocityWeight
        XCTAssertEqual(sum, 1.0, accuracy: 0.001)
    }

    func testWeightsNormalization() {
        let w = ConvergenceWeights(sizeDeltaWeight: 1, similarityWeight: 2, velocityWeight: 1)
        let n = w.normalized
        XCTAssertEqual(n.sizeDeltaWeight, 0.25, accuracy: 0.001)
        XCTAssertEqual(n.similarityWeight, 0.5, accuracy: 0.001)
        XCTAssertEqual(n.velocityWeight, 0.25, accuracy: 0.001)
    }

    func testWeightsCodable() throws {
        let w = ConvergenceWeights(sizeDeltaWeight: 0.2, similarityWeight: 0.5, velocityWeight: 0.3)
        let data = try JSONEncoder().encode(w)
        let decoded = try JSONDecoder().decode(ConvergenceWeights.self, from: data)
        XCTAssertEqual(decoded.sizeDeltaWeight, 0.2, accuracy: 0.001)
        XCTAssertEqual(decoded.similarityWeight, 0.5, accuracy: 0.001)
        XCTAssertEqual(decoded.velocityWeight, 0.3, accuracy: 0.001)
    }

    // MARK: - ConvergenceVersionPairMetrics Codable

    func testMetricsCodable() throws {
        let planId = UUID()
        let prev = PlanVersion(planId: planId, content: "old", roundNumber: 1, changeDescription: "r1")
        let curr = PlanVersion(planId: planId, content: "new content", roundNumber: 2, changeDescription: "r2")
        let metrics = ConvergenceVersionPairMetrics(previous: prev, current: curr)

        let data = try JSONEncoder().encode(metrics)
        let decoded = try JSONDecoder().decode(ConvergenceVersionPairMetrics.self, from: data)

        XCTAssertEqual(decoded.previousRoundNumber, 1)
        XCTAssertEqual(decoded.currentRoundNumber, 2)
        XCTAssertEqual(decoded.sizeDelta, metrics.sizeDelta, accuracy: 0.001)
        XCTAssertEqual(decoded.compositeScore, metrics.compositeScore, accuracy: 0.001)
    }

    // MARK: - ConvergenceTracker Integration

    func testTrackerWithFewerThanTwoVersions() {
        let tracker = ConvergenceTracker()
        let plan = makePlan(contents: ["Only one version"])

        let metrics = tracker.computeAllMetrics(for: plan)
        XCTAssertTrue(metrics.isEmpty)
        XCTAssertNil(tracker.latestConvergenceScore(for: plan))
        XCTAssertFalse(tracker.hasConverged(plan: plan))
    }

    func testTrackerWithIdenticalVersions() {
        let tracker = ConvergenceTracker()
        let content = "# Plan\n\nThis is a plan with several words."
        let plan = makePlan(contents: [content, content])

        let score = tracker.latestConvergenceScore(for: plan)
        XCTAssertNotNil(score)
        XCTAssertEqual(score!, 1.0, accuracy: 0.001, "Identical versions should have score 1.0")
        XCTAssertTrue(tracker.hasConverged(plan: plan))
    }

    func testTrackerWithConvergingVersions() {
        let tracker = ConvergenceTracker()
        let v1 = "# Plan\n\nOriginal idea about building a web app"
        let v2 = "# Plan\n\nRefined idea about building a web app with React"
        let v3 = "# Plan\n\nRefined idea about building a web app with React and Node"
        let plan = makePlan(contents: [v1, v2, v3])

        let allMetrics = tracker.computeAllMetrics(for: plan)
        XCTAssertEqual(allMetrics.count, 2)

        // Metrics should be ordered by round
        XCTAssertEqual(allMetrics[0].currentRoundNumber, 2)
        XCTAssertEqual(allMetrics[1].currentRoundNumber, 3)
    }

    func testTrackerHasConvergedDefaultThreshold() {
        let tracker = ConvergenceTracker()

        // Nearly identical versions should converge
        let convergedPlan = makePlan(contents: [
            "# Plan\n\nBuild a web app with React and a Node backend.",
            "# Plan\n\nBuild a web app with React and a Node.js backend.",
        ])
        XCTAssertTrue(tracker.hasConverged(plan: convergedPlan))

        // Very different versions should not converge
        let divergentPlan = makePlan(contents: [
            "# Plan A\n\nBuild a mobile app.",
            "# Plan B\n\nDesign a completely different desktop application with new architecture.",
        ])
        XCTAssertFalse(tracker.hasConverged(plan: divergentPlan))
    }

    func testTrackerCustomConvergenceThreshold() {
        let tracker = ConvergenceTracker()
        let plan = makePlan(contents: [
            "Build a web app with React",
            "Build a web app with React and Node",
        ])

        // With a very low threshold, it should converge
        XCTAssertTrue(tracker.hasConverged(plan: plan, threshold: 0.1))

        // With threshold of 1.0, only identical content converges
        XCTAssertFalse(tracker.hasConverged(plan: plan, threshold: 1.0))
    }

    // MARK: - PlanDocument Integration

    func testPlanDocumentRebuildMetrics() {
        let plan = makePlan(contents: [
            "version 1 content here",
            "version 2 updated content here",
            "version 3 final content here",
        ])

        plan.rebuildConvergenceMetrics()
        XCTAssertEqual(plan.convergenceMetrics.count, 2)

        let latest = plan.latestConvergenceMetrics()
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.currentRoundNumber, 3)
    }

    func testPlanDocumentNeedsRefresh() {
        let plan = makePlan(contents: ["v1", "v2"])
        // Clear metrics to force refresh detection
        plan.convergenceMetrics = []
        XCTAssertTrue(plan.needsConvergenceMetricsRefresh())

        plan.rebuildConvergenceMetrics()
        XCTAssertFalse(plan.needsConvergenceMetricsRefresh())
    }

    // MARK: - Efficiency

    func testLargeDocumentPerformance() {
        // Generate ~10,000 word documents
        let baseWords = (0..<10_000).map { "word\($0)" }
        let v1 = baseWords.joined(separator: " ")
        var modifiedWords = baseWords
        for i in stride(from: 0, to: modifiedWords.count, by: 20) {
            modifiedWords[i] = "changed\(i)"
        }
        let v2 = modifiedWords.joined(separator: " ")

        let start = CFAbsoluteTimeGetCurrent()
        let metrics = ConvergenceVersionPairMetrics(
            previous: PlanVersion(planId: UUID(), content: v1, roundNumber: 1, changeDescription: "r1"),
            current: PlanVersion(planId: UUID(), content: v2, roundNumber: 2, changeDescription: "r2")
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 5.0, "10,000 word documents should compute in under 5 seconds")
        XCTAssertGreaterThan(metrics.compositeScore, 0.5)
    }

    // MARK: - Helpers

    private func makeMetrics(previous: String, current: String) -> ConvergenceVersionPairMetrics {
        let planId = UUID()
        return ConvergenceVersionPairMetrics(
            previous: PlanVersion(planId: planId, content: previous, roundNumber: 1, changeDescription: "r1"),
            current: PlanVersion(planId: planId, content: current, roundNumber: 2, changeDescription: "r2")
        )
    }

    private func makePlan(contents: [String]) -> PlanDocument {
        let planId = UUID()
        let versions = contents.enumerated().map { index, content in
            PlanVersion(
                planId: planId,
                content: content,
                roundNumber: index + 1,
                changeDescription: "Round \(index + 1)"
            )
        }
        return PlanDocument(
            id: planId,
            title: "Test Plan",
            content: contents.last ?? "",
            versions: versions
        )
    }
}
