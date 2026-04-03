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

private struct GenerationSession: Identifiable {
    let id = UUID()
    let title: String
    let stream: AsyncThrowingStream<LLMEvent, Error>
}

// MARK: - Plan Generation View

struct PlanGenerationView: View {
    @State private var projectDescription = ""
    @State private var providerRegistry = ProviderRegistry()
    @State private var selectedModelID: GenerationModelOption.ID?
    @State private var showStructuredFields = false
    @State private var isLoadingProviders = false
    @State private var generationSession: GenerationSession?
    @State private var providerLoadError: String?

    // Optional structured fields
    @State private var projectName = ""
    @State private var techStack = ""
    @State private var targetPlatform = ""
    @State private var repositoryURL = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            // Main content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    descriptionSection
                    structuredFieldsSection
                    modelSelectionSection
                }
                .padding(20)
            }

            Divider()

            // Footer with generate button
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await refreshProviders()
        }
        .sheet(item: $generationSession) { session in
            NavigationStack {
                StreamingResponseView(stream: session.stream)
                    .navigationTitle(session.title)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") {
                                generationSession = nil
                            }
                        }
                    }
                    .frame(minWidth: 720, minHeight: 520)
            }
        }
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
                    Text("Checking configured providers…")
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
            if generationSession != nil {
                ProgressView()
                    .controlSize(.small)
                Text("Generation session active")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: generatePlan) {
                Label("Generate Plan", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canGenerate)
        }
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
            && generationSession == nil
            && hasConfiguredProviders
            && !isLoadingProviders
    }

    // MARK: - Actions

    private func generatePlan() {
        guard let selectedModel,
              let provider = providerRegistry.provider(for: selectedModel.providerID)
        else {
            return
        }

        let stream = provider.send(
            prompt: buildPrompt(),
            model: selectedModel.modelID,
            system: PromptTemplates.planGenerationSystem,
            stream: true
        )

        generationSession = GenerationSession(
            title: selectedModel.modelDisplayName,
            stream: stream
        )
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

// MARK: - Previews

#Preview {
    PlanGenerationView()
        .frame(width: 700, height: 600)
}
