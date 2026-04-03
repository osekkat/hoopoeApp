# Hoopoe

A native macOS application for multi-agent software development. Hoopoe implements the Agentic Coding Flywheel methodology (**Plan > Beads > Swarm > Harden > Learn**) in a visual desktop experience, orchestrating Claude Code, OpenAI Codex, and Gemini CLI simultaneously.

Hoopoe replaces the terminal-and-VPS-centric agentic coding workflow with a structured GUI that provides real-time visibility into agent status, bead progress, inter-agent communication, and code quality — without requiring the user to manage tmux panes, SSH sessions, or raw CLI commands.

---

## Architecture

Hoopoe uses a **Core/Shell** architecture with a strict separation between the Rust engine and the Swift UI layer, connected by a UniFFI bridge.

| Layer | Technology | Role |
|-------|-----------|------|
| **Shell** | Swift 6 (SwiftUI + AppKit) | UI, windowing, editor, terminal, macOS integration |
| **Core** | Rust (stable, Tokio) | Agent orchestration, providers, coordination, persistence, learning |
| **Bridge** | Mozilla UniFFI + Swift adapter | Type-safe FFI: coarse commands, async operations, snapshots, event streams |

```
Hoopoe.app
├── hoopoe-engine/          # Rust core (Tokio async runtime)
│   ├── src/core/           #   Agent orchestration, scheduling, leasing, checkpoints
│   ├── src/providers/      #   Claude, Codex, Gemini provider adapters
│   ├── src/coordination/   #   Agent Mail, beads, file reservations
│   ├── src/planning/       #   Plan AST, linting, traceability, bead conversion
│   ├── src/hardening/      #   Review orchestration, testing, quality gates
│   ├── src/learning/       #   CASS session indexing, memory, skill refinement
│   ├── src/persistence/    #   SQLite, event log, checkpoint storage
│   └── src/host_traits/    #   Interfaces implemented by the Swift host
│
├── HoopoeBridge/           # Swift adapter layer over UniFFI bindings
│                           #   EngineFacade, EngineStore, EventReducer, ViewModels
├── HoopoeHost/             # macOS services (Keychain, Seatbelt, file dialogs)
├── HoopoeUI/               # Hybrid SwiftUI + AppKit shell
│   ├── MainWindow/         #   Sidebar, ContentArea, InspectorPanel, NextActionPanel
│   ├── Planning/           #   Multi-model synthesis, refinement tracking
│   ├── Beads/              #   Kanban board, dependency graph, polishing
│   ├── Swarm/              #   Agent cards, mailbox, approvals, cost dashboard
│   ├── Hardening/          #   Test runner, quality gates
│   ├── Learning/           #   Skill editor, insights, session search
│   ├── Settings/           #   Provider, agent, and project configuration
│   └── AppKitViews/        #   PlanEditor, DiffViewer, GhosttyTerminal, BeadGraph,
│                           #     TimelineView, SessionBrowser, ReviewPanel
└── HoopoeUtils/            # Shared Swift utilities (markdown, git, diagnostics)
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
│  │  │ (Agent SDK)  │  │ (JSON-RPC)   │  │ (CLI)        │    │    │
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

## Flywheel Phases

### 1. Planning

Rich markdown plan editor (AppKit, TreeSitter-powered) with multi-model synthesis, iterative refinement, convergence tracking, and structural linting. Plans are compiled into a typed AST with stable section IDs. The "Lie to Them" adversarial technique sends plans to frontier models for exhaustive critique.

### 2. Plan to Beads

Plans are converted into structured work items (beads) with acceptance criteria, test obligations, risk levels, capabilities, and rollback notes. Beads are visualized on a kanban board, dependency graph, and sortable list. Iterative polishing with convergence detection. Bidirectional plan-bead traceability via stable section IDs.

### 3. Agent Swarm Execution

Configurable agent composition with adaptive concurrency. Each agent runs in a Rust-owned PTY with optional tmux persistence. The swarm dashboard shows live agent status cards, bead progress timeline, Agent Mail inbox, file reservation map, and cost tracking. Operator automation runs via session forks (Claude) to avoid interrupting agents. Swarm checkpoints enable crash recovery.

### 4. Review, Testing, and Hardening

Cross-model adversarial review (agents review each other's work in read-only sandboxes), fresh-eyes review, random code exploration, test coverage analysis, quality gates, and de-slopification scanning.

### 5. Meta-Skill (CASS Mining and Skill Refinement)

CASS-compatible session indexing, three-layer memory (episodic, working, procedural), ritual detection for repeated patterns, and automated skill refinement. Session browser with DAG-based replay and Spotlight-style search overlay (Cmd+Shift+K).

---

## Key Features

- **Multi-provider orchestration** — Claude Code (via Agent SDK), OpenAI Codex (app-server JSON-RPC), Gemini CLI (stream-json) behind a common `ProviderTrait`
- **Session forks** — Non-disruptive one-shot operations (commits, reviews, status checks) using Claude's `--fork-session` without interrupting agents
- **Swarm checkpoints** — Complete engine state snapshots (agents, runs, beads, git, budget, approvals) in SQLite for crash recovery
- **Smart agent routing** — Graph metrics (PageRank, betweenness) + bead capabilities determine optimal agent assignment
- **Next Action panel** — Always-visible panel surfacing the single highest-priority intervention with a one-click action button
- **`.context/` shared knowledge** — Filesystem-based persistent context directory readable by all agents without MCP calls
- **GPU-accelerated terminals** — Ghostty via libghostty C API with per-agent terminal caching for instant switching
- **Tiered safety** — Policy engine with Allowed/Blocked/ApprovalRequired tiers, native macOS approval dialogs, Seatbelt sandboxing, file reservation enforcement
- **Cost optimization** — Per-agent/model/bead token tracking, projections, model-switching recommendations, rate limit rotation

---

## Tech Stack

### Rust (Core)

| Crate | Purpose |
|-------|---------|
| `tokio` | Async runtime (process, network, timer, fs) |
| `serde` + `serde_json` | Serialization/deserialization |
| `uniffi` | FFI bridge to Swift |
| `rusqlite` | SQLite persistence |
| `portable-pty` | PTY management for agent processes |
| `thiserror` | Error trait derive macro |
| `tracing` | Structured logging and diagnostics |
| `uuid` | Unique identifiers |
| `chrono` | Date/time handling |
| `tokio-tungstenite` | WebSocket for Claude CLI JSON-RPC |

### Swift (Shell)

| Package | Purpose |
|---------|---------|
| SourceEditor | NSTextView-based code editor |
| TreeSitter | Syntax highlighting and structural parsing |
| libghostty | GPU-accelerated terminal rendering (Zig submodule) |

---

## Building

### Rust Engine

```bash
# Check for compiler errors
cargo check --workspace --all-targets

# Run clippy (pedantic + nursery lints)
cargo clippy --workspace --all-targets -- -D warnings

# Verify formatting
cargo fmt --check

# Run tests
cargo test --workspace
```

### Swift App

```bash
# Build via Xcode
xcodebuild build -scheme Hoopoe -destination 'platform=macOS'
```

---

## Development Roadmap

| Phase | Focus |
|-------|-------|
| 0 | Planning app (Swift-only): editor, multi-model synthesis, refinement |
| 1 | Plan intelligence: AST compiler, structural linter, adversarial critique |
| 2 | Rust engine foundation: UniFFI bridge, host traits, provider trait, SQLite |
| 3 | Bead creation and curation: conversion, `.context/`, traceability, graph |
| 4 | Swarm core + Codex provider: scheduling, leasing, session forks, dashboard |
| 5 | Gemini provider + provider hardening: rate limits, cross-provider coordination |
| 6 | Hardening and quality: review workflows, test coverage, quality gates |
| 7 | Learning and polish: CASS indexing, memory, ritual detection, cost dashboard |
| 8 | Integration hardening and packaging: contract tests, code signing, bundled runtime |

---

## Security

- **Tiered policy engine** — Allowed/Blocked/ApprovalRequired patterns with durable approval records in SQLite
- **Seatbelt sandboxing** — Agent processes restricted to project directory, limited network access
- **macOS Keychain** — All credentials stored via Keychain, never in plaintext files
- **File reservation enforcement** — Pre-commit hooks block commits to files reserved by other agents
- **Budget guards** — Hard cost limits that terminate sessions when exceeded

---

## License

Proprietary. All rights reserved.
