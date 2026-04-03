import Foundation
import Observation

// MARK: - Plan Type

/// Categorizes a plan as either the master plan or a feature-specific sub-plan.
enum PlanType: Codable, Sendable, Hashable {
    case master
    case feature(name: String)
}

// MARK: - Plan Document

/// The central data model for a plan in Phase 0.
///
/// `PlanDocument` holds raw markdown content and version history.
/// The typed Plan AST (stable section IDs, structural parsing) is deferred to Phase 1.
///
/// This is an `@Observable` reference type so SwiftUI views can bind to property changes.
/// It is intended to be accessed exclusively from `@MainActor` contexts.
@Observable
final class PlanDocument: Identifiable {
    let id: UUID
    var title: String
    var content: String
    var type: PlanType
    var createdAt: Date
    var updatedAt: Date
    var filePath: URL?
    var versions: [PlanVersion]
    var convergenceMetrics: [ConvergenceVersionPairMetrics]

    /// Whether the current content differs from the most recent saved version.
    var isDirty: Bool {
        guard let lastVersion = versions.last else {
            return !content.isEmpty
        }
        return content != lastVersion.content
    }

    /// Computed metadata derived from the current content and version history.
    var metadata: PlanMetadata {
        let lastModel = versions.last(where: { $0.provenance != nil })?.provenance?.modelName
        return PlanMetadata(content: content, versions: versions, lastModelUsed: lastModel)
    }

    init(
        id: UUID = UUID(),
        title: String = "Untitled Plan",
        content: String = "",
        type: PlanType = .master,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        filePath: URL? = nil,
        versions: [PlanVersion] = [],
        convergenceMetrics: [ConvergenceVersionPairMetrics] = []
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.type = type
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.filePath = filePath
        self.versions = versions
        self.convergenceMetrics = convergenceMetrics
    }

    /// Captures a full snapshot of the current content as a new version.
    func snapshot(
        changeDescription: String,
        convergenceWeights: ConvergenceWeights = .default
    ) {
        let version = PlanVersion(
            planId: id,
            content: content,
            roundNumber: versions.count + 1,
            changeDescription: changeDescription
        )
        appendVersion(version, convergenceWeights: convergenceWeights)
    }

    func appendVersion(
        _ version: PlanVersion,
        convergenceWeights: ConvergenceWeights = .default
    ) {
        let normalizedWeights = convergenceWeights.normalized
        if needsConvergenceMetricsRefresh(weights: normalizedWeights) {
            rebuildConvergenceMetrics(weights: normalizedWeights)
        }

        if let previousVersion = versions.last {
            let metric = ConvergenceVersionPairMetrics(
                previous: previousVersion,
                current: version,
                weights: normalizedWeights
            )
            convergenceMetrics.removeAll { $0.currentVersionId == version.id }
            convergenceMetrics.append(metric)
        }

        versions.append(version)
        updatedAt = Date()
    }

    func metrics(for version: PlanVersion) -> ConvergenceVersionPairMetrics? {
        convergenceMetrics.first { $0.currentVersionId == version.id }
    }

    func latestConvergenceMetrics() -> ConvergenceVersionPairMetrics? {
        convergenceMetrics.max { $0.currentRoundNumber < $1.currentRoundNumber }
    }

    func rebuildConvergenceMetrics(weights: ConvergenceWeights = .default) {
        let normalizedWeights = weights.normalized
        guard versions.count >= 2 else {
            convergenceMetrics = []
            return
        }

        convergenceMetrics = zip(versions, versions.dropFirst()).map { previousVersion, currentVersion in
            ConvergenceVersionPairMetrics(
                previous: previousVersion,
                current: currentVersion,
                weights: normalizedWeights
            )
        }
    }

    func needsConvergenceMetricsRefresh(weights: ConvergenceWeights = .default) -> Bool {
        let normalizedWeights = weights.normalized
        let expectedMetricCount = max(versions.count - 1, 0)
        guard convergenceMetrics.count == expectedMetricCount else {
            return true
        }

        guard versions.count >= 2 else {
            return !convergenceMetrics.isEmpty
        }

        for index in convergenceMetrics.indices {
            let metric = convergenceMetrics[index]
            let previousVersion = versions[index]
            let currentVersion = versions[index + 1]

            if metric.previousVersionId != previousVersion.id ||
                metric.currentVersionId != currentVersion.id ||
                metric.weights != normalizedWeights
            {
                return true
            }
        }

        return false
    }
}

// MARK: - PlanDocument + Codable

extension PlanDocument: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, content, type, createdAt, updatedAt, filePath, versions, convergenceMetrics
    }

    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            content: try container.decode(String.self, forKey: .content),
            type: try container.decode(PlanType.self, forKey: .type),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            filePath: try container.decodeIfPresent(URL.self, forKey: .filePath),
            versions: try container.decode([PlanVersion].self, forKey: .versions),
            convergenceMetrics: try container.decodeIfPresent(
                [ConvergenceVersionPairMetrics].self,
                forKey: .convergenceMetrics
            ) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        try container.encode(type, forKey: .type)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(filePath, forKey: .filePath)
        try container.encode(versions, forKey: .versions)
        try container.encode(convergenceMetrics, forKey: .convergenceMetrics)
    }
}

// MARK: - Plan Version

/// An immutable snapshot of plan content at a specific refinement round.
///
/// Stores the full content (not a diff) for simplicity in Phase 0.
/// Diff computation happens at display time when comparing versions.
struct PlanVersion: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let planId: UUID
    let content: String
    let createdAt: Date
    let roundNumber: Int
    let changeDescription: String
    let provenance: VersionProvenance?

    init(
        id: UUID = UUID(),
        planId: UUID,
        content: String,
        createdAt: Date = Date(),
        roundNumber: Int,
        changeDescription: String,
        provenance: VersionProvenance? = nil
    ) {
        self.id = id
        self.planId = planId
        self.content = content
        self.createdAt = createdAt
        self.roundNumber = roundNumber
        self.changeDescription = changeDescription
        self.provenance = provenance
    }
}

// MARK: - Version Provenance

/// Tracks which LLM model produced a version and the operation type.
struct VersionProvenance: Codable, Sendable, Hashable {
    let modelName: String
    let promptType: PromptType

    enum PromptType: String, Codable, Sendable, Hashable {
        case generation
        case refinement
        case synthesis
        case manual
    }
}

// MARK: - Convergence Metrics

struct ConvergenceWeights: Codable, Sendable, Hashable {
    let sizeDeltaWeight: Double
    let similarityWeight: Double
    let velocityWeight: Double

    static let `default` = ConvergenceWeights(
        sizeDeltaWeight: 0.3,
        similarityWeight: 0.4,
        velocityWeight: 0.3
    )

    var normalized: ConvergenceWeights {
        let totalWeight = sizeDeltaWeight + similarityWeight + velocityWeight
        guard totalWeight > 0 else { return .default }
        return ConvergenceWeights(
            sizeDeltaWeight: sizeDeltaWeight / totalWeight,
            similarityWeight: similarityWeight / totalWeight,
            velocityWeight: velocityWeight / totalWeight
        )
    }
}

struct ConvergenceVersionPairMetrics: Identifiable, Codable, Sendable, Hashable {
    let previousVersionId: UUID
    let currentVersionId: UUID
    let previousRoundNumber: Int
    let currentRoundNumber: Int
    let previousWordCount: Int
    let currentWordCount: Int
    let sizeDelta: Double
    let changeVelocity: Double
    let contentSimilarity: Double
    let compositeScore: Double
    let weights: ConvergenceWeights

    var id: UUID { currentVersionId }

    init(
        previous: PlanVersion,
        current: PlanVersion,
        weights: ConvergenceWeights = .default
    ) {
        let normalizedWeights = weights.normalized
        let previousWordCount = Self.wordCount(in: previous.content)
        let currentWordCount = Self.wordCount(in: current.content)
        let sizeDelta = Self.computeSizeDelta(
            previousWordCount: previousWordCount,
            currentWordCount: currentWordCount
        )
        let changeVelocity = Self.computeChangeVelocity(
            previousContent: previous.content,
            currentContent: current.content
        )
        let contentSimilarity = Self.computeContentSimilarity(
            previousContent: previous.content,
            currentContent: current.content
        )

        self.previousVersionId = previous.id
        self.currentVersionId = current.id
        self.previousRoundNumber = previous.roundNumber
        self.currentRoundNumber = current.roundNumber
        self.previousWordCount = previousWordCount
        self.currentWordCount = currentWordCount
        self.sizeDelta = sizeDelta
        self.changeVelocity = changeVelocity
        self.contentSimilarity = contentSimilarity
        self.compositeScore = Self.computeCompositeScore(
            sizeDelta: sizeDelta,
            changeVelocity: changeVelocity,
            contentSimilarity: contentSimilarity,
            weights: normalizedWeights
        )
        self.weights = normalizedWeights
    }

    private static func computeSizeDelta(
        previousWordCount: Int,
        currentWordCount: Int
    ) -> Double {
        guard previousWordCount > 0 else {
            return currentWordCount == 0 ? 0 : 1
        }

        return abs(Double(currentWordCount - previousWordCount)) / Double(previousWordCount)
    }

    private static func computeChangeVelocity(
        previousContent: String,
        currentContent: String
    ) -> Double {
        let previousLines = normalizedLines(from: previousContent)
        let currentLines = normalizedLines(from: currentContent)
        let baseline = max(previousLines.count, currentLines.count, 1)
        let difference = currentLines.difference(from: previousLines)
        let changedLineCount = difference.reduce(into: 0) { count, _ in
            count += 1
        }

        return clamp(Double(changedLineCount) / Double(baseline))
    }

    private static func computeContentSimilarity(
        previousContent: String,
        currentContent: String
    ) -> Double {
        let previousWords = normalizedWordSet(from: previousContent)
        let currentWords = normalizedWordSet(from: currentContent)

        if previousWords.isEmpty && currentWords.isEmpty {
            return 1
        }

        let union = previousWords.union(currentWords)
        guard !union.isEmpty else { return 1 }

        return Double(previousWords.intersection(currentWords).count) / Double(union.count)
    }

    private static func computeCompositeScore(
        sizeDelta: Double,
        changeVelocity: Double,
        contentSimilarity: Double,
        weights: ConvergenceWeights
    ) -> Double {
        let normalizedWeights = weights.normalized
        let sizeStability = 1 - min(sizeDelta, 1)
        let velocityStability = 1 - min(changeVelocity, 1)

        return clamp(
            (normalizedWeights.sizeDeltaWeight * sizeStability) +
                (normalizedWeights.similarityWeight * contentSimilarity) +
                (normalizedWeights.velocityWeight * velocityStability)
        )
    }

    private static func wordCount(in content: String) -> Int {
        content.split(whereSeparator: \.isWhitespace).count
    }

    private static func normalizedLines(from content: String) -> [String] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        if normalized.hasSuffix("\n"), lines.last == "" {
            lines.removeLast()
        }

        return lines
    }

    private static func normalizedWordSet(from content: String) -> Set<String> {
        Set(
            content.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

// MARK: - Plan Metadata

/// Computed metadata derived from plan content and version history.
///
/// This is a value type recomputed on demand, not persisted.
struct PlanMetadata: Sendable {
    let wordCount: Int
    let sectionCount: Int
    let refinementRounds: Int
    let lastModelUsed: String?

    init(content: String, versions: [PlanVersion], lastModelUsed: String? = nil) {
        self.wordCount = content.split(whereSeparator: \.isWhitespace).count
        // Count markdown headings (lines starting with #)
        self.sectionCount = content.components(separatedBy: "\n")
            .filter { $0.hasPrefix("#") }
            .count
        self.refinementRounds = versions.count
        self.lastModelUsed = lastModelUsed
    }
}
