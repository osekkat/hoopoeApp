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
        .frame(width: 480, height: 320)
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
        Form {
            Section("API Keys") {
                Text("Provider API key configuration will be available in a future update.")
                    .foregroundStyle(.secondary)

                // Placeholder structure for the three providers
                GroupBox("Claude (Anthropic)") {
                    Text("Not configured")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }

                GroupBox("OpenAI (GPT)") {
                    Text("Not configured")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }

                GroupBox("Google (Gemini)") {
                    Text("Not configured")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
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
