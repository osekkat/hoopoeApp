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
        versions: [PlanVersion] = []
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.type = type
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.filePath = filePath
        self.versions = versions
    }

    /// Captures a full snapshot of the current content as a new version.
    func snapshot(changeDescription: String) {
        let version = PlanVersion(
            planId: id,
            content: content,
            roundNumber: versions.count + 1,
            changeDescription: changeDescription
        )
        versions.append(version)
        updatedAt = Date()
    }
}

// MARK: - PlanDocument + Codable

extension PlanDocument: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, content, type, createdAt, updatedAt, filePath, versions
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
            versions: try container.decode([PlanVersion].self, forKey: .versions)
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
