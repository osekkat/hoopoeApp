# Hoopoe: Agentic Coding Flywheel Orchestrator for macOS

## Context

The user wants a native macOS app that centralizes and automates the Agentic Coding Flywheel methodology (from agent-flywheel.com/complete-guide). Today this workflow requires manually coordinating multiple CLI tools (br, bv, ntm, Agent Mail) and terminal sessions. Hoopoe replaces that with a single GUI that manages the full lifecycle: plan creation -> bead conversion -> bead visualization/curation -> agent swarm launch -> monitoring.

The closest comparable app is conductor.build (a macOS app for parallel Claude/Codex orchestration via git worktrees). Hoopoe differentiates by being plan-centric, integrating the beads system, and using MCP Agent Mail for inter-agent coordination.

**Current state**: Empty project at `/Users/osekkat/hoopoeApp/` with Swift 6.2.4, Xcode 26.3, macOS 15 arm64.

---

## Tech Stack

- **Swift 6.2 + SwiftUI** (native macOS app)
- **Xcode project** with SPM dependencies
- **No App Sandbox** (must spawn CLI processes, access filesystem)
- **Deployment target**: macOS 14.0+ (for @Observable macro)

**SPM Dependencies:**
- `apple/swift-markdown` — parse plan.md into AST for bead conversion
- `apple/swift-collections` — ordered collections for graph operations
- `apple/swift-async-algorithms` — merge/debounce async streams from agent processes

**Why SwiftUI over Tauri/Electron**: Native performance, first-class Process spawning via Foundation, structured concurrency for multi-agent monitoring, Metal-backed Canvas for graph rendering. Developer tool should feel native.

---

## Architecture

```
UI Layer (SwiftUI Views)
  |
ViewModel Layer (@Observable classes)
  |
Service Layer (actors)
  |
Model Layer (structs/enums)
```

### Service Layer — How We Talk to External Tools

| Service | Wraps | Method |
|---------|-------|--------|
| `CLIService` | Foundation `Process` | Actor. Spawns processes, captures stdout/stderr via Pipe, returns `CLIOutput` or `AsyncStream<String>` |
| `AgentDetectionService` | `claude`, `codex`, `gemini`, `br`, `bv`, `ntm` | Checks `~/.local/bin/`, `~/.bun/bin/`, `$PATH`. Runs `--version` to confirm |
| `BeadsService` | `br` CLI | `br list --json`, `br create`, `br update`, `br close`, `br dep add`, `br ready --json`, `br sync --flush-only` |
| `BeadsViewerService` | `bv` CLI | `bv --robot-triage`, `bv --robot-graph --graph-format=json`, `bv --robot-insights`, `bv --robot-plan` |
| `NTMService` | `ntm` CLI | `ntm spawn --cc=N --cod=N --gmi=N`, `ntm send`, `ntm --robot-status`, `ntm --robot-snapshot` |
| `AgentMailService` | HTTP `127.0.0.1:8765` | JSON-RPC 2.0 via URLSession. `ensure_project`, `register_agent`, `send_message`, `fetch_inbox`, `file_reservation_paths` |
| `PlanParserService` | `swift-markdown` | Parses plan.md AST -> extracts headings/checkboxes -> produces `[BeadDraft]` |
| `FileWatcherService` | `DispatchSource` | Monitors `.beads/issues.jsonl` for external changes, triggers refresh |

### Key Design Decisions

1. **Bead data is authoritative in `.beads/`** — Hoopoe never writes JSONL directly. All mutations go through `br` CLI. App reads via `br list --json` and `bv --robot-graph`.
2. **Polling for swarm monitoring** — Poll `ntm --robot-snapshot` every 2s during active swarms. Compare `dataHash` to skip redundant parsing.
3. **App registers as Agent Mail orchestrator** — Hoopoe registers itself as an agent to send directives and receive status.

---

## Core Data Models

```swift
struct Project: Identifiable, Codable {
    let id: UUID
    var name: String
    var path: URL
    var plans: [PlanReference]
    var isBeadsInitialized: Bool
}

struct PlanReference: Identifiable, Codable {
    let id: UUID
    var filename: String        // "plan.md", "feature1.md"
    var path: URL
}

struct Bead: Identifiable, Codable {
    let id: String              // "bd-xxx"
    var title: String
    var description: String?
    var status: BeadStatus      // open | in_progress | closed
    var priority: Int           // 0-4
    var issueType: String?
    var labels: [String]
    var dependencies: [Dependency]
    var comments: [Comment]
    var createdAt: Date
    var updatedAt: Date
}

enum BeadStatus: String, Codable, CaseIterable {
    case open, inProgress = "in_progress", closed
}

struct Dependency: Codable {
    let issueId: String
    let dependsOnId: String
    let type: DependencyType
}

enum DependencyType: String, Codable {
    case blocks, blockedBy = "blocked_by", related
}

struct Comment: Codable {
    let author: String
    let body: String
    let createdAt: Date
}

struct SwarmConfig {
    var sessionName: String
    var projectPath: URL
    var claudeCount: Int
    var codexCount: Int
    var geminiCount: Int
}

struct DetectedAgent: Identifiable {
    let id = UUID()
    let type: AgentType
    let path: String
    let version: String?
    let isAvailable: Bool
}

enum AgentType: String, CaseIterable {
    case claude, codex, gemini
    var displayName: String { rawValue.capitalized }
}

struct SwarmSession: Identifiable {
    let id: String
    var agents: [SwarmAgent]
    var status: SwarmStatus
    var createdAt: Date
}

struct SwarmAgent: Identifiable {
    let id: String
    var type: AgentType
    var state: AgentState
    var currentBead: String?
    var lastOutput: String?
}

enum AgentState: String { case idle, working, error, exited }
enum SwarmStatus { case running, stopped, error }

struct AgentMessage: Identifiable, Codable {
    let id: String
    var from: String
    var to: String
    var subject: String?
    var body: String
    var threadId: String?
    var timestamp: Date
    var isRead: Bool
}
```

---

## UI Layout

```
NavigationSplitView
+--------+------------------------------------------+--------------+
| Sidebar|        Main Content                      | Inspector    |
|        |                                          | (optional)   |
| Project|  Switches based on sidebar selection:    |              |
| -------+                                          |              |
| Plans  |  - PlanEditorView (split: source|preview)|              |
|  plan  |  - BeadGraphView (Canvas DAG)            | BeadDetail   |
|  feat1 |  - BeadListView (Table)                  |              |
| -------+  - SwarmConfigView (agent steppers)      |              |
| Beads  |  - SwarmDashboardView (agent cards)       |              |
|  Graph |  - AgentMailView (inbox/thread)           |              |
|  List  |                                          |              |
| -------+                                          |              |
| Swarm  |                                          |              |
|  Config|                                          |              |
|  Dash  |                                          |              |
| -------+                                          |              |
| Mail   |                                          |              |
| -------+                                          |              |
| Settings                                          |              |
+--------+------------------------------------------+--------------+
| Status Bar: agent counts, mail badge, swarm status              |
+----------------------------------------------------------------+
```

### Key Views

1. **PlanEditorView** — HSplitView: TextEditor (monospace) + MarkdownPreview (AttributedString via swift-markdown). Toolbar: "Convert to Beads" button.

2. **BeadGraphView** — SwiftUI Canvas rendering a Sugiyama (layered) DAG layout.
   - Nodes: rounded rects, colored by status (gray=open, blue=in_progress, green=closed)
   - Node size scaled by PageRank score
   - Priority shown as left-edge accent bar (red=P0, orange=P1, yellow=P2)
   - Critical path: thick orange edges drawn on top
   - "Ready" beads (unblocked+open): pulsing green border
   - Agent assignments: avatar badge on node
   - Interactions: pan, zoom, click-to-select, hover-to-highlight-deps, right-click context menu
   - Quadtree spatial index for hit-testing (Canvas lacks built-in hit-test)
   - Minimap overlay in corner

3. **BeadListView** — SwiftUI Table with columns (ID, Title, Status, Priority, Labels, Deps). Filter bar for status/priority/label. Synchronized selection with graph view via shared `@Observable` state.

4. **SwarmConfigView** — Shows detected agents (green/red status). Steppers for Claude/Codex/Gemini count (0-8 each). "Launch Swarm" button.

5. **SwarmDashboardView** — Grid of AgentCards. Each card: status dot, agent type icon, current bead, last 5 lines of output. Refreshed via `ntm --robot-snapshot` polling every 2s. Broadcast send, stop buttons.

6. **AgentMailView** — HSplitView: message list + message detail. Compose/reply. Unread badge in sidebar.

---

## Graph Rendering Strategy

**Layout: Sugiyama (layered/hierarchical)** — correct for DAGs, makes critical path flow top-to-bottom, aligns same-phase beads in layers. Written in pure Swift, runs on background actor. <50ms for 500 nodes.

**Rendering: SwiftUI Canvas** — Metal-backed, 60fps for 500 nodes + 1000 edges. Immediate-mode drawing. Node/edge renderers as helper functions.

**Hit-testing: Quadtree** — ~100 lines of Swift. Updated after each layout pass. O(log n) lookups.

**Performance: LOD** — At zoom <0.3x, replace rects with circles and hide labels. At zoom <0.15x, hide edges, show colored dots only.

**Animation: TimelineView** — Status transitions animate color over 0.5s. In-progress beads pulse. New nodes fade in. Structural changes re-layout with position interpolation over 0.8s.

**Visual Encoding:**
- Status: gray=open, blue=in_progress, green=closed (node fill)
- Priority: left-edge accent bar (red=P0/critical, orange=P1/high, yellow=P2/medium, gray=P3/low, none=P4/backlog)
- PageRank: node size (40x24 to 80x48 points)
- Betweenness centrality: double border (bottleneck indicator)
- Critical path: thick orange edges, drawn on top layer
- Ready beads (unblocked+open): pulsing green dashed border
- Agent-assigned: avatar badge bottom-right
- Issue type: small SF Symbol top-left (checkmark=task, ladybug=bug, star=feature, diamond=epic)
- Edge types: solid arrow=blocks, dashed gray=related

---

## Project File Structure

```
/Users/osekkat/hoopoeApp/
  Hoopoe/
    HoopoeApp.swift
    MainView.swift
    Models/
      Project.swift
      Bead.swift
      Agent.swift
      Swarm.swift
      AgentMessage.swift
      GraphTypes.swift
    ViewModels/
      AppState.swift
      PlanViewModel.swift
      BeadViewModel.swift
      GraphViewModel.swift
      SwarmViewModel.swift
      AgentMailViewModel.swift
      ToolDetectionViewModel.swift
    Views/
      Sidebar/
        SidebarView.swift
        ProjectSelectorView.swift
      Plan/
        PlanEditorView.swift
        PlanListView.swift
        MarkdownPreviewView.swift
      Beads/
        BeadGraphView.swift
        BeadListView.swift
        BeadEditSheet.swift
        BeadDetailInspector.swift
      Swarm/
        SwarmConfigView.swift
        SwarmDashboardView.swift
        AgentCardView.swift
      Mail/
        AgentMailView.swift
        MessageListView.swift
        MessageDetailView.swift
      Settings/
        SettingsView.swift
        ToolDetectionView.swift
      Shared/
        StatusBadge.swift
        PriorityBadge.swift
        LoadingOverlay.swift
    Services/
      CLIService.swift
      BeadsService.swift
      BeadsViewerService.swift
      NTMService.swift
      AgentMailService.swift
      AgentDetectionService.swift
      PlanParserService.swift
      FileWatcherService.swift
    Utilities/
      JSONRPCClient.swift
      SugiyamaLayout.swift
      ForceDirectedLayout.swift
      Quadtree.swift
      MarkdownRenderer.swift
      ColorPalette.swift
    Resources/
      Assets.xcassets/
        AppIcon.appiconset/
        AgentIcons/
        StatusColors.colorset/
      Hoopoe.entitlements
    Preview Content/
      PreviewData.swift
  HoopoeTests/
    Services/
      CLIServiceTests.swift
      BeadsServiceTests.swift
      PlanParserServiceTests.swift
    ViewModels/
      SwarmViewModelTests.swift
  Hoopoe.xcodeproj/
  plan.md
  .gitignore
```

---

## Implementation Phases

### Phase 1: Foundation (app shell, project management, agent detection)
- Create Xcode project with folder structure
- `HoopoeApp.swift`, `MainView.swift` (NavigationSplitView), `SidebarView.swift`
- `AppState` (@Observable) with project list persistence in `~/Library/Application Support/Hoopoe/`
- `CLIService` actor (Process + Pipe, async stdout capture)
- `AgentDetectionService` (find claude/codex/gemini/br/bv/ntm)
- `SettingsView` + `ToolDetectionView` (green/red per tool)
- `ProjectSelectorView` (create/open project)

### Phase 2: Plans & Beads (import plans, convert to beads, table view)
- `PlanParserService` using swift-markdown (AST -> BeadDraft[])
- `PlanEditorView` with split editor/preview
- `BeadsService` wrapping br CLI commands
- `BeadListView` with Table, filter bar, sorting
- `BeadEditSheet` for manual curation
- "Convert to Beads" flow: parse plan -> confirm drafts -> `br create` batch

### Phase 3: Bead Graph (interactive dependency visualization)
- `SugiyamaLayout` algorithm (layer assignment, crossing minimization, coordinate assignment)
- `BeadsViewerService` wrapping `bv --robot-graph --graph-format=json`
- `BeadGraphView` using SwiftUI Canvas (nodes, edges, arrows)
- `Quadtree` for hit-testing
- Pan/zoom gestures, click-to-select, hover-to-highlight
- `GraphViewModel` merging bv data with layout state
- Critical path overlay from `bv --robot-insights`
- Minimap, filter bar, dual-view sync with table

### Phase 4: Swarm Launch & Config
- `NTMService` wrapping ntm spawn/status/send/stop
- `SwarmConfigView` with agent steppers and launch button
- Launch flow: validate tools -> `ntm spawn` -> transition to dashboard
- `FileWatcherService` monitoring `.beads/issues.jsonl`

### Phase 5: Swarm Monitoring Dashboard
- `SwarmDashboardView` with agent card grid
- `AgentCardView` (status, type, current bead, output tail)
- Polling loop: `ntm --robot-snapshot` every 2s
- Per-agent tail via `ntm --robot-tail`
- Broadcast send, stop controls
- Alerts from `bv --robot-alerts`

### Phase 6: Agent Mail Integration
- `AgentMailService` with JSON-RPC 2.0 client (`JSONRPCClient`)
- `AgentMailView` with message list + detail
- Register Hoopoe as orchestrator agent
- Compose/reply, unread badge

### Phase 7: Polish
- Keyboard shortcuts, menu bar status, drag-and-drop in graph
- Bead merge, undo/redo, error handling, graph export

---

## Verification

After each phase, verify:
1. **Phase 1**: App launches, shows sidebar, detects installed CLI tools with green/red indicators
2. **Phase 2**: Can create project, import plan.md, see bead list from `br list --json`
3. **Phase 3**: Bead graph renders with correct layout, nodes selectable, dependencies visible
4. **Phase 4**: Can configure and launch swarm via NTM, agents start in tmux
5. **Phase 5**: Dashboard updates in real-time, shows agent status and bead progress
6. **Phase 6**: Can view Agent Mail inbox, send messages to agents
7. **Build**: `xcodebuild -project Hoopoe.xcodeproj -scheme Hoopoe build` succeeds throughout

---

## External Tool CLI Reference

### Agent Detection Paths
```
claude:  ~/.local/bin/claude, ~/.bun/bin/claude
codex:   ~/.local/bin/codex, ~/.bun/bin/codex
gemini:  ~/.local/bin/gemini, ~/.bun/bin/gemini
br:      ~/.cargo/bin/br, ~/.local/bin/br
bv:      ~/.cargo/bin/bv, ~/.local/bin/bv
ntm:     ~/.cargo/bin/ntm, ~/.local/bin/ntm
```

### Agent Non-Interactive Flags
```
claude --dangerously-skip-permissions "<prompt>"
codex --dangerously-bypass-approvals-and-sandbox "<prompt>"
gemini --yolo "<prompt>"
```

### Beads CLI (br)
```bash
br list --json                    # All beads as JSON array
br ready --json                   # Unblocked beads
br create --title "..." --priority 2 --labels backend
br update <id> --status in_progress
br close <id> --reason "Done"
br dep add <id> <dep_id>
br comments add <id> "Note..."
br sync --flush-only
br init                           # Initialize .beads/ in project
```

### Beads Viewer (bv) — ALWAYS use --robot-* flags
```bash
bv --robot-triage                 # Full recommendations + metrics
bv --robot-graph --graph-format=json  # Dependency graph as JSON
bv --robot-insights               # PageRank, betweenness, HITS, critical path
bv --robot-plan                   # Parallel execution tracks
bv --robot-alerts                 # Stale issues, blocking cascades
bv --robot-next                   # Single top pick
```

### NTM (Named Tmux Manager)
```bash
ntm spawn <name> --cc=N --cod=N --gmi=N  # Launch agent swarm
ntm send <name> "prompt"                   # Broadcast to all agents
ntm send <name> --cc "prompt"              # Send to Claude agents only
ntm --robot-status                         # JSON status
ntm --robot-snapshot                       # Full swarm snapshot
ntm --robot-tail <session> --lines=50      # Recent output
```

### Agent Mail (HTTP JSON-RPC 2.0 at 127.0.0.1:8765)
```
Health:        GET /health/liveness
MCP endpoint:  POST /mcp/

Key tools:
- ensure_project(project_key)
- register_agent(project_key, program, model)
- send_message(project_key, sender_name, to, subject, body_md, thread_id)
- fetch_inbox(project_key, agent_name, limit)
- file_reservation_paths(project_key, agent_name, paths, ttl_seconds, exclusive, reason)
- release_file_reservations(project_key, agent_name, paths)
- acknowledge_message(project_key, agent_name, message_id)
```

### Bead JSONL Schema (`.beads/issues.jsonl`)
```json
{
  "id": "bd-xxx",
  "title": "string",
  "description": "markdown string",
  "status": "open|in_progress|closed",
  "priority": 0-4,
  "issue_type": "task|bug|feature|epic|question|docs",
  "labels": ["string"],
  "dependencies": [{"issue_id": "bd-xxx", "depends_on_id": "bd-yyy", "type": "blocks|blocked_by|related"}],
  "comments": [{"author": "string", "body": "string", "created_at": "ISO8601"}],
  "created_at": "ISO8601",
  "updated_at": "ISO8601",
  "closed_at": "ISO8601 (optional)",
  "close_reason": "string (optional)"
}
```
