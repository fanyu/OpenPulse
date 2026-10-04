# OpenPulse Project Rules

OpenPulse is a native macOS menu bar app with an iOS companion target (SwiftUI, Swift 6.2, macOS 26+) that unifies token consumption and quota tracking across AI coding assistants: Claude Code, Codex, GitHub Copilot, and Gemini Code Assist (Antigravity).

## Source Of Truth

- `project.yml` is authoritative for targets, schemes, deployment versions, build settings, and test targets. Regenerate `OpenPulse.xcodeproj` with `xcodegen generate` only when `project.yml` changes.
- The architecture section below is orientation, not an inventory. Inspect the touched source and its callers before relying on it; it can lag the code.

## Scope And Safety

- Follow the global task-sizing rules. Small, explicit changes do not require a build or test unless requested.
- Treat SwiftData models, migrations, Keychain access, OAuth credentials, file-system watchers, polling, and concurrency as higher-risk areas; inspect the active code path and use proportionate verification.
- Never print, copy, or commit credentials, tokens, or private local-tool data.
- Preserve unrelated changes and avoid updating generated Xcode project files directly when the corresponding `project.yml` change is required.

## Verification

- For standard work, choose the narrowest relevant scheme or test target declared in `project.yml`.
- A build, unit test, Simulator check, and runtime credential/API validation are distinct evidence; report precisely what ran.

## Build Commands

This is an XcodeGen project; there is no Makefile or npm. `scripts/` holds helper tooling (e.g. `compose_showcase.py`), not build steps.

```bash
# Regenerate Xcode project from project.yml (XcodeGen)
xcodegen generate

# Build from command line
xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug build

# Open in Xcode
open OpenPulse.xcodeproj
```

Unit tests live in the `OpenPulseTests` and `OpenPulseiPhoneTests` targets (see `project.yml`); no linter is configured. The project enforces Swift 6 strict concurrency via `SWIFT_STRICT_CONCURRENCY = complete` in `project.yml`.

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

1. **Local file parsers** — `ClaudeCodeParser` (JSONL files at `~/.claude/projects/`), `CodexParser` (SQLite at `~/.codex/state_5.sqlite`), `AntigravityParser` (markdown at `~/.gemini/antigravity/brain/`)
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
