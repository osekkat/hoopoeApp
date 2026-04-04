import Foundation
import Testing

@testable import Hoopoe

// MARK: - PlanVersionManager Tests

@Suite("PlanVersionManager")
@MainActor
struct PlanVersionManagerTests {
    /// Creates a store in a temporary directory for testing.
    private func makeStore() -> PlanStore {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoopoeTests-\(UUID().uuidString)", isDirectory: true)
        return PlanStore(directory: tmp)
    }

    // MARK: - Version Creation

    @Test("createVersion appends version with correct round number")
    func createVersionRoundNumber() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        let plan = store.createPlan(title: "Test", content: "initial")

        manager.createVersion(for: plan, description: "First")
        manager.createVersion(for: plan, description: "Second")

        #expect(plan.versions.count == 2)
        #expect(plan.versions[0].roundNumber == 1)
        #expect(plan.versions[1].roundNumber == 2)
    }

    @Test("createVersion captures content at time of creation")
    func createVersionCapturesContent() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        let plan = store.createPlan(title: "Test", content: "version one")

        manager.createVersion(for: plan, description: "v1")
        plan.content = "version two"
        manager.createVersion(for: plan, description: "v2")

        #expect(plan.versions[0].content == "version one")
        #expect(plan.versions[1].content == "version two")
    }

    @Test("createVersion computes convergence metrics for the new version pair")
    func createVersionComputesConvergenceMetrics() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        let plan = store.createPlan(title: "Test", content: "alpha beta")

        manager.createVersion(for: plan, description: "v1")
        plan.content = "alpha beta gamma"
        let version = manager.createVersion(for: plan, description: "v2")

        #expect(plan.convergenceMetrics.count == 1)
        let metric = plan.metrics(for: version)
        #expect(metric?.previousRoundNumber == 1)
        #expect(metric?.currentRoundNumber == 2)
        #expect(metric?.previousWordCount == 2)
        #expect(metric?.currentWordCount == 3)
    }

    // MARK: - Provenance Tracking

    @Test("createRefinementVersion sets refinement provenance")
    func refinementProvenance() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        let plan = store.createPlan(title: "Test", content: "content")

        let version = manager.createRefinementVersion(
            for: plan, modelName: "claude-opus-4", description: "Refined"
        )

        #expect(version.provenance?.modelName == "claude-opus-4")
        #expect(version.provenance?.promptType == .refinement)
    }

    @Test("createGenerationVersion sets generation provenance")
    func generationProvenance() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        let plan = store.createPlan(title: "Test", content: "content")

        let version = manager.createGenerationVersion(
            for: plan, modelName: "gpt-4o"
        )

        #expect(version.provenance?.modelName == "gpt-4o")
        #expect(version.provenance?.promptType == .generation)
    }

    @Test("createSynthesisVersion sets synthesis provenance")
    func synthesisProvenance() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        let plan = store.createPlan(title: "Test", content: "content")

        let version = manager.createSynthesisVersion(
            for: plan, modelName: "gemini-pro"
        )

        #expect(version.provenance?.modelName == "gemini-pro")
        #expect(version.provenance?.promptType == .synthesis)
    }

    @Test("createManualVersion sets manual provenance with user model")
    func manualProvenance() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        let plan = store.createPlan(title: "Test", content: "content")

        let version = manager.createManualVersion(for: plan)

        #expect(version.provenance?.modelName == "user")
        #expect(version.provenance?.promptType == .manual)
    }

    // MARK: - Version Limit Enforcement

    @Test("enforceLimit evicts oldest versions when limit exceeded")
    func enforceLimitEvictsOldest() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        manager.maxVersionsPerPlan = 3

        let plan = store.createPlan(title: "Test", content: "c0")

        // Create 5 versions (limit is 3)
        for i in 1...5 {
            plan.content = "content \(i)"
            manager.createVersion(for: plan, description: "v\(i)")
        }

        #expect(plan.versions.count == 3)
        // Should have kept rounds 3, 4, 5 (newest)
        #expect(plan.versions[0].roundNumber == 3)
        #expect(plan.versions[1].roundNumber == 4)
        #expect(plan.versions[2].roundNumber == 5)
    }

    @Test("Newly created version is never evicted by enforceLimit")
    func newVersionNeverEvicted() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        manager.maxVersionsPerPlan = 2

        let plan = store.createPlan(title: "Test", content: "initial")

        manager.createVersion(for: plan, description: "v1")
        manager.createVersion(for: plan, description: "v2")
        let v3 = manager.createVersion(for: plan, description: "v3")

        // v3 should still be present (the newest should never be evicted)
        #expect(plan.versions.contains { $0.id == v3.id })
        #expect(plan.versions.count == 2)
    }

    @Test("enforceLimit rebuilds convergence metrics for retained versions only")
    func enforceLimitRebuildsConvergenceMetrics() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        manager.maxVersionsPerPlan = 2

        let plan = store.createPlan(title: "Test", content: "one")
        manager.createVersion(for: plan, description: "v1")
        plan.content = "one two"
        manager.createVersion(for: plan, description: "v2")
        plan.content = "one two three"
        manager.createVersion(for: plan, description: "v3")

        #expect(plan.versions.count == 2)
        #expect(plan.convergenceMetrics.count == 1)
        #expect(plan.convergenceMetrics[0].previousRoundNumber == 2)
        #expect(plan.convergenceMetrics[0].currentRoundNumber == 3)
    }

    // MARK: - Version Queries

    @Test("getVersions returns versions sorted by descending createdAt")
    func getVersionsNewestFirst() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        let plan = store.createPlan(title: "Test", content: "c")

        manager.createVersion(for: plan, description: "first")
        plan.content = "updated"
        manager.createVersion(for: plan, description: "second")

        let versions = manager.getVersions(for: plan)
        #expect(versions.count == 2)
        // Verify descending order: each createdAt >= next
        for i in 0..<(versions.count - 1) {
            #expect(versions[i].createdAt >= versions[i + 1].createdAt)
        }
        // The higher round number should be first (or tied)
        #expect(versions[0].roundNumber >= versions[1].roundNumber)
    }

    @Test("getVersion finds version by ID")
    func getVersionById() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        let plan = store.createPlan(title: "Test", content: "c")

        let v = manager.createVersion(for: plan, description: "target")

        let found = manager.getVersion(id: v.id, in: plan)
        #expect(found?.changeDescription == "target")
    }

    @Test("getVersion returns nil for unknown ID")
    func getVersionUnknownId() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        let plan = store.createPlan(title: "Test", content: "c")

        let found = manager.getVersion(id: UUID(), in: plan)
        #expect(found == nil)
    }

    @Test("latestVersion returns highest round number")
    func latestVersion() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        let plan = store.createPlan(title: "Test", content: "c")

        manager.createVersion(for: plan, description: "v1")
        manager.createVersion(for: plan, description: "v2")
        manager.createVersion(for: plan, description: "v3")

        let latest = manager.latestVersion(for: plan)
        #expect(latest?.roundNumber == 3)
        #expect(latest?.changeDescription == "v3")
    }

    // MARK: - Restore

    @Test("restore appends backup and restored versions when current draft is dirty")
    func restoreCreatesBackupAndRestoredVersion() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        let plan = store.createPlan(title: "Test", content: "original")

        let v1 = manager.createVersion(for: plan, description: "v1")
        plan.content = "modified"
        manager.createVersion(for: plan, description: "v2")
        plan.content = "unsaved draft"

        let countBefore = plan.versions.count
        let restored = manager.restore(v1, in: plan)

        #expect(plan.content == "original")
        #expect(plan.versions.count == countBefore + 2)

        let backup = plan.versions[plan.versions.count - 2]
        #expect(backup.changeDescription.contains("Before restore"))
        #expect(backup.content == "unsaved draft")

        let restoredVersion = plan.versions.last!
        #expect(restoredVersion.id == restored.id)
        #expect(restoredVersion.changeDescription == "Restored from round 1")
        #expect(restoredVersion.content == "original")
    }

    @Test("restore appends only the restored version when current content already matches the latest snapshot")
    func restoreWithoutDirtyDraftAvoidsRedundantBackup() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        let plan = store.createPlan(title: "Test", content: "A")

        let v1 = manager.createVersion(for: plan, description: "v1")
        plan.content = "B"
        manager.createVersion(for: plan, description: "v2")

        let countBefore = plan.versions.count
        let restored = manager.restore(v1, in: plan)

        #expect(plan.content == "A")
        #expect(plan.versions.count == countBefore + 1)
        #expect(plan.versions.last?.id == restored.id)
        #expect(plan.versions.last?.changeDescription == "Restored from round 1")
    }

    @Test("restore records an explicit restore when dirty draft already matches target version")
    func restoreDirtyDraftMatchingTargetCreatesSingleRestoreVersion() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        let plan = store.createPlan(title: "Test", content: "A")

        let v1 = manager.createVersion(for: plan, description: "v1")
        plan.content = "B"
        manager.createVersion(for: plan, description: "v2")
        plan.content = "A"

        let countBefore = plan.versions.count
        let restored = manager.restore(v1, in: plan)

        #expect(plan.content == "A")
        #expect(plan.versions.count == countBefore + 1)
        #expect(plan.versions.last?.id == restored.id)
        #expect(plan.versions.last?.changeDescription == "Restored from round 1")
        #expect(plan.versions.filter { $0.changeDescription.contains("Before restore") }.isEmpty)
    }
}
