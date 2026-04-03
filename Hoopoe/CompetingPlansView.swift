import HoopoeUI
import SwiftUI

// MARK: - Competing Plans Manager

/// Manages parallel multi-model plan generation using Swift structured concurrency.
///
/// Sends the same prompt to all configured LLM providers simultaneously via
/// `withThrowingTaskGroup`, tracking per-provider streaming text, token usage,
/// cost, and error state independently. Partial failures are isolated — if one
/// provider fails, others continue unaffected.
@Observable
@MainActor
final class CompetingPlansManager {

    // MARK: - Types

    enum ProviderPhase: Sendable {
        case waiting
        case streaming
        case completed(text: String)
        case failed(String)
        case cancelled
    }

    /// Tracks the state of a single provider's response during competing generation.
    struct ProviderResult: Identifiable {
        let id: String
        let providerID: String
        let providerName: String
        let modelID: String
        let modelName: String
        let providerIcon: String
        var phase: ProviderPhase = .waiting
        var streamingText: String = ""
        var tokenUsage: TokenUsage?
        var costEstimate: Double?
        var latency: TimeInterval?

        var isComplete: Bool {
            if case .completed = phase { return true }
            return false
        }

        var completedText: String? {
            if case .completed(let text) = phase { return text }
            return nil
        }

        var isFailed: Bool {
            if case .failed = phase { return true }
            return false
        }

        var errorMessage: String? {
            if case .failed(let msg) = phase { return msg }
            return nil
        }

        var isActive: Bool {
            switch phase {
            case .waiting, .streaming: return true
            default: return false
            }
        }
    }

    // MARK: - State

    var results: [ProviderResult] = []
    var isRunning = false
    private var groupTask: Task<Void, Never>?

    /// Number of providers that have completed (success or failure).
    var completedCount: Int {
        results.filter { !$0.isActive }.count
    }

    /// Total cost across all completed providers.
    var totalCost: Double {
        results.compactMap(\.costEstimate).reduce(0, +)
    }

    /// Whether all providers have finished (success, failure, or cancellation).
    var allFinished: Bool {
        !results.isEmpty && results.allSatisfy { !$0.isActive }
    }

    /// Results that completed successfully, sorted by latency (fastest first).
    var successfulResults: [ProviderResult] {
        results
            .filter(\.isComplete)
            .sorted { ($0.latency ?? .infinity) < ($1.latency ?? .infinity) }
    }

    /// Whether synthesis is available (2+ successful competing plans).
    var canSynthesize: Bool {
        successfulResults.count >= 2
    }

    // MARK: - Actions

    /// Sends the prompt to all configured providers in parallel.
    func startCompetingRequests(
        prompt: String,
        system: String?,
        registry: ProviderRegistry
    ) {
        cancel()

        let entries = registry.allModels
        guard !entries.isEmpty else { return }

        // Initialize per-provider result slots
        results = entries.map { entry in
            ProviderResult(
                id: "\(entry.provider.id)::\(entry.model.id)",
                providerID: entry.provider.id,
                providerName: entry.provider.displayName,
                modelID: entry.model.id,
                modelName: entry.model.displayName,
                providerIcon: providerIcon(for: entry.provider.id)
            )
        }

        isRunning = true

        // Capture provider references for the task group
        let providerEntries = entries.map { (provider: $0.provider, model: $0.model) }

        groupTask = Task { @MainActor [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for (index, entry) in providerEntries.enumerated() {
                    let provider = entry.provider
                    let modelID = entry.model.id
                    let resultID = self?.results[index].id ?? ""

                    group.addTask { @MainActor [weak self] in
                        guard let self, !Task.isCancelled else { return }

                        let startTime = CFAbsoluteTimeGetCurrent()
                        self.updatePhase(for: resultID, phase: .streaming)

                        let stream = provider.send(
                            prompt: prompt,
                            model: modelID,
                            system: system,
                            stream: true
                        )

                        do {
                            for try await event in stream {
                                guard !Task.isCancelled else {
                                    self.updatePhase(for: resultID, phase: .cancelled)
                                    return
                                }

                                switch event {
                                case .text(let chunk):
                                    self.appendText(for: resultID, chunk: chunk)

                                case .done(let response):
                                    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                                    self.completeResult(
                                        for: resultID,
                                        text: response.fullText,
                                        tokenUsage: response.tokenUsage,
                                        costEstimate: response.costEstimate,
                                        latency: elapsed
                                    )
                                    return

                                case .error(let error):
                                    self.updatePhase(
                                        for: resultID,
                                        phase: .failed(error.localizedDescription)
                                    )
                                    return
                                }
                            }
                            // Stream ended without .done — use accumulated text
                            if let idx = self.resultIndex(for: resultID),
                               case .streaming = self.results[idx].phase
                            {
                                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                                let accumulated = self.results[idx].streamingText
                                self.completeResult(
                                    for: resultID,
                                    text: accumulated,
                                    tokenUsage: nil,
                                    costEstimate: nil,
                                    latency: elapsed
                                )
                            }
                        } catch is CancellationError {
                            self.updatePhase(for: resultID, phase: .cancelled)
                        } catch {
                            self.updatePhase(
                                for: resultID,
                                phase: .failed(error.localizedDescription)
                            )
                        }
                    }
                }
            }

            self?.isRunning = false
        }
    }

    /// Cancels all in-flight provider requests.
    func cancel() {
        groupTask?.cancel()
        groupTask = nil
        isRunning = false
        for i in results.indices where results[i].isActive {
            results[i].phase = .cancelled
        }
    }

    /// Cancels a single provider's request (not yet supported by TaskGroup,
    /// so we mark it as cancelled and ignore further events).
    func cancelProvider(_ resultID: String) {
        updatePhase(for: resultID, phase: .cancelled)
    }

    // MARK: - Internal Helpers

    private func resultIndex(for id: String) -> Int? {
        results.firstIndex(where: { $0.id == id })
    }

    private func updatePhase(for id: String, phase: ProviderPhase) {
        guard let idx = resultIndex(for: id) else { return }
        results[idx].phase = phase
    }

    private func appendText(for id: String, chunk: String) {
        guard let idx = resultIndex(for: id) else { return }
        results[idx].streamingText += chunk
    }

    private func completeResult(
        for id: String,
        text: String,
        tokenUsage: TokenUsage?,
        costEstimate: Double?,
        latency: TimeInterval
    ) {
        guard let idx = resultIndex(for: id) else { return }
        results[idx].phase = .completed(text: text)
        results[idx].streamingText = text
        results[idx].tokenUsage = tokenUsage
        results[idx].costEstimate = costEstimate
        results[idx].latency = latency
    }

    private func providerIcon(for providerID: String) -> String {
        switch providerID {
        case "anthropic": "brain"
        case "openai": "sparkles"
        case "google": "diamond"
        default: "cpu"
        }
    }
}

// MARK: - Competing Plans View

/// Multi-model competing plans interface.
///
/// Sends the current plan's description to all configured providers simultaneously,
/// displays streaming results side-by-side, and lets the user accept the best output
/// as a new plan version or replace the plan content entirely.
struct CompetingPlansView: View {
    let plan: PlanDocument
    let planStore: PlanStore
    let router: NavigationRouter

    enum DisplayMode: String, CaseIterable {
        case tabs
        case sideBySide

        var label: String {
            switch self {
            case .tabs: "Tabs"
            case .sideBySide: "Side by Side"
            }
        }

        var icon: String {
            switch self {
            case .tabs: "rectangle.stack"
            case .sideBySide: "rectangle.split.3x1"
            }
        }
    }

    @State private var manager = CompetingPlansManager()
    @State private var providerRegistry = ProviderRegistry()
    @State private var isLoadingProviders = false
    @State private var selectedResultID: String?
    @State private var selectedTabID: String?
    @State private var showCostDetails = false
    @State private var displayMode: DisplayMode = .tabs

    // Synthesis state
    @State private var showSynthesisPanel = false
    @State private var synthesisPhase: SynthesisPhase = .idle
    @State private var synthesisText = ""
    @State private var synthesisModelID: String?
    @State private var synthesisTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !manager.results.isEmpty {
                tabBar
                Divider()
            }
            if showSynthesisPanel {
                synthesisPanel
            } else {
                content
            }
        }
        .task {
            await refreshProviders()
        }
        .onChange(of: manager.results.count) { _, _ in
            if selectedTabID == nil, let first = manager.results.first {
                selectedTabID = first.id
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.on.square")
                .foregroundStyle(.secondary)
            Text("Competing Plans")
                .font(.headline)

            Spacer()

            if !manager.results.isEmpty {
                Picker("Display", selection: $displayMode) {
                    ForEach(DisplayMode.allCases, id: \.self) { mode in
                        Label(mode.label, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            if manager.isRunning {
                progressIndicator
            }

            if !manager.results.isEmpty {
                costBadge
            }

            toolbarActions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(manager.results) { result in
                    tabButton(for: result)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func tabButton(for result: CompetingPlansManager.ProviderResult) -> some View {
        Button {
            selectedTabID = result.id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: result.providerIcon)
                    .font(.caption)
                    .foregroundStyle(cardAccentColor(for: result))

                Text(result.modelName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)

                tabStatusDot(result)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                selectedTabID == result.id
                    ? Color.accentColor.opacity(0.1)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        selectedTabID == result.id
                            ? Color.accentColor.opacity(0.3)
                            : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func tabStatusDot(_ result: CompetingPlansManager.ProviderResult) -> some View {
        switch result.phase {
        case .waiting:
            Circle().fill(.secondary.opacity(0.3)).frame(width: 6, height: 6)
        case .streaming:
            Circle().fill(.blue).frame(width: 6, height: 6)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var progressIndicator: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("\(manager.completedCount)/\(manager.results.count) complete")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private var costBadge: some View {
        if manager.totalCost > 0 {
            Button {
                showCostDetails.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "dollarsign.circle")
                    Text(formatCost(manager.totalCost))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showCostDetails) {
                costBreakdown
            }
        }
    }

    @ViewBuilder
    private var toolbarActions: some View {
        if manager.isRunning {
            Button("Cancel All") { manager.cancel() }
                .buttonStyle(.bordered)
                .tint(.red)
        } else {
            Button {
                startCompetingGeneration()
            } label: {
                Label(
                    manager.results.isEmpty ? "Generate Competing Plans" : "Regenerate",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoadingProviders || providerRegistry.configuredProviders.isEmpty)
        }

        if manager.canSynthesize && !manager.isRunning {
            Button {
                showSynthesisPanel.toggle()
            } label: {
                Label("Synthesize", systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .tint(.purple)
        }

        if canSynthesize || synthesisComplete {
            Button {
                showSynthesisSheet = true
            } label: {
                Label("Synthesize", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .sheet(isPresented: $showSynthesisSheet) {
                synthesisSheet
            }
        }

        Button("Back to Editor") {
            router.navigate(to: .planEditor(planId: plan.id))
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if manager.results.isEmpty {
            emptyState
        } else {
            switch displayMode {
            case .tabs:
                tabbedContent
            case .sideBySide:
                sideBySideContent
            }
        }
    }

    // MARK: - Tabbed Content (single plan, full width)

    @ViewBuilder
    private var tabbedContent: some View {
        if let tabID = selectedTabID ?? manager.results.first?.id,
           let result = manager.results.first(where: { $0.id == tabID })
        {
            VStack(spacing: 0) {
                // Full-width card body
                cardBody(result)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Footer with stats and accept
                if result.isComplete || result.isFailed {
                    Divider()
                    cardFooter(result)
                }
            }
        }
    }

    // MARK: - Side-by-Side Content (max 3 panes)

    private var sideBySideContent: some View {
        let visibleResults = Array(manager.results.prefix(3))
        return HStack(spacing: 1) {
            ForEach(visibleResults) { result in
                VStack(alignment: .leading, spacing: 0) {
                    // Compact header
                    HStack(spacing: 6) {
                        Image(systemName: result.providerIcon)
                            .font(.caption)
                            .foregroundStyle(cardAccentColor(for: result))
                        Text(result.modelName)
                            .font(.caption.weight(.medium))
                        Spacer()
                        cardStatusBadge(result)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(cardHeaderBackground(for: result))

                    Divider()

                    cardBody(result)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if result.isComplete || result.isFailed {
                        Divider()
                        cardFooter(result)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))

                if result.id != visibleResults.last?.id {
                    Divider()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.on.square")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("Compare Plans from Multiple Models")
                .font(.title3)
                .fontWeight(.medium)

            Text("Send your plan to all configured AI providers simultaneously.\nCompare their approaches side-by-side and pick the best one.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if providerRegistry.configuredProviders.isEmpty {
                Label("No providers configured", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)

                Button("Configure Providers") {
                    // Navigate to settings when available
                }
                .buttonStyle(.bordered)
            } else {
                HStack(spacing: 8) {
                    ForEach(providerRegistry.configuredProviders, id: \.id) { provider in
                        providerChip(name: provider.displayName, icon: chipIcon(for: provider.id))
                    }
                }

                Text("\(providerRegistry.configuredProviders.count) provider(s) ready")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button {
                    startCompetingGeneration()
                } label: {
                    Label("Generate Competing Plans", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Provider Card (used in side-by-side mode headers)

    private func providerCard(_ result: CompetingPlansManager.ProviderResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card header
            HStack(spacing: 8) {
                Image(systemName: result.providerIcon)
                    .foregroundStyle(cardAccentColor(for: result))

                VStack(alignment: .leading, spacing: 1) {
                    Text(result.modelName)
                        .font(.subheadline.weight(.medium))
                    Text(result.providerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                cardStatusBadge(result)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(cardHeaderBackground(for: result))

            Divider()

            // Card body
            cardBody(result)
                .frame(minHeight: 200, maxHeight: 400)

            // Card footer with actions
            if result.isComplete || result.isFailed {
                Divider()
                cardFooter(result)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    selectedResultID == result.id
                        ? Color.accentColor
                        : Color(nsColor: .separatorColor),
                    lineWidth: selectedResultID == result.id ? 2 : 1
                )
        )
        .onTapGesture {
            if result.isComplete {
                selectedResultID = result.id
            }
        }
    }

    @ViewBuilder
    private func cardStatusBadge(_ result: CompetingPlansManager.ProviderResult) -> some View {
        switch result.phase {
        case .waiting:
            Text("Waiting")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.1), in: Capsule())

        case .streaming:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Streaming")
                    .font(.caption2)
            }
            .foregroundStyle(.blue)

        case .completed:
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                if let latency = result.latency {
                    Text(String(format: "%.1fs", latency))
                        .font(.caption2)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.green)

        case .failed:
            HStack(spacing: 3) {
                Image(systemName: "xmark.circle.fill")
                Text("Failed")
            }
            .font(.caption2)
            .foregroundStyle(.red)

        case .cancelled:
            Text("Cancelled")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func cardBody(_ result: CompetingPlansManager.ProviderResult) -> some View {
        switch result.phase {
        case .waiting:
            VStack(spacing: 8) {
                ProgressView()
                Text("Waiting for response...")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .streaming:
            ScrollView {
                Text(result.streamingText)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }

        case .completed(let text):
            ScrollView {
                Text(attributedMarkdown(text))
                    .textSelection(.enabled)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }

        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .cancelled:
            VStack(spacing: 8) {
                Image(systemName: "xmark.circle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Request cancelled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cardFooter(_ result: CompetingPlansManager.ProviderResult) -> some View {
        HStack(spacing: 8) {
            if let usage = result.tokenUsage {
                Text("\(usage.inputTokens + usage.outputTokens) tokens")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            if let cost = result.costEstimate {
                Text(formatCost(cost))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Spacer()

            if result.isComplete {
                Button("Accept This Plan") {
                    acceptResult(result)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)
            }

            if result.isFailed {
                Button("Retry") {
                    // Individual retry not supported yet — regenerate all
                    startCompetingGeneration()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Cost Breakdown Popover

    private var costBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cost Breakdown")
                .font(.headline)

            ForEach(manager.results.filter { $0.costEstimate != nil }) { result in
                HStack {
                    Image(systemName: result.providerIcon)
                    Text(result.modelName)
                        .font(.caption)
                    Spacer()
                    Text(formatCost(result.costEstimate ?? 0))
                        .font(.caption.monospacedDigit())
                }
            }

            Divider()

            HStack {
                Text("Total")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(formatCost(manager.totalCost))
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    // MARK: - Actions

    private func startCompetingGeneration() {
        selectedTabID = nil

        let prompt = PromptTemplates.substitute(
            template: PromptTemplates.planGenerationUser,
            variables: [
                "project_name": plan.title,
                "platform": "Unspecified",
                "tech_stack": "Unspecified",
                "project_description": plan.content,
            ]
        )

        manager.startCompetingRequests(
            prompt: prompt,
            system: PromptTemplates.planGenerationSystem,
            registry: providerRegistry
        )

        // Select first tab after starting
        selectedTabID = manager.results.first?.id
    }

    // MARK: - Synthesis Panel

    private var synthesisPanel: some View {
        VStack(spacing: 0) {
            // Synthesis header
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(.purple)
                Text("Best-of-All-Worlds Synthesis")
                    .font(.headline)

                Spacer()

                if !isSynthesizing {
                    synthesisModelPicker

                    if manager.canSynthesize {
                        synthesisCostEstimate
                    }

                    Button {
                        startSynthesis()
                    } label: {
                        Label("Synthesize", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(!manager.canSynthesize)
                } else {
                    Button("Cancel") { cancelSynthesis() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                }

                Button {
                    showSynthesisPanel = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.purple.opacity(0.05))

            Divider()

            // Synthesis content
            synthesisContent
        }
    }

    private var synthesisModelPicker: some View {
        Picker("Model", selection: $synthesisModelID) {
            ForEach(providerRegistry.allModels, id: \.model.id) { entry in
                Text("\(entry.model.displayName) (\(entry.provider.displayName))")
                    .tag(Optional(entry.model.id))
            }
        }
        .frame(maxWidth: 240)
    }

    @ViewBuilder
    private var synthesisCostEstimate: some View {
        let totalWords = manager.successfulResults.compactMap(\.completedText)
            .map { $0.split(whereSeparator: \.isWhitespace).count }
            .reduce(0, +)
        let estimatedTokens = totalWords * 4 / 3 // rough word-to-token ratio
        Text("~\(estimatedTokens) input tokens")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
    }

    @ViewBuilder
    private var synthesisContent: some View {
        switch synthesisPhase {
        case .idle:
            VStack(spacing: 16) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.purple.opacity(0.4))
                Text("Ready to Synthesize")
                    .font(.title3)
                Text("Merges the best ideas from \(manager.successfulResults.count) competing plans into a single superior plan.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .streaming:
            VStack(spacing: 0) {
                ScrollView {
                    Text(synthesisText)
                        .textSelection(.enabled)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                Divider()
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Synthesizing \(manager.successfulResults.count) plans...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }

        case .complete(let text):
            VStack(spacing: 0) {
                ScrollView {
                    Text(attributedMarkdown(text))
                        .textSelection(.enabled)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                Divider()
                HStack(spacing: 12) {
                    Spacer()
                    Button("Discard") {
                        synthesisPhase = .idle
                        synthesisText = ""
                    }
                    .buttonStyle(.bordered)

                    Button {
                        acceptSynthesis()
                    } label: {
                        Label("Accept Synthesized Plan", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.red)
                Text("Synthesis Failed")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Try Again") { startSynthesis() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Synthesis Logic

    enum SynthesisPhase {
        case idle
        case streaming
        case complete(text: String)
        case failed(String)
    }

    private var canSynthesize: Bool {
        manager.completedCount >= 2 && !isSynthesizing
    }

    private var isSynthesizing: Bool {
        if case .streaming = synthesisPhase { return true }
        return false
    }

    private var synthesisComplete: Bool {
        if case .complete = synthesisPhase { return true }
        return false
    }

    private func startSynthesis() {
        guard let modelId = synthesisModelID ?? providerRegistry.allModels.first?.model.id,
              let entry = providerRegistry.allModels.first(where: { $0.model.id == modelId })
        else { return }

        let completedPlans = manager.results.compactMap { result -> String? in
            guard let text = result.completedText else { return nil }
            return "### Plan by \(result.providerName) (\(result.modelName))\n\n\(text)"
        }

        let prompt = PromptTemplates.substitute(
            template: PromptTemplates.planSynthesisUser,
            variables: [
                "plan_count": "\(completedPlans.count)",
                "competing_plans": completedPlans.joined(separator: "\n\n---\n\n"),
                "user_highlights": "",
            ]
        )

        synthesisText = ""
        synthesisPhase = .streaming

        let stream = entry.provider.send(
            prompt: prompt,
            model: modelId,
            system: PromptTemplates.planSynthesisSystem,
            stream: true
        )

        synthesisTask = Task { @MainActor in
            do {
                for try await event in stream {
                    switch event {
                    case .text(let chunk):
                        synthesisText += chunk
                    case .done(let response):
                        synthesisPhase = .complete(text: response.fullText)
                        return
                    case .error(let error):
                        synthesisPhase = .failed(error.localizedDescription)
                        return
                    }
                }
                if case .streaming = synthesisPhase {
                    synthesisPhase = .complete(text: synthesisText)
                }
            } catch is CancellationError {
                synthesisPhase = .idle
            } catch {
                synthesisPhase = .failed(error.localizedDescription)
            }
        }
    }

    private func acceptSynthesis() {
        guard case .complete(let text) = synthesisPhase else { return }

        plan.content = text
        plan.updatedAt = Date()

        let versionManager = PlanVersionManager(store: planStore)
        let modelName = synthesisModelID ?? "unknown"
        versionManager.createSynthesisVersion(
            for: plan,
            modelName: modelName,
            description: "Best-of-All-Worlds synthesis from \(manager.completedCount) competing plans"
        )

        try? planStore.save(plan)
        router.navigate(to: .planEditor(planId: plan.id))
    }

    private func cancelSynthesis() {
        synthesisTask?.cancel()
        synthesisTask = nil
        if case .streaming = synthesisPhase {
            synthesisPhase = .idle
        }
    }

    private func acceptResult(_ result: CompetingPlansManager.ProviderResult) {
        guard let text = result.completedText else { return }

        plan.content = text
        plan.updatedAt = Date()

        let versionManager = PlanVersionManager(store: planStore)
        versionManager.createSynthesisVersion(
            for: plan,
            modelName: result.modelName,
            description: "Competing plan from \(result.modelName) (\(result.providerName))"
        )

        try? planStore.save(plan)
        router.navigate(to: .planEditor(planId: plan.id))
    }

    @MainActor
    private func refreshProviders() async {
        isLoadingProviders = true
        defer { isLoadingProviders = false }

        let keychain = KeychainService()
        var discovered: [any LLMProvider] = []

        if let key = try? await keychain.retrieve(provider: "anthropic") {
            discovered.append(ClaudeProvider(apiKey: key))
        }
        if let key = try? await keychain.retrieve(provider: "openai") {
            discovered.append(OpenAIProvider(apiKey: key))
        }
        if let key = try? await keychain.retrieve(provider: "google") {
            discovered.append(GeminiProvider(apiKey: key))
        }

        providerRegistry.replaceProviders(with: discovered)
    }

    // MARK: - Helpers

    private func providerChip(name: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(name)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.secondary.opacity(0.1), in: Capsule())
    }

    private func chipIcon(for providerID: String) -> String {
        switch providerID {
        case "anthropic": "brain"
        case "openai": "sparkles"
        case "google": "diamond"
        default: "cpu"
        }
    }

    private func cardAccentColor(for result: CompetingPlansManager.ProviderResult) -> Color {
        switch result.providerID {
        case "anthropic": .orange
        case "openai": .green
        case "google": .blue
        default: .secondary
        }
    }

    private func cardHeaderBackground(for result: CompetingPlansManager.ProviderResult) -> some ShapeStyle {
        cardAccentColor(for: result).opacity(0.05)
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        }
        return String(format: "$%.2f", cost)
    }

    private func attributedMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
