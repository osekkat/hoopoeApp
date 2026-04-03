import SwiftUI
import UniformTypeIdentifiers

// MARK: - Focused Value Keys

struct FocusedPlanKey: FocusedValueKey {
    typealias Value = PlanDocument
}

struct FocusedPlanStoreKey: FocusedValueKey {
    typealias Value = PlanStore
}

struct FocusedRouterKey: FocusedValueKey {
    typealias Value = NavigationRouter
}

extension FocusedValues {
    var plan: PlanDocument? {
        get { self[FocusedPlanKey.self] }
        set { self[FocusedPlanKey.self] = newValue }
    }

    var planStore: PlanStore? {
        get { self[FocusedPlanStoreKey.self] }
        set { self[FocusedPlanStoreKey.self] = newValue }
    }

    var router: NavigationRouter? {
        get { self[FocusedRouterKey.self] }
        set { self[FocusedRouterKey.self] = newValue }
    }
}

// MARK: - Commands

struct HoopoeCommands: Commands {
    @FocusedValue(\.plan) private var activePlan
    @FocusedValue(\.planStore) private var planStore
    @FocusedValue(\.router) private var router

    var body: some Commands {
        // File menu additions
        CommandGroup(after: .newItem) {
            Divider()
            Button("Open Plan...") {
                if let planStore, let router {
                    PlanImporter.importMarkdown(into: planStore, router: router)
                }
            }
            .keyboardShortcut("o")
            .disabled(planStore == nil)

            Divider()

            Button("Export As...") {
                if let plan = activePlan {
                    PlanExporter.exportMarkdown(plan: plan)
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(activePlan == nil)
        }

        // Add to existing View menu (not CommandMenu, which creates a duplicate)
        CommandGroup(after: .toolbar) {
            Button("Toggle Sidebar") {
                NSApp.keyWindow?.firstResponder?.tryToPerform(
                    #selector(NSSplitViewController.toggleSidebar(_:)),
                    with: nil
                )
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }

        // Help menu override
        CommandGroup(replacing: .help) {
            Button("Hoopoe Help") {
                // Placeholder — help system
            }
        }
    }
}

// MARK: - Plan Exporter

/// Handles exporting plan documents to disk via NSSavePanel.
enum PlanExporter {
    /// Presents an NSSavePanel and writes the plan content as a .md file.
    @MainActor
    static func exportMarkdown(plan: PlanDocument) {
        let panel = NSSavePanel()
        panel.title = "Export Plan"
        panel.nameFieldLabel = "File name:"
        panel.nameFieldStringValue = sanitizedFileName(plan.title)
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.canCreateDirectories = true

        // Accessory view: checkbox to include metadata sidecar
        let accessory = NSStackView()
        accessory.orientation = .horizontal
        accessory.spacing = 8

        let checkbox = NSButton(checkboxWithTitle: "Include metadata sidecar (.json)", target: nil, action: nil)
        checkbox.state = .off
        accessory.addArrangedSubview(checkbox)
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try plan.content.write(to: url, atomically: true, encoding: .utf8)

            // Write metadata sidecar if requested
            if checkbox.state == .on {
                let metaURL = metadataURL(for: url)
                let metadata = ExportMetadata(from: plan)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(metadata)
                try data.write(to: metaURL, options: .atomic)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    /// Exports each version as a separate .md file into a chosen directory.
    @MainActor
    static func exportAllVersions(plan: PlanDocument) {
        let panel = NSOpenPanel()
        panel.title = "Export All Versions"
        panel.message = "Choose a folder for the exported versions."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let baseName = sanitizedFileName(plan.title)
        let sortedVersions = plan.versions.sorted { $0.roundNumber < $1.roundNumber }

        for version in sortedVersions {
            let fileName = "\(baseName)-v\(version.roundNumber).md"
            let fileURL = directory.appendingPathComponent(fileName)
            do {
                try version.content.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
                return
            }
        }
    }

    private static func sanitizedFileName(_ title: String) -> String {
        let safe = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return safe.isEmpty ? "Untitled Plan" : safe
    }

    private static func metadataURL(for mdURL: URL) -> URL {
        let dir = mdURL.deletingLastPathComponent()
        let name = mdURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent(".\(name)-meta.json")
    }
}

// MARK: - Export Metadata

/// Lightweight metadata for exported plans.
private struct ExportMetadata: Codable {
    let id: UUID
    let title: String
    let type: PlanType
    let createdAt: Date
    let updatedAt: Date
    let versionCount: Int
    let wordCount: Int

    init(from plan: PlanDocument) {
        self.id = plan.id
        self.title = plan.title
        self.type = plan.type
        self.createdAt = plan.createdAt
        self.updatedAt = plan.updatedAt
        self.versionCount = plan.versions.count
        self.wordCount = plan.content.split(whereSeparator: \.isWhitespace).count
    }
}

// MARK: - Plan Importer

/// Handles importing .md files into PlanStore.
enum PlanImporter {

    /// Result of an import operation, shown to the user.
    struct ImportSummary {
        let title: String
        let wordCount: Int
        let sectionCount: Int
        let hadSidecar: Bool
    }

    /// Presents an NSOpenPanel and imports the selected .md file(s).
    @MainActor
    static func importMarkdown(into store: PlanStore, router: NavigationRouter) {
        let panel = NSOpenPanel()
        panel.title = "Import Plan"
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }

        var lastImported: PlanDocument?
        for url in panel.urls {
            if let plan = importFile(at: url, into: store) {
                lastImported = plan
            }
        }

        // Navigate to the last imported plan
        if let plan = lastImported {
            router.navigate(to: .planEditor(planId: plan.id))
        }
    }

    /// Imports a single .md file, creating a PlanDocument with an initial version.
    @MainActor
    @discardableResult
    static func importFile(at url: URL, into store: PlanStore) -> PlanDocument? {
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Try other encodings as fallback
            guard let data = try? Data(contentsOf: url),
                  let fallbackContent = String(data: data, encoding: .utf16)
                    ?? String(data: data, encoding: .ascii)
            else {
                let alert = NSAlert()
                alert.messageText = "Import Failed"
                alert.informativeText = "Could not read \(url.lastPathComponent). The file encoding is not supported."
                alert.alertStyle = .warning
                alert.runModal()
                return nil
            }
            content = fallbackContent
        }

        let title = url.deletingPathExtension().lastPathComponent

        // Check for sidecar metadata
        let sidecarURL = sidecarMetadataURL(for: url)
        var planId = UUID()
        var planType: PlanType = .master
        var existingVersions: [PlanVersion] = []

        if FileManager.default.fileExists(atPath: sidecarURL.path),
           let data = try? Data(contentsOf: sidecarURL),
           let decoder = try? JSONDecoder() as JSONDecoder
        {
            decoder.dateDecodingStrategy = .iso8601
            if let metadata = try? decoder.decode(ImportSidecarMetadata.self, from: data) {
                planId = metadata.id ?? planId
                planType = metadata.type ?? .master
                existingVersions = metadata.versions ?? []
            }
        }

        let plan = store.createPlan(id: planId, title: title, content: content, type: planType)
        plan.filePath = url

        // If sidecar had versions, use them; otherwise create an import version
        if !existingVersions.isEmpty {
            plan.versions = existingVersions
        } else {
            let importVersion = PlanVersion(
                planId: plan.id,
                content: content,
                roundNumber: 1,
                changeDescription: "Imported from \(url.lastPathComponent)"
            )
            plan.versions = [importVersion]
        }

        try? store.save(plan)
        return plan
    }

    private static func sidecarMetadataURL(for mdURL: URL) -> URL {
        let dir = mdURL.deletingLastPathComponent()
        let name = mdURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent(".\(name)-meta.json")
    }
}

/// Sidecar metadata that may accompany an imported .md file.
private struct ImportSidecarMetadata: Codable {
    let id: UUID?
    let type: PlanType?
    let versions: [PlanVersion]?
}
