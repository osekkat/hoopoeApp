import Foundation
import Observation
import SwiftUI

/// Centralized, observable application settings backed by UserDefaults.
///
/// All preference values flow through this single source of truth.
/// SwiftUI views observe property changes automatically via `@Observable`.
///
/// This class is designed to be accessed from `@MainActor` contexts
/// and will serve as the basis for the HoopoeHost SettingsService in Phase 2+.
@MainActor @Observable
final class AppSettings {
    // MARK: - Shared Instance

    static let shared = AppSettings()

    // MARK: - UserDefaults Keys

    private enum Key {
        static let defaultSaveDirectory = "defaultSaveDirectory"
        static let lastProjectDirectory = "lastProjectDirectory"
        static let autoSaveEnabled = "autoSaveEnabled"
        static let autoSaveIntervalSeconds = "autoSaveIntervalSeconds"
        static let editorFontSize = "editorFontSize"
        static let editorLineWrapping = "editorLineWrapping"
        static let editorShowLineNumbers = "editorShowLineNumbers"
        static let editorTheme = "editorTheme"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    // MARK: - Storage

    private let defaults: UserDefaults

    // MARK: - General Settings

    /// Directory where plans are saved by default.
    var defaultSaveDirectory: URL {
        didSet { defaults.set(defaultSaveDirectory.path, forKey: Key.defaultSaveDirectory) }
    }

    /// Last opened project directory (nil = show project picker on launch).
    var lastProjectDirectory: URL? {
        didSet {
            if let dir = lastProjectDirectory {
                defaults.set(dir.path, forKey: Key.lastProjectDirectory)
            } else {
                defaults.removeObject(forKey: Key.lastProjectDirectory)
            }
        }
    }

    /// Whether auto-save is enabled.
    var autoSaveEnabled: Bool {
        didSet { defaults.set(autoSaveEnabled, forKey: Key.autoSaveEnabled) }
    }

    /// Auto-save interval in seconds.
    var autoSaveIntervalSeconds: Int {
        didSet { defaults.set(autoSaveIntervalSeconds, forKey: Key.autoSaveIntervalSeconds) }
    }

    // MARK: - Editor Settings

    /// Editor font size in points.
    var editorFontSize: Double {
        didSet { defaults.set(editorFontSize, forKey: Key.editorFontSize) }
    }

    /// Whether the editor wraps long lines.
    var editorLineWrapping: Bool {
        didSet { defaults.set(editorLineWrapping, forKey: Key.editorLineWrapping) }
    }

    /// Whether to show line numbers in the editor gutter.
    var editorShowLineNumbers: Bool {
        didSet { defaults.set(editorShowLineNumbers, forKey: Key.editorShowLineNumbers) }
    }

    /// Editor color theme.
    var editorTheme: EditorTheme {
        didSet { defaults.set(editorTheme.rawValue, forKey: Key.editorTheme) }
    }

    // MARK: - Onboarding

    /// Whether the user has completed the first-run onboarding.
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Register defaults
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let defaultPlansDir = documentsDir.appendingPathComponent("Hoopoe Plans", isDirectory: true)

        defaults.register(defaults: [
            Key.defaultSaveDirectory: defaultPlansDir.path,
            Key.autoSaveEnabled: true,
            Key.autoSaveIntervalSeconds: 30,
            Key.editorFontSize: 14.0,
            Key.editorLineWrapping: true,
            Key.editorShowLineNumbers: true,
            Key.editorTheme: EditorTheme.system.rawValue,
            Key.hasCompletedOnboarding: false,
        ])

        // Load persisted values
        if let path = defaults.string(forKey: Key.defaultSaveDirectory) {
            self.defaultSaveDirectory = URL(fileURLWithPath: path)
        } else {
            self.defaultSaveDirectory = defaultPlansDir
        }

        if let projectPath = defaults.string(forKey: Key.lastProjectDirectory) {
            self.lastProjectDirectory = URL(fileURLWithPath: projectPath)
        } else {
            self.lastProjectDirectory = nil
        }
        self.autoSaveEnabled = defaults.bool(forKey: Key.autoSaveEnabled)

        let interval = defaults.integer(forKey: Key.autoSaveIntervalSeconds)
        self.autoSaveIntervalSeconds = interval > 0 ? interval : 30

        let fontSize = defaults.double(forKey: Key.editorFontSize)
        self.editorFontSize = fontSize > 0 ? fontSize : 14.0

        self.editorLineWrapping = defaults.bool(forKey: Key.editorLineWrapping)
        self.editorShowLineNumbers = defaults.bool(forKey: Key.editorShowLineNumbers)

        if let themeRaw = defaults.string(forKey: Key.editorTheme),
           let theme = EditorTheme(rawValue: themeRaw)
        {
            self.editorTheme = theme
        } else {
            self.editorTheme = .system
        }

        self.hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
    }
}

// MARK: - Editor Theme

enum EditorTheme: String, CaseIterable, Identifiable, Sendable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }
}
