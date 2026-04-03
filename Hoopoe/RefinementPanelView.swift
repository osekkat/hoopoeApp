import HoopoeUI
import SwiftUI

// MARK: - Refinement State

/// Tracks the state of a single refinement round.
@Observable
@MainActor
final class RefinementState {
    enum Phase {
        case idle
        case refining
        case completed(text: String)
        case failed(String)
    }

    var phase: Phase = .idle
    private var streamTask: Task<Void, Never>?
    /// Text accumulated so far during streaming. Updated on each chunk.
    var streamingText = ""

    var isRefining: Bool {
        if case .refining = phase { return true }
        return false
    }

    var completedText: String? {
        if case .completed(let text) = phase { return text }
        return nil
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        if case .refining = phase {
            phase = .idle
        }
    }

    func setStreamTask(_ task: Task<Void, Never>) {
        self.streamTask = task
    }
}

// MARK: - Refinement Panel View

/// The iterative plan refinement interface.
///
/// Left pane shows the current plan as read-only markdown.
/// Right pane shows the streaming refined version.
/// Accept replaces the plan content; Reject discards.
struct RefinementPanelView: View {
    let plan: PlanDocument
    let versionManager: PlanVersionManager
    let registry: ProviderRegistry

    @State private var state = RefinementState()
    @State private var selectedProviderId: String?
    @State private var selectedModelId: String?
    @State private var focusAreas = ""
    @State private var refinementRound: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            splitContent
        }
        .onAppear {
            refinementRound = plan.versions.count
            if selectedProviderId == nil, let first = registry.allModels.first {
                selectedProviderId = first.provider.id
                selectedModelId = first.model.id
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Refinement Round \(refinementRound + 1)")
                .font(.headline)

            Spacer()

            if registry.configuredProviders.isEmpty {
                Label("No providers configured", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else {
                modelPicker
                TextField("Focus areas (optional)", text: $focusAreas)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }

            actionButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var modelPicker: some View {
        Picker("Model", selection: modelBinding) {
            ForEach(registry.allModels, id: \.model.id) { entry in
                Text("\(entry.provider.displayName) — \(entry.model.displayName)")
                    .tag(ModelSelection(providerId: entry.provider.id, modelId: entry.model.id))
            }
        }
        .frame(maxWidth: 280)
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            startRefinement()
        } label: {
            Label(state.isRefining ? "Refining..." : "Refine", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(state.isRefining || registry.configuredProviders.isEmpty)

        if state.completedText != nil {
            Button("Accept") { acceptRefinement() }
                .buttonStyle(.borderedProminent)
                .tint(.green)

            Button("Reject") { rejectRefinement() }
                .buttonStyle(.bordered)
        }

        if state.isRefining {
            Button("Cancel") { state.cancel() }
                .buttonStyle(.bordered)
                .tint(.red)
        }
    }

    // MARK: - Split Content

    private var splitContent: some View {
        HSplitView {
            currentPlanPane
                .frame(minWidth: 300)
            refinedPane
                .frame(minWidth: 300)
        }
    }

    private var currentPlanPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Current Plan")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(plan.metadata.wordCount) words")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            ScrollView {
                Text(attributedMarkdown(plan.content))
                    .textSelection(.enabled)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private var refinedPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Refined Plan")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider()

            switch state.phase {
            case .idle:
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("Click Refine to start")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("The plan will be sent to the selected model for improvement.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .refining:
                VStack(spacing: 0) {
                    ScrollView {
                        Text(attributedMarkdown(state.streamingText))
                            .textSelection(.enabled)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    Divider()
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Streaming...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
                }

            case .completed(let text):
                ScrollView {
                    Text(attributedMarkdown(text))
                        .textSelection(.enabled)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }

            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.red)
                    Text("Refinement failed")
                        .font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Try Again") { startRefinement() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
    }

    // MARK: - Actions

    private func startRefinement() {
        guard let selection = resolvedSelection,
              let provider = registry.provider(for: selection.providerId),
              let model = provider.availableModels.first(where: { $0.id == selection.modelId })
        else { return }

        state.cancel()
        state.streamingText = ""

        let focusAreaText = focusAreas.isEmpty
            ? ""
            : "**User-specified focus areas:** \(focusAreas)"

        let userPrompt = PromptTemplates.substitute(
            template: PromptTemplates.planRefinementUser,
            variables: [
                "current_plan": plan.content,
                "refinement_round": "\(refinementRound + 1)",
                "focus_areas": focusAreaText,
            ]
        )

        let stream = provider.send(
            prompt: userPrompt,
            model: model.id,
            system: PromptTemplates.planRefinementSystem,
            stream: true
        )

        state.phase = .refining

        let task = Task { @MainActor in
            do {
                for try await event in stream {
                    switch event {
                    case .text(let chunk):
                        state.streamingText += chunk
                    case .done(let response):
                        state.phase = .completed(text: response.fullText)
                        return
                    case .error(let error):
                        state.phase = .failed(error.localizedDescription)
                        return
                    }
                }
                // Stream ended without .done — use accumulated text
                if case .refining = state.phase {
                    state.phase = .completed(text: state.streamingText)
                }
            } catch is CancellationError {
                if case .refining = state.phase {
                    state.phase = .idle
                }
            } catch {
                state.phase = .failed(error.localizedDescription)
            }
        }
        state.setStreamTask(task)
    }

    private func acceptRefinement() {
        guard let text = state.completedText else { return }
        let modelName = resolvedSelection?.modelId ?? "unknown"

        plan.content = text
        versionManager.createRefinementVersion(
            for: plan,
            modelName: modelName,
            description: "Refinement round \(refinementRound + 1) via \(modelName)"
        )

        refinementRound += 1
        state.phase = .idle
        state.streamingText = ""
    }

    private func rejectRefinement() {
        state.phase = .idle
        state.streamingText = ""
    }

    // MARK: - Model Selection

    private struct ModelSelection: Hashable {
        let providerId: String
        let modelId: String
    }

    private var resolvedSelection: ModelSelection? {
        if let pid = selectedProviderId, let mid = selectedModelId {
            return ModelSelection(providerId: pid, modelId: mid)
        }
        if let first = registry.allModels.first {
            return ModelSelection(providerId: first.provider.id, modelId: first.model.id)
        }
        return nil
    }

    private var modelBinding: Binding<ModelSelection> {
        Binding(
            get: { resolvedSelection ?? ModelSelection(providerId: "", modelId: "") },
            set: { newValue in
                selectedProviderId = newValue.providerId
                selectedModelId = newValue.modelId
            }
        )
    }

    // MARK: - Helpers

    private func attributedMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
