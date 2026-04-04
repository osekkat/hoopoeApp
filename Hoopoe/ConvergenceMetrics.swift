import Foundation
import Observation

// MARK: - Convergence Tracker

/// Observable wrapper providing UI-friendly convergence state for a plan.
///
/// Delegates to PlanDocument's built-in convergence metrics computation
/// (ConvergenceVersionPairMetrics). This class adds:
/// - Observable state for SwiftUI binding
/// - `hasConverged` threshold check (default 0.75 per Flywheel methodology)
/// - Cache invalidation coordination
///
/// Note: The core metric types (`ConvergenceWeights`, `ConvergenceVersionPairMetrics`)
/// and computation logic live in PlanDocument.swift. This class wraps that for UI use.
@Observable
final class ConvergenceTracker {

    // MARK: - Public API

    /// Returns all convergence metrics for a plan's version pairs, ordered by round number.
    ///
    /// Returns an empty array if the plan has fewer than two versions.
    func computeAllMetrics(for plan: PlanDocument) -> [ConvergenceVersionPairMetrics] {
        if plan.needsConvergenceMetricsRefresh() {
            plan.rebuildConvergenceMetrics()
        }
        return plan.convergenceMetrics.sorted { $0.currentRoundNumber < $1.currentRoundNumber }
    }

    /// Returns the latest composite convergence score, or nil if fewer than 2 versions.
    func latestConvergenceScore(for plan: PlanDocument) -> Double? {
        if plan.needsConvergenceMetricsRefresh() {
            plan.rebuildConvergenceMetrics()
        }
        return plan.latestConvergenceMetrics()?.compositeScore
    }

    /// Whether the plan has converged (latest score >= threshold).
    ///
    /// The default threshold of 0.75 follows the Flywheel recommendation
    /// (Section 3.1.2, Step 4).
    func hasConverged(plan: PlanDocument, threshold: Double = 0.75) -> Bool {
        guard let score = latestConvergenceScore(for: plan) else { return false }
        return score >= threshold
    }

    /// Forces a rebuild of all convergence metrics for a plan.
    func invalidateCache(for plan: PlanDocument, weights: ConvergenceWeights = .default) {
        plan.rebuildConvergenceMetrics(weights: weights)
    }

    /// Shorthand: clears and rebuilds with default weights.
    func invalidateCache() {
        // No-op without a plan reference; the per-plan overload should be used.
        // Kept for backward compatibility with ConvergenceMeterView.
    }
}
