import Foundation
import Observation

// MARK: - Plan Store Error

enum PlanStoreError: LocalizedError {
    case directoryCreationFailed(URL, Error)
    case saveFailed(URL, Error)
    case loadFailed(URL, Error)
    case deleteFailed(URL, Error)
    case fileNotFound(URL)
    case decodingFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let url, let error):
            "Failed to create directory at \(url.lastPathComponent): \(error.localizedDescription)"
        case .saveFailed(let url, let error):
            "Failed to save \(url.lastPathComponent): \(error.localizedDescription)"
        case .loadFailed(let url, let error):
            "Failed to load \(url.lastPathComponent): \(error.localizedDescription)"
        case .deleteFailed(let url, let error):
            "Failed to delete \(url.lastPathComponent): \(error.localizedDescription)"
        case .fileNotFound(let url):
            "File not found: \(url.lastPathComponent)"
        case .decodingFailed(let url, let error):
            "Failed to read metadata for \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

// MARK: - Plan Store

/// Manages persistence of PlanDocument instances as markdown files with JSON sidecar metadata.
///
/// Each plan is stored as:
/// - `<title>.md` — the raw markdown content
/// - `.<title>-meta.json` — sidecar with id, type, versions, dates
///
/// Designed so the backing storage can be swapped to SQLite (Rust engine) in Phase 2
/// without changing callers.
@Observable
final class PlanStore {
    /// All loaded plans, sorted by most recently updated.
    private(set) var plans: [PlanDocument] = []

    /// The most recent error, surfaced for UI alerts.
    var lastError: PlanStoreError?

    /// Directory where plans are stored.
    var storeDirectory: URL {
        didSet {
            ensureDirectoryExists(storeDirectory)
        }
    }

    // MARK: - Auto-save

    private var autoSaveTask: Task<Void, Never>?
    private var autoSaveInterval: TimeInterval = 30

    /// Whether auto-save is active.
    var isAutoSaveEnabled: Bool = true {
        didSet {
            if isAutoSaveEnabled {
                startAutoSave()
            } else {
                stopAutoSave()
            }
        }
    }

    // MARK: - Init

    init(directory: URL? = nil) {
        let defaultDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Hoopoe Plans", isDirectory: true)
        self.storeDirectory = directory ?? defaultDir
        ensureDirectoryExists(storeDirectory)
    }

    // MARK: - CRUD Operations

    /// Creates a new plan and adds it to the store.
    @discardableResult
    func createPlan(
        title: String = "Untitled Plan",
        content: String = "",
        type: PlanType = .master
    ) -> PlanDocument {
        let plan = PlanDocument(title: title, content: content, type: type)
        plans.insert(plan, at: 0)
        return plan
    }

    /// Saves a plan to disk as .md with sidecar JSON metadata.
    func save(_ plan: PlanDocument) throws {
        let mdURL = markdownURL(for: plan)
        let metaURL = metadataURL(for: plan)

        // Write markdown content using file coordination
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var innerWriteError: Error?

        coordinator.coordinate(writingItemAt: mdURL, options: .forReplacing, error: &coordinatorError) { url in
            do {
                try plan.content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                innerWriteError = error
            }
        }

        if let error = coordinatorError {
            let storeError = PlanStoreError.saveFailed(mdURL, error)
            lastError = storeError
            throw storeError
        }

        if let error = innerWriteError {
            let storeError = PlanStoreError.saveFailed(mdURL, error)
            lastError = storeError
            throw storeError
        }

        // Write sidecar metadata
        let metadata = PlanSidecarMetadata(from: plan)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: metaURL, options: .atomic)
        } catch {
            let storeError = PlanStoreError.saveFailed(metaURL, error)
            lastError = storeError
            throw storeError
        }

        plan.updatedAt = Date()
        if let path = plan.filePath, path != mdURL {
            plan.filePath = mdURL
        } else if plan.filePath == nil {
            plan.filePath = mdURL
        }
    }

    /// Loads all plans from the store directory.
    func loadAll() throws {
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: storeDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            let storeError = PlanStoreError.loadFailed(storeDirectory, error)
            lastError = storeError
            throw storeError
        }

        let mdFiles = contents.filter { $0.pathExtension == "md" }
        var loaded: [PlanDocument] = []

        for mdURL in mdFiles {
            do {
                let plan = try loadPlan(from: mdURL)
                loaded.append(plan)
            } catch {
                // Log but continue loading other plans
                lastError = error as? PlanStoreError ?? .loadFailed(mdURL, error)
            }
        }

        plans = loaded.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Loads a single plan from a markdown file, merging sidecar metadata if available.
    func loadPlan(from mdURL: URL) throws -> PlanDocument {
        let fm = FileManager.default
        guard fm.fileExists(atPath: mdURL.path) else {
            throw PlanStoreError.fileNotFound(mdURL)
        }

        let content: String
        do {
            content = try String(contentsOf: mdURL, encoding: .utf8)
        } catch {
            throw PlanStoreError.loadFailed(mdURL, error)
        }

        let title = mdURL.deletingPathExtension().lastPathComponent

        // Try to load sidecar metadata
        let metaURL = metadataURLForMarkdownFile(mdURL)
        if fm.fileExists(atPath: metaURL.path) {
            do {
                let data = try Data(contentsOf: metaURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let metadata = try decoder.decode(PlanSidecarMetadata.self, from: data)

                return PlanDocument(
                    id: metadata.id,
                    title: metadata.title ?? title,
                    content: content,
                    type: metadata.type,
                    createdAt: metadata.createdAt,
                    updatedAt: metadata.updatedAt,
                    filePath: mdURL,
                    versions: metadata.versions
                )
            } catch {
                lastError = .decodingFailed(metaURL, error)
                // Fall through to create without metadata
            }
        }

        // No sidecar — create a fresh PlanDocument from file attributes
        let attributes = try? fm.attributesOfItem(atPath: mdURL.path)
        let createdAt = attributes?[.creationDate] as? Date ?? Date()
        let updatedAt = attributes?[.modificationDate] as? Date ?? Date()

        return PlanDocument(
            title: title,
            content: content,
            createdAt: createdAt,
            updatedAt: updatedAt,
            filePath: mdURL
        )
    }

    /// Removes a plan from the store and deletes its files from disk.
    func delete(_ plan: PlanDocument) throws {
        let fm = FileManager.default
        let mdURL = plan.filePath ?? markdownURL(for: plan)
        let metaURL = metadataURLForMarkdownFile(mdURL)

        do {
            if fm.fileExists(atPath: mdURL.path) {
                try fm.removeItem(at: mdURL)
            }
            if fm.fileExists(atPath: metaURL.path) {
                try fm.removeItem(at: metaURL)
            }
        } catch {
            let storeError = PlanStoreError.deleteFailed(mdURL, error)
            lastError = storeError
            throw storeError
        }

        plans.removeAll { $0.id == plan.id }
    }

    /// Saves all dirty plans.
    func saveAllDirty() {
        for plan in plans where plan.isDirty {
            do {
                try save(plan)
            } catch {
                // lastError already set by save()
            }
        }
    }

    // MARK: - Auto-save

    func startAutoSave() {
        stopAutoSave()
        autoSaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.autoSaveInterval ?? 30))
                guard !Task.isCancelled else { break }
                self?.saveAllDirty()
            }
        }
    }

    func stopAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
    }

    // MARK: - File Paths

    private func markdownURL(for plan: PlanDocument) -> URL {
        if let existing = plan.filePath { return existing }
        let safeName = plan.title.replacingOccurrences(of: "/", with: "-")
        return storeDirectory.appendingPathComponent("\(safeName).md")
    }

    private func metadataURL(for plan: PlanDocument) -> URL {
        metadataURLForMarkdownFile(markdownURL(for: plan))
    }

    private func metadataURLForMarkdownFile(_ mdURL: URL) -> URL {
        let dir = mdURL.deletingLastPathComponent()
        let name = mdURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent(".\(name)-meta.json")
    }

    private func ensureDirectoryExists(_ url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                lastError = .directoryCreationFailed(url, error)
            }
        }
    }
}

// MARK: - Sidecar Metadata

/// JSON-serializable metadata stored alongside each plan .md file.
private struct PlanSidecarMetadata: Codable {
    let id: UUID
    let title: String?
    let type: PlanType
    let createdAt: Date
    let updatedAt: Date
    let versions: [PlanVersion]

    init(from plan: PlanDocument) {
        self.id = plan.id
        self.title = plan.title
        self.type = plan.type
        self.createdAt = plan.createdAt
        self.updatedAt = plan.updatedAt
        self.versions = plan.versions
    }
}
