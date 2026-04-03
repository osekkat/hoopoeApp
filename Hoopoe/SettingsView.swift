import HoopoeUtils
import SwiftUI

// MARK: - Settings Tabs

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case providers = "Providers"
    case editor = "Editor"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .providers: "key"
        case .editor: "pencil.and.outline"
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            ProvidersSettingsTab()
                .tabItem {
                    Label("Providers", systemImage: "key")
                }
                .tag(SettingsTab.providers)

            EditorSettingsTab()
                .tabItem {
                    Label("Editor", systemImage: "pencil.and.outline")
                }
                .tag(SettingsTab.editor)
        }
        .frame(width: 520, height: 440)
    }
}

// MARK: - General Settings Tab

struct GeneralSettingsTab: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("File Management") {
                HStack {
                    Text("Default save location:")
                    Spacer()
                    Text(settings.defaultSaveDirectory.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Choose...") {
                        chooseSaveDirectory()
                    }
                }

                Toggle("Auto-save plans", isOn: $settings.autoSaveEnabled)

                if settings.autoSaveEnabled {
                    Picker("Auto-save interval:", selection: $settings.autoSaveIntervalSeconds) {
                        Text("15 seconds").tag(15)
                        Text("30 seconds").tag(30)
                        Text("60 seconds").tag(60)
                        Text("2 minutes").tag(120)
                        Text("5 minutes").tag(300)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select the default directory for saving plans."

        if panel.runModal() == .OK, let url = panel.url {
            settings.defaultSaveDirectory = url
        }
    }
}

// MARK: - Providers Settings Tab

struct ProvidersSettingsTab: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ProviderSection(
                    providerName: "Claude (Anthropic)",
                    providerKey: KeychainService.Provider.anthropic.rawValue,
                    icon: "brain.head.profile",
                    keyHint: "sk-ant-..."
                )
                ProviderSection(
                    providerName: "OpenAI (GPT)",
                    providerKey: KeychainService.Provider.openai.rawValue,
                    icon: "sparkles",
                    keyHint: "sk-..."
                )
                ProviderSection(
                    providerName: "Google (Gemini)",
                    providerKey: KeychainService.Provider.google.rawValue,
                    icon: "globe",
                    keyHint: "AI..."
                )
            }
            .padding()
        }
    }
}

// MARK: - Provider Section

private struct ProviderSection: View {
    let providerName: String
    let providerKey: String
    let icon: String
    let keyHint: String

    @State private var keys: [ProviderKeyEntry] = []
    @State private var newKeyText = ""
    @State private var newKeyAccount = "default"
    @State private var isExpanded = true
    @State private var validationMessage: String?

    private let keychain = KeychainService()

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                // Existing keys
                if keys.isEmpty {
                    Text("No API keys configured")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                        .padding(.vertical, 4)
                } else {
                    ForEach(keys) { entry in
                        ProviderKeyRow(
                            entry: entry,
                            isPrimary: entry.account == "default",
                            onMakePrimary: { makePrimary(entry) },
                            onDelete: { deleteKey(entry) }
                        )
                    }
                }

                Divider()

                // Add new key
                HStack(spacing: 8) {
                    SecureField(keyHint, text: $newKeyText)
                        .textFieldStyle(.roundedBorder)

                    if !keys.isEmpty {
                        TextField("Label", text: $newKeyAccount)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }

                    Button {
                        addKey()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newKeyText.isEmpty)
                    .buttonStyle(.plain)
                    .foregroundStyle(.green)

                    Button("Test") {
                        validateKey()
                    }
                    .disabled(newKeyText.isEmpty)
                    .controlSize(.small)
                }

                if let message = validationMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message.contains("Valid") ? .green : .red)
                }
            }
            .padding(.leading, 4)
        } label: {
            Label(providerName, systemImage: icon)
                .font(.headline)
        }
        .padding(12)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task { await loadKeys() }
    }

    private func loadKeys() async {
        do {
            let accounts = try await keychain.listAccounts(provider: providerKey)
            var entries: [ProviderKeyEntry] = []
            for credential in accounts {
                let masked = await maskedKey(for: credential.account)
                entries.append(ProviderKeyEntry(account: credential.account, maskedKey: masked))
            }
            keys = entries
        } catch {
            keys = []
        }
    }

    private func maskedKey(for account: String) async -> String {
        do {
            let secret = try await keychain.retrieve(provider: providerKey, account: account)
            if secret.count > 4 {
                return "..." + String(secret.suffix(4))
            }
            return "****"
        } catch {
            return "****"
        }
    }

    private func addKey() {
        let account = keys.isEmpty ? "default" : newKeyAccount
        Task {
            do {
                try await keychain.upsert(secret: newKeyText, provider: providerKey, account: account)
                newKeyText = ""
                newKeyAccount = "default"
                validationMessage = nil
                await loadKeys()
            } catch {
                validationMessage = "Failed to save: \(error.localizedDescription)"
            }
        }
    }

    private func deleteKey(_ entry: ProviderKeyEntry) {
        Task {
            do {
                try await keychain.delete(provider: providerKey, account: entry.account)
                await loadKeys()
            } catch {
                validationMessage = "Failed to delete: \(error.localizedDescription)"
            }
        }
    }

    private func makePrimary(_ entry: ProviderKeyEntry) {
        // Swap: promoted key becomes "default", old "default" takes the promoted key's account name
        Task {
            do {
                let promotedSecret = try await keychain.retrieve(provider: providerKey, account: entry.account)

                // Retrieve old default if it exists, so we can preserve it under the swapped name
                var oldDefaultSecret: String?
                do {
                    oldDefaultSecret = try await keychain.retrieve(provider: providerKey, account: "default")
                } catch {
                    // No existing default — nothing to swap
                }

                // Delete both entries before re-inserting to avoid duplicate errors
                try? await keychain.delete(provider: providerKey, account: entry.account)
                try? await keychain.delete(provider: providerKey, account: "default")

                // Promoted key → "default"
                try await keychain.store(secret: promotedSecret, provider: providerKey, account: "default")

                // Old default → promoted key's old account name (if there was an old default)
                if let oldSecret = oldDefaultSecret {
                    try await keychain.store(secret: oldSecret, provider: providerKey, account: entry.account)
                }

                await loadKeys()
            } catch {
                validationMessage = "Failed to set primary: \(error.localizedDescription)"
            }
        }
    }

    private func validateKey() {
        Task {
            let isValid = await keychain.validateKeyFormat(key: newKeyText, provider: providerKey)
            validationMessage = isValid ? "Valid format" : "Invalid format for \(providerName)"
        }
    }
}

// MARK: - Provider Key Entry

private struct ProviderKeyEntry: Identifiable {
    let account: String
    let maskedKey: String
    var id: String { account }
}

// MARK: - Provider Key Row

private struct ProviderKeyRow: View {
    let entry: ProviderKeyEntry
    let isPrimary: Bool
    let onMakePrimary: () -> Void
    let onDelete: () -> Void

    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 8) {
            // Primary indicator
            Button {
                if !isPrimary { onMakePrimary() }
            } label: {
                Image(systemName: isPrimary ? "star.fill" : "star")
                    .foregroundStyle(isPrimary ? .yellow : .tertiary)
            }
            .buttonStyle(.plain)
            .help(isPrimary ? "Primary key" : "Make primary")

            // Account label
            Text(entry.account)
                .font(.callout)
                .frame(width: 60, alignment: .leading)

            // Masked/revealed key
            Text(entry.maskedKey)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            // Delete button
            Button {
                onDelete()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editor Settings Tab

struct EditorSettingsTab: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme:", selection: $settings.editorTheme) {
                    ForEach(EditorTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Font size:")
                    Slider(value: $settings.editorFontSize, in: 10...24, step: 1) {
                        Text("Font size")
                    }
                    Text("\(Int(settings.editorFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Section("Behavior") {
                Toggle("Wrap long lines", isOn: $settings.editorLineWrapping)
                Toggle("Show line numbers", isOn: $settings.editorShowLineNumbers)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Previews

#Preview("Settings") {
    SettingsView()
}
