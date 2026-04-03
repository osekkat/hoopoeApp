import Foundation
import Observation

/// Manages version creation for plan documents with configurable limits and model provenance.
///
/// Versions are created at intentional milestones (refinement rounds, synthesis, manual save),
/// NOT on auto-save. The manager coordinates with PlanStore to persist versions in sidecar JSON.
@Observable
final class PlanVersionManager {
    /// Maximum number of versions to retain per plan. Oldest versions are evicted first.
    var maxVersionsPerPlan: Int = 50
    /// Centralized weights so the convergence formula is easy to tune in one place.
    var convergenceWeights: ConvergenceWeights = .default

    private let store: PlanStore

    init(store: PlanStore) {
        self.store = store
    }

    // MARK: - Version Creation

    /// Creates a version snapshot for a plan after a refinement round completes.
    @discardableResult
    func createVersion(
        for plan: PlanDocument,
        description: String,
        provenance: VersionProvenance? = nil
    ) -> PlanVersion {
        let version = PlanVersion(
            planId: plan.id,
            content: plan.content,
            roundNumber: plan.versions.count + 1,
            changeDescription: description,
            provenance: provenance
        )

        plan.appendVersion(version, convergenceWeights: convergenceWeights)

        // Enforce version limit
        enforceLimit(for: plan)

        // Persist immediately
        try? store.save(plan)

        return version
    }

    /// Creates a version from an LLM refinement round.
    @discardableResult
    func createRefinementVersion(
        for plan: PlanDocument,
        modelName: String,
        description: String
    ) -> PlanVersion {
        createVersion(
            for: plan,
            description: description,
            provenance: VersionProvenance(modelName: modelName, promptType: .refinement)
        )
    }

    /// Creates a version from initial plan generation.
    @discardableResult
    func createGenerationVersion(
        for plan: PlanDocument,
        modelName: String,
        description: String = "Initial generation"
    ) -> PlanVersion {
        createVersion(
            for: plan,
            description: description,
            provenance: VersionProvenance(modelName: modelName, promptType: .generation)
        )
    }

    /// Creates a version from multi-model synthesis.
    @discardableResult
    func createSynthesisVersion(
        for plan: PlanDocument,
        modelName: String,
        description: String = "Multi-model synthesis"
    ) -> PlanVersion {
        createVersion(
            for: plan,
            description: description,
            provenance: VersionProvenance(modelName: modelName, promptType: .synthesis)
        )
    }

    /// Creates a manual version snapshot (user-initiated "Save Version").
    @discardableResult
    func createManualVersion(
        for plan: PlanDocument,
        description: String = "Manual snapshot"
    ) -> PlanVersion {
        createVersion(
            for: plan,
            description: description,
            provenance: VersionProvenance(modelName: "user", promptType: .manual)
        )
    }

    // MARK: - Version Queries

    /// Returns all versions for a plan, newest first.
    func getVersions(for plan: PlanDocument) -> [PlanVersion] {
        plan.versions.sorted { $0.createdAt > $1.createdAt }
    }

    /// Returns a specific version by ID.
    func getVersion(id: UUID, in plan: PlanDocument) -> PlanVersion? {
        plan.versions.first { $0.id == id }
    }

    /// Returns the most recent version for a plan.
    func latestVersion(for plan: PlanDocument) -> PlanVersion? {
        plan.versions.max(by: { $0.roundNumber < $1.roundNumber })
    }

    /// Restores a plan's content to a previous version and records the restore as a new snapshot.
    @discardableResult
    func restore(_ version: PlanVersion, in plan: PlanDocument) -> PlanVersion {
        if plan.isDirty {
            createVersion(
                for: plan,
                description: "Before restore to round \(version.roundNumber)",
                provenance: VersionProvenance(modelName: "user", promptType: .manual)
            )
        }

        plan.content = version.content
        return createVersion(
            for: plan,
            description: "Restored from round \(version.roundNumber)",
            provenance: VersionProvenance(modelName: "user", promptType: .manual)
        )
    }

    // MARK: - Limit Enforcement

    private func enforceLimit(for plan: PlanDocument) {
        guard plan.versions.count > maxVersionsPerPlan else { return }
        let excess = plan.versions.count - maxVersionsPerPlan
        // Remove oldest versions (lowest round numbers)
        let sorted = plan.versions.sorted { $0.roundNumber < $1.roundNumber }
        let toRemove = Set(sorted.prefix(excess).map(\.id))
        plan.versions.removeAll { toRemove.contains($0.id) }
        plan.rebuildConvergenceMetrics(weights: convergenceWeights)
    }
}
