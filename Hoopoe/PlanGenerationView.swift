import SwiftUI

// MARK: - LLM Provider (placeholder for br-2bf.21 integration)

/// Available LLM providers for plan generation.
/// Populated from configured API keys once provider beads land.
enum LLMProvider: String, CaseIterable, Identifiable, Sendable {
    case claudeOpus = "Claude Opus"
    case claudeSonnet = "Claude Sonnet"
    case gpt4o = "GPT-4o"
    case geminiPro = "Gemini Pro"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .claudeOpus, .claudeSonnet: "brain"
        case .gpt4o: "sparkle"
        case .geminiPro: "diamond"
        }
    }
}

// MARK: - Plan Generation View

struct PlanGenerationView: View {
    @State private var projectDescription = ""
    @State private var selectedProvider: LLMProvider = .claudeOpus
    @State private var showStructuredFields = false
    @State private var isGenerating = false

    // Optional structured fields
    @State private var projectName = ""
    @State private var techStack = ""
    @State private var targetPlatform = ""
    @State private var repositoryURL = ""

    // Provider availability (will be wired to KeychainService in later beads)
    @State private var hasConfiguredProviders = true

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

            if hasConfiguredProviders {
                Picker("Model", selection: $selectedProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Label(provider.rawValue, systemImage: provider.icon)
                            .tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 240)
            } else {
                noProvidersPrompt
            }
        }
    }

    private var noProvidersPrompt: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("No API keys configured.")
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .buttonStyle(.link)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if isGenerating {
                ProgressView()
                    .controlSize(.small)
                Text("Generating plan...")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: generatePlan) {
                Label("Generate Plan", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(projectDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating || !hasConfiguredProviders)
        }
    }

    // MARK: - Computed Properties

    private var wordCount: Int {
        projectDescription.split(whereSeparator: \.isWhitespace).count
    }

    // MARK: - Actions

    private func generatePlan() {
        isGenerating = true
        // Plan generation will be wired to LLM API client (br-2bf.21+) in a later bead.
        // For now, this is a placeholder that will be connected when the streaming
        // response renderer (br-2bf.25) and API clients (br-2bf.22/23/24) are ready.
        Task {
            try? await Task.sleep(for: .seconds(1))
            isGenerating = false
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
