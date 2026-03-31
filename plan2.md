# Hoopoe Phase 1: App Shell, CLI Detection, Project & Plan Management

## Context

Building a native macOS SwiftUI app ("Hoopoe") that orchestrates the Agentic Coding Flywheel methodology. The app manages the full lifecycle: plan creation -> bead conversion -> bead visualization -> agent swarm launch -> monitoring. Phase 1 establishes the foundation: app shell, CLI agent detection, project management, and plan import/editing.

**Current state**: Empty directory with only `plan.md`. No Xcode project, no source files.  
**Machine**: macOS 15 arm64, Swift 6.2.4, Xcode 26.3, xcodegen 2.44.1.  
**Installed CLIs**: claude (v2.1.88), codex (v0.117.0), gemini (v0.35.1), br (v0.1.14), bv, ntm — all via nvm/homebrew/local.

---

## Key Design Decisions

1. **xcodegen** for project generation — `project.yml` -> `.xcodeproj`. Already installed. Avoids hand-crafting `.pbxproj` UUIDs.
2. **No SPM dependencies in Phase 1** — Markdown preview uses Foundation's `AttributedString(markdown:)` (macOS 13+). Defer `swift-markdown`, `swift-collections`, `swift-async-algorithms` to Phase 2.
3. **Actor-based services** — `CLIService` and `AgentDetectionService` are Swift actors for thread-safe CLI interaction under Swift 6 strict concurrency.
4. **Login shell PATH resolution** — GUI apps don't inherit user PATH. Use `zsh -l -c 'env -0'` to capture the full environment (nvm, homebrew, cargo, bun paths).
5. **Four-state detection** — `notFound | found(version) | authenticated(version, detail) | error(message)`.
6. **Parallel detection** — `TaskGroup` scans all 6+ tools concurrently (~5s max vs ~30s sequential).

---

## File Structure (23 files)

```
/Users/osekkat/hoopoeApp/
  project.yml                              # xcodegen spec
  .gitignore
  plan.md                                  # (exists)
  Hoopoe/
    HoopoeApp.swift                        # @main App entry
    Info.plist
    Models/
      Project.swift                        # Project, PlanReference
      Agent.swift                          # AgentKind, DetectionStatus, DetectedAgent, DetectedTool
      CLIOutput.swift                      # CLIOutput, CLIError
    ViewModels/
      AppState.swift                       # @Observable @MainActor central state
    Views/
      MainView.swift                       # NavigationSplitView root
      DetailRouter.swift                   # Routes sidebar -> detail views
      WelcomeView.swift                    # Landing screen
      Sidebar/
        SidebarView.swift                  # Project list + sections
        StatusBarView.swift                # Bottom bar with agent indicators
      Project/
        NewProjectSheet.swift              # Create project modal
        ProjectDashboardView.swift         # Project overview + plan grid
      Plan/
        PlanEditorView.swift               # Split editor + markdown preview
      Settings/
        SettingsView.swift                 # Tool detection rows + rescan
      Shared/
        StatusBadge.swift                  # Reusable green/red dot
        EmptyStateView.swift               # Reusable empty state placeholder
    Services/
      CLIService.swift                     # Actor: Foundation Process wrapper
      AgentDetectionService.swift          # Actor: finds + verifies CLI tools
    Resources/
      Hoopoe.entitlements                  # Sandbox disabled
      Assets.xcassets/
        Contents.json
        AppIcon.appiconset/Contents.json
    Preview Content/
      PreviewData.swift
```

---

## Implementation Plan (4 Batches)

### Batch 1: Scaffold (verify: `xcodegen generate` succeeds)

**Files**: `.gitignore`, `project.yml`, `Info.plist`, `Hoopoe.entitlements`, `Assets.xcassets/` contents

`project.yml` key settings:
- `deploymentTarget.macOS: "14.0"` (for @Observable)
- `SWIFT_VERSION: "6.0"` (strict concurrency)
- `ENABLE_APP_SANDBOX: NO`
- `DEVELOPMENT_TEAM: EU3MHLDEPF`
- `sources: [{path: Hoopoe}]` (auto-discovers .swift files)
- No SPM dependencies

**Verify**: `cd /Users/osekkat/hoopoeApp && xcodegen generate`

---

### Batch 2: Models + Services (verify: `xcodebuild build` succeeds)

#### `Hoopoe/Models/CLIOutput.swift`
- `struct CLIOutput: Sendable` — `stdout: String`, `stderr: String`, `exitCode: Int32`, computed `succeeded: Bool`
- `enum CLIError: Error, Sendable` — cases: `binaryNotFound`, `timeout`, `processError`, `environmentResolutionFailed`

#### `Hoopoe/Models/Agent.swift`
- `enum AgentKind: String, CaseIterable, Sendable` — `.claude`, `.codex`, `.gemini` with `displayName`, `iconName` (SF Symbols), `knownPaths`, `credentialPaths`
- `enum SupportingToolKind: String, CaseIterable, Sendable` — `.br`, `.bv`, `.ntm`, `.agentMail`
- `enum DetectionStatus: Sendable` — `.notFound`, `.found(version:)`, `.authenticated(version:, authDetail:)`, `.error(message:)`
- `enum AuthDetail: Sendable` — `.claude(email:, subscriptionType:)`, `.codex(authMode:)`, `.gemini(activeAccount:)`, `.token`
- `struct DetectedAgent: Identifiable, Sendable` — `kind`, `binaryPath`, `status`, `detectedAt`
- `struct DetectedTool: Identifiable, Sendable` — same shape
- `struct DetectionResult: Sendable` — `agents: [DetectedAgent]`, `tools: [DetectedTool]`, `scanDuration`, `scannedAt`

#### `Hoopoe/Models/Project.swift`
- `struct Project: Identifiable, Codable, Hashable` — `id: UUID`, `name: String`, `path: URL`, `plans: [PlanReference]`, `createdAt: Date`
- `struct PlanReference: Identifiable, Codable, Hashable` — `id: UUID`, `filename: String`, `path: URL`

#### `Hoopoe/Services/CLIService.swift`
Actor wrapping Foundation `Process`. Critical methods:

- `resolveEnvironment() async throws -> [String: String]` — runs `zsh -l -c 'env -0'` once, caches result. Parses null-delimited output into dictionary. This gives the full user PATH including nvm, homebrew, cargo, bun paths.
- `run(_ executablePath:, arguments:, timeout:) async throws -> CLIOutput` — spawns Process with resolved environment. Reads stdout/stderr via Pipe using `DispatchQueue.global().async` + `withCheckedContinuation` bridge (avoids blocking cooperative thread pool). Timeout via TaskGroup race pattern.
- `findBinary(named:, searchPaths:) async -> String?` — checks explicit paths first (expanding `~` and nvm glob `*/`), then searches resolved PATH entries directly. Uses `FileManager.isExecutableFile(atPath:)`.
- `invalidateEnvironmentCache()` — clears cached env for re-scan.

**Deadlock prevention**: `readDataToEndOfFile()` is synchronous and blocks. Must dispatch to `DispatchQueue.global()` and bridge back via continuation. Never call it on the cooperative thread pool.

#### `Hoopoe/Services/AgentDetectionService.swift`
Actor using CLIService. Key method:

- `scan() async -> DetectionResult` — runs `detectAllAgents()` and `detectAllTools()` concurrently via `async let`. Each internally uses `withTaskGroup` for parallel per-tool detection.

Per-agent detection sequence:
1. `findBinary` in known paths (expanding nvm globs like `~/.nvm/versions/node/*/bin/claude`)
2. Run `<tool> --version`, parse output per tool:
   - Claude: `"2.1.88 (Claude Code)"` -> `"2.1.88"` (split on space, take first)
   - Codex: `"codex-cli 0.117.0"` -> `"0.117.0"` (split on space, take last)
   - Gemini: `"0.35.1"` -> `"0.35.1"` (as-is)
3. Check auth:
   - **Claude**: run `claude auth status` -> parse JSON (`loggedIn`, `email`, `subscriptionType`)
   - **Codex**: read `~/.codex/auth.json` -> check for `OPENAI_API_KEY` or `tokens.access_token`
   - **Gemini**: read `~/.gemini/google_accounts.json` -> check `active` field; fallback read `~/.gemini/oauth_creds.json`
   - **Agent Mail**: HTTP GET `http://127.0.0.1:8765/health/liveness` (200 = running)

**Verify**: `xcodegen generate && xcodebuild -project Hoopoe.xcodeproj -scheme Hoopoe build`

---

### Batch 3: App Shell + Sidebar + Navigation

#### `Hoopoe/ViewModels/AppState.swift`
`@MainActor @Observable class AppState`:
- Properties: `projects: [Project]`, `selectedSidebarItem: SidebarItem?`, `detectionResult: DetectionResult?`, `isDetecting: Bool`
- `enum SidebarItem: Hashable` — `.welcome`, `.project(UUID)`, `.plan(UUID)`, `.settings`
- Persistence: JSON at `~/Library/Application Support/Hoopoe/projects.json`. `loadProjects()` on init, `saveProjects()` after mutations. `JSONEncoder` with `.prettyPrinted`, `.sortedKeys`, `.iso8601`.
- Project CRUD: `createProject(name:path:)`, `deleteProject(id:)`, `addPlanToProject(projectID:, fileURL:)`, `removePlan(planID:, fromProject:)`
- `runDetection() async` — calls `AgentDetectionService.scan()`, updates `detectionResult`

#### `Hoopoe/HoopoeApp.swift`
- `@main struct HoopoeApp: App` with `@State private var appState = AppState()`
- Injects via `.environment(appState)`. WindowGroup + Settings scene.
- `.defaultSize(width: 1100, height: 700)`

#### `Hoopoe/Views/MainView.swift`
- `NavigationSplitView` with sidebar + detail
- `.task { await appState.runDetection() }` triggers scan on launch
- `@Bindable var appState = appState` pattern for bindings with @Observable

#### `Hoopoe/Views/DetailRouter.swift`
- Switches on `appState.selectedSidebarItem` -> WelcomeView / ProjectDashboardView / PlanEditorView / SettingsView

#### `Hoopoe/Views/Sidebar/SidebarView.swift`
- `List(selection:)` with sections: Projects (disclosure groups with nested plans), Settings
- Toolbar "+" button -> NewProjectSheet
- `.safeAreaInset(edge: .bottom) { StatusBarView() }`

#### `Hoopoe/Views/Sidebar/StatusBarView.swift`
- Compact row of colored dots for each detected agent + tool count

#### `Hoopoe/Views/Shared/StatusBadge.swift`
- `Circle().fill(isActive ? .green : .red).frame(width: 8, height: 8)`

#### `Hoopoe/Views/Shared/EmptyStateView.swift`
- Reusable: SF Symbol icon, title, description, optional action button

**Verify**: App launches, shows NavigationSplitView with empty sidebar + welcome screen. Status bar shows detection results.

---

### Batch 4: Content Views

#### `Hoopoe/Views/WelcomeView.swift`
- Centered layout: app name, "Create New Project" button, "Open Existing Directory" button
- If no agents detected: warning callout with install instructions
- Recent projects list

#### `Hoopoe/Views/Project/NewProjectSheet.swift`
- Form: TextField for name, directory picker via `NSOpenPanel` (canChooseDirectories, canCreateDirectories)
- Create button calls `appState.createProject(name:path:)`

#### `Hoopoe/Views/Project/ProjectDashboardView.swift`
- Project name as title, directory path (clickable -> reveal in Finder)
- Grid of plan file cards + "Import Plan" button (NSOpenPanel filtered to `.md`)
- "Create New Plan" button -> creates empty .md file in project directory

#### `Hoopoe/Views/Plan/PlanEditorView.swift`
- `HSplitView`: left = `TextEditor` (monospace), right = togglable markdown preview
- Preview via `AttributedString(markdown: sourceText, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))`
- Toolbar: Preview toggle, Save button (Cmd+S)
- Loads file content on `.task`, writes back on save

#### `Hoopoe/Views/Settings/SettingsView.swift`
- Form with two sections: "AI Agents" (claude/codex/gemini rows) and "Flywheel Tools" (br/bv/ntm/agent mail rows)
- Each row: SF Symbol, name, version, status badge (green=authenticated, orange=found, red=not found), path in caption
- "Re-scan" button at bottom

#### `Hoopoe/Preview Content/PreviewData.swift`
- Static sample data for SwiftUI previews

**Verify**: Full Phase 1 acceptance criteria (see below).

---

## Critical Implementation Details

### PATH Resolution (CLIService)
GUI apps launched from Finder/Dock inherit minimal launchd PATH (`/usr/bin:/bin:/usr/sbin:/sbin`). User tools at `~/.nvm/`, `~/.local/bin/`, `/opt/homebrew/bin/` are invisible. Fix: `zsh -l -c 'env -0'` captures the login shell environment. Cache on first call, invalidate on re-scan.

### Process Pipe Deadlock Prevention
If a process writes >64KB to stdout, `readDataToEndOfFile()` blocks and `waitUntilExit()` never returns. Solution: dispatch reads to `DispatchQueue.global()` and bridge back via `withCheckedContinuation`:
```swift
let stdout = await withCheckedContinuation { cont in
    DispatchQueue.global().async {
        cont.resume(returning: pipe.fileHandleForReading.readDataToEndOfFile())
    }
}
```

### Swift 6 Strict Concurrency
- `CLIService`, `AgentDetectionService` = actors (inherently Sendable isolation)
- `AppState` = `@MainActor @Observable` (UI-bound)
- All model structs = `Sendable` (pure value types)
- `Process` never crosses actor boundaries (confined to CLIService)
- `@Bindable var appState = appState` pattern required for bindings with @Observable

### NVM Glob Expansion
Tools are at `~/.nvm/versions/node/v22.17.0/bin/` — the version dir changes on upgrade. Search paths use glob pattern `~/.nvm/versions/node/*/bin/<tool>`. `AgentDetectionService.expandGlob()` enumerates the parent directory and checks each candidate.

### Home Directory Path Expansion
`~` does NOT expand in Swift's FileManager. Always use `FileManager.default.homeDirectoryForCurrentUser` and append components.

---

## Verification Checklist

After all batches complete:

1. **Build**: `xcodegen generate && xcodebuild -project Hoopoe.xcodeproj -scheme Hoopoe build` — zero errors
2. **Launch**: App opens with NavigationSplitView. Sidebar shows "Projects" (empty) + "Settings"
3. **Detection**: Status bar shows colored dots for claude, codex, gemini. Settings shows all 6 tools with versions and auth status
4. **Create project**: Click "+", name it, choose directory. Project appears in sidebar
5. **Import plan**: Select project, click "Import Plan", pick .md file. Plan appears nested under project
6. **Create plan**: Click "Create New Plan" in dashboard. New .md file created in project directory
7. **Edit plan**: Click plan in sidebar. Editor loads content. Edit + Save (Cmd+S). Reopen — changes persisted
8. **Preview**: Toggle preview pane. Markdown renders bold, italic, headings, code
9. **Persistence**: Quit + relaunch. Projects and plans still present. Check `~/Library/Application Support/Hoopoe/projects.json`
10. **Graceful degradation**: If a CLI is missing, app shows red dot + "Not found" but remains fully functional for project/plan management
