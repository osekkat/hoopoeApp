import Foundation
import Testing

@testable import Hoopoe

// MARK: - PlanStore Tests (BUG FIX: save() error propagation)

@Suite("PlanStore")
struct PlanStoreTests {
    /// Creates a temporary directory for each test, cleaned up after.
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoopoeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try body(tmp)
    }

    /// Async variant for tests that need to await auto-save behavior.
    private func withTempDirAsync(_ body: (URL) async throws -> Void) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoopoeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await body(tmp)
    }

    private func readData(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }

    // MARK: - Save & Load Round-Trip

    @Test("Save and load round-trip preserves plan data")
    func saveLoadRoundTrip() throws {
        try withTempDir { dir in
            let store = PlanStore(directory: dir)
            let plan = store.createPlan(title: "My Plan", content: "# Hello\n\nWorld.")

            try store.save(plan)

            // Verify files exist
            let mdPath = dir.appendingPathComponent("My Plan.md")
            let metaPath = dir.appendingPathComponent(".My Plan-meta.json")
            #expect(FileManager.default.fileExists(atPath: mdPath.path))
            #expect(FileManager.default.fileExists(atPath: metaPath.path))

            // Load into a fresh store
            let store2 = PlanStore(directory: dir)
            try store2.loadAll()
            #expect(store2.plans.count == 1)
            #expect(store2.plans[0].title == "My Plan")
            #expect(store2.plans[0].content == "# Hello\n\nWorld.")
            #expect(store2.plans[0].id == plan.id)
        }
    }

    @Test("Save preserves version history in sidecar JSON")
    func savePreservesVersions() throws {
        try withTempDir { dir in
            let store = PlanStore(directory: dir)
            let plan = store.createPlan(title: "Versioned", content: "v1")
            plan.snapshot(changeDescription: "Initial")
            plan.content = "v2"
            plan.snapshot(changeDescription: "Refined")

            try store.save(plan)

            let store2 = PlanStore(directory: dir)
            try store2.loadAll()
            #expect(store2.plans[0].versions.count == 2)
            #expect(store2.plans[0].versions[0].content == "v1")
            #expect(store2.plans[0].versions[1].content == "v2")
        }
    }

    @Test("Save preserves convergence metrics in sidecar JSON")
    func savePreservesConvergenceMetrics() throws {
        try withTempDir { dir in
            let store = PlanStore(directory: dir)
            let plan = store.createPlan(title: "Metrics", content: "one two")
            plan.snapshot(changeDescription: "Initial")
            plan.content = "one two three"
            plan.snapshot(changeDescription: "Expanded")

            try store.save(plan)

            let store2 = PlanStore(directory: dir)
            try store2.loadAll()

            #expect(store2.plans[0].convergenceMetrics.count == 1)
            let metric = store2.plans[0].convergenceMetrics[0]
            #expect(metric.previousRoundNumber == 1)
            #expect(metric.currentRoundNumber == 2)
            #expect(abs(metric.sizeDelta - 0.5) < 0.000_1)
        }
    }

    @Test("Load tolerates legacy sidecar metadata without convergence metrics")
    func loadLegacySidecarWithoutConvergenceMetrics() throws {
        try withTempDir { dir in
            let store = PlanStore(directory: dir)
            let plan = store.createPlan(title: "Legacy", content: "one two")
            plan.snapshot(changeDescription: "Initial")
            plan.content = "one two three"
            plan.snapshot(changeDescription: "Expanded")
            try store.save(plan)

            let metaPath = dir.appendingPathComponent(".Legacy-meta.json")
            var object = try #require(
                JSONSerialization.jsonObject(
                    with: try readData(from: metaPath)
                ) as? [String: Any]
            )
            object.removeValue(forKey: "convergenceMetrics")
            let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try legacyData.write(to: metaPath, options: .atomic)

            let store2 = PlanStore(directory: dir)
            try store2.loadAll()

            #expect(store2.plans.count == 1)
            #expect(store2.plans[0].convergenceMetrics.isEmpty)
            #expect(store2.plans[0].versions.count == 2)
        }
    }

    @Test("Save preserves version provenance in sidecar JSON")
    func savePreservesProvenance() throws {
        try withTempDir { dir in
            let store = PlanStore(directory: dir)
            let plan = store.createPlan(title: "WithProv", content: "content")

            let version = PlanVersion(
                planId: plan.id,
                content: "content",
                roundNumber: 1,
                changeDescription: "Gen",
                provenance: VersionProvenance(modelName: "claude-opus-4", promptType: .generation)
            )
            plan.versions.append(version)

            try store.save(plan)

            let store2 = PlanStore(directory: dir)
            try store2.loadAll()
            let loaded = store2.plans[0]
            #expect(loaded.versions[0].provenance?.modelName == "claude-opus-4")
            #expect(loaded.versions[0].provenance?.promptType == .generation)
        }
    }

    @Test("Save refreshes updatedAt before writing sidecar metadata")
    func saveRefreshesUpdatedAtBeforeEncodingMetadata() throws {
        try withTempDir { dir in
            let store = PlanStore(directory: dir)
            let plan = store.createPlan(title: "Timestamped", content: "snapshot")
            let staleDate = Date(timeIntervalSince1970: 123)
            plan.updatedAt = staleDate

            try store.save(plan)

            let store2 = PlanStore(directory: dir)
            try store2.loadAll()
            #expect(store2.plans[0].updatedAt > staleDate)
        }
    }

    // MARK: - Error Propagation (BUG FIX)

    @Test("Save throws when writing to a read-only directory")
    func saveThrowsOnReadOnlyDirectory() throws {
        try withTempDir { dir in
            let readOnlyDir = dir.appendingPathComponent("readonly", isDirectory: true)
            try FileManager.default.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)

            // Make directory read-only
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o444],
                ofItemAtPath: readOnlyDir.path
            )
            defer {
                // Restore permissions for cleanup
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: readOnlyDir.path
                )
            }

            let store = PlanStore(directory: readOnlyDir)
            let plan = PlanDocument(title: "Fail", content: "Should fail")
            plan.filePath = readOnlyDir.appendingPathComponent("Fail.md")

            // Before the fix, this would silently succeed.
            // After the fix, it must throw.
            #expect(throws: PlanStoreError.self) {
                try store.save(plan)
            }

            // Verify lastError is also set
            #expect(store.lastError != nil)
        }
    }

    @Test("Save propagates inner write error, not just coordinator error")
    func saveInnerWriteErrorPropagated() throws {
        try withTempDir { dir in
            let store = PlanStore(directory: dir)
            let plan = store.createPlan(title: "Test", content: "data")

            // Point the plan's filePath into a nonexistent subdirectory.
            // The NSFileCoordinator will coordinate access (no coordinator error),
            // but the actual write inside the closure will fail because the
            // parent directory doesn't exist.
            let ghostDir = dir.appendingPathComponent("does-not-exist", isDirectory: true)
            plan.filePath = ghostDir.appendingPathComponent("Test.md")

            // Before the fix, this inner write error was silently swallowed.
            // After the fix, it must propagate as a thrown PlanStoreError.
            #expect(throws: PlanStoreError.self) {
                try store.save(plan)
            }

            #expect(store.lastError != nil)
        }
    }

    // MARK: - Load Without Sidecar

    @Test("Load plan without sidecar creates fresh metadata from file attributes")
    func loadWithoutSidecar() throws {
        try withTempDir { dir in
            // Write a bare .md file with no sidecar
            let mdPath = dir.appendingPathComponent("Bare Plan.md")
            try "# Bare Plan\n\nNo metadata.".write(to: mdPath, atomically: true, encoding: .utf8)

            let store = PlanStore(directory: dir)
            try store.loadAll()

            #expect(store.plans.count == 1)
            #expect(store.plans[0].title == "Bare Plan")
            #expect(store.plans[0].content == "# Bare Plan\n\nNo metadata.")
            #expect(store.plans[0].versions.isEmpty)
            #expect(store.plans[0].type == .master) // default type
        }
    }

    // MARK: - Delete

    @Test("Delete removes both .md and sidecar files")
    func deleteRemovesFiles() throws {
        try withTempDir { dir in
            let store = PlanStore(directory: dir)
            let plan = store.createPlan(title: "Doomed", content: "bye")
            try store.save(plan)

            let mdPath = dir.appendingPathComponent("Doomed.md")
            let metaPath = dir.appendingPathComponent(".Doomed-meta.json")
            #expect(FileManager.default.fileExists(atPath: mdPath.path))
            #expect(FileManager.default.fileExists(atPath: metaPath.path))

            try store.delete(plan)

            #expect(!FileManager.default.fileExists(atPath: mdPath.path))
            #expect(!FileManager.default.fileExists(atPath: metaPath.path))
            #expect(store.plans.isEmpty)
        }
    }

    // MARK: - Title Sanitization

    @Test("Save sanitizes slashes in plan title for filename")
    func saveSanitizesTitle() throws {
        try withTempDir { dir in
            let store = PlanStore(directory: dir)
            let plan = store.createPlan(title: "Phase 1/2 Plan", content: "ok")
            try store.save(plan)

            let expected = dir.appendingPathComponent("Phase 1-2 Plan.md")
            #expect(FileManager.default.fileExists(atPath: expected.path))
        }
    }

    // MARK: - Create

    @Test("createPlan adds to beginning of plans array")
    func createPlanInsertsAtFront() {
        let store = PlanStore(directory: FileManager.default.temporaryDirectory)
        let first = store.createPlan(title: "First")
        let second = store.createPlan(title: "Second")
        #expect(store.plans[0].id == second.id)
        #expect(store.plans[1].id == first.id)
    }

    @Test("createPlan supports explicit ids for stable routing")
    func createPlanSupportsExplicitIDs() {
        let store = PlanStore(directory: FileManager.default.temporaryDirectory)
        let fixedID = UUID()
        let plan = store.createPlan(id: fixedID, title: "Stable")

        #expect(plan.id == fixedID)
        #expect(store.plans[0].id == fixedID)
    }

    @Test("Auto-save starts during initialization when enabled")
    func autoSaveStartsDuringInitialization() async throws {
        try await withTempDirAsync { dir in
            let store = PlanStore(directory: dir, autoSaveInterval: 0.05)
            _ = store.createPlan(title: "AutoSaved", content: "# Draft")

            try await Task.sleep(for: .milliseconds(250))

            let mdPath = dir.appendingPathComponent("AutoSaved.md")
            #expect(FileManager.default.fileExists(atPath: mdPath.path))
            store.stopAutoSave()
        }
    }
}
