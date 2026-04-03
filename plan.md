# Hoopoe — Native macOS Multi-Agent Software Development App

## Comprehensive Architectural Plan

---

## 1. Executive Summary

Hoopoe is a native macOS application that implements the Agentic Coding Flywheel methodology in a polished, visual desktop experience. It replaces the current terminal-and-VPS-centric workflow with a structured GUI that guides users through the full lifecycle: **Plan → Beads → Swarm → Harden → Learn**. The app orchestrates multiple AI coding agents (Claude Code, OpenAI Codex, and Gemini CLI) simultaneously, providing real-time visibility into agent status, bead progress, inter-agent communication, and code quality — all without requiring the user to manage tmux panes, SSH sessions, or raw CLI commands.

The core insight driving this design: the Flywheel methodology proves that 85% of value comes from exhaustive planning and bead polishing, yet the existing tooling requires deep terminal expertise to operate. Hoopoe democratizes this methodology by encoding the workflow into a purpose-built application while preserving full power-user escape hatches.

The product adopts a **Core/Shell architecture**:

- **Shell (SwiftUI + AppKit):** All macOS-native UI, windowing, editor, terminal, permissions, Keychain access, and user interaction.
- **Core (Rust):** Agent orchestration, provider integrations, coordination stack, persistence, session indexing, budgeting, and protocol adapters.
- **Bridge (UniFFI + Swift adapter layer):** A narrow FFI boundary exposing coarse commands, async operations, snapshots, and event streams from Rust into a Swift-native shell.

---

## 2. Application Architecture

### 2.1 Technology Stack

| Layer                   | Technology                                                                                                                                         | Rationale                                                                                                                                                                                                                                                                                                                                                                           |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **UI Framework**        | SwiftUI + AppKit (hybrid, see framework split below)                                                                                               | SwiftUI for data-entry and status-display views (sidebar, settings, kanban, config panels, cost dashboard). AppKit for high-performance rendering, rich text, and complex layout (plan editor, diff viewer, terminal emulation, swarm dashboard panes, dependency graph, session browser). Bridged via `NSViewRepresentable` (AppKit→SwiftUI) and `NSHostingView` (SwiftUI→AppKit). |
| **Shell Language**      | Swift 6 (with strict concurrency)                                                                                                                  | Native performance, modern async/await, first-class macOS integration                                                                                                                                                                                                                                                                                                               |
| **Core Language**       | Rust (stable)                                                                                                                                      | Memory safety without GC, strong async ecosystem (Tokio), ideal for protocol/process orchestration                                                                                                                                                                                                                                                                                  |
| **Bridge Layer**        | Mozilla UniFFI + handwritten Swift adapter facade                                                                                                  | Type-safe FFI with async support; adapter layer insulates shell from generated types                                                                                                                                                                                                                                                                                                |
| **Agent Orchestration** | Rust async runtime (`tokio`) + task supervision                                                                                                    | Non-blocking process/network/storage I/O; structured task trees for agent lifecycle                                                                                                                                                                                                                                                                                                 |
| **Agent Harnesses**     | Rust provider adapters for Claude Code, Codex, and Gemini                                                                                          | All providers behind a common Rust trait. Claude uses the Agent SDK (Python) via Rust adapter; native Rust port remains a future option                                                                                                                                                                                                                                                                                                      |
| **IPC Layer**           | `tokio::process`, WebSocket/JSON-RPC, stdout stream parsing, Unix domain sockets                                                                   | Tokio-native process and network I/O for provider communication                                                                                                                                                                                                                                                                                                                     |
| **Coordination**        | MCP Agent Mail (SQLite + Git), beads_rust (br), beads_viewer (bv)                                                                                  | Direct integration with the Flywheel coordination stack                                                                                                                                                                                                                                                                                                                             |
| **Database**            | SQLite owned by the Rust core                                                                                                                      | Single authority for persistent state; shell queries snapshots                                                                                                                                                                                                                                                                                                                      |
| **Code Editor**         | SourceEditor (NSTextView-based) + TreeSitter                                                                                                       | Syntax highlighting, diff view for reviewing agent changes                                                                                                                                                                                                                                                                                                                          |
| **Terminal Emulation**  | Ghostty via `libghostty` C API (GPU-accelerated Metal rendering)                                                                                   | High-performance terminal rendering proven by Factory Floor; `ghostty_surface_t` wrapped in NSView, built as git submodule (Zig)                                                                                                                                                                                                                                                                 |
| **Build System**        | Cargo workspace + Swift Package Manager + Xcode                                                                                                    | Rust engine builds via Cargo; Xcode/SPM integrates the xcframework                                                                                                                                                                                                                                                                                                                  |
| **Persistence**         | Rust-managed SQLite + JSONL session artifacts                                                                                                      | Engine owns structured data; JSONL for CASS-compatible session logs                                                                                                                                                                                                                                                                                                                 |

### 2.2 Module Architecture

```
Hoopoe.app
├── hoopoe-engine/                 # Rust core crate/workspace
│   ├── src/core/                 # Agent orchestration engine
│   │   ├── agent_manager.rs      # Agent lifecycle, task supervision
│   │   ├── agent_process.rs      # tokio::process wrapper for agent CLIs
│   │   ├── scheduler.rs          # Dependency-aware work scheduling: leases ready beads
│   │   │                         #   to agents based on dependency readiness, provider
│   │   │                         #   capabilities, budget headroom, system load, and
│   │   │                         #   recent completion rates. Adapts concurrency dynamically.
│   │   ├── run_manager.rs        # Run state machine: tracks each attempt to complete a
│   │   │                         #   bead (queued→leased→running→review→merged | failed).
│   │   │                         #   Handles retries, orphan cleanup, and dead-letter routing.
│   │   ├── lease_manager.rs      # Run leases with TTLs and heartbeats. Missing heartbeats
│   │   │                         #   trigger automatic requeue or escalation.
│   │   ├── dead_letter.rs        # Failed runs requiring human action: presents context,
│   │   │                         #   failure summary, and suggested next steps
│   │   ├── agent_router.rs       # Capability-aware provider selection using bead
│   │   │                         #   requiredCapabilities + graph metrics
│   │   ├── rate_limit.rs         # Detects rate limits, rotates accounts
│   │   ├── budget_tracker.rs     # Token usage and cost tracking
│   │   ├── policy_engine.rs      # Tiered safety: Allowed/Blocked/ApprovalRequired
│   │   │                         #   Regex pattern matching, durable approval records
│   │   └── checkpoint.rs         # Swarm checkpoint: snapshot & restore full engine
│   │                             #   state (agents, runs, beads, git, budget, approvals)
│   │
│   ├── src/providers/            # Multi-provider abstraction
│   │   ├── mod.rs                # Common ProviderTrait + ProviderEvent
│   │   ├── claude/
│   │   │   ├── protocol.rs       # WebSocket/JSON-RPC control protocol
│   │   │   ├── types.rs          # Message types, options, hooks
│   │   │   └── sdk_adapter.rs    # Rust adapter wrapping the Claude Agent SDK (Python)
│   │   │                         #   as a Tokio-managed subprocess. Primary integration
│   │   │                         #   path. Future: port to native Rust when justified.
│   │   ├── codex.rs              # OpenAI Codex app-server JSON-RPC client
│   │   ├── gemini.rs             # Gemini CLI subprocess + stream-json parsing
│   │   └── detector.rs           # Auto-detects installed CLIs
│   │
│   ├── src/coordination/         # Flywheel coordination stack
│   │   ├── agent_mail.rs         # MCP Agent Mail integration
│   │   ├── beads_manager.rs      # br (beads_rust) integration
│   │   ├── beads_viewer.rs       # bv (beads_viewer) graph analysis
│   │   ├── file_reservation.rs   # Advisory file locking
│   │   └── agentsmd_gen.rs       # Auto-generates AGENTS.md
│   │
│   ├── src/planning/             # Plan creation & management
│   │   ├── plan_document.rs      # Markdown source + compiled Plan AST
│   │   ├── plan_schema.rs        # Typed sections (goals, constraints, architecture,
│   │   │                         #   failure modes, testing, observability, rollout,
│   │   │                         #   security, acceptance criteria), stable section IDs,
│   │   │                         #   and structural invariants
│   │   ├── plan_linter.rs        # Structural + semantic validation: flags missing
│   │   │                         #   required sections, empty acceptance criteria,
│   │   │                         #   orphaned references, even if markdown is valid
│   │   ├── traceability.rs       # Persistent section↔bead links via stable section IDs;
│   │   │                         #   survives plan edits and bead re-polishing
│   │   ├── multi_model.rs        # Multi-model plan refinement
│   │   ├── plan_to_beads.rs      # Plan → beads conversion (lowers typed intent into
│   │   │                         #   structured work items, not text summarization)
│   │   └── bead_polisher.rs      # Iterative bead refinement
│   │
│   ├── src/hardening/            # Review, testing, quality
│   │   ├── review_orchestrator.rs # Cross-agent review workflows
│   │   ├── test_coverage.rs      # Coverage analysis
│   │   ├── ubs_integration.rs    # Ultimate Bug Scanner bridge
│   │   ├── de_slopifier.rs       # AI writing pattern detection
│   │   └── fresh_eyes.rs         # Fresh-session review automation
│   │
│   ├── src/learning/             # CASS Memory & skill refinement
│   │   ├── session_indexer.rs    # CASS-compatible session indexing
│   │   ├── memory_manager.rs     # Three-layer memory architecture
│   │   ├── ritual_detector.rs    # Discovers repeated patterns
│   │   └── skill_refiner.rs      # Meta-skill refinement pipeline
│   │
│   ├── src/persistence/          # Engine-owned storage
│   │   ├── session_store.rs      # Persistent session state (SQLite)
│   │   ├── approval_store.rs     # Durable approval records (SQLite): pending/approved/denied
│   │   ├── checkpoint_store.rs   # Swarm checkpoint snapshots (SQLite): agent assignments,
│   │   │                         #   bead graph state, git branches, budget, approval queue
│   │   ├── event_log.rs          # Append-only engine event log (rotated JSONL files).
│   │   │                         #   Every event carries a correlation_id for audit trails.
│   │   │                         #   Enables replay, analytics, and webhook integration.
│   │   ├── schema.rs             # Database schema and migrations
│   │   └── jsonl.rs              # JSONL session artifact parsing
│   │
│   ├── src/host_traits/          # Interfaces implemented by Swift host
│   │   ├── keychain.rs           # KeychainHost trait
│   │   ├── sandbox.rs            # SandboxHost trait
│   │   ├── file_dialog.rs        # FileDialogHost trait
│   │   ├── workspace.rs          # WorkspaceHost trait
│   │   └── notification.rs       # NotificationHost trait
│   │
│   ├── src/ffi.rs                # UniFFI export surface
│   ├── src/lib.rs                # Crate root
│   ├── Cargo.toml
│   ├── build.rs
│   └── src/hoopoe.udl            # UniFFI definition language schema
│
├── HoopoeBridge/                  # Swift adapter layer over UniFFI-generated bindings
│   ├── EngineFacade.swift        # Coarse command/query API wrapping UniFFI calls
│   ├── EngineStore.swift         # @Observable store reducing engine snapshots/events
│   ├── EventReducer.swift        # Maps engine event batches into view model deltas
│   ├── HostServices.swift        # Swift implementations of UniFFI foreign traits
│   └── ViewModels/               # Per-feature @MainActor view models
│       ├── PlanningVM.swift
│       ├── BeadsVM.swift
│       ├── SwarmVM.swift
│       ├── HardeningVM.swift
│       └── LearningVM.swift
│
├── HoopoeHost/                    # macOS-only services (Keychain, Seatbelt, etc.)
│   ├── KeychainService.swift     # macOS Keychain access
│   ├── SandboxService.swift      # Seatbelt profile management
│   ├── FileDialogService.swift   # File picker / permissions
│   └── NotificationService.swift # macOS notifications
│
├── HoopoeUI/                      # Hybrid SwiftUI + AppKit shell
│   │
│   │  ## SwiftUI layer (data-entry, status-display, reactive state)
│   │  ## These views bind to @MainActor view models and stores in `HoopoeBridge/`.
│   │  ## They do NOT bind directly to UniFFI-generated objects.
│   │
│   │  Boundary rules:
│   │
│   │  1. SwiftUI/AppKit views bind only to Swift-native @Observable / @MainActor
│   │     view models.
│   │  2. UniFFI-generated types are wrapped by EngineFacade and EngineStore.
│   │  3. The FFI boundary is coarse-grained: commands, async operations, snapshots,
│   │     batched deltas, and event streams.
│   │  4. macOS-only capabilities are provided to Rust through foreign traits
│   │     implemented by the Swift host layer.
│   │
│   ├── MainWindow/
│   │   ├── Sidebar.swift         # [SwiftUI] Project navigator + phase sidebar
│   │   ├── ContentArea.swift     # [SwiftUI] Main content router (context-dependent)
│   │   ├── InspectorPanel.swift  # [SwiftUI] Right-side detail panel
│   │   └── NextActionPanel.swift # [SwiftUI] Persistent panel showing the single best
│   │                             #   intervention right now: blocked deps, failed gates,
│   │                             #   pending approvals, dead-letter runs, review wins,
│   │                             #   or next milestone. Always visible; adapts per phase.
│   ├── Planning/
│   │   ├── ModelPanel.swift      # [SwiftUI] Multi-model synthesis controls
│   │   └── RefinementTracker.swift # [SwiftUI] Convergence visualization
│   ├── Beads/
│   │   ├── BeadBoard.swift       # [SwiftUI] Kanban-style bead cards with drag-and-drop
│   │   ├── BeadDetail.swift      # [SwiftUI] Rich bead inspector
│   │   ├── BeadListView.swift    # [SwiftUI] Sortable/filterable table view
│   │   └── PolishProgress.swift  # [SwiftUI] Convergence meter
│   ├── Swarm/
│   │   ├── AgentCard.swift       # [SwiftUI] Agent status card: current bead, completed beads, health; "Show Terminal" button
│   │   ├── MailboxView.swift     # [SwiftUI] Agent Mail message browser
│   │   ├── ApprovalDialog.swift   # [SwiftUI] Native macOS approval dialog (NSAlert) for
│   │   │                         #   agent tool-permission requests: shows agent name,
│   │   │                         #   requested action, [Allow] / [Deny] buttons
│   │   ├── ConflictAlert.swift   # [SwiftUI] File conflict notifications
│   │   └── CostDashboard.swift   # [SwiftUI] Running cost totals, charts, projections
│   ├── Hardening/
│   │   ├── TestRunner.swift      # [SwiftUI] Test execution pass/fail dashboard
│   │   └── QualityGates.swift    # [SwiftUI] Validation gate checklist
│   ├── Learning/
│   │   ├── SkillEditor.swift     # [SwiftUI] Skill management
│   │   ├── InsightsView.swift    # [SwiftUI] Analytics and patterns
│   │   └── SessionSearchOverlay.swift # [SwiftUI] Spotlight-style floating search panel
│   │                             #   (Cmd+Shift+K) for instant full-text CASS session
│   │                             #   search with agent/project/date filters
│   ├── Settings/
│   │   ├── ProvidersConfig.swift # [SwiftUI] API keys, auth, accounts
│   │   ├── AgentConfig.swift     # [SwiftUI] Default agent behaviors
│   │   └── ProjectConfig.swift   # [SwiftUI] Per-project settings
│   │
│   │  ## AppKit layer (rich text, high-perf rendering, complex layout)
│   │  ## Each AppKit component is wrapped via NSViewRepresentable for
│   │  ## SwiftUI embedding. Exposes Binding<T> + callback closures so
│   │  ## the SwiftUI layer doesn't know it's talking to AppKit.
│   │
│   ├── AppKitViews/
│   │   ├── PlanEditorView.swift  # [AppKit] NSTextView + TreeSitter markdown editor
│   │   │                         #   Rich editing: syntax highlight, line numbers,
│   │   │                         #   section folding, inline comments, version diff
│   │   ├── DiffViewer.swift      # [AppKit] NSTextView side-by-side diff with gutter
│   │   ├── GhosttyTerminal.swift  # [AppKit] GPU-accelerated terminal: libghostty C API
│   │   │                         #   (`ghostty_surface_t` wrapped in NSView, Metal
│   │   │                         #    rendering). Ghostty built as git submodule (Zig).
│   │   │                         #   Reference: Factory Floor's TerminalView.swift
│   │   ├── TerminalCache.swift    # [AppKit] Caches live GhosttyTerminal instances
│   │   │                         #   keyed by agent UUID. Preserves scroll position,
│   │   │                         #   output buffer, and PTY state across tab switches.
│   │   │                         #   Surfaces evicted only on agent termination.
│   │   ├── AgentTerminal.swift    # [AppKit] Hosts a GhosttyTerminal from the cache;
│   │   │                         #   wires it to agent PTY stream via the engine
│   │   ├── SwarmLayout.swift     # [AppKit] NSSplitViewController with user-draggable
│   │   │                         #   resizable panes (agent grid + timeline + mailbox)
│   │   ├── BeadGraph.swift       # [AppKit] NSView + Core Animation force-directed
│   │   │                         #   dependency graph with pan/zoom/click
│   │   ├── TimelineView.swift    # [AppKit] Gantt-chart bead completion timeline
│   │   ├── SessionBrowser.swift  # [AppKit] NSOutlineView for parentUuid DAG tree,
│   │   │                         #   performant with thousands of session entries
│   │   └── ReviewPanel.swift     # [AppKit] Annotated code diffs with severity ratings
│
└── HoopoeUtils/                   # Shared Swift utilities
    ├── MarkdownParser.swift      # Markdown parsing/rendering (shell-side)
    ├── GitIntegration.swift      # libgit2 bindings (shell-side convenience)
    └── Diagnostics.swift         # System health checks
```

### 2.3 Data Flow Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                    Hoopoe UI  (Swift Shell)                       │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ Planning  │  │  Beads   │  │  Swarm   │  │ Harden   │        │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘        │
│       └──────────────┴──────────────┴──────────────┘              │
│                              │                                    │
│               @MainActor ViewModels + EngineStore                │
└──────────────────────────────┼───────────────────────────────────┘
                               │  UniFFI (commands, snapshots,
                               │  event streams, host trait calls)
┌──────────────────────────────┼───────────────────────────────────┐
│                    hoopoe-engine  (Rust Core, tokio)              │
│  ┌─────────────────┐  ┌────────────────┐  ┌─────────────────┐   │
│  │  AgentManager    │  │ SessionStore   │  │  BudgetTracker  │   │
│  └────────┬─────────┘  └───────┬────────┘  └────────┬────────┘  │
│           │                    │                     │            │
│  ┌────────▼─────────────────────────────────────────────────┐    │
│  │              Providers (Rust adapters)                     │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │    │
│  │  │ Claude       │  │ Codex        │  │ Gemini       │    │    │
│  │  │ (Agent SDK   │  │ app-server   │  │ CLI          │    │    │
│  │  │  via Python) │  │ (JSON-RPC)   │  │ (subprocess) │    │    │
│  │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘    │    │
│  └─────────┼─────────────────┼─────────────────┼────────────┘    │
│            │                 │                 │                  │
│  ┌─────────▼─────────────────▼─────────────────▼────────────┐    │
│  │              Coordination Layer                            │    │
│  │  ┌──────────────┐  ┌──────────┐  ┌──────────┐  ┌──────┐ │    │
│  │  │  Agent Mail   │  │  Beads   │  │    bv    │  │ Git  │ │    │
│  │  │  (MCP + DB)   │  │  (br)    │  │  (graph) │  │      │ │    │
│  │  └──────────────┘  └──────────┘  └──────────┘  └──────┘ │    │
│  └──────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
```

---

## 3. User Flow — Phase by Phase

### Phase 1: Planning

#### 3.1.1 Entry Points

The user begins a new project by either:

1. **Importing an existing plan**: Drag-and-drop or file picker for `plan.md` files. The app parses the markdown, displays it in the rich editor, and runs an initial assessment (word count, section structure, coverage analysis).
2. **Creating a plan from scratch**: A guided wizard that implements the Flywheel planning methodology step by step.
3. **Feature plans for brownfield projects**: Import or create `plan_feature1.md`, `plan_feature2.md` for adding features to existing codebases. The app detects the existing codebase structure and pre-populates context.

#### 3.1.2 Guided Plan Creation Workflow

**Step 1 — Foundation Bundle**: The app prompts for: project name, tech stack (with AI-assisted suggestions), target platform, repository URL (if existing). It then auto-generates an initial AGENTS.md, pulls in relevant best-practice guides, and creates the project scaffolding.

**Step 2 — Initial Plan Draft**: The user describes their vision in a free-form text area (stream-of-consciousness is encouraged, per the Flywheel methodology). Hoopoe sends this to the user's chosen "planning model" (defaulting to GPT 5.4 extra high, with Claude Opus and Gemini as alternatives) and displays the resulting plan in a split-pane editor: user's intent on the left, generated plan on the right.

**Step 3 — Multi-Model Synthesis**: The app offers a "Get Competing Plans" button. This simultaneously sends the project description to 3-4 frontier models and displays the results in a tabbed comparison view. The user can highlight sections they like from each plan. Hoopoe then triggers the "Best-of-All-Worlds" synthesis prompt (from the Flywheel guide) automatically, using the user's highlights to weight the synthesis.

**Step 4 — Iterative Refinement**: A refinement panel shows the current plan alongside a "Refine" button. Each press starts a fresh conversation with a frontier model using the standard refinement prompt. A convergence meter (tracking output size delta, change velocity, and content similarity) shows when the plan has stabilized. The app recommends stopping after the meter reaches 0.75+.

**Step 5 — Structural Validation**: Before moving to beads, the plan linter (`plan_linter.rs`) validates the typed AST: all required semantic sections must be present (goals, constraints, architecture, failure modes, testing, observability, rollout, security, acceptance criteria), cross-references must resolve, and no section may be empty. Lint errors are surfaced inline in the editor even when the markdown is syntactically valid. The app also runs the "Lie to Them" adversarial technique — sending the plan to frontier models for exhaustive critique — and presents findings as an actionable checklist.

#### 3.1.3 Plan Editor Features

The plan editor is markdown-first, but every save compiles the markdown into a typed Plan AST with stable section IDs (via `plan_schema.rs`). The editor provides: live preview, section folding, table of contents navigation, inline comments, version history (every refinement round is a version), diff view between versions, word/line count per section, a coverage heatmap showing which sections have been refined most, and **inline semantic lint errors** when required sections or acceptance criteria are missing — even if the markdown itself is syntactically valid. Section IDs are stable across edits, ensuring that traceability links to beads survive plan revisions.

### Phase 2: Plan → Beads Conversion

#### 3.2.1 Conversion Trigger

The user presses "Convert to Beads." Hoopoe sends the plan to Claude Code (via the Agent SDK) with the standard conversion prompt from the Flywheel guide, instrumented with structured output to capture beads in JSON format. The conversion runs in a visible agent session — the user can watch the agent work in real time.

#### 3.2.2 Bead Visualization

Once conversion completes, beads are displayed in three synchronized views:

1. **Kanban Board**: Columns for Open, In Progress, Review, Done. Beads are cards with title, priority badge (P0-P4), type icon, and dependency count. Drag-and-drop to re-prioritize.
2. **Dependency Graph**: An interactive node-graph visualization (using a force-directed layout) showing all beads and their dependency relationships. Color-coded by priority. Critical path highlighted in red. Bottleneck beads (high PageRank + high betweenness) are visually prominent.
3. **List View**: Sortable table with all bead metadata. Filter by status, priority, type, label.

#### 3.2.3 Manual Curation

Users can: edit bead descriptions (inline rich editor), change priority, add/remove dependencies (by dragging edges in the graph view), merge duplicate beads (select multiple → merge), split large beads, add new beads manually, and delete unnecessary beads. Every curation action is tracked in an undo stack.

#### 3.2.4 Automated Polishing

The "Polish Beads" button runs the iterative polishing loop from the Flywheel methodology. Hoopoe tracks: duplicate detection rate, description quality scores (WHAT/WHY/HOW completeness), dependency link corrections, and content similarity between rounds. A convergence meter shows progress. The app auto-stops when convergence reaches 0.90+. A separate "Fresh Eyes" button spawns a new agent session for independent review. A "Cross-Reference" button validates beads against the original plan bidirectionally.

### Phase 3: Agent Swarm Execution

#### 3.3.1 Swarm Configuration

Before launching, the user configures — either manually or by selecting a **swarm recipe**:

- **Agent composition**: A visual slider panel showing how many of each agent type to spawn. Defaults follow the Flywheel recommendation (2 Claude, 1 Codex, 1 Gemini) but scales with bead count per the guide's table. An "Auto" mode calculates both composition and live concurrency from dependency readiness, provider capabilities, budget headroom, system load, and recent completion rates — adapting dynamically as the swarm runs rather than fixing the mix at launch time.
- **Model selection**: Per-agent-type model selection (e.g., Claude Opus 4.6 for Claude agents, GPT-5-Codex for Codex agents, Gemini 3 for Gemini agents).
- **Cost limits**: Per-session budget cap, per-agent budget cap, and cost alerts.
- **Safety level**: Three presets — "Supervised" (approval required for file writes), "Guided" (approval for deletes/dangerous ops only, Codex `approvalPolicy: "on-request"`), "Autonomous" (full autonomy with DCG-style safety guards only).

#### 3.3.2 Swarm Dashboard

The dashboard is the nerve center during execution, displaying:

**Agent Status Grid**: Each agent gets a card showing: whimsical name (Agent Mail identity), agent type icon (Claude/Codex/Gemini), current bead assignment with status (open/in-progress/review/done), list of completed beads, tokens used/remaining, and health indicator (green/yellow/red for active/rate-limited/error). A "Show Terminal" button on each card opens the agent's live terminal output in a detail pane (backed by a cached `GhosttyTerminal` per agent — switching between agents is instant with full scroll history preserved). Terminal output is hidden by default to keep the dashboard focused on bead progress.

**Bead Progress Timeline**: A Gantt-chart-style timeline showing which beads are in progress, completed, and blocked. Real-time updates as agents close beads.

**Agent Mail Inbox**: A unified view of all inter-agent messages, threaded by bead ID. Users can see coordination happening in real time.

**File Reservation Map**: A visual representation of which files are reserved by which agent. Each reserved file displays a lock icon badge with the holding agent's name and a TTL countdown timer. Expired reservations fade to a warning state. The map updates in real time as agents acquire and release reservations.

**Conflict Alerts**: Real-time notifications when two agents attempt to modify the same file, with one-click resolution options.

**Cost Dashboard**: Running total of API costs, broken down by agent and by model.

#### 3.3.3 Swarm Launch Sequence

Hoopoe implements adaptive ramp-up based on provider quota, machine load, and registration latency (with a conservative 30-second stagger as fallback) to avoid the thundering herd problem. On relaunch after a crash or restart, the engine restores from the latest swarm checkpoint and reattaches to surviving tmux sessions (or respawns agents fresh if tmux mode has been disabled). The launch sequence:

1. If resuming, restore from the latest swarm checkpoint (agent assignments, bead state, budget). Check for surviving tmux sessions on the `-L hoopoe` socket and reattach.
2. Start Agent Mail MCP server
3. Generate per-agent AGENTS.md files
4. Spawn new agents in staggered order via `tmux new-session -A` on the `-L hoopoe` socket
5. Send marching orders prompt to each agent (the standard prompt from the Flywheel guide)
6. Monitor for registration in Agent Mail
7. Verify each agent has chosen a bead via bv
8. Create "post-launch" checkpoint

#### 3.3.4 Operator Automation

Hoopoe automates the human machine-tending tasks described in the Flywheel guide:

- **Auto-compaction recovery**: When an agent's context is compacted (detected via session monitoring), Hoopoe automatically sends "Reread AGENTS.md."
- **Auto-bead-status updates**: When an agent starts writing code for a bead, the bead status is updated to "in_progress." When the agent commits, the bead is marked for review.
- **Periodic review triggers**: Every 30 minutes, Hoopoe picks the agent that most recently finished a bead and sends the "fresh eyes" review prompt.
- **Organized commits**: Every 2 hours, one agent is designated for the organized commits prompt.
- **Rate limit rotation**: When rate limits are detected, Hoopoe automatically switches to backup API keys/accounts.
- **Lease expiry and stalled-run detection**: Every run carries a TTL and emits periodic heartbeats. When heartbeats are missing or the lease expires without progress, the scheduler automatically requeues the bead to another agent, escalates to the user, or routes to the dead-letter queue — depending on retry count and last-known workspace state. This replaces fixed-timer heuristics with a principled supervision model.

### Phase 4: Review, Testing & Hardening

#### 3.4.1 Review Workflows

The Hardening phase provides a review orchestration panel with preset workflows:

- **Self-Review (Fresh Eyes)**: Spawns a new agent session, sends the "fresh eyes" review prompt, collects findings as annotated issues.
- **Cross-Model Adversarial Review**: Spawns a *different* model family to review each agent's work (e.g., Gemini CLI reviews Claude's code, Claude reviews Codex's code). The reviewing agent runs in a **read-only sandbox** — Claude reviewers get `disallowedTools: ["Write", "Edit"]`, Codex reviewers run with `approvalPolicy: "never"`, and all reviewers are placed under a read-only Seatbelt profile — so the reviewer can ruthlessly critique without risk of mutating files.
- **Random Code Exploration**: Triggers the "randomly explore" prompt, which surfaces bugs in neglected areas of the codebase.
- **Deep Review Round**: Runs all three review types simultaneously, deduplicates findings, and presents a unified issue list.

Each review round's findings are displayed as annotated code diffs with severity ratings. Users can accept fixes, reject them, or create new beads for complex issues.

#### 3.4.2 Testing

- **Coverage Analysis**: Integration with language-specific coverage tools (lcov, coverage.py, jest --coverage). Visual coverage overlay on the file tree.
- **Test Generation**: "Generate Tests" button creates beads for missing test coverage, using the standard testing prompt from the Flywheel guide.
- **Test Runner**: Built-in test execution with streaming output, pass/fail visualization, and failure drill-down.

#### 3.4.3 Quality Gates

Inspired by the Flywheel's validation gates, Hoopoe implements a checklist of quality gates that must pass before a project phase can advance:

| Gate         | Checks                                                                              |
| ------------ | ----------------------------------------------------------------------------------- |
| Foundation   | AGENTS.md exists, tech stack defined, best practices loaded                         |
| Plan         | Plan covers workflows, architecture, constraints, testing, failure paths            |
| Translation  | Bidirectional plan↔bead coverage verified                                           |
| Bead Quality | Beads self-contained, deps correct, context rich, tests specified                   |
| Launch       | Agent Mail running, file reservations active, bv available, staggered start         |
| Ship         | Reviews clean, tests passing, UBS clean, remaining work as beads, feedback captured |

#### 3.4.4 De-Slopification

A dedicated "De-Slopify" panel for user-facing text (README, docs, comments). It scans for AI writing patterns (emdash overuse, "It's not X, it's Y" constructions, "Let's dive in," etc.) and highlights them with suggested rewrites. The scan is performed by an agent but the fixes require human approval.

### Phase 5: Meta-Skill — CASS Mining & Skill Refinement

#### 3.5.1 Session Indexing

Every agent session is automatically indexed in CASS-compatible format by the Rust core. For Claude agents, the engine reads the native JSONL session files directly from `~/.claude/projects/<PROJECT_HASH>/sessions/` (see Section 5.5 for the verified format). Each JSONL entry is a message in a `parentUuid`-linked DAG supporting conversation branching. For Codex and Gemini agents, the engine normalizes their session data into the same JSONL format for unified indexing. The Swift shell queries indexed snapshots and replay data from the engine rather than parsing session files directly. Hoopoe provides two search interfaces:

1. **Session Browser** (`SessionBrowser.swift`): An NSOutlineView-based panel for browsing the full session DAG tree, with filtering by agent type/project/date, session replay (step-by-step visualization following `parentUuid` chains), and export to HTML.

2. **Spotlight-style Search Overlay** (`SessionSearchOverlay.swift`): Summoned via **Cmd+Shift+K**, a floating macOS overlay (similar to Spotlight or Alfred) that provides instant full-text search across all indexed sessions. The user types a natural-language query (e.g., "How did we fix the Redis auth issue?"), and results appear as ranked conversational deltas with agent name, timestamp, and bead context. Clicking a result jumps to the full session in the Session Browser.

#### 3.5.2 Three-Layer Memory

Implementing the CASS Memory architecture:

- **Episodic Memory**: Raw session logs from all agents (automatic, always on).
- **Working Memory (Diary)**: After each session, Hoopoe prompts an agent to summarize the session into structured notes.
- **Procedural Memory (Playbook)**: Periodically, Hoopoe runs `cm reflect` equivalent — extracting rules with confidence scores, 90-day half-life decay, and 4x harmful multiplier.

#### 3.5.3 Ritual Detection

Hoopoe mines session history for repeated prompt patterns (the Flywheel's ritual detection). Prompts used 10+ times across sessions are flagged as "validated rituals" and offered for inclusion in the project's skill library.

#### 3.5.4 Skill Refinement Loop

The meta-skill from the Flywheel guide is automated: Hoopoe searches CASS for all sessions where agents used a specific skill, identifies patterns of confusion, repeated mistakes, and invented workarounds, then generates a refined skill document. The user reviews and approves the refinement.

---

## 4. Agent Harness Integration

### 4.1 Detection and Configuration

On first launch, Hoopoe scans the system for installed agent CLIs:

```rust
// In hoopoe-engine/src/providers/detector.rs
pub async fn detect_providers() -> Vec<DetectedProvider> {
    let mut providers = Vec::new();

    // Claude Code
    if let Some(path) = find_executable("claude", &[
        "~/.claude/local/claude",
        "/usr/local/bin/claude",
    ]) {
        let version = get_version(&path, &["--version"]).await;
        providers.push(DetectedProvider::Claude { path, version });
    }

    // Codex CLI
    if let Some(path) = find_executable("codex", &[
        "~/.npm-global/bin/codex",
    ]) {
        providers.push(DetectedProvider::Codex { path, .. });
    }

    // Gemini CLI
    if let Some(path) = find_executable("gemini", &[
        "~/.npm-global/bin/gemini",
    ]) {
        providers.push(DetectedProvider::Gemini { path, .. });
    }

    providers
}
```

### 4.2 Agent Process Model

Each agent runs in a **Rust-owned PTY** managed directly by the `tokio` runtime. The engine
spawns agent CLI processes using `portable-pty` (or raw `openpty(2)` + `tokio::process`),
giving Hoopoe direct, non-escaped access to stdin/stdout/stderr streams without an
intermediary process manager.

**PTY ownership model:**

- **Direct spawn**: Each agent CLI is forked into a PTY owned by `AgentProcess`. The engine
  holds the master fd; the child process gets the slave fd as its controlling terminal.
- **Structured IPC**: For providers with JSON-RPC protocols (Claude, Codex), the engine
  communicates over the structured channel (WebSocket or stdin/stdout JSON-RPC) — not by
  injecting keystrokes. The PTY stream is used only for terminal rendering and log capture.
- **Raw stream access**: stderr is captured separately for error/rate-limit detection.
  No tmux buffering, escaping, or encoding intermediary.
- **FSEvents monitoring**: File system watching for detecting agent-made file changes.

**Process persistence via tmux + checkpoint:**

By default, each agent PTY is wrapped in a tmux session, so agent processes survive app
crashes and quits. On recovery, the engine restores the latest swarm checkpoint (ensuring
consistent engine state) and reattaches to surviving tmux sessions. This combination gives
the strongest resilience: tmux preserves running agent processes, while checkpoints preserve
engine state (bead assignments, budget, approvals). Users can disable tmux mode in settings
if they prefer direct PTY ownership without tmux — in that case, agents are respawned fresh
from checkpoints on recovery.

**Tmux session management (enabled by default):**

- **Dedicated socket**: All agent sessions live on `-L hoopoe`, isolated from the user's tmux.
- **Deterministic session names**: `hoopoe/<project>/<agent-mail-name>` for reliable reattach.
- **Create-or-attach**: `tmux new-session -A` on spawn; on relaunch the engine reattaches.
- **Graceful shutdown**: `tmux kill-session` on swarm stop; sessions left alive on app quit.

```rust
// In hoopoe-engine/src/core/agent_process.rs
pub struct AgentProcess {
    id: Uuid,
    provider: ProviderType,
    agent_mail_name: String,      // Whimsical name for coordination
    pty: Box<dyn portable_pty::MasterPty + Send>,  // Owned PTY master fd
    child: tokio::process::Child,                   // Owned child process handle
    structured_channel: Option<StructuredChannel>,  // WebSocket or JSON-RPC pipe (if provider supports it)
    tmux_session: Option<String>,                   // Set by default; None only when tmux mode is disabled

    current_run: Option<RunId>,               // Active run (links to bead + attempt metadata)
    token_usage: TokenUsage,
    status: AgentStatus,  // Idle, Working, RateLimited, Compacting, Error
}

impl AgentProcess {
    pub async fn spawn(&mut self) -> Result<()> { ... }
    pub async fn send_structured(&mut self, msg: &ProviderMessage) -> Result<()> { ... }  // via JSON-RPC/WebSocket
    pub async fn send_raw(&mut self, input: &str) -> Result<()> { ... }  // via PTY stdin (fallback)
    pub fn stream_output(&mut self) -> impl Stream<Item = AgentEvent> { ... }
    pub fn stream_terminal(&mut self) -> impl Stream<Item = Vec<u8>> { ... }  // raw PTY bytes for GhosttyTerminal
    pub async fn terminate(&mut self) -> Result<()> { ... }
    pub async fn is_alive(&self) -> bool { ... }  // direct process status check
}
```

**Terminal surface caching (Swift shell):**

The `TerminalCache` in the AppKit layer maintains live `GhosttyTerminal` instances
keyed by agent UUID. When the user switches between agents in the swarm dashboard, the
terminal view is swapped instantly — scroll position, output history, and PTY state are
preserved. Surfaces are evicted only when an agent is terminated or the swarm ends. This
prevents the cost of re-rendering terminal history on every tab switch.

**Swarm checkpoints (Rust engine):**

Tmux session persistence preserves agent _processes_ across crashes, but not engine
_state_. The checkpoint system (inspired by NTM) captures a complete, named snapshot of
the swarm that can be listed, inspected, and restored:

```rust
// In hoopoe-engine/src/core/checkpoint.rs
pub struct SwarmCheckpoint {
    id: Uuid,
    name: String,                         // User-assigned or auto ("pre-launch", "hourly-3")
    project_id: Uuid,
    created_at: DateTime<Utc>,

    agent_states: Vec<AgentSnapshot>,     // Per-agent: current run, status, token usage
    run_states: Vec<RunSnapshot>,         // All active/queued runs: state, lease, retry count
    bead_graph: BeadGraphSnapshot,        // Full bead statuses, dependencies, graph metrics
    git_states: Vec<GitBranchState>,      // Per-agent: branch, HEAD commit, dirty flag
    budget_state: BudgetSnapshot,         // Per-agent and total cost, remaining budget
    pending_approvals: Vec<ApprovalRecord>, // Durable approval queue
    coordination_state: CoordinationSnapshot, // Agent Mail threads, file reservations
}
```

Checkpoints are stored in SQLite via `checkpoint_store.rs`. The engine auto-checkpoints:
before swarm launch, every 30 minutes during execution, and before swarm shutdown. Users
can also create named checkpoints manually. "Resume swarm" restores from the latest
checkpoint and reattaches to surviving tmux sessions for agents that are still running.
If tmux mode has been disabled, agents are respawned fresh with their prior context
(bead assignment, conversation history, budget state).

**Correlation IDs and audit trail:**

Every engine operation is assigned a `correlation_id: Uuid` that threads through all
related events — from bead assignment through agent prompt, tool calls, file changes,
approval requests, and review findings. Events are written to rotated JSONL files
(`event_log.rs`) rather than SQLite to avoid write contention on the hot path. The Swift
shell can query the event log for debugging ("show me everything that happened for bead
br-042") and the Rust engine can replay events for analytics and webhook integration.

### 4.3 Integration Modes by Provider

| Provider        | Integration Mode                                                                                                          | Protocol                                          | Key Capabilities                                                                                                                                                   |
| --------------- | ------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Claude Code** | Rust adapter wrapping the Claude Agent SDK (Python) as a Tokio-managed subprocess. Future: native Rust port when justified. Behind `ProviderTrait`. | WebSocket + bidirectional JSON-RPC (`claude` CLI) | Custom tools via in-process MCP, hooks (PreToolUse, PostToolUse, SubagentStart), file checkpointing + rewind, structured output, budget control, agent definitions |
| **Codex**       | `codex app-server` subprocess                                                                                             | JSON-RPC over stdin/stdout                        | Seatbelt sandboxing (built-in), subagents, approval workflows, session resume via `thread/resume`, plan mode                                                       |
| **Gemini**      | CLI subprocess with `--output-format stream-json`                                                                         | Streaming JSON over stdout                        | Google Search grounding, 1M token context, checkpointing, GEMINI.md context files                                                                                  |

### 4.4 Claude Provider Strategy — Agent SDK First

The Claude Agent SDK (~6,300 lines of Python) is a bidirectional control protocol wrapper around the `claude` CLI. It does not call the Anthropic API directly — it spawns the CLI as a subprocess and communicates via JSON-RPC over stdin/stdout. Hoopoe uses this SDK as its primary Claude integration.

**Primary architecture — Claude Agent SDK (Python):**

```
SwiftUI/AppKit → Swift ViewModel → EngineFacade → UniFFI → Rust Engine
→ Rust sdk_adapter.rs → Claude Agent SDK (Python subprocess) → `claude` CLI → Anthropic API
```

The Rust adapter (`sdk_adapter.rs`) manages the Python SDK as a Tokio-owned subprocess. It translates between Hoopoe's `ProviderTrait` interface and the SDK's Python API, marshalling commands via stdin/stdout JSON and consuming events from the SDK's output stream. The SDK handles all protocol complexity — WebSocket connection management, JSON-RPC framing, hook callbacks, MCP server bridging — while the Rust adapter focuses on lifecycle management, event normalization, and error handling.

**Future option — Native Rust port:**

```
SwiftUI/AppKit → Swift ViewModel → EngineFacade → UniFFI → Rust Engine
→ native Rust Claude provider → `claude` CLI → Anthropic API
```

A native Rust implementation of the SDK's protocol could eliminate the Python dependency and reduce latency. This is not on the current roadmap but the architecture is designed to make it a drop-in replacement: both the SDK adapter and a future native provider implement the same `ProviderTrait` and emit the same events. The protocol documentation in Section 4.4.1 below is maintained in part to keep this option viable.

**Architecture rules:**

1. All Hoopoe code communicates with Claude exclusively through the Rust `ProviderTrait` — never through Python internals or raw FFI.
2. `providers/claude/types.rs` mirrors the SDK's type system: `ClaudeAgentOptions`, `ClaudeMessage` (User, Assistant, System, Result), hook types, agent definitions, MCP server configs.
3. The event stream is a Tokio channel exposed via UniFFI as an async Swift stream.
4. The `ProviderTrait` boundary is designed so that a future native Rust provider can replace the SDK adapter without changing the Swift UI shell or any other engine code.

#### 4.4.1 SDK ↔ CLI Protocol (Verified from Claude Code Source)

Analysis of the Claude Code CLI source (`entrypoints/sdk/`, `bridge/replBridge.ts`, `services/mcp/SdkControlTransport.ts`) reveals the exact protocol the SDK uses. This documents the protocol both for the current SDK adapter integration and to keep the door open for a future native Rust port.

**Transport layer:** The SDK communicates with the CLI via WebSocket + JSON-RPC (not plain stdin/stdout as initially assumed). The `replBridge.ts` (~100KB) implements the server side — it accepts WebSocket connections from the SDK, routes JSON-RPC messages to the query engine, and streams results back.

**Control protocol messages (SDK → CLI):**

| Message                                                                           | Purpose                                                             |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `{ type: "control_request", subtype: "initialize", hooks: {...}, agents: {...} }` | Register hooks, agent definitions, and MCP servers at session start |
| `{ type: "user", message: {...}, session_id, parent_tool_use_id }`                | Send user message (prompt)                                          |
| `{ type: "control_response", request_id, subtype: "success", response: {...} }`   | Return hook callback result or MCP tool result to CLI               |

**Control protocol messages (CLI → SDK):**

| Message                                                                     | Purpose                                              |
| --------------------------------------------------------------------------- | ---------------------------------------------------- |
| `{ type: "assistant", message: {...}, uuid }`                               | Complete assistant response                          |
| `{ type: "stream_event", ... }`                                             | Individual streaming tokens                          |
| `{ type: "result", message_id, totalCostUsd }`                              | Turn completion with usage stats                     |
| `{ type: "control_request", subtype: "can_use_tool", tool_name, input }`    | Ask SDK for tool permission                          |
| `{ type: "control_request", subtype: "hook_callback", callback_id, input }` | Invoke SDK-side hook (PreToolUse, PostToolUse, etc.) |
| `{ type: "control_request", subtype: "mcp_message", server_name, message }` | Route MCP tool call to SDK-hosted MCP server         |

**SDK MCP server bridging:** When Hoopoe registers in-process MCP servers (Agent Mail, beads) via `ClaudeAgentOptions.mcp_servers`, the CLI routes tool calls for those servers through `SdkControlTransport` — sending `mcp_message` control requests to the SDK, which executes the tool and returns the result. The Rust provider must implement this exact routing to support Agent Mail injection.

**Hook callback flow:** The CLI sends `hook_callback` control requests when a hook fires. The SDK invokes the registered callback function, then returns the result via `control_response`. Field name conversion is required: Python uses `continue_` (to avoid keyword conflict) → CLI expects `continue`. The Rust provider handles this at the serde serialization boundary.

**Key source files for port reference:**

- `entrypoints/sdk/coreTypes.ts` — SDK message type definitions
- `bridge/replBridge.ts` — Server-side WebSocket + JSON-RPC handler
- `services/mcp/SdkControlTransport.ts` — MCP server bridging over control channel
- `services/tools/toolHooks.ts` — Hook dispatch and callback routing
- `utils/sessionStorage.ts` — Session persistence format (see Section 5.5)

### 4.5 Claude Code Session Storage Format (Verified from Source)

Analysis of `utils/sessionStorage.ts` and `utils/fileHistory.ts` from the Claude Code source reveals the exact session persistence format. This is critical for Hoopoe's CASS session indexer, compaction detection, and session replay features.

**Storage location:** `~/.claude/projects/<PROJECT_HASH>/sessions/<SESSION_UUID>.jsonl`

The project hash is derived from the sanitized working directory path. Each session is a single JSONL file (one JSON object per line).

**Entry types:**

```
// User message
{ "type": "user", "uuid": "<msg-uuid>", "content": "...", "parentUuid": "<parent-msg-uuid>" }

// Assistant response
{ "type": "assistant", "uuid": "<msg-uuid>", "message": { "content": [...], "model": "...", "usage": {...} }, "parentUuid": "<parent-msg-uuid>" }

// System message
{ "type": "system", "uuid": "<msg-uuid>", "content": "...", "parentUuid": "<parent-msg-uuid>" }

// Compaction boundary (marks where history was compressed)
{ "type": "compact_boundary", "uuid": "<msg-uuid>", "parentUuid": "<parent-msg-uuid>" }

// Tool use summary (compressed representation of long tool output sequences)
{ "type": "tool_use_summary", "uuid": "<msg-uuid>", "summary": "...", "parentUuid": "<parent-msg-uuid>" }

// File attachment
{ "type": "attachment", "uuid": "<msg-uuid>", "files": [...], "parentUuid": "<parent-msg-uuid>" }
```

**Message DAG structure:** Messages form a directed acyclic graph via `parentUuid` links (not a flat list). This supports conversation branching — when an agent forks from a previous point, the new messages link to the fork point's UUID. Hoopoe's session replay must follow `parentUuid` chains to reconstruct the correct conversation path.

**Compaction detection:** When a `compact_boundary` entry appears in the JSONL stream, it means the agent's context was compressed. Hoopoe's auto-compaction recovery watches for this entry type and triggers "Reread AGENTS.md" to the affected agent. This is more reliable than monitoring stderr.

**Cost data:** The `result` message type (emitted at end of each turn) contains `totalCostUsd` and per-model token usage. Hoopoe's `BudgetTracker` can read these directly from the session file rather than reimplementing cost estimation. Additionally, per-session cost state is persisted in `.claude/config.json` under `lastSessionId` with per-model usage breakdowns, and can be restored on session resume via `getStoredSessionCosts(sessionId)`.

**File history:** When `enable_file_checkpointing` is active, file snapshots are stored alongside the session. The `fileHistory.ts` module tracks file state at each user message, enabling `rewind_files()` to restore files to any checkpoint.

**Implications for Hoopoe:**

- `session_indexer.rs` in the Rust core parses these JSONL files directly — no conversion needed.
- Session search uses the `parentUuid` DAG to reconstruct conversation threads.
- The session browser in the Swift shell queries replay data from the engine via snapshots.
- Compaction recovery triggers on `compact_boundary` entries rather than stderr heuristics.
- Cost tracking reads `result` entries and `.claude/config.json` rather than estimating independently.
- The JSONL path canonicalization (`PROJECT_HASH`) must match Claude Code's JavaScript hashing algorithm for the Rust engine to locate session files correctly.

### 4.6 Agent Mail Integration

Hoopoe runs an Agent Mail MCP server instance that all agents connect to. The server is embedded directly in the app (SQLite database stored in the project directory). Each agent session is pre-configured with the Agent Mail MCP server in its MCP configuration.

For Claude Code agents, this is injected via the `ClaudeAgentOptions.mcp_servers` parameter. For Codex, it's added to `~/.codex/config.toml` under `[mcp]`. For Gemini, it's configured in `~/.gemini/settings.json`.

---

## 5. Key Innovations Beyond the Flywheel

### 5.1 Visual Bead Graph with Live Updates

The dependency graph is not a static visualization — it updates in real time as agents work. Beads change color as they transition through statuses. The critical path recalculates as beads complete. Users can zoom, pan, filter by label, and click any bead to see its full context and the agent working on it.

### 5.2 Integrated Agent Inspector

Every agent gets a detail panel (opened via the "Show Terminal" button on the agent card or by clicking the agent name) showing: live terminal output, its full conversation history (rendered markdown, not raw JSON), the files it has modified (with inline diffs), its Agent Mail messages, its bead history, its token usage over time, and a "health" timeline showing rate limits, compactions, and errors.

### 5.3 Plan ↔ Bead Traceability Matrix

A two-way traceability matrix linking every section of the plan to the beads that implement it, and vice versa. Orphaned plan sections (not covered by any bead) and orphaned beads (not traceable to any plan section) are flagged. This implements the Flywheel's bidirectional cross-reference validation as a persistent, visual artifact.

### 5.4 Convergence Visualization

Inspired by the Flywheel's convergence detection for bead polishing, Hoopoe renders a real-time convergence chart showing: dependency stability (how much the dep graph changes between rounds), content similarity (Jaccard similarity between successive bead descriptions), length delta (how much bead total content changes), and semantic density (information density per token). The chart makes it visually obvious when to stop polishing.

### 5.5 Smart Agent Routing

Hoopoe uses bv's graph metrics (PageRank, betweenness centrality) combined with agent capability profiles to route beads to the optimal agent type:

- **High-PageRank foundation beads** → Claude (best for architectural reasoning)
- **Leaf beads with test obligations** → Codex (fast iteration, built-in testing)
- **Documentation beads** → Gemini (strong at docs, has Google Search grounding)
- **Review beads** → Claude or Codex in review-only mode (`disallowedTools: ["Write", "Edit"]` for Claude, `--careful` for Codex)

### 5.6 One-Click Reality Check

A prominent button in the Swarm Dashboard that triggers a structured cross-agent status assessment across all active agents simultaneously, collects their assessments, synthesizes a unified project status report, and presents it to the user with actionable recommendations (add beads, revise beads, change strategy). The results feed directly into the Next Action panel.

### 5.7 Automatic AGENTS.md Generation

Hoopoe generates AGENTS.md files automatically, composing them from: a standard template with the Flywheel's core rules (Rule 0 override prerogative, no file deletion, no destructive git, etc.), project-specific context extracted from the plan, tool documentation blurbs for br, bv, Agent Mail, and any other tools in the project, and per-phase behavioral adjustments (e.g., during hardening, agents get additional review instructions).

### 5.8 Cost Optimization Engine

Hoopoe tracks token usage per agent, per model, per bead and provides: cost projections based on remaining beads, model-switching recommendations (e.g., "switching Agent 3 from Opus to Sonnet would save $X with minimal quality impact for these leaf beads"), rate limit prediction (based on usage patterns, warn before hitting limits), and daily/weekly/monthly cost dashboards.

### 5.9 Next Action Panel

A persistent, always-visible panel (`NextActionPanel.swift`) that answers one question: "What should I do right now?" The panel inspects the full engine state — blocked dependencies, failed quality gates, pending approval requests, dead-letter runs, stalled leases, cheap review wins, cost alerts, and upcoming milestones — and surfaces the single highest-priority intervention with a one-click action button. During planning, it might say "Section 'failure modes' is empty — add failure scenarios before converting to beads." During swarm execution, it might say "Run br-042 failed twice — review the dead-letter summary and reassign or split the bead." During hardening, it might say "3 review findings are unresolved — accept or create new beads." The panel replaces cognitive overload with directed focus, making Hoopoe usable by operators who don't yet have deep Flywheel expertise.

---

## 6. Data Model

### 6.1 Core Entities

```
Project
├── id: UUID
├── name: String
├── path: URL (filesystem path)
├── createdAt: Date
├── plans: [PlanDocument]
├── beadDatabase: URL (.beads/ directory)
├── agentsmd: String (generated content)
└── settings: ProjectSettings

PlanDocument
├── id: UUID
├── filename: String
├── content: String (markdown source)
├── ast: PlanAST (compiled typed representation)
├── sectionIds: [PlanSectionID] (stable across edits)
├── versions: [PlanVersion]
├── type: .master | .feature(name)
├── refinementRounds: Int
└── lintErrors: [PlanLintError] (recomputed on every save)

Bead (mirrors br's data model, enriched with execution metadata)
├── id: String (br-xxx format)
├── title: String
├── description: String (rich markdown)
├── acceptanceCriteria: [String] (required; what "done" means)
├── testObligations: [String] (required tests/coverage expectations)
├── riskLevel: .low | .medium | .high
├── requiredCapabilities: [CapabilityTag] (e.g., architecture, testing, docs, review)
├── rollbackNotes: String? (how to undo if this bead causes problems)
├── observabilityNotes: [String] (logging, metrics, alerts this bead should add)
├── tracedSections: [PlanSectionID] (links to originating plan sections)
├── status: .open | .inProgress | .review | .done | .blocked
├── priority: P0...P4
├── type: .task | .bug | .feature | .epic | .question | .docs
├── labels: [String]
├── dependencies: [BeadID]
├── blockedBy: [BeadID]
├── assignedAgent: AgentID?
├── comments: [Comment]
└── graphMetrics: BeadGraphMetrics (PageRank, betweenness, etc.)

Run (one attempt by one agent to complete one bead)
├── id: UUID
├── beadId: BeadID
├── state: .queued | .leased | .running | .review | .merged | .failed | .deadLetter
├── assignedAgent: AgentID?
├── leaseExpiresAt: Date?
├── lastHeartbeat: Date?
├── retryCount: Int
├── startedAt: Date?
├── finishedAt: Date?
├── failureSummary: String?
└── tokenUsage: TokenUsage

AgentSession
├── id: UUID
├── provider: ProviderType
├── model: String
├── agentMailName: String
├── startedAt: Date
├── status: AgentStatus
├── currentRun: RunID? (replaces currentBead — the Run links to the bead)
├── tokenUsage: TokenUsage
├── costUSD: Decimal
├── conversationLog: [Message]
└── fileChanges: [FileChange]

AgentMailMessage
├── id: UUID
├── threadId: String (typically bead ID)
├── from: String (agent mail name)
├── to: String | .broadcast
├── subject: String
├── body: String
├── timestamp: Date
└── attachments: [String]
```

---

## 7. Security Architecture

### 7.1 Layered Safety Model

Following the Flywheel's defense-in-depth approach:

1. **SDK-Level Restrictions**: `disallowedTools` and `allowed_tools` on Claude Agent SDK. Codex's `approvalPolicy` modes (`on-request` / `never`). Gemini's user-approval flow for file modifications.
2. **Tiered Policy Engine** (inspired by NTM): The Rust engine implements a `PolicyEngine` in `core/policy_engine.rs` with three evaluation tiers, applied in order:
   - **Allowed**: Explicitly safe patterns matched first (e.g., `git status`, `git log`, `git diff`). Permits execution without further checks.
   - **Blocked**: Destructive patterns always rejected (e.g., `git reset --hard`, `rm -rf /`, `git push --force`). Logged and the user is notified.
   - **ApprovalRequired**: Potentially dangerous patterns that require human sign-off before execution (e.g., `git rebase`, `rm -rf <project-dir>`, `docker rm`). The engine pauses the agent and surfaces a **native macOS approval dialog** (`ApprovalDialog.swift`) — an NSAlert-style sheet displaying the agent's whimsical name, the exact command or action requested, and **[Allow]** / **[Deny]** buttons (e.g., *"Agent 'Night-Watchman' wants to run `npm install`. [Allow] [Deny]"*). The agent remains paused until the user responds.

   Approval records are **durable** — stored in SQLite with status (pending/approved/denied), requester (agent name), approver (user), timestamp, and expiry. Pending approvals survive app crashes and are re-presented on restart. The user's "Safety level" preset (Supervised/Guided/Autonomous) controls which tier thresholds are active: Supervised routes most operations through ApprovalRequired, Guided only routes destructive operations, and Autonomous disables the approval tier (Blocked still applies).

3. **Seatbelt Sandboxing**: On macOS, agent processes run under Seatbelt profiles restricting filesystem access to the project directory, preventing network access to anything except API endpoints, and limiting process spawning.
4. **File Reservation Enforcement**: A pre-commit hook (injected into the project's Git configuration) blocks commits to files reserved by other agents.
5. **Budget Guards**: Hard cost limits that terminate agent sessions when exceeded.

### 7.2 Credential Management

API keys and auth tokens are stored in the macOS Keychain by the Swift host layer. The Rust engine requests credentials through a `KeychainHost` foreign trait and never reads plaintext secrets from app-owned files. Hoopoe never stores credentials in plaintext files. The app supports multiple accounts per provider (for rate limit rotation) with a CAAM-like account management UI.

### 7.3 Host Services via UniFFI Foreign Traits

macOS-only capabilities are provided to the Rust engine through foreign traits implemented by the Swift host layer:

- `KeychainHost` — read/write API keys and auth tokens from the macOS Keychain
- `SandboxHost` — apply Seatbelt profiles and manage scoped exceptions for agent processes
- `FileDialogHost` — present file pickers and request user-approved file/path access
- `WorkspaceHost` — Finder integration, open-panel, reveal-in-project behaviors
- `NotificationHost` — macOS notifications and user alerts

---

## 8. Performance Architecture

### 8.1 Concurrency Model

Hoopoe uses a split concurrency architecture:

- **Rust engine (`tokio`)**: Provider processes, WebSocket/JSON-RPC control channels, stdout stream parsing, Agent Mail coordination, SQLite access, session indexing, budgeting, and background workflows. All async I/O is non-blocking on the Tokio runtime.
- **Swift shell (`@MainActor`)**: View models, user-triggered commands, presentation state, editor state, windowing, and AppKit/SwiftUI coordination. All UI state lives on the main actor.
- **Bridge contract**: Rust emits coarse event batches and snapshots; Swift reduces them into UI state via `EventReducer` and `EngineStore`. The FFI boundary never passes fine-grained interior references.

### 8.2 Resource Management

- Agent processes are pooled and reused when possible (Codex's `app-server` especially benefits from persistent connections).
- File system events are debounced (50ms) to prevent UI thrashing from rapid agent edits.
- Session logs and engine artifacts are written by the Rust core; the Swift shell never performs parallel structured writes to the same authority.
- The dependency graph is precomputed and cached; only invalidated when bead dependencies change.

---

## 9. Development Roadmap

### Phase 0: Planning App (Swift-Only)

- Xcode project setup, SwiftUI app shell, main window layout, settings infrastructure
- Plan editor in AppKit (markdown editing with NSTextView + TreeSitter, live preview, section folding, line numbers)
- Direct API integration from Swift to frontier models (Claude, GPT, Gemini) for plan generation and refinement
- Multi-model synthesis workflow: send project description to multiple models, tabbed comparison view, user-guided "Best-of-All-Worlds" synthesis
- Iterative refinement with convergence tracking (output size delta, change velocity, content similarity)
- Plan import/export (drag-and-drop `.md` files) and guided plan creation wizard
- Plan version history: every refinement round saved, diff view between versions
- Keychain integration for API key storage

### Phase 1: Plan Intelligence

- Plan AST compiler (`plan_schema.rs` equivalent in Swift): parse markdown into typed sections with stable section IDs
- Structural linter: validate required sections (goals, constraints, architecture, failure modes, testing, observability, rollout, security, acceptance criteria), flag empty sections, check cross-references
- Inline semantic lint errors in the editor (even when markdown is syntactically valid)
- "Lie to Them" adversarial critique: send plan to frontier models for exhaustive review, present findings as actionable checklist
- Convergence meter visualization (recommend stopping at 0.75+)
- Coverage heatmap showing which sections have been refined most

### Phase 2: Rust Engine Foundation

- Create Cargo workspace (`hoopoe-engine`) + Xcode/SPM integration
- Define UniFFI surface and UDL schema (`hoopoe.udl`)
- Stand up `EngineFacade` / `EngineStore` / `EventReducer` in `HoopoeBridge`
- Implement host traits for Keychain, sandbox, and file access (`HoopoeHost`)
- Migrate plan persistence and API orchestration from Swift into the Rust engine
- SQLite schema and migrations in Rust core
- Rust `ProviderTrait` + Claude Agent SDK adapter (`sdk_adapter.rs`)
- Provider detection in Rust, exposed via UniFFI
- End-to-end smoke test: Swift shell sends command → Rust engine → event → Swift UI update

### Phase 3: Bead Creation & Curation

- Plan-to-beads conversion via Claude provider with structured output (enriched beads with acceptance criteria, test obligations, risk level, capabilities, rollback notes)
- Traceability engine (`traceability.rs`): persistent section↔bead links via stable section IDs
- Bead kanban board and list views (SwiftUI binding to `BeadsVM`)
- Bead dependency graph visualization (interactive, force-directed, AppKit)
- Manual curation: inline editing, drag-and-drop dependencies, merge/split, undo stack
- Bead polishing automation with convergence tracking
- Bidirectional plan↔bead traceability matrix
- bv integration for graph metrics (PageRank, betweenness, critical path)

### Phase 4: Swarm Core + Second Provider

- Scheduler (`scheduler.rs`), run state machine (`run_manager.rs`), lease manager (`lease_manager.rs`), dead-letter queue (`dead_letter.rs`)
- Agent process management with PTY ownership + structured channels
- **Codex `app-server` JSON-RPC integration** (`providers/codex.rs`) — introduced here to validate the `ProviderTrait` abstraction under real multi-provider scheduling
- Agent Mail MCP server integration in Rust coordination layer
- Swarm dashboard with live agent cards (SwiftUI binding to `SwarmVM`)
- Next Action panel (`NextActionPanel.swift`)
- Adaptive ramp-up launch, auto-compaction recovery
- File reservation visualization
- Dry run / simulation mode
- Swarm checkpoint + crash recovery (now includes run states)
- bv integration for smart routing using bead `requiredCapabilities`

### Phase 5: Third Provider + Provider Hardening

- Gemini CLI subprocess integration (`providers/gemini.rs`)
- Rate limit detection and account rotation in Rust engine
- Cross-provider coordination via Agent Mail

### Phase 6: Hardening & Quality

- Review orchestration workflows
- Test coverage integration
- Quality gates system
- De-slopification scanner
- UBS integration

### Phase 7: Learning & Polish

- CASS-compatible session indexing in Rust core
- Three-layer memory system
- Ritual detection
- Skill refinement pipeline
- Cost optimization dashboard
- Comprehensive onboarding flow

### Phase 8: Integration Hardening & Packaging

- Lock contract tests for Claude Agent SDK adapter (recorded transcripts + session artifacts)
- Evaluate native Rust port feasibility based on SDK stability and performance data
- Finalize packaging, code signing, and update pipeline (including bundled Python runtime for Agent SDK)
- Verify all host traits are minimal and coarse-grained

---

## 10. Technical Risks & Mitigations

| Risk                            | Impact                                                | Mitigation                                                                                                                                                                                 |
| ------------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Agent CLI API instability       | Breaking changes in Claude/Codex/Gemini CLIs          | Version detection, adapter pattern, fallback to older API modes                                                                                                                            |
| Rate limit unpredictability     | Swarm stalls when agents hit limits                   | Multi-account rotation, automatic model downgrade, cost-aware scheduling                                                                                                                   |
| Agent coordination failures     | Merge conflicts, duplicate work                       | Agent Mail + file reservations + pre-commit guards; automated conflict resolution                                                                                                          |
| macOS sandbox restrictions      | Agents can't access needed resources                  | Granular Seatbelt profiles; user-approved exceptions for specific paths                                                                                                                    |
| Context window pressure         | Large projects exceed agent context limits            | AGENTS.md layering, progressive disclosure, automatic compaction recovery                                                                                                                  |
| Cost overruns                   | Large swarms consume significant API budget           | Hard budget caps per session/project/agent, cost projections, alerts                                                                                                                       |
| Rust↔Swift boundary churn       | UI and engine contracts change too often              | Freeze coarse command/event contracts early; adapter layer absorbs churn                                                                                                                   |
| UniFFI Swift rough edges        | Swift 6 async/sendability friction                    | Keep UniFFI behind Swift wrapper types; avoid direct UI binding to generated objects                                                                                                       |
| Build/packaging complexity      | Cargo + Xcode/SPM integration can become brittle      | Single workspace script, deterministic codegen, CI contract tests                                                                                                                          |
| Python SDK dependency           | Bundling a Python runtime adds packaging complexity and attack surface | Bundle via PyInstaller or embedded Python; pin SDK version; keep `ProviderTrait` boundary clean so native Rust port remains a viable future option                                          |
| Claude Agent SDK drift          | SDK updates may break the Rust adapter's assumptions  | Contract tests against recorded protocol transcripts and session artifacts; pin SDK version with explicit upgrade cadence; full access to CLI source for reference                          |
| Host-service overreach          | Too many tiny host calls across FFI                   | Use coarse host traits; keep high-frequency logic inside Rust                                                                                                                              |

---

## 11. Success Metrics

The app should be measured against validated throughput, recovery quality, and operator effort — not output volume:

- **Planning velocity**: Time from project concept to lint-clean typed plan + polished beads should be < 4 hours for a medium-complexity project.
- **Validated throughput**: Median time from "bead ready" to "merged with tests passing" should trend down release over release.
- **Resume reliability**: >95% of UI reconnects and >90% of forced app restarts should recover an active swarm cleanly (runs resume, no orphan agents, no lost state).
- **Operator load**: Median operator touches per accepted bead should be < 0.25 (most beads complete without human intervention).
- **Integration quality**: >85% of completed runs should merge without manual conflict resolution.
- **Budget efficiency**: Cost per accepted bead and cost per merged test-covered change should trend down over time.
- **Diagnosis speed**: Median time to explain a failed run via local diagnostics (event log, run history, dead-letter context) should be < 5 minutes.
- **New user onboarding**: A developer unfamiliar with the Flywheel methodology should be able to go from zero to a first validated run in under 1 hour (vs. the current 2-4 hours of terminal setup).
