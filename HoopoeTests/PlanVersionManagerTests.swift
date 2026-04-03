import Foundation
import Testing

@testable import Hoopoe

// MARK: - PlanVersionManager Tests

@Suite("PlanVersionManager")
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

    @Test("restore sets content to version content and creates backup snapshot")
    func restoreCreatesBackup() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        let plan = store.createPlan(title: "Test", content: "original")

        let v1 = manager.createVersion(for: plan, description: "v1")
        plan.content = "modified"
        manager.createVersion(for: plan, description: "v2")

        let countBefore = plan.versions.count
        manager.restore(v1, in: plan)

        // Content should be restored to v1's content
        #expect(plan.content == "original")
        // A backup snapshot should have been created before restoring
        #expect(plan.versions.count == countBefore + 1)
        // The backup is the last version added by restore() — it captured
        // the pre-restore content ("modified") before overwriting
        let backup = plan.versions[plan.versions.count - 1]
        #expect(backup.changeDescription.contains("Before restore"))
        #expect(backup.content == "modified")
    }

    @Test("restore backup is the last element, not second-to-last (regression)")
    func restoreBackupIsLastElement() {
        let store = makeStore()
        let manager = PlanVersionManager(store: store)
        let plan = store.createPlan(title: "Test", content: "A")

        let v1 = manager.createVersion(for: plan, description: "v1")
        plan.content = "B"
        manager.createVersion(for: plan, description: "v2")
        plan.content = "C"
        manager.createVersion(for: plan, description: "v3")

        // Restore to v1. restore() adds exactly ONE backup version,
        // so the backup must be at the very end of the array.
        manager.restore(v1, in: plan)

        let lastVersion = plan.versions.last!
        #expect(lastVersion.changeDescription.contains("Before restore"))
        #expect(lastVersion.content == "C") // captured pre-restore content

        // The version BEFORE the backup must be v3, not the backup
        let secondToLast = plan.versions[plan.versions.count - 2]
        #expect(secondToLast.changeDescription == "v3")
    }
}
