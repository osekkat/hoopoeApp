# AGENTS.md — Hoopoe

> Guidelines for AI coding agents working on this native macOS application (Swift + Rust).

---

## RULE 0 - THE FUNDAMENTAL OVERRIDE PREROGATIVE

If I tell you to do something, even if it goes against what follows below, YOU MUST LISTEN TO ME. I AM IN CHARGE, NOT YOU.

---

## RULE NUMBER 1: NO FILE DELETION

**YOU ARE NEVER ALLOWED TO DELETE A FILE WITHOUT EXPRESS PERMISSION.** Even a new file that you yourself created, such as a test code file. You have a horrible track record of deleting critically important files or otherwise throwing away tons of expensive work. As a result, you have permanently lost any and all rights to determine that a file or folder should be deleted.

**YOU MUST ALWAYS ASK AND RECEIVE CLEAR, WRITTEN PERMISSION BEFORE EVER DELETING A FILE OR FOLDER OF ANY KIND.**

---

## Irreversible Git & Filesystem Actions — DO NOT EVER BREAK GLASS

1. **Absolutely forbidden commands:** `git reset --hard`, `git clean -fd`, `rm -rf`, or any command that can delete or overwrite code/data must never be run unless the user explicitly provides the exact command and states, in the same message, that they understand and want the irreversible consequences.
2. **No guessing:** If there is any uncertainty about what a command might delete or overwrite, stop immediately and ask the user for specific approval. "I think it's safe" is never acceptable.
3. **Safer alternatives first:** When cleanup or rollbacks are needed, request permission to use non-destructive options (`git status`, `git diff`, `git stash`, copying to backups) before ever considering a destructive command.
4. **Mandatory explicit plan:** Even after explicit user authorization, restate the command verbatim, list exactly what will be affected, and wait for a confirmation that your understanding is correct. Only then may you execute it—if anything remains ambiguous, refuse and escalate.
5. **Document the confirmation:** When running any approved destructive command, record (in the session notes / final response) the exact user text that authorized it, the command actually run, and the execution time. If that record is absent, the operation did not happen.

---

## Toolchain: Swift + Rust

Hoopoe is a **Core/Shell** macOS application with two distinct technology stacks connected by a UniFFI bridge.

### Shell: Swift 6 (SwiftUI + AppKit)

- **Language:** Swift 6 with strict concurrency
- **UI Framework:** SwiftUI for data-entry and status-display views (sidebar, settings, kanban, config panels, cost dashboard); AppKit for high-performance rendering (plan editor, diff viewer, terminal emulation, swarm dashboard, dependency graph, session browser)
- **AppKit↔SwiftUI bridging:** `NSViewRepresentable` (AppKit→SwiftUI) and `NSHostingView` (SwiftUI→AppKit)
- **Package manager:** Swift Package Manager (SPM) + Xcode
- **Concurrency model:** `@MainActor` for all UI state; `async/await` for bridge calls

### Core: Rust (stable)

- **Async runtime:** Tokio — the Rust core uses `tokio` for all async operations (process management, WebSocket/JSON-RPC, file watching, SQLite access, coordination)
- **Package manager:** Cargo workspace (`hoopoe-engine/`)
- **Unsafe code:** Forbidden (`#![forbid(unsafe_code)]`) except in crates that require platform FFI (e.g., PTY management, libghostty bindings) — those crates override the workspace lint locally
- **Clippy:** Pedantic + nursery lints denied at workspace level

### Bridge: UniFFI + Swift Adapter Layer

- **Technology:** Mozilla UniFFI with UDL schema (`hoopoe-engine/src/hoopoe.udl`)
- **Pattern:** Coarse-grained commands, async operations, snapshots, and event streams — never fine-grained interior references across the FFI boundary
- **Swift adapter facade:** `HoopoeBridge/` wraps UniFFI-generated bindings in idiomatic Swift types

### CRITICAL: Architecture Boundary Rules

These rules preserve the Core/Shell separation. Violating them creates architectural rot that is expensive to reverse.

1. **SwiftUI/AppKit views bind only to Swift-native `@Observable` / `@MainActor` view models** — never to UniFFI-generated objects.
2. **UniFFI-generated types are wrapped by `EngineFacade` and `EngineStore`** in `HoopoeBridge/`.
3. **The FFI boundary is coarse-grained:** commands, async operations, snapshots, batched deltas, and event streams.
4. **macOS-only capabilities are provided to Rust through foreign traits** implemented by the Swift host layer (`HoopoeHost/`).
5. **The Rust engine owns all persistent state** (SQLite, session artifacts). The Swift shell queries snapshots — it does NOT maintain its own data authority.
6. **All provider communication goes through `ProviderTrait`** in Rust — never through raw Python internals, CLI stdin hacking, or direct API calls from Swift.

**YOU MUST NEVER:**

- Have Swift UI code directly import or reference UniFFI-generated types
- Have the Swift shell write to the engine's SQLite database
- Have the Swift shell spawn agent processes — that is the Rust engine's job
- Bypass the `ProviderTrait` to talk to agent CLIs directly
- Move persistent state authority from Rust to Swift

### Key Dependencies (Rust)

| Crate                  | Purpose                                              |
| ---------------------- | ---------------------------------------------------- |
| `tokio`                | Async runtime (process, network, timer, fs)          |
| `serde` + `serde_json` | Serialization/deserialization                        |
| `uniffi`               | FFI bridge to Swift                                  |
| `rusqlite`             | SQLite persistence (engine-owned)                    |
| `portable-pty`         | PTY management for agent processes                   |
| `thiserror`            | Derive macro for `Error` trait implementations       |
| `tracing`              | Structured logging and diagnostics                   |
| `uuid`                 | Unique identifiers for agents, runs, beads, sessions |
| `chrono`               | Date/time handling                                   |
| `tokio-tungstenite`    | WebSocket for Claude CLI JSON-RPC protocol           |

### Key Dependencies (Swift)

| Package      | Purpose                                            |
| ------------ | -------------------------------------------------- |
| SourceEditor | NSTextView-based code editor                       |
| TreeSitter   | Syntax highlighting and structural parsing         |
| libghostty   | GPU-accelerated terminal rendering (Zig submodule) |

### Release Profile

```toml
[profile.release]
opt-level = "z"     # Optimize for size
lto = true          # Link-time optimization
codegen-units = 1   # Single codegen unit for better optimization
panic = "abort"     # Smaller binary
strip = true        # Remove debug symbols
```

For throughput benchmarking and perf work:

```toml
[profile.release-perf]
inherits = "release"
opt-level = 3
```

---

## Code Editing Discipline

### No Script-Based Changes

**NEVER** run a script that processes/changes code files in this repo. Brittle regex-based transformations create far more problems than they solve.

- **Always make code changes manually**, even when there are many instances
- For many simple changes: use parallel subagents
- For subtle/complex changes: do them methodically yourself

### No File Proliferation

If you want to change something or add a feature, **revise existing code files in place**.

**NEVER** create variations like:

- `AgentManagerV2.rs` or `PlanEditorV2.swift`
- `main_improved.rs`
- `main_enhanced.swift`

New files are reserved for **genuinely new functionality** that makes zero sense to include in any existing file. The bar for creating new files is **incredibly high**.

---

## Backwards Compatibility

We do not care about backwards compatibility — we're in early development with no users. We want to do things the **RIGHT** way with **NO TECH DEBT**.

- Never create "compatibility shims"
- Never create wrapper functions for deprecated APIs
- Just fix the code directly

---

## Compiler Checks (CRITICAL)

**After any substantive code changes, you MUST verify no errors were introduced.**

### Rust (hoopoe-engine)

```bash
# Check for compiler errors and warnings
cargo check --workspace --all-targets

# Check for clippy lints (pedantic + nursery are enabled)
cargo clippy --workspace --all-targets -- -D warnings

# Verify formatting
cargo fmt --check
```

### Swift (Xcode/SPM)

```bash
# Build the full app
xcodebuild build -scheme Hoopoe -destination 'platform=macOS'

# Or via SPM for non-Xcode packages
swift build
```

If you see errors, **carefully understand and resolve each issue**. Read sufficient context to fix them the RIGHT way.

---

## Testing

### Testing Policy

Every component includes tests alongside the implementation. Tests must cover:

- Happy path
- Edge cases (empty input, max values, boundary conditions)
- Error conditions

### Rust Tests

```bash
# Run all Rust tests
cargo test --workspace

# Run with output
cargo test --workspace -- --nocapture

# Run tests for a specific crate/module
cargo test -p hoopoe-engine

# Run a specific test by name
cargo test --workspace -- test_name_here
```

### Swift Tests

```bash
# Run all tests via Xcode
xcodebuild test -scheme Hoopoe -destination 'platform=macOS'
```

### Test Categories

| Module                            | Focus Areas                                                          |
| --------------------------------- | -------------------------------------------------------------------- |
| `hoopoe-engine/src/core/`         | Agent lifecycle, scheduling, leasing, run state machine, checkpoints |
| `hoopoe-engine/src/providers/`    | Provider trait conformance, protocol parsing, event normalization    |
| `hoopoe-engine/src/coordination/` | Agent Mail integration, beads management, file reservations          |
| `hoopoe-engine/src/planning/`     | Plan AST compilation, linting, traceability, bead conversion         |
| `hoopoe-engine/src/hardening/`    | Review orchestration, coverage analysis, de-slopification            |
| `hoopoe-engine/src/learning/`     | Session indexing, memory management, ritual detection                |
| `hoopoe-engine/src/persistence/`  | SQLite operations, event log, checkpoint storage                     |
| `HoopoeBridge/`                   | EngineFacade commands, EventReducer correctness, ViewModel updates   |
| `HoopoeHost/`                     | Keychain access, sandbox profiles, file dialog                       |
| `HoopoeUI/`                       | View snapshot tests, SwiftUI preview conformance                     |

---

## Third-Party Library Usage

If you aren't 100% sure how to use a third-party library, **SEARCH ONLINE** to find the latest documentation and current best practices. This applies to both Rust crates and Swift packages.

---

## Hoopoe — This Project

**This is the project you're working on.** Hoopoe is a native macOS application that implements the Agentic Coding Flywheel methodology in a polished, visual desktop experience. It orchestrates multiple AI coding agents (Claude Code, OpenAI Codex, and Gemini CLI) simultaneously, guiding users through the full lifecycle: **Plan → Beads → Swarm → Harden → Learn**.

### Core Innovation

Hoopoe democratizes the Flywheel methodology — which proves that 85% of value comes from exhaustive planning and bead polishing — by encoding the workflow into a purpose-built application. It replaces the terminal-and-VPS-centric workflow with a structured GUI while preserving full power-user escape hatches.

### Architecture

```
Hoopoe.app
├── hoopoe-engine/          # Rust core (Tokio): agent orchestration, providers,
│                           #   coordination, planning, persistence, learning
├── HoopoeBridge/           # Swift adapter layer over UniFFI-generated bindings
│                           #   EngineFacade, EngineStore, EventReducer, ViewModels
├── HoopoeHost/             # macOS-only services (Keychain, Seatbelt, file dialogs)
├── HoopoeUI/               # Hybrid SwiftUI + AppKit shell
│   ├── MainWindow/         #   Sidebar, ContentArea, InspectorPanel, NextActionPanel
│   ├── Planning/           #   Multi-model synthesis, refinement tracking
│   ├── Beads/              #   Kanban board, dependency graph, polishing
│   ├── Swarm/              #   Agent cards, mailbox, approvals, cost dashboard
│   ├── Hardening/          #   Test runner, quality gates
│   ├── Learning/           #   Skill editor, insights, session search
│   ├── Settings/           #   Provider config, agent config, project config
│   └── AppKitViews/        #   PlanEditor, DiffViewer, GhosttyTerminal, BeadGraph,
│                           #     TimelineView, SessionBrowser, ReviewPanel
└── HoopoeUtils/            # Shared Swift utilities (markdown, git, diagnostics)
```

### Rust Engine Internals

```
hoopoe-engine/
├── src/core/               # Agent orchestration engine
│   ├── agent_manager.rs    # Agent lifecycle, task supervision
│   ├── agent_process.rs    # tokio::process wrapper for agent CLIs + PTY
│   ├── scheduler.rs        # Dependency-aware work scheduling
│   ├── run_manager.rs      # Run state machine (queued→leased→running→review→merged|failed)
│   ├── lease_manager.rs    # Run leases with TTLs and heartbeats
│   ├── dead_letter.rs      # Failed runs requiring human action
│   ├── agent_router.rs     # Capability-aware provider selection
│   ├── rate_limit.rs       # Rate limit detection, account rotation
│   ├── budget_tracker.rs   # Token usage and cost tracking
│   ├── policy_engine.rs    # Tiered safety: Allowed/Blocked/ApprovalRequired
│   └── checkpoint.rs       # Swarm checkpoint: snapshot & restore full engine state
│
├── src/providers/          # Multi-provider abstraction
│   ├── mod.rs              # Common ProviderTrait + ProviderEvent
│   ├── claude/             # Claude Agent SDK (Python subprocess) → claude CLI
│   │   ├── protocol.rs     # WebSocket/JSON-RPC control protocol
│   │   ├── types.rs        # Message types, options, hooks
│   │   └── sdk_adapter.rs  # Rust adapter wrapping Claude Agent SDK
│   ├── codex.rs            # Codex app-server JSON-RPC client
│   ├── gemini.rs           # Gemini CLI subprocess + stream-json parsing
│   └── detector.rs         # Auto-detects installed CLIs
│
├── src/coordination/       # Flywheel coordination stack
│   ├── agent_mail.rs       # MCP Agent Mail integration
│   ├── beads_manager.rs    # br (beads_rust) integration
│   ├── beads_viewer.rs     # bv (beads_viewer) graph analysis
│   ├── file_reservation.rs # Advisory file locking
│   └── agentsmd_gen.rs     # Auto-generates AGENTS.md for spawned agents
│
├── src/planning/           # Plan creation & management
│   ├── plan_document.rs    # Markdown source + compiled Plan AST
│   ├── plan_schema.rs      # Typed sections with stable section IDs
│   ├── plan_linter.rs      # Structural + semantic validation
│   ├── traceability.rs     # Persistent section↔bead links
│   ├── multi_model.rs      # Multi-model plan refinement
│   ├── plan_to_beads.rs    # Plan → beads conversion
│   └── bead_polisher.rs    # Iterative bead refinement
│
├── src/hardening/          # Review, testing, quality
│   ├── review_orchestrator.rs # Cross-agent review workflows
│   ├── test_coverage.rs    # Coverage analysis
│   ├── ubs_integration.rs  # Ultimate Bug Scanner bridge
│   ├── de_slopifier.rs     # AI writing pattern detection
│   └── fresh_eyes.rs       # Fresh-session review automation
│
├── src/learning/           # CASS Memory & skill refinement
│   ├── session_indexer.rs  # CASS-compatible session indexing
│   ├── memory_manager.rs   # Three-layer memory architecture
│   ├── ritual_detector.rs  # Discovers repeated patterns
│   └── skill_refiner.rs    # Meta-skill refinement pipeline
│
├── src/persistence/        # Engine-owned storage
│   ├── session_store.rs    # Persistent session state (SQLite)
│   ├── approval_store.rs   # Durable approval records (SQLite)
│   ├── checkpoint_store.rs # Swarm checkpoint snapshots (SQLite)
│   ├── event_log.rs        # Append-only engine event log (rotated JSONL)
│   ├── schema.rs           # Database schema and migrations
│   └── jsonl.rs            # JSONL session artifact parsing
│
├── src/host_traits/        # Interfaces implemented by Swift host
│   ├── keychain.rs         # KeychainHost trait
│   ├── sandbox.rs          # SandboxHost trait
│   ├── file_dialog.rs      # FileDialogHost trait
│   ├── workspace.rs        # WorkspaceHost trait
│   └── notification.rs     # NotificationHost trait
│
├── src/ffi.rs              # UniFFI export surface
├── src/lib.rs              # Crate root
├── src/hoopoe.udl          # UniFFI definition language schema
├── Cargo.toml
└── build.rs
```

### Data Flow

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
│                    hoopoe-engine  (Rust Core, Tokio)              │
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

### Key Design Decisions

- **Core/Shell split** — Rust owns orchestration, persistence, and protocol logic; Swift owns UI, macOS integration, and user interaction
- **UniFFI bridge** — Type-safe FFI with async support; coarse-grained boundary (commands + snapshots + events)
- **Tokio async runtime** — All Rust async I/O (process, network, storage) is non-blocking on Tokio
- **Agent process model** — Each agent runs in a Rust-owned PTY with optional tmux persistence for crash recovery
- **Multiple provider support** — Claude (Agent SDK via Python subprocess), Codex (app-server JSON-RPC), Gemini (CLI subprocess) — all behind a common `ProviderTrait`
- **Swarm checkpoints** — Complete snapshots of engine state (agents, runs, beads, git, budget, approvals) stored in SQLite for crash recovery
- **Host traits** — macOS capabilities (Keychain, Seatbelt, file dialogs, notifications) provided to Rust via UniFFI foreign traits
- **Ghostty terminal** — GPU-accelerated terminal rendering via libghostty C API, cached per agent for instant switching
- **Structured tracing** throughout — every layer emits spans for diagnostics

### Flywheel Phases

| Phase      | Engine Components                                    | UI Components                                                   |
| ---------- | ---------------------------------------------------- | --------------------------------------------------------------- |
| **Plan**   | plan_document, plan_schema, plan_linter, multi_model | PlanEditorView, ModelPanel, RefinementTracker                   |
| **Beads**  | plan_to_beads, bead_polisher, traceability           | BeadBoard, BeadGraph, BeadDetail, PolishProgress                |
| **Swarm**  | agent_manager, scheduler, run_manager, lease_manager | AgentCard, MailboxView, CostDashboard, GhosttyTerminal          |
| **Harden** | review_orchestrator, test_coverage, de_slopifier     | TestRunner, QualityGates, ReviewPanel, DiffViewer               |
| **Learn**  | session_indexer, memory_manager, ritual_detector     | SkillEditor, InsightsView, SessionBrowser, SessionSearchOverlay |

### Provider Integration

| Provider        | Integration Mode                                  | Protocol                           | Key Capabilities                                                           |
| --------------- | ------------------------------------------------- | ---------------------------------- | -------------------------------------------------------------------------- |
| **Claude Code** | Agent SDK (Python) via Rust adapter               | WebSocket + bidirectional JSON-RPC | Custom tools via MCP, hooks, file checkpointing, structured output, budget |
| **Codex**       | `codex app-server` subprocess                     | JSON-RPC over stdin/stdout         | Seatbelt sandboxing, subagents, approval workflows, session resume         |
| **Gemini**      | CLI subprocess with `--output-format stream-json` | Streaming JSON over stdout         | Google Search grounding, 1M token context, checkpointing                   |

### Smart Agent Routing

Hoopoe uses bv's graph metrics (PageRank, betweenness centrality) combined with bead `requiredCapabilities` to route beads to the optimal agent type:

- **High-PageRank foundation beads** → Claude (best for architectural reasoning)
- **Leaf beads with test obligations** → Codex (fast iteration, built-in testing)
- **Documentation beads** → Gemini (strong at docs, has Google Search grounding)
- **Review beads** → Claude or Codex in review-only mode

---

## MCP Agent Mail — Multi-Agent Coordination

A mail-like layer that lets coding agents coordinate asynchronously via MCP tools and resources. Provides identities, inbox/outbox, searchable threads, and advisory file reservations with human-auditable artifacts in Git.

### Why It's Useful

- **Prevents conflicts:** Explicit file reservations (leases) for files/globs
- **Token-efficient:** Messages stored in per-project archive, not in context
- **Quick reads:** `resource://inbox/...`, `resource://thread/...`

### Same Repository Workflow

1. **Register identity:**

   ```
   ensure_project(project_key=<abs-path>)
   register_agent(project_key, program, model)
   ```

2. **Reserve files before editing:**

   ```
   file_reservation_paths(project_key, agent_name, ["src/**"], ttl_seconds=3600, exclusive=true)
   ```

3. **Communicate with threads:**

   ```
   send_message(..., thread_id="FEAT-123")
   fetch_inbox(project_key, agent_name)
   acknowledge_message(project_key, agent_name, message_id)
   ```

4. **Quick reads:**
   ```
   resource://inbox/{Agent}?project=<abs-path>&limit=20
   resource://thread/{id}?project=<abs-path>&include_bodies=true
   ```

### Macros vs Granular Tools

- **Prefer macros for speed:** `macro_start_session`, `macro_prepare_thread`, `macro_file_reservation_cycle`, `macro_contact_handshake`
- **Use granular tools for control:** `register_agent`, `file_reservation_paths`, `send_message`, `fetch_inbox`, `acknowledge_message`

### Common Pitfalls

- `"from_agent not registered"`: Always `register_agent` in the correct `project_key` first
- `"FILE_RESERVATION_CONFLICT"`: Adjust patterns, wait for expiry, or use non-exclusive reservation
- **Auth errors:** If JWT+JWKS enabled, include bearer token with matching `kid`

---

## Beads (br) — Dependency-Aware Issue Tracking

Beads provides a lightweight, dependency-aware issue database and CLI (`br` - beads_rust) for selecting "ready work," setting priorities, and tracking status. It complements MCP Agent Mail's messaging and file reservations.

**Important:** `br` is non-invasive—it NEVER runs git commands automatically. You must manually commit changes after `br sync --flush-only`.

### Conventions

- **Single source of truth:** Beads for task status/priority/dependencies; Agent Mail for conversation and audit
- **Shared identifiers:** Use Beads issue ID (e.g., `br-123`) as Mail `thread_id` and prefix subjects with `[br-123]`
- **Reservations:** When starting a task, call `file_reservation_paths()` with the issue ID in `reason`

### Typical Agent Flow

1. **Pick ready work (Beads):**

   ```bash
   br ready --json  # Choose highest priority, no blockers
   ```

2. **Reserve edit surface (Mail):**

   ```
   file_reservation_paths(project_key, agent_name, ["src/**"], ttl_seconds=3600, exclusive=true, reason="br-123")
   ```

3. **Announce start (Mail):**

   ```
   send_message(..., thread_id="br-123", subject="[br-123] Start: <title>", ack_required=true)
   ```

4. **Work and update:** Reply in-thread with progress

5. **Complete and release:**
   ```bash
   br close 123 --reason "Completed"
   br sync --flush-only  # Export to JSONL (no git operations)
   ```
   ```
   release_file_reservations(project_key, agent_name, paths=["src/**"])
   ```
   Final Mail reply: `[br-123] Completed` with summary

### Mapping Cheat Sheet

| Concept                   | Value                             |
| ------------------------- | --------------------------------- |
| Mail `thread_id`          | `br-###`                          |
| Mail subject              | `[br-###] ...`                    |
| File reservation `reason` | `br-###`                          |
| Commit messages           | Include `br-###` for traceability |

---

## bv — Graph-Aware Triage Engine

bv is a graph-aware triage engine for Beads projects (`.beads/beads.jsonl`). It computes PageRank, betweenness, critical path, cycles, HITS, eigenvector, and k-core metrics deterministically.

**Scope boundary:** bv handles _what to work on_ (triage, priority, planning). For agent-to-agent coordination (messaging, work claiming, file reservations), use MCP Agent Mail.

**CRITICAL: Use ONLY `--robot-*` flags. Bare `bv` launches an interactive TUI that blocks your session.**

### The Workflow: Start With Triage

**`bv --robot-triage` is your single entry point.** It returns:

- `quick_ref`: at-a-glance counts + top 3 picks
- `recommendations`: ranked actionable items with scores, reasons, unblock info
- `quick_wins`: low-effort high-impact items
- `blockers_to_clear`: items that unblock the most downstream work
- `project_health`: status/type/priority distributions, graph metrics
- `commands`: copy-paste shell commands for next steps

```bash
bv --robot-triage        # THE MEGA-COMMAND: start here
bv --robot-next          # Minimal: just the single top pick + claim command
```

### Command Reference

**Planning:**
| Command | Returns |
|---------|---------|
| `--robot-plan` | Parallel execution tracks with `unblocks` lists |
| `--robot-priority` | Priority misalignment detection with confidence |

**Graph Analysis:**
| Command | Returns |
|---------|---------|
| `--robot-insights` | Full metrics: PageRank, betweenness, HITS, eigenvector, critical path, cycles, k-core, articulation points, slack |
| `--robot-label-health` | Per-label health: `health_level`, `velocity_score`, `staleness`, `blocked_count` |
| `--robot-label-flow` | Cross-label dependency: `flow_matrix`, `dependencies`, `bottleneck_labels` |
| `--robot-label-attention [--attention-limit=N]` | Attention-ranked labels |

**History & Change Tracking:**
| Command | Returns |
|---------|---------|
| `--robot-history` | Bead-to-commit correlations |
| `--robot-diff --diff-since <ref>` | Changes since ref: new/closed/modified issues, cycles |

**Other:**
| Command | Returns |
|---------|---------|
| `--robot-burndown <sprint>` | Sprint burndown, scope changes, at-risk items |
| `--robot-forecast <id\|all>` | ETA predictions with dependency-aware scheduling |
| `--robot-alerts` | Stale issues, blocking cascades, priority mismatches |
| `--robot-suggest` | Hygiene: duplicates, missing deps, label suggestions |
| `--robot-graph [--graph-format=json\|dot\|mermaid]` | Dependency graph export |
| `--export-graph <file.html>` | Interactive HTML visualization |

### Scoping & Filtering

```bash
bv --robot-plan --label backend              # Scope to label's subgraph
bv --robot-insights --as-of HEAD~30          # Historical point-in-time
bv --recipe actionable --robot-plan          # Pre-filter: ready to work
bv --recipe high-impact --robot-triage       # Pre-filter: top PageRank
bv --robot-triage --robot-triage-by-track    # Group by parallel work streams
bv --robot-triage --robot-triage-by-label    # Group by domain
```

### Understanding Robot Output

**All robot JSON includes:**

- `data_hash` — Fingerprint of source beads.jsonl
- `status` — Per-metric state: `computed|approx|timeout|skipped` + elapsed ms
- `as_of` / `as_of_commit` — Present when using `--as-of`

**Two-phase analysis:**

- **Phase 1 (instant):** degree, topo sort, density
- **Phase 2 (async, 500ms timeout):** PageRank, betweenness, HITS, eigenvector, cycles

### jq Quick Reference

```bash
bv --robot-triage | jq '.quick_ref'                        # At-a-glance summary
bv --robot-triage | jq '.recommendations[0]'               # Top recommendation
bv --robot-plan | jq '.plan.summary.highest_impact'        # Best unblock target
bv --robot-insights | jq '.status'                         # Check metric readiness
bv --robot-insights | jq '.Cycles'                         # Circular deps (must fix!)
```

---

## UBS — Ultimate Bug Scanner

**Golden Rule:** `ubs <changed-files>` before every commit. Exit 0 = safe. Exit >0 = fix & re-run.

### Commands

```bash
ubs file.rs file2.swift                 # Specific files (< 1s) — USE THIS
ubs $(git diff --name-only --cached)    # Staged files — before commit
ubs --only=rust,swift src/              # Language filter (3-5x faster)
ubs --ci --fail-on-warning .            # CI mode — before PR
ubs .                                   # Whole project (ignores build artifacts)
```

### Output Format

```
Warning  Category (N errors)
    file.rs:42:5 – Issue description
    Hint: Suggested fix
Exit code: 1
```

Parse: `file:line:col` → location | Hint → how to fix | Exit 0/1 → pass/fail

### Fix Workflow

1. Read finding → category + fix suggestion
2. Navigate `file:line:col` → view context
3. Verify real issue (not false positive)
4. Fix root cause (not symptom)
5. Re-run `ubs <file>` → exit 0
6. Commit

### Bug Severity

- **Critical (always fix):** Memory safety, use-after-free, data races, injection vulnerabilities
- **Important (production):** Force-unwrap panics, resource leaks, overflow checks
- **Contextual (judgment):** TODO/FIXME, print debugging

---

## ast-grep vs ripgrep

**Use `ast-grep` when structure matters.** It parses code and matches AST nodes, ignoring comments/strings, and can **safely rewrite** code.

- Refactors/codemods: rename APIs, change import forms
- Policy checks: enforce patterns across a repo
- Editor/automation: LSP mode, `--json` output

**Use `ripgrep` when text is enough.** Fastest way to grep literals/regex.

- Recon: find strings, TODOs, log lines, config values
- Pre-filter: narrow candidate files before ast-grep

### Rule of Thumb

- Need correctness or **applying changes** → `ast-grep`
- Need raw speed or **hunting text** → `rg`
- Often combine: `rg` to shortlist files, then `ast-grep` to match/modify

### Examples

```bash
# Rust: Find all unwrap() calls in the engine
ast-grep run -l Rust -p '$EXPR.unwrap()' hoopoe-engine/

# Swift: Find all @MainActor classes
ast-grep run -l Swift -p '@MainActor class $NAME { $$$BODY }'

# Quick textual hunt
rg -n 'ProviderTrait' -t rust
rg -n '@Observable' -t swift

# Combine speed + precision
rg -l -t rust 'unwrap\(' | xargs ast-grep run -l Rust -p '$X.unwrap()' --json
```

---

## Morph Warp Grep — AI-Powered Code Search

**Use `mcp__morph-mcp__warp_grep` for exploratory "how does X work?" questions.** An AI agent expands your query, greps the codebase, reads relevant files, and returns precise line ranges with full context.

**Use `ripgrep` for targeted searches.** When you know exactly what you're looking for.

**Use `ast-grep` for structural patterns.** When you need AST precision for matching/rewriting.

### When to Use What

| Scenario                                  | Tool        | Why                                    |
| ----------------------------------------- | ----------- | -------------------------------------- |
| "How does the agent scheduling work?"     | `warp_grep` | Exploratory; don't know where to start |
| "How does the UniFFI bridge pass events?" | `warp_grep` | Need to understand architecture        |
| "Find all uses of `ProviderTrait`"        | `ripgrep`   | Targeted literal search                |
| "Find files with `println!`"              | `ripgrep`   | Simple pattern                         |
| "Replace all `unwrap()` with `expect()`"  | `ast-grep`  | Structural refactor                    |

### warp_grep Usage

```
mcp__morph-mcp__warp_grep(
  repoPath: "/Users/osekkat/hoopoeApp",
  query: "How does the swarm checkpoint system work?"
)
```

Returns structured results with file paths, line ranges, and extracted code snippets.

### Anti-Patterns

- **Don't** use `warp_grep` to find a specific function name → use `ripgrep`
- **Don't** use `ripgrep` to understand "how does X work" → wastes time with manual reads
- **Don't** use `ripgrep` for codemods → risks collateral edits

<!-- bv-agent-instructions-v1 -->

---

## Beads Workflow Integration

This project uses [beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`) for issue tracking. Issues are stored in `.beads/` and tracked in git.

**Important:** `br` is non-invasive—it NEVER executes git commands. After `br sync --flush-only`, you must manually run `git add .beads/ && git commit`.

### Essential Commands

```bash
# View issues (launches TUI - avoid in automated sessions)
bv

# CLI commands for agents (use these instead)
br ready              # Show issues ready to work (no blockers)
br list --status=open # All open issues
br show <id>          # Full issue details with dependencies
br create --title="..." --type=task --priority=2
br update <id> --status=in_progress
br close <id> --reason "Completed"
br close <id1> <id2>  # Close multiple issues at once
br sync --flush-only  # Export to JSONL (NO git operations)
```

### Workflow Pattern

1. **Start**: Run `br ready` to find actionable work
2. **Claim**: Use `br update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `br close <id>`
5. **Sync**: Run `br sync --flush-only` then manually commit

### Key Concepts

- **Dependencies**: Issues can block other issues. `br ready` shows only unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers, not words)
- **Types**: task, bug, feature, epic, question, docs
- **Blocking**: `br dep add <issue> <depends-on>` to add dependencies

### Session Protocol

**Before ending any session, run this checklist:**

```bash
git status              # Check what changed
git add <files>         # Stage code changes
br sync --flush-only    # Export beads to JSONL
git add .beads/         # Stage beads changes
git commit -m "..."     # Commit everything together
git push                # Push to remote
```

### Best Practices

- Check `br ready` at session start to find available work
- Update status as you work (in_progress → closed)
- Create new issues with `br create` when you discover tasks
- Use descriptive titles and set appropriate priority/type
- Always `br sync --flush-only && git add .beads/` before ending session

<!-- end-bv-agent-instructions -->

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Sync beads** - `br sync --flush-only` to export to JSONL
5. **Hand off** - Provide context for next session

---

## cass — Cross-Agent Session Search

`cass` indexes prior agent conversations (Claude Code, Codex, Cursor, Gemini, ChatGPT, etc.) so we can reuse solved problems.

**Rules:** Never run bare `cass` (TUI). Always use `--robot` or `--json`.

### Examples

```bash
cass health
cass search "agent scheduling" --robot --limit 5
cass view /path/to/session.jsonl -n 42 --json
cass expand /path/to/session.jsonl -n 42 -C 3 --json
cass capabilities --json
cass robot-docs guide
```

### Tips

- Use `--fields minimal` for lean output
- Filter by agent with `--agent`
- Use `--days N` to limit to recent history

stdout is data-only, stderr is diagnostics; exit code 0 means success.

Treat cass as a way to avoid re-solving problems other agents already handled.

---

Note for Codex/GPT-5.2:

You constantly bother me and stop working with concerned questions that look similar to this:

```
Unexpected changes (need guidance)

- Working tree still shows edits I did not make in various files. Please advise whether to keep/commit/revert these before any further work. I did not touch them.
```

NEVER EVER DO THAT AGAIN. The answer is literally ALWAYS the same: those are changes created by the potentially dozen of other agents working on the project at the same time. This is not only a common occurrence, it happens multiple times PER MINUTE. The way to deal with it is simple: you NEVER, under ANY CIRCUMSTANCE, stash, revert, overwrite, or otherwise disturb in ANY way the work of other agents. Just treat those changes identically to changes that you yourself made. Just fool yourself into thinking YOU made the changes and simply don't recall it for some reason.

---

## Note on Built-in TODO Functionality

Also, if I ask you to explicitly use your built-in TODO functionality, don't complain about this and say you need to use beads. You can use built-in TODOs if I tell you specifically to do so. Always comply with such orders.
