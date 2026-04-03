import Foundation
import Testing

@testable import Hoopoe

// MARK: - PlanDocument Tests

@Suite("PlanDocument")
struct PlanDocumentTests {
    // MARK: - Initialization

    @Test("Default init creates empty untitled plan")
    func defaultInit() {
        let plan = PlanDocument()
        #expect(plan.title == "Untitled Plan")
        #expect(plan.content.isEmpty)
        #expect(plan.type == .master)
        #expect(plan.versions.isEmpty)
        #expect(plan.convergenceMetrics.isEmpty)
        #expect(plan.filePath == nil)
    }

    @Test("Init with feature type preserves associated value")
    func featureTypeInit() {
        let plan = PlanDocument(type: .feature(name: "auth"))
        if case .feature(let name) = plan.type {
            #expect(name == "auth")
        } else {
            Issue.record("Expected .feature type")
        }
    }

    // MARK: - isDirty

    @Test("Empty plan with no versions is not dirty")
    func emptyPlanNotDirty() {
        let plan = PlanDocument(content: "")
        #expect(!plan.isDirty)
    }

    @Test("Plan with content but no versions is dirty")
    func contentWithoutVersionIsDirty() {
        let plan = PlanDocument(content: "Some content")
        #expect(plan.isDirty)
    }

    @Test("Plan is not dirty when content matches last version")
    func contentMatchesLastVersion() {
        let plan = PlanDocument(content: "Hello world")
        plan.snapshot(changeDescription: "Initial")
        #expect(!plan.isDirty)
    }

    @Test("Plan is dirty when content differs from last version")
    func contentDiffersFromLastVersion() {
        let plan = PlanDocument(content: "Hello world")
        plan.snapshot(changeDescription: "Initial")
        plan.content = "Hello world, updated"
        #expect(plan.isDirty)
    }

    // MARK: - snapshot

    @Test("Snapshot captures current content and increments round number")
    func snapshotCaptures() {
        let plan = PlanDocument(content: "v1 content")
        plan.snapshot(changeDescription: "First")
        #expect(plan.versions.count == 1)
        #expect(plan.versions[0].content == "v1 content")
        #expect(plan.versions[0].roundNumber == 1)
        #expect(plan.versions[0].changeDescription == "First")

        plan.content = "v2 content"
        plan.snapshot(changeDescription: "Second")
        #expect(plan.versions.count == 2)
        #expect(plan.versions[1].content == "v2 content")
        #expect(plan.versions[1].roundNumber == 2)
    }

    @Test("Snapshot computes convergence metrics for consecutive versions")
    func snapshotComputesConvergenceMetrics() {
        let plan = PlanDocument(content: "alpha beta gamma")
        plan.snapshot(changeDescription: "Initial")

        plan.content = "alpha beta gamma\ndelta epsilon"
        plan.snapshot(changeDescription: "Expanded")

        #expect(plan.convergenceMetrics.count == 1)
        let metric = plan.convergenceMetrics[0]
        #expect(metric.previousRoundNumber == 1)
        #expect(metric.currentRoundNumber == 2)
        #expect(metric.previousWordCount == 3)
        #expect(metric.currentWordCount == 5)
        #expect(abs(metric.sizeDelta - (2.0 / 3.0)) < 0.000_1)
        #expect(metric.changeVelocity > 0)
        #expect(metric.contentSimilarity > 0)
        #expect(metric.compositeScore >= 0)
        #expect(metric.compositeScore <= 1)
    }

    // MARK: - Codable Round-Trip

    @Test("PlanDocument survives JSON encode/decode round-trip")
    func codableRoundTrip() throws {
        let original = PlanDocument(
            title: "Test Plan",
            content: "# My Plan\n\nSome content.",
            type: .feature(name: "login")
        )
        original.snapshot(changeDescription: "Initial")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PlanDocument.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.title == "Test Plan")
        #expect(decoded.content == "# My Plan\n\nSome content.")
        #expect(decoded.type == .feature(name: "login"))
        #expect(decoded.versions.count == 1)
        #expect(decoded.versions[0].content == "# My Plan\n\nSome content.")
    }

    @Test("PlanType.master round-trips through Codable")
    func planTypeMasterCodable() throws {
        let original = PlanType.master
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlanType.self, from: data)
        #expect(decoded == .master)
    }

    @Test("PlanType.feature round-trips through Codable")
    func planTypeFeatureCodable() throws {
        let original = PlanType.feature(name: "payments")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlanType.self, from: data)
        #expect(decoded == .feature(name: "payments"))
    }

    // MARK: - PlanVersion with Provenance

    @Test("PlanVersion with provenance round-trips through Codable")
    func versionProvenanceCodable() throws {
        let version = PlanVersion(
            planId: UUID(),
            content: "test",
            roundNumber: 1,
            changeDescription: "Generated",
            provenance: VersionProvenance(modelName: "claude-opus-4", promptType: .generation)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(version)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PlanVersion.self, from: data)

        #expect(decoded.provenance?.modelName == "claude-opus-4")
        #expect(decoded.provenance?.promptType == .generation)
    }

    @Test("PlanVersion without provenance decodes with nil provenance")
    func versionNoProvenanceCodable() throws {
        let version = PlanVersion(
            planId: UUID(),
            content: "test",
            roundNumber: 1,
            changeDescription: "Manual"
        )

        let data = try JSONEncoder().encode(version)
        let decoded = try JSONDecoder().decode(PlanVersion.self, from: data)

        #expect(decoded.provenance == nil)
    }
}

// MARK: - Convergence Metrics Tests

@Suite("ConvergenceMetricsBackfill")
struct ConvergenceMetricsBackfillTests {
    @Test("Identical versions produce a fully converged score")
    func identicalVersionsFullyConverged() {
        let planId = UUID()
        let previous = PlanVersion(
            planId: planId,
            content: "# Plan\n\nStable content",
            roundNumber: 1,
            changeDescription: "Initial"
        )
        let current = PlanVersion(
            planId: planId,
            content: "# Plan\n\nStable content",
            roundNumber: 2,
            changeDescription: "No-op revision"
        )

        let metrics = ConvergenceVersionPairMetrics(previous: previous, current: current)

        #expect(metrics.sizeDelta == 0)
        #expect(metrics.changeVelocity == 0)
        #expect(metrics.contentSimilarity == 1)
        #expect(metrics.compositeScore == 1)
    }

    @Test("ConvergenceTracker backfills missing metrics lazily")
    func trackerBackfillsMissingMetrics() {
        let plan = PlanDocument(content: "Current")
        let v1 = PlanVersion(
            planId: plan.id,
            content: "alpha beta",
            roundNumber: 1,
            changeDescription: "v1"
        )
        let v2 = PlanVersion(
            planId: plan.id,
            content: "alpha beta gamma",
            roundNumber: 2,
            changeDescription: "v2"
        )
        let v3 = PlanVersion(
            planId: plan.id,
            content: "alpha beta gamma delta",
            roundNumber: 3,
            changeDescription: "v3"
        )
        plan.versions = [v1, v2, v3]
        plan.convergenceMetrics = []

        let tracker = ConvergenceTracker()
        let metrics = tracker.computeAllMetrics(for: plan)

        #expect(plan.convergenceMetrics.count == 2)
        #expect(metrics.count == 2)
        #expect(metrics.last?.currentRoundNumber == 3)
        #expect(tracker.latestConvergenceScore(for: plan) != nil)
        #expect(tracker.hasConverged(plan: plan, threshold: 0) == true)
    }
}

// MARK: - PlanMetadata Tests (BUG FIX: lastModelUsed was always nil)

@Suite("PlanMetadata")
struct PlanMetadataTests {
    @Test("lastModelUsed derives from last version with provenance")
    func lastModelUsedFromProvenance() {
        let plan = PlanDocument(content: "# Plan\n\nContent here.")
        let v1 = PlanVersion(
            planId: plan.id,
            content: "v1",
            roundNumber: 1,
            changeDescription: "Gen",
            provenance: VersionProvenance(modelName: "gpt-4o", promptType: .generation)
        )
        let v2 = PlanVersion(
            planId: plan.id,
            content: "v2",
            roundNumber: 2,
            changeDescription: "Refine",
            provenance: VersionProvenance(modelName: "claude-opus-4", promptType: .refinement)
        )
        plan.versions = [v1, v2]

        #expect(plan.metadata.lastModelUsed == "claude-opus-4")
    }

    @Test("lastModelUsed is nil when no versions have provenance")
    func lastModelUsedNilWithoutProvenance() {
        let plan = PlanDocument(content: "content")
        plan.snapshot(changeDescription: "Manual save")
        // snapshot() creates versions without provenance
        #expect(plan.metadata.lastModelUsed == nil)
    }

    @Test("lastModelUsed skips versions without provenance to find last model")
    func lastModelUsedSkipsNilProvenance() {
        let plan = PlanDocument(content: "content")
        let v1 = PlanVersion(
            planId: plan.id, content: "v1", roundNumber: 1,
            changeDescription: "Gen",
            provenance: VersionProvenance(modelName: "gemini-pro", promptType: .generation)
        )
        let v2 = PlanVersion(
            planId: plan.id, content: "v2", roundNumber: 2,
            changeDescription: "Manual", provenance: nil
        )
        plan.versions = [v1, v2]

        // Should find gemini-pro (last version WITH provenance), not nil
        #expect(plan.metadata.lastModelUsed == "gemini-pro")
    }

    @Test("wordCount counts whitespace-separated tokens")
    func wordCount() {
        let meta = PlanMetadata(content: "Hello world, this is a test.", versions: [])
        #expect(meta.wordCount == 6)
    }

    @Test("wordCount is zero for empty string")
    func wordCountEmpty() {
        let meta = PlanMetadata(content: "", versions: [])
        #expect(meta.wordCount == 0)
    }

    @Test("sectionCount counts markdown headings")
    func sectionCount() {
        let content = """
        # Title
        Some text.
        ## Section A
        More text.
        ### Subsection
        Even more.
        """
        let meta = PlanMetadata(content: content, versions: [])
        #expect(meta.sectionCount == 3)
    }

    @Test("refinementRounds equals version count")
    func refinementRounds() {
        let versions = (1...5).map { i in
            PlanVersion(planId: UUID(), content: "v\(i)", roundNumber: i, changeDescription: "r\(i)")
        }
        let meta = PlanMetadata(content: "x", versions: versions)
        #expect(meta.refinementRounds == 5)
    }
}
