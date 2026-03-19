# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Project Overview

OpenPulse is a native macOS menu bar app (SwiftUI, Swift 6.2, macOS 26+) that unifies token consumption and quota tracking across AI coding assistants: Codex, Codex, GitHub Copilot, and Gemini Code Assist (Antigravity).

## Build Commands

This is a pure Xcode project — no Makefile, npm, or scripts.

```bash
# Regenerate Xcode project from project.yml (XcodeGen)
xcodegen generate

# Build from command line
xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug build

# Open in Xcode
open OpenPulse.xcodeproj
```

There are no automated tests or linters configured. The project enforces Swift 6 strict concurrency via `SWIFT_STRICT_CONCURRENCY = complete` in `project.yml`.

## Architecture

### Entry Point & Global State

- **`App/OpenPulseApp.swift`** — `@main` entry; defines `MenuBarExtra` (popover) + `Window` (main dashboard) scenes.
- **`App/AppStore.swift`** — `@Observable` singleton holding active tab, SwiftData `ModelContainer`, and reference to `DataSyncService`. Injected via `.environment`.

### Data Flow

```
AppStore.startSync()
  → DataSyncService.start()
    → Parallel actor parsers (one per tool)
      → SessionRecord / QuotaRecord / DailyStatsRecord → SwiftData
        → @Query views update reactively
```

### Parser Layer (`Data/Parsers/`)

Each tool has a dedicated `actor` (thread-safe, no locks). Three integration patterns:

1. **Local file parsers** — `ClaudeCodeParser` (JSONL files at `~/.Codex/projects/`), `CodexParser` (SQLite at `~/.codex/state_5.sqlite`), `AntigravityParser` (markdown at `~/.gemini/antigravity/brain/`)
2. **REST API clients** — `CopilotAPIClient` (GitHub internal API)
3. **Hybrid** — `AntigravityParser` reads local files for sessions + calls Google OAuth API for quota

`DataSyncService` orchestrates all parsers, manages FSEvents watchers for local files, and per-tool polling timers (Copilot: 1h, API tools: 30–60min).

### Persistence (`Data/Persistence/`)

SwiftData `@Model` types: `SessionRecord`, `QuotaRecord`, `DailyStatsRecord`. Views use `@Query` directly — no intermediate ViewModels.

### Credentials

`KeychainService` is the only place credentials are stored/read. Service name: `com.fanyu.openpulse`. OAuth tokens are resolved via fallback chain: local tool config file → Keychain.

### View Structure

- **`MenuBarView`** — Compact popover: quota cards, today's token count, tool visibility/reordering, sync status.
- **`MainWindowView`** — `NavigationSplitView` with 7 tabs: Quota, Activity, Trends, Providers, Configs, Settings, Logs.
- **`AppLogger`** — In-memory ring buffer (500 entries); surfaced in `LogView`.

### Key Models

- **`Tool`** (enum) — Single source of truth for display name, SF Symbol, brand logo name, accent color, auth kind, `isQuotaOnly` flag.
- **`ToolSession`** — Per-session record: tokens (input/output/cache), model, cwd, git branch, task description.
- **`ToolQuota`** — Quota snapshot: remaining, total, unit, resetAt; computes fraction and countdown.

## Adding a New Tool

1. Add a case to `Tool` enum with metadata.
2. Create a new `actor` parser in `Data/Parsers/` following existing patterns.
3. Register the parser in `DataSyncService.start()`.
4. Add any required Keychain credential lookup in `KeychainService` or the parser itself.
5. Add brand logo to `Assets.xcassets`.
