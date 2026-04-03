import HoopoeUI
import HoopoeUtils
import SwiftUI

// MARK: - Wizard State

@Observable
@MainActor
final class WizardState {
    enum Step: Int, CaseIterable {
        case foundation = 0
        case vision = 1
        case generation = 2
        case review = 3

        var title: String {
            switch self {
            case .foundation: "Foundation"
            case .vision: "Vision"
            case .generation: "Generate"
            case .review: "Review"
            }
        }
    }

    enum GenerationPhase {
        case idle
        case generating
        case complete(text: String)
        case failed(String)
    }

    var currentStep: Step = .foundation

    // Step 1 — Foundation
    var projectName = ""
    var techStack = ""
    var targetPlatform = ""
    var repositoryURL = ""

    // Step 2 — Vision
    var projectVision = ""

    // Step 3 — Generation
    var generationPhase: GenerationPhase = .idle
    var streamingText = ""
    private var streamTask: Task<Void, Never>?

    // Step 4 — Review
    var generatedPlanText: String? {
        if case .complete(let text) = generationPhase { return text }
        return nil
    }

    var canAdvance: Bool {
        switch currentStep {
        case .foundation:
            !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .vision:
            true
        case .generation:
            generatedPlanText != nil
        case .review:
            false
        }
    }

    var canGoBack: Bool {
        currentStep.rawValue > 0
    }

    var isGenerating: Bool {
        if case .generating = generationPhase { return true }
        return false
    }

    func goNext() {
        guard let next = Step(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
    }

    func goBack() {
        guard let prev = Step(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prev
    }

    func jumpTo(_ step: Step) {
        currentStep = step
    }

    func startOver() {
        cancelGeneration()
        currentStep = .foundation
    }

    func cancelGeneration() {
        streamTask?.cancel()
        streamTask = nil
        if case .generating = generationPhase {
            generationPhase = .idle
            streamingText = ""
        }
    }

    func setStreamTask(_ task: Task<Void, Never>) {
        self.streamTask = task
    }

    func resetGeneration() {
        cancelGeneration()
        generationPhase = .idle
        streamingText = ""
    }
}

// MARK: - Plan Wizard View

struct PlanWizardView: View {
    let router: NavigationRouter
    let planStore: PlanStore

    @State private var wizard = WizardState()
    @State private var providerRegistry = ProviderRegistry()
    @State private var selectedModelID: String?
    @State private var isLoadingProviders = false

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            navigationBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .task {
            await refreshProviders()
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(WizardState.Step.allCases, id: \.rawValue) { step in
                HStack(spacing: 6) {
                    Circle()
                        .fill(stepColor(for: step))
                        .frame(width: 8, height: 8)

                    Text(step.title)
                        .font(.caption)
                        .fontWeight(step == wizard.currentStep ? .semibold : .regular)
                        .foregroundStyle(step == wizard.currentStep ? .primary : .secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if step.rawValue <= wizard.currentStep.rawValue {
                        wizard.jumpTo(step)
                    }
                }

                if step != WizardState.Step.allCases.last {
                    Rectangle()
                        .fill(step.rawValue < wizard.currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                }
            }
        }
    }

    private func stepColor(for step: WizardState.Step) -> Color {
        if step.rawValue < wizard.currentStep.rawValue {
            return .accentColor
        } else if step == wizard.currentStep {
            return .accentColor
        } else {
            return .secondary.opacity(0.3)
        }
    }

    // MARK: - Step Content

    @ViewBuilder
    private var stepContent: some View {
        switch wizard.currentStep {
        case .foundation:
            foundationStep
        case .vision:
            visionStep
        case .generation:
            generationStep
        case .review:
            reviewStep
        }
    }

    // MARK: - Step 1: Foundation

    private var foundationStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project Foundation")
                        .font(.title2.weight(.semibold))
                    Text("Name your project and optionally describe its technical context.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    HStack(alignment: .center) {
                        Text("Project Name")
                            .frame(width: 120, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        TextField("e.g., Hoopoe", text: $wizard.projectName)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(alignment: .center) {
                        Text("Tech Stack")
                            .frame(width: 120, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("e.g., Swift 6, Rust, SwiftUI", text: $wizard.techStack)
                                .textFieldStyle(.roundedBorder)
                            if !techStackSuggestions.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(techStackSuggestions, id: \.self) { suggestion in
                                        Button(suggestion) {
                                            if wizard.techStack.isEmpty {
                                                wizard.techStack = suggestion
                                            } else {
                                                wizard.techStack += ", \(suggestion)"
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(.quaternary)
                                        .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                    }

                    HStack(alignment: .center) {
                        Text("Platform")
                            .frame(width: 120, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        TextField("e.g., macOS 14+", text: $wizard.targetPlatform)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack(alignment: .center) {
                        Text("Repository")
                            .frame(width: 120, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        TextField("e.g., github.com/user/repo (optional)", text: $wizard.repositoryURL)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Text("Only the project name is required. The more context you provide, the better the generated plan.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
    }

    private var techStackSuggestions: [String] {
        let name = wizard.projectName.lowercased()
        var suggestions: [String] = []
        if name.contains("ios") || name.contains("iphone") || name.contains("ipad") {
            suggestions.append("Swift, SwiftUI")
        }
        if name.contains("macos") || name.contains("mac") || name.contains("desktop") {
            suggestions.append("Swift, AppKit")
        }
        if name.contains("web") || name.contains("site") || name.contains("dashboard") {
            suggestions.append("React, TypeScript")
        }
        if name.contains("cli") || name.contains("tool") || name.contains("command") {
            suggestions.append("Rust")
        }
        if name.contains("api") || name.contains("server") || name.contains("backend") {
            suggestions.append("Node.js, TypeScript")
        }
        if name.contains("python") || name.contains("ml") || name.contains("data") {
            suggestions.append("Python")
        }
        return suggestions
    }

    // MARK: - Step 2: Vision

    private var visionStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Project Vision")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Text("\(visionWordCount) words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text("Tell me everything about your project \u{2014} the more detail, the better the plan.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            TextEditor(text: $wizard.projectVision)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .topLeading) {
                    if wizard.projectVision.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Consider describing:")
                                .fontWeight(.medium)
                            Text("\u{2022} What problem does this solve?")
                            Text("\u{2022} Who is the target user?")
                            Text("\u{2022} What are the main features?")
                            Text("\u{2022} What constraints or requirements exist?")
                            Text("\u{2022} What does success look like?")
                        }
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(16)
                        .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            if visionWordCount >= 50 {
                HStack(spacing: 6) {
                    Image(systemName: visionWordCount >= 200 ? "checkmark.circle.fill" : "info.circle")
                        .foregroundStyle(visionWordCount >= 200 ? .green : .blue)
                    Text(visionEncouragement)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
    }

    private var visionWordCount: Int {
        wizard.projectVision.split(whereSeparator: \.isWhitespace).count
    }

    private var visionEncouragement: String {
        switch visionWordCount {
        case 50..<100:
            "Good start. Adding more detail about features and constraints will improve the plan."
        case 100..<200:
            "Nice detail! Consider adding architecture preferences or failure modes."
        case 200..<500:
            "Great depth! This will produce a thorough plan."
        default:
            "Excellent! This level of detail will produce an exceptional plan."
        }
    }

    // MARK: - Step 3: Generation

    private var generationStep: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Generate Plan")
                    .font(.title2.weight(.semibold))

                if isLoadingProviders {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking providers...")
                            .foregroundStyle(.secondary)
                    }
                } else if hasConfiguredProviders {
                    HStack(spacing: 12) {
                        Text("Model:")
                            .foregroundStyle(.secondary)
                        Picker("Model", selection: $selectedModelID) {
                            ForEach(providerRegistry.allModels, id: \.model.id) { entry in
                                Text("\(entry.provider.displayName) \u{2014} \(entry.model.displayName)")
                                    .tag(Optional(entry.model.id))
                            }
                        }
                        .frame(maxWidth: 300)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("No API keys configured. Open Settings to add one.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            switch wizard.generationPhase {
            case .idle:
                VStack(spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("Ready to generate")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Your project details will be sent to the selected model to create a comprehensive plan.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)

                    Button {
                        startGeneration()
                    } label: {
                        Label("Generate Plan", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!hasConfiguredProviders || isLoadingProviders)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .generating:
                VStack(spacing: 0) {
                    ScrollView {
                        Text(wizard.streamingText)
                            .textSelection(.enabled)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    Divider()
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating plan...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") {
                            wizard.cancelGeneration()
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
                }

            case .complete(_):
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    Text("Plan generated successfully!")
                        .font(.title3)
                    Text("Continue to review the generated plan.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.red)
                    Text("Generation failed")
                        .font(.title3)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)

                    Button {
                        wizard.resetGeneration()
                        startGeneration()
                    } label: {
                        Label("Try Again", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Step 4: Review

    @ViewBuilder
    private var reviewStep: some View {
        if let planText = wizard.generatedPlanText {
            VStack(spacing: 0) {
                HStack {
                    Text("Review Generated Plan")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Text("\(planText.split(whereSeparator: \.isWhitespace).count) words")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider()

                ScrollView {
                    Text(attributedMarkdown(planText))
                        .textSelection(.enabled)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("No plan generated yet")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Button("Go to Generation") {
                    wizard.jumpTo(.generation)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        HStack {
            if wizard.canGoBack {
                Button {
                    wizard.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if wizard.currentStep == .review {
                Button {
                    wizard.resetGeneration()
                    wizard.jumpTo(.generation)
                } label: {
                    Label("Regenerate", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)

                Button("Start Over") {
                    wizard.startOver()
                }
                .buttonStyle(.bordered)

                Button {
                    acceptAndOpenEditor()
                } label: {
                    Label("Accept & Open in Editor", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(wizard.generatedPlanText == nil)
            } else if wizard.currentStep == .generation {
                if wizard.generatedPlanText != nil {
                    Button {
                        wizard.goNext()
                    } label: {
                        Label("Review Plan", systemImage: "chevron.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Button {
                    wizard.goNext()
                } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!wizard.canAdvance)
            }
        }
    }

    // MARK: - Actions

    private func startGeneration() {
        guard let modelEntry = selectedModelEntry,
              let provider = providerRegistry.provider(for: modelEntry.provider.id)
        else { return }

        wizard.resetGeneration()
        wizard.generationPhase = .generating

        let prompt = buildPrompt()

        let stream = provider.send(
            prompt: prompt,
            model: modelEntry.model.id,
            system: PromptTemplates.planGenerationSystem,
            stream: true
        )

        let task = Task { @MainActor in
            do {
                for try await event in stream {
                    switch event {
                    case .text(let chunk):
                        wizard.streamingText += chunk
                    case .done(let response):
                        wizard.generationPhase = .complete(text: response.fullText)
                        return
                    case .error(let error):
                        wizard.generationPhase = .failed(error.localizedDescription)
                        return
                    }
                }
                if case .generating = wizard.generationPhase {
                    wizard.generationPhase = .complete(text: wizard.streamingText)
                }
            } catch is CancellationError {
                if case .generating = wizard.generationPhase {
                    wizard.generationPhase = .idle
                }
            } catch {
                wizard.generationPhase = .failed(error.localizedDescription)
            }
        }
        wizard.setStreamTask(task)
    }

    private func acceptAndOpenEditor() {
        guard let planText = wizard.generatedPlanText else { return }

        let trimmedName = wizard.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedName.isEmpty ? "Generated Plan" : trimmedName

        let plan = planStore.createPlan(title: title, content: planText)

        let modelName = selectedModelEntry?.model.displayName ?? "unknown"
        let versionManager = PlanVersionManager(store: planStore)
        versionManager.createGenerationVersion(
            for: plan,
            modelName: modelName,
            description: "Generated via plan wizard using \(modelName)"
        )

        router.navigate(to: .planEditor(planId: plan.id))
    }

    private func buildPrompt() -> String {
        var description = wizard.projectVision
        if !wizard.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            description += "\n\nRepository URL: \(wizard.repositoryURL)"
        }

        return PromptTemplates.substitute(
            template: PromptTemplates.planGenerationUser,
            variables: [
                "project_name": sanitized(wizard.projectName, fallback: "Untitled Project"),
                "platform": sanitized(wizard.targetPlatform, fallback: "Unspecified"),
                "tech_stack": sanitized(wizard.techStack, fallback: "Unspecified"),
                "project_description": sanitized(description, fallback: wizard.projectName),
            ]
        )
    }

    private func sanitized(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    // MARK: - Provider Discovery

    private var hasConfiguredProviders: Bool {
        !providerRegistry.allModels.isEmpty
    }

    private var selectedModelEntry: (provider: any LLMProvider, model: LLMModel)? {
        if let id = selectedModelID {
            return providerRegistry.allModels.first { $0.model.id == id }
        }
        return providerRegistry.allModels.first
    }

    @MainActor
    private func refreshProviders() async {
        isLoadingProviders = true
        defer { isLoadingProviders = false }

        let discovered = await discoverProviders()
        providerRegistry.replaceProviders(with: discovered)

        if selectedModelID == nil || !providerRegistry.allModels.contains(where: { $0.model.id == selectedModelID }) {
            selectedModelID = providerRegistry.allModels.first?.model.id
        }
    }

    private func discoverProviders() async -> [any LLMProvider] {
        let keychain = KeychainService()
        var discovered: [any LLMProvider] = []

        for (providerID, factory) in Self.providerFactories {
            do {
                let apiKey = try await keychain.retrieve(provider: providerID)
                discovered.append(factory(apiKey))
            } catch {
                continue
            }
        }

        return discovered
    }

    private static let providerFactories: [(String, (String) -> any LLMProvider)] = [
        ("anthropic", { ClaudeProvider(apiKey: $0) }),
        ("openai", { OpenAIProvider(apiKey: $0) }),
        ("google", { GeminiProvider(apiKey: $0) }),
    ]

    // MARK: - Helpers

    private func attributedMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
