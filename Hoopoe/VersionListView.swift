import SwiftUI

// MARK: - Version List View

/// Browsable refinement history for a plan document.
///
/// Left pane: scrollable timeline of all versions (newest first).
/// Right pane: read-only preview of a selected version, or a diff between the selected version
/// and the current plan content.
struct VersionListView: View {
    let plan: PlanDocument
    let versionManager: PlanVersionManager
    let router: NavigationRouter

    @State private var selectedVersionId: UUID?
    @State private var showingDiff = false
    @State private var showingRestoreConfirmation = false

    private var versions: [PlanVersion] {
        versionManager.getVersions(for: plan)
    }

    private var selectedVersion: PlanVersion? {
        guard let id = selectedVersionId else { return nil }
        return versionManager.getVersion(id: id, in: plan)
    }

    var body: some View {
        HSplitView {
            versionListPane
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
            detailPane
                .frame(minWidth: 400)
        }
        .onAppear(perform: syncSelection)
        .onChange(of: versions.map(\.id)) { _, _ in
            syncSelection()
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    let snapshot = versionManager.createManualVersion(
                        for: plan,
                        description: "Manual snapshot"
                    )
                    selectedVersionId = snapshot.id
                    showingDiff = false
                } label: {
                    Label("Save Snapshot", systemImage: "camera.viewfinder")
                }

                Button {
                    router.navigate(to: .planEditor(planId: plan.id))
                } label: {
                    Label("Back to Editor", systemImage: "chevron.left")
                }
            }
        }
    }

    // MARK: - Version List Pane

    private var versionListPane: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Version History", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Text("\(versions.count) versions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if versions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No versions yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Versions are created when you refine, generate, or manually snapshot a plan.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button("Save Initial Snapshot") {
                        let snapshot = versionManager.createManualVersion(
                            for: plan,
                            description: "Manual snapshot"
                        )
                        selectedVersionId = snapshot.id
                        showingDiff = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                            VersionRow(
                                version: version,
                                isSelected: selectedVersionId == version.id,
                                isFirst: index == 0,
                                isLast: index == versions.count - 1,
                                wordCountDelta: wordCountDelta(for: version)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedVersionId = version.id
                                showingDiff = false
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(.background)
    }

    // MARK: - Detail Pane

    @ViewBuilder
    private var detailPane: some View {
        if let version = selectedVersion {
            VStack(spacing: 0) {
                // Detail header with actions
                detailHeader(for: version)
                Divider()

                if showingDiff {
                    DiffView(
                        oldText: version.content,
                        newText: plan.content,
                        oldLabel: "Round \(version.roundNumber)",
                        newLabel: "Current"
                    )
                } else {
                    ScrollView {
                        Text(attributedMarkdown(version.content))
                            .textSelection(.enabled)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            }
            .background(.background)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Select a version to preview")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(for version: PlanVersion) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Round \(version.roundNumber)")
                    .font(.headline)
                Text(version.changeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(versionMetadata(for: version))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            // Toggle between preview and diff
            Picker("View", selection: $showingDiff) {
                Text("Preview").tag(false)
                Text("Diff vs Current").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)

            Button("Restore") {
                showingRestoreConfirmation = true
            }
            .buttonStyle(.bordered)
            .disabled(canRestore(version) == false)
            .confirmationDialog(
                "Restore to Round \(version.roundNumber)?",
                isPresented: $showingRestoreConfirmation,
                titleVisibility: .visible
            ) {
                Button("Restore") {
                    versionManager.restore(version, in: plan)
                    selectedVersionId = nil
                    showingDiff = false
                }
            } message: {
                Text("If the current draft differs from the latest saved version, it will be preserved before the restore. No history will be lost.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Helpers

    private func wordCountDelta(for version: PlanVersion) -> Int? {
        // Find the version immediately before this one (by round number)
        let sorted = plan.versions.sorted { $0.roundNumber < $1.roundNumber }
        guard let idx = sorted.firstIndex(where: { $0.id == version.id }), idx > 0 else {
            return nil
        }
        let previous = sorted[idx - 1]
        let currentWords = version.content.split(whereSeparator: \.isWhitespace).count
        let previousWords = previous.content.split(whereSeparator: \.isWhitespace).count
        return currentWords - previousWords
    }

    private func canRestore(_ version: PlanVersion) -> Bool {
        plan.isDirty || version.content != plan.content
    }

    private func versionMetadata(for version: PlanVersion) -> String {
        [
            version.createdAt.formatted(date: .abbreviated, time: .shortened),
            version.provenance?.modelName ?? "Manual",
            wordCountDeltaText(for: version)
        ]
        .compactMap { $0 }
        .joined(separator: " • ")
    }

    private func wordCountDeltaText(for version: PlanVersion) -> String? {
        guard let delta = wordCountDelta(for: version) else {
            return nil
        }
        if delta == 0 {
            return "No word change"
        }
        let prefix = delta > 0 ? "+" : ""
        return "\(prefix)\(delta) words"
    }

    private func syncSelection() {
        guard versions.isEmpty == false else {
            selectedVersionId = nil
            return
        }

        if let selectedVersionId,
           versions.contains(where: { $0.id == selectedVersionId }) {
            return
        }

        selectedVersionId = versions.first?.id
    }

    private func attributedMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

// MARK: - Version Row

private struct VersionRow: View {
    let version: PlanVersion
    let isSelected: Bool
    let isFirst: Bool
    let isLast: Bool
    let wordCountDelta: Int?

    private var wordCount: Int {
        version.content.split(whereSeparator: \.isWhitespace).count
    }

    var body: some View {
        HStack(spacing: 0) {
            // Timeline indicator
            timelineIndicator
                .frame(width: 32)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Round \(version.roundNumber)")
                        .font(.callout.weight(.semibold))

                    if let provenance = version.provenance {
                        provenanceBadge(provenance)
                    }

                    Spacer()

                    Text(relativeDate(version.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(version.changeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text("\(wordCount) words")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let delta = wordCountDelta {
                        Text(delta >= 0 ? "+\(delta)" : "\(delta)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(delta >= 0 ? .green : .red)
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.trailing, 12)
        }
        .background(isSelected ? Color.accentColor.opacity(0.1) : .clear)
    }

    private var timelineIndicator: some View {
        VStack(spacing: 0) {
            // Line above
            Rectangle()
                .fill(isFirst ? .clear : Color.secondary.opacity(0.3))
                .frame(width: 2)

            // Dot
            Circle()
                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(width: 10, height: 10)

            // Line below
            Rectangle()
                .fill(isLast ? .clear : Color.secondary.opacity(0.3))
                .frame(width: 2)
        }
    }

    private func provenanceBadge(_ provenance: VersionProvenance) -> some View {
        HStack(spacing: 3) {
            Image(systemName: provenanceIcon(provenance.promptType))
                .font(.caption2)
            Text(provenance.modelName)
                .font(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.1))
        .clipShape(Capsule())
    }

    private func provenanceIcon(_ type: VersionProvenance.PromptType) -> String {
        switch type {
        case .generation: "wand.and.stars"
        case .refinement: "arrow.triangle.2.circlepath"
        case .synthesis: "square.on.square"
        case .manual: "hand.raised"
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Preview

#Preview("Version History") {
    let store = PlanStore(directory: URL.temporaryDirectory)
    let plan = PlanDocument(
        title: "Sample Plan",
        content: "# Sample Plan\n\nThis is the current content after three rounds of refinement."
    )
    let vm = PlanVersionManager(store: store)
    let router = NavigationRouter(initialRoute: .versionHistory(planId: plan.id))

    // Create some sample versions
    let _ = {
        plan.versions = [
            PlanVersion(
                planId: plan.id,
                content: "# Sample Plan\n\nInitial draft.",
                roundNumber: 1,
                changeDescription: "Initial generation",
                provenance: VersionProvenance(modelName: "claude-3.5-sonnet", promptType: .generation)
            ),
            PlanVersion(
                planId: plan.id,
                content: "# Sample Plan\n\nImproved draft with more detail and structure.",
                roundNumber: 2,
                changeDescription: "Refinement round 2 via claude-3.5-sonnet",
                provenance: VersionProvenance(modelName: "claude-3.5-sonnet", promptType: .refinement)
            ),
            PlanVersion(
                planId: plan.id,
                content: "# Sample Plan\n\nThis is the current content after three rounds of refinement.",
                roundNumber: 3,
                changeDescription: "Manual snapshot",
                provenance: VersionProvenance(modelName: "user", promptType: .manual)
            ),
        ]
    }()

    VersionListView(plan: plan, versionManager: vm, router: router)
        .frame(width: 900, height: 600)
}
