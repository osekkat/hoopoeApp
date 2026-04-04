import HoopoeUI
import HoopoeUtils
import SwiftUI

private struct GenerationModelOption: Identifiable, Hashable {
    let providerID: String
    let providerName: String
    let modelID: String
    let modelDisplayName: String

    var id: String { "\(providerID)::\(modelID)" }

    var pickerLabel: String {
        "\(modelDisplayName) · \(providerName)"
    }

    var icon: String {
        switch providerID {
        case "anthropic":
            "brain"
        case "openai":
            "sparkles"
        case "google":
            "diamond"
        default:
            "cpu"
        }
    }
}

// MARK: - Generation Mode

private enum GenerationMode {
    case guided
    case quick
}

private struct GuidedQuestion {
    let question: String
    let options: [String]
    var answer: String
}

// MARK: - Generation Flow State

@Observable
@MainActor
final class GenerationFlowState {
    enum Phase {
        case input
        case generating
        case complete(text: String)
        case failed(String)
    }

    var phase: Phase = .input
    var streamingText = ""
    var tokenUsage: TokenUsage?
    var costEstimate: Double?

    /// Frozen snapshot of the model used for the current generation.
    var frozenDescription = ""
    var frozenModelName = ""
    var frozenModelID = ""
    var frozenProviderID = ""

    private var streamTask: Task<Void, Never>?

    var isInputPhase: Bool {
        if case .input = phase { return true }
        return false
    }

    var isGenerating: Bool {
        if case .generating = phase { return true }
        return false
    }

    var completedText: String? {
        if case .complete(let text) = phase { return text }
        return nil
    }

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        if case .generating = phase {
            phase = .input
            streamingText = ""
        }
    }

    func returnToInput() {
        streamTask?.cancel()
        streamTask = nil
        streamingText = ""
        tokenUsage = nil
        costEstimate = nil
        phase = .input
    }

    func setStreamTask(_ task: Task<Void, Never>) {
        self.streamTask = task
    }
}

// MARK: - Plan Generation View

struct PlanGenerationView: View {
    let router: NavigationRouter
    let planStore: PlanStore

    @State private var flowState = GenerationFlowState()
    @State private var projectDescription = ""
    @State private var providerRegistry = ProviderRegistry()
    @State private var selectedModelID: GenerationModelOption.ID?
    @State private var showStructuredFields = false
    @State private var isLoadingProviders = false
    @State private var providerLoadError: String?

    // Optional structured fields
    @State private var projectName = ""
    @State private var techStack = ""
    @State private var targetPlatform = ""
    @State private var repositoryURL = ""

    // Mode selection and guided Q&A
    @State private var mode: GenerationMode?
    @State private var guidedQuestions: [GuidedQuestion] = []
    @State private var currentQuestion: String?
    @State private var currentOptions: [String] = []
    @State private var selectedOptionIndex: Int?
    @State private var customAnswer = ""
    @State private var isAskingQuestion = false
    @State private var guidedComplete = false
    @State private var guidedError: String?

    var body: some View {
        Group {
            if mode == nil {
                modeSelectionView
            } else if mode == .guided && !guidedComplete {
                guidedQuestionView
            } else if mode == .guided && guidedComplete && flowState.isInputPhase {
                guidedGeneratingTransition
            } else {
                switch flowState.phase {
                case .input:
                    inputView
                case .generating, .complete, .failed:
                    splitPaneView
                }
            }
        }
        .task {
            await refreshProviders()
        }
    }

    // MARK: - Guided Generating Transition

    private var guidedGeneratingTransition: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Generating your plan...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard let selectedModel,
                  let provider = providerRegistry.provider(for: selectedModel.providerID)
            else { return }
            startGuidedGeneration(provider: provider, model: selectedModel)
        }
    }

    // MARK: - Mode Selection View

    private var modeSelectionView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Generate a Plan")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Choose how you want to create your project plan.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            VStack(spacing: 24) {
                Spacer()

                HStack(spacing: 20) {
                    modeCard(
                        icon: "questionmark.bubble",
                        title: "Guided",
                        subtitle: "AI asks questions to\nbuild the best plan",
                        action: { mode = .guided }
                    )
                    modeCard(
                        icon: "sparkles",
                        title: "Quick",
                        subtitle: "Generate a comprehensive\nplan immediately",
                        action: { mode = .quick }
                    )
                }
                .padding(.horizontal, 40)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func modeCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tint)

                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Guided Question View

    private var guidedQuestionView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Guided Plan Creation")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Spacer()

                    if !guidedQuestions.isEmpty {
                        Text("Question \(guidedQuestions.count + (currentQuestion != nil ? 1 : 0))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Text("Answer the questions below so the AI can build a thorough plan for your project.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if currentQuestion == nil && !isAskingQuestion && guidedQuestions.isEmpty {
                guidedDescriptionInput
            } else {
                guidedQuestionContent
            }

            Divider()

            guidedFooter
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var guidedDescriptionInput: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Project Vision")
                        .font(.headline)

                    TextEditor(text: $projectDescription)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .frame(minHeight: 200, idealHeight: 280)
                        .overlay(alignment: .topLeading) {
                            if projectDescription.isEmpty {
                                Text("Briefly describe what you want to build. The AI will ask follow-up questions to fill in the details.")
                                    .font(.body)
                                    .foregroundStyle(.tertiary)
                                    .padding(16)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                modelSelectionSection
            }
            .padding(20)
        }
    }

    private var guidedQuestionContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !guidedQuestions.isEmpty {
                    ForEach(Array(guidedQuestions.enumerated()), id: \.offset) { index, qa in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Q\(index + 1): \(qa.question)")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Text(qa.answer)
                                .font(.callout)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.accentColor.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    Divider()
                        .padding(.vertical, 4)
                }

                if isAskingQuestion {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking of the next question...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if currentQuestion == nil && !guidedQuestions.isEmpty {
                    VStack(spacing: 12) {
                        Text("Ready to generate your plan based on the answers above.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Button {
                            guard let selectedModel,
                                  let provider = providerRegistry.provider(for: selectedModel.providerID)
                            else { return }
                            askNextQuestion(provider: provider, model: selectedModel)
                        } label: {
                            Label("Continue", systemImage: "arrow.right")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let question = currentQuestion {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(question)
                            .font(.body.weight(.medium))

                        VStack(spacing: 8) {
                            ForEach(Array(currentOptions.enumerated()), id: \.offset) { index, option in
                                let isOther = option.lowercased().hasPrefix("other")
                                let isSelected = selectedOptionIndex == index

                                Button {
                                    selectedOptionIndex = index
                                    if !isOther {
                                        customAnswer = ""
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        Text(optionLetter(index))
                                            .font(.system(.callout, design: .rounded).weight(.semibold))
                                            .foregroundStyle(isSelected ? .white : .secondary)
                                            .frame(width: 24, height: 24)
                                            .background(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
                                            )

                                        Text(option)
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .multilineTextAlignment(.leading)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .strokeBorder(
                                                        isSelected ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor),
                                                        lineWidth: isSelected ? 1.5 : 1
                                                    )
                                            )
                                    )
                                }
                                .buttonStyle(.plain)

                                if isOther && isSelected {
                                    TextField("Type your answer...", text: $customAnswer)
                                        .textFieldStyle(.roundedBorder)
                                        .padding(.leading, 36)
                                }
                            }
                        }
                    }
                }

                if let error = guidedError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(20)
        }
    }

    private func optionLetter(_ index: Int) -> String {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        guard index < letters.count else { return "\(index + 1)" }
        return String(letters[letters.index(letters.startIndex, offsetBy: index)])
    }

    private var currentResolvedAnswer: String? {
        guard let index = selectedOptionIndex, index < currentOptions.count else { return nil }
        let option = currentOptions[index]
        if option.lowercased().hasPrefix("other") {
            let trimmed = customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return option
    }

    private var guidedFooter: some View {
        HStack {
            Button("Back") {
                if currentQuestion != nil {
                    currentQuestion = nil
                    currentOptions = []
                    selectedOptionIndex = nil
                    customAnswer = ""
                    guidedError = nil
                } else {
                    mode = nil
                    guidedQuestions = []
                }
            }
            .disabled(isAskingQuestion)

            Spacer()

            if currentQuestion != nil {
                Button(action: submitAnswerAndAskNext) {
                    Label("Next", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(currentResolvedAnswer == nil || isAskingQuestion)
            } else if guidedQuestions.isEmpty {
                Button(action: startGuidedFlow) {
                    Label("Start", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    projectDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !hasConfiguredProviders
                    || isLoadingProviders
                    || isAskingQuestion
                )
            }
        }
    }

    // MARK: - Input View (Quick Mode)

    private var inputView: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    descriptionSection
                    structuredFieldsSection
                    modelSelectionSection
                }
                .padding(20)
            }

            Divider()

            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Generate a Plan")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Describe your project vision. The more detail you provide, the better the generated plan.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Description Section

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Project Vision")
                    .font(.headline)
                Spacer()
                Text("\(wordCount) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            TextEditor(text: $projectDescription)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .frame(minHeight: 240, idealHeight: 320)
                .overlay(alignment: .topLeading) {
                    if projectDescription.isEmpty {
                        Text("Describe your project vision. Be detailed about goals, constraints, architecture preferences, target users, and key features. Stream-of-consciousness is encouraged — don't hold back.")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(16)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: - Structured Fields

    private var structuredFieldsSection: some View {
        DisclosureGroup(isExpanded: $showStructuredFields) {
            VStack(spacing: 12) {
                LabeledField(label: "Project Name", text: $projectName, placeholder: "e.g., Hoopoe")
                LabeledField(label: "Tech Stack", text: $techStack, placeholder: "e.g., Swift 6, Rust, SwiftUI, Tokio")
                LabeledField(label: "Platform", text: $targetPlatform, placeholder: "e.g., macOS 14+")
                LabeledField(label: "Repository URL", text: $repositoryURL, placeholder: "e.g., github.com/user/repo")
            }
            .padding(.top, 8)
        } label: {
            Text("Structured Fields (Optional)")
                .font(.headline)
        }
    }

    // MARK: - Model Selection

    private var modelSelectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model")
                .font(.headline)

            if isLoadingProviders {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking configured providers...")
                        .foregroundStyle(.secondary)
                }
            } else if hasConfiguredProviders {
                Picker("Model", selection: $selectedModelID) {
                    ForEach(modelOptions) { option in
                        Label(option.pickerLabel, systemImage: option.icon)
                            .tag(Optional(option.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 280)

                Text("\(modelOptions.count) configured model\(modelOptions.count == 1 ? "" : "s") available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                noProvidersPrompt
            }
        }
    }

    private var noProvidersPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(providerLoadError ?? "No API keys configured.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Open Settings") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .buttonStyle(.link)

                Button("Refresh Providers") {
                    Task {
                        await refreshProviders()
                    }
                }
                .buttonStyle(.link)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()

            Button(action: generatePlan) {
                Label("Generate Plan", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canGenerate)
        }
    }

    // MARK: - Split-Pane View

    private var splitPaneView: some View {
        VStack(spacing: 0) {
            splitPaneToolbar
            Divider()
            HSplitView {
                descriptionPane
                    .frame(minWidth: 300)
                generatedPlanPane
                    .frame(minWidth: 300)
            }
        }
    }

    private var splitPaneToolbar: some View {
        HStack(spacing: 12) {
            Text("Plan Generation")
                .font(.headline)

            if flowState.isGenerating {
                Text("via \(flowState.frozenModelName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if hasConfiguredProviders {
                Picker("Model", selection: $selectedModelID) {
                    ForEach(modelOptions) { option in
                        Label(option.pickerLabel, systemImage: option.icon)
                            .tag(Optional(option.id))
                    }
                }
                .frame(maxWidth: 280)
            }

            Spacer()

            splitPaneActions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var splitPaneActions: some View {
        if flowState.completedText != nil {
            Button {
                acceptAndEdit()
            } label: {
                Label("Accept & Edit", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

            Button {
                regenerate()
            } label: {
                Label("Regenerate", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)

            Button("Discard") {
                flowState.returnToInput()
            }
            .buttonStyle(.bordered)
        }

        if flowState.isGenerating {
            Button("Cancel") {
                flowState.cancel()
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }

        if case .failed = flowState.phase {
            Button {
                regenerate()
            } label: {
                Label("Try Again", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderedProminent)

            Button("Discard") {
                flowState.returnToInput()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Description Pane (Left)

    private var descriptionPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Your Vision")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(flowState.frozenDescription.split(whereSeparator: \.isWhitespace).count) words")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            ScrollView {
                Text(attributedMarkdown(flowState.frozenDescription))
                    .textSelection(.enabled)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .background(.background)
    }

    // MARK: - Generated Plan Pane (Right)

    @ViewBuilder
    private var generatedPlanPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Generated Plan")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider()

            switch flowState.phase {
            case .input:
                EmptyView()

            case .generating:
                VStack(spacing: 0) {
                    ScrollView {
                        Text(flowState.streamingText)
                            .textSelection(.enabled)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    Divider()
                    streamingStatusBar
                }

            case .complete(let text):
                MarkdownPreviewRepresentable(
                    markdown: text,
                    scrollFraction: 0
                )

            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.red)
                    Text("Generation failed")
                        .font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
    }

    private var streamingStatusBar: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Generating plan...")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if let usage = flowState.tokenUsage {
                Text("\(usage.totalTokens) tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let cost = flowState.costEstimate, cost > 0 {
                Text(String(format: "$%.4f", cost))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Computed Properties

    private var wordCount: Int {
        projectDescription.split(whereSeparator: \.isWhitespace).count
    }

    private var modelOptions: [GenerationModelOption] {
        providerRegistry.allModels.map { option in
            GenerationModelOption(
                providerID: option.provider.id,
                providerName: option.provider.displayName,
                modelID: option.model.id,
                modelDisplayName: option.model.displayName
            )
        }
    }

    private var hasConfiguredProviders: Bool {
        !modelOptions.isEmpty
    }

    private var selectedModel: GenerationModelOption? {
        modelOptions.first { $0.id == selectedModelID } ?? modelOptions.first
    }

    private var canGenerate: Bool {
        !projectDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !flowState.isGenerating
            && hasConfiguredProviders
            && !isLoadingProviders
    }

    // MARK: - Actions

    private func generatePlan() {
        guard let selectedModel,
              let provider = providerRegistry.provider(for: selectedModel.providerID)
        else { return }

        startGeneration(provider: provider, model: selectedModel)
    }

    private func regenerate() {
        guard let selectedModel,
              let provider = providerRegistry.provider(for: selectedModel.providerID)
        else { return }

        startGeneration(provider: provider, model: selectedModel)
    }

    private func startGuidedFlow() {
        guard let selectedModel,
              let provider = providerRegistry.provider(for: selectedModel.providerID)
        else { return }

        askNextQuestion(provider: provider, model: selectedModel)
    }

    private func submitAnswerAndAskNext() {
        guard let question = currentQuestion,
              let answer = currentResolvedAnswer,
              let selectedModel,
              let provider = providerRegistry.provider(for: selectedModel.providerID)
        else { return }

        guidedQuestions.append(GuidedQuestion(question: question, options: currentOptions, answer: answer))
        currentQuestion = nil
        currentOptions = []
        selectedOptionIndex = nil
        customAnswer = ""

        askNextQuestion(provider: provider, model: selectedModel)
    }

    private func askNextQuestion(provider: any LLMProvider, model: GenerationModelOption) {
        isAskingQuestion = true
        guidedError = nil

        let qaHistory = guidedQuestions.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")

        let prompt = PromptTemplates.substitute(
            template: PromptTemplates.guidedQuestionUser,
            variables: [
                "project_description": projectDescription,
                "qa_history": qaHistory.isEmpty ? "(none yet)" : qaHistory,
            ]
        )

        let stream = provider.send(
            prompt: prompt,
            model: model.modelID,
            system: PromptTemplates.guidedQuestionSystem,
            stream: false
        )

        Task { @MainActor in
            var accumulated = ""
            do {
                for try await event in stream {
                    switch event {
                    case .text(let chunk):
                        accumulated += chunk
                    case .done(let response):
                        accumulated = response.fullText
                    case .error(let error):
                        guidedError = error.localizedDescription
                        isAskingQuestion = false
                        return
                    }
                }

                let parsed = parseGuidedResponse(accumulated)
                switch parsed {
                case .question(let q, let opts):
                    currentQuestion = q
                    currentOptions = opts.isEmpty ? ["Other..."] : opts
                    selectedOptionIndex = nil
                    customAnswer = ""
                case .ready:
                    guidedComplete = true
                case .parseError(let raw):
                    currentQuestion = raw
                    currentOptions = ["Other..."]
                    selectedOptionIndex = nil
                    customAnswer = ""
                }
            } catch {
                guidedError = error.localizedDescription
            }
            isAskingQuestion = false
        }
    }

    private func parseGuidedResponse(_ text: String) -> GuidedResponseParser.Result {
        GuidedResponseParser.parse(text)
    }

    private func startGuidedGeneration(provider: any LLMProvider, model: GenerationModelOption) {
        let qaContext = guidedQuestions.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
        let enrichedDescription = """
        \(projectDescription)

        ---
        Additional context gathered through guided questions:

        \(qaContext)
        """

        flowState.cancel()
        flowState.streamingText = ""
        flowState.tokenUsage = nil
        flowState.costEstimate = nil
        flowState.frozenDescription = enrichedDescription
        flowState.frozenModelName = model.modelDisplayName
        flowState.frozenModelID = model.modelID
        flowState.frozenProviderID = model.providerID

        let prompt = PromptTemplates.substitute(
            template: PromptTemplates.planGenerationUser,
            variables: [
                "project_name": sanitized(projectName, fallback: "Untitled Project"),
                "platform": sanitized(targetPlatform, fallback: "Unspecified"),
                "tech_stack": sanitized(techStack, fallback: "Unspecified"),
                "project_description": sanitized(enrichedDescription, fallback: "No description provided."),
            ]
        )

        let stream = provider.send(
            prompt: prompt,
            model: model.modelID,
            system: PromptTemplates.planGenerationSystem,
            stream: true
        )

        flowState.phase = .generating

        let task = Task { @MainActor in
            do {
                for try await event in stream {
                    switch event {
                    case .text(let chunk):
                        flowState.streamingText += chunk
                    case .done(let response):
                        flowState.tokenUsage = response.tokenUsage
                        flowState.costEstimate = response.costEstimate
                        flowState.phase = .complete(text: response.fullText)
                        return
                    case .error(let error):
                        flowState.phase = .failed(error.localizedDescription)
                        return
                    }
                }
                if case .generating = flowState.phase {
                    flowState.phase = .complete(text: flowState.streamingText)
                }
            } catch is CancellationError {
                if case .generating = flowState.phase {
                    flowState.phase = .input
                }
            } catch {
                flowState.phase = .failed(error.localizedDescription)
            }
        }
        flowState.setStreamTask(task)
    }

    private func startGeneration(provider: any LLMProvider, model: GenerationModelOption) {
        flowState.cancel()
        flowState.streamingText = ""
        flowState.tokenUsage = nil
        flowState.costEstimate = nil
        flowState.frozenDescription = projectDescription
        flowState.frozenModelName = model.modelDisplayName
        flowState.frozenModelID = model.modelID
        flowState.frozenProviderID = model.providerID

        let stream = provider.send(
            prompt: buildPrompt(),
            model: model.modelID,
            system: PromptTemplates.planGenerationSystem,
            stream: true
        )

        flowState.phase = .generating

        let task = Task { @MainActor in
            do {
                for try await event in stream {
                    switch event {
                    case .text(let chunk):
                        flowState.streamingText += chunk
                    case .done(let response):
                        flowState.tokenUsage = response.tokenUsage
                        flowState.costEstimate = response.costEstimate
                        flowState.phase = .complete(text: response.fullText)
                        return
                    case .error(let error):
                        flowState.phase = .failed(error.localizedDescription)
                        return
                    }
                }
                // Stream ended without .done — use accumulated text
                if case .generating = flowState.phase {
                    flowState.phase = .complete(text: flowState.streamingText)
                }
            } catch is CancellationError {
                if case .generating = flowState.phase {
                    flowState.phase = .input
                }
            } catch {
                flowState.phase = .failed(error.localizedDescription)
            }
        }
        flowState.setStreamTask(task)
    }

    private func acceptAndEdit() {
        guard let text = flowState.completedText else { return }

        let trimmedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedName.isEmpty ? "Generated Plan" : trimmedName

        let plan = planStore.createPlan(title: title, content: text)

        let versionManager = PlanVersionManager(store: planStore)
        versionManager.createGenerationVersion(
            for: plan,
            modelName: flowState.frozenModelName,
            description: "Initial generation via \(flowState.frozenModelName)"
        )

        router.navigate(to: .planEditor(planId: plan.id))
    }

    private func buildPrompt() -> String {
        let description = if repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            projectDescription
        } else {
            "\(projectDescription)\n\nRepository URL: \(repositoryURL)"
        }

        return PromptTemplates.substitute(
            template: PromptTemplates.planGenerationUser,
            variables: [
                "project_name": sanitized(projectName, fallback: "Untitled Project"),
                "platform": sanitized(targetPlatform, fallback: "Unspecified"),
                "tech_stack": sanitized(techStack, fallback: "Unspecified"),
                "project_description": sanitized(description, fallback: "No description provided."),
            ]
        )
    }

    private func sanitized(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    @MainActor
    private func refreshProviders() async {
        isLoadingProviders = true
        defer { isLoadingProviders = false }

        providerLoadError = nil
        let discoveredProviders = await discoverProviders()
        providerRegistry.replaceProviders(with: discoveredProviders)

        if let currentSelection = selectedModelID,
           modelOptions.contains(where: { $0.id == currentSelection }) {
            return
        }
        selectedModelID = modelOptions.first?.id
    }

    private func discoverProviders() async -> [any LLMProvider] {
        let keychain = KeychainService()
        var discovered: [any LLMProvider] = []

        await loadProvider(into: &discovered, using: keychain, providerID: "anthropic") { apiKey in
            ClaudeProvider(apiKey: apiKey)
        }
        await loadProvider(into: &discovered, using: keychain, providerID: "openai") { apiKey in
            OpenAIProvider(apiKey: apiKey)
        }
        await loadProvider(into: &discovered, using: keychain, providerID: "google") { apiKey in
            GeminiProvider(apiKey: apiKey)
        }

        return discovered
    }

    private func loadProvider(
        into discovered: inout [any LLMProvider],
        using keychain: KeychainService,
        providerID: String,
        factory: (String) -> any LLMProvider
    ) async {
        do {
            let apiKey = try await keychain.retrieve(provider: providerID)
            discovered.append(factory(apiKey))
        } catch KeychainError.itemNotFound {
            return
        } catch {
            providerLoadError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func attributedMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

// MARK: - Labeled Field

private struct LabeledField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(alignment: .center) {
            Text(label)
                .frame(width: 120, alignment: .trailing)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Guided Response Parser

enum GuidedResponseParser {
    enum Result {
        case question(String, [String])
        case ready
        case parseError(String)
    }

    static func parse(_ text: String) -> Result {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") { cleaned = String(cleaned.dropFirst(7)) }
        if cleaned.hasPrefix("```") { cleaned = String(cleaned.dropFirst(3)) }
        if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String
        else {
            return .parseError(cleaned)
        }

        if status == "ready" {
            return .ready
        } else if status == "question", let question = json["question"] as? String {
            let options = (json["options"] as? [String]) ?? []
            return .question(question, options)
        }

        return .parseError(cleaned)
    }
}

// MARK: - Previews

#Preview {
    PlanGenerationView(
        router: NavigationRouter(),
        planStore: PlanStore(directory: FileManager.default.temporaryDirectory)
    )
    .frame(width: 900, height: 600)
}
