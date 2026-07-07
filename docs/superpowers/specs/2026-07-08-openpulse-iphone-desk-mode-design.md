# OpenPulse iPhone Desk Mode Design

Date: 2026-07-08

## Goal

Build a first iPhone companion for OpenPulse that shows Codex and Claude quota side by side on a horizontally placed, always-on desk phone.

The iPhone app is read-only. macOS remains the only parser and account owner. The phone only consumes a compact CloudKit snapshot and renders a pet-driven full-screen dashboard.

## Scope

### In Scope

- A new iPhone app target in this repository
- One full-screen landscape-only dashboard
- Simultaneous display of Codex and Claude
- CloudKit sync from Mac to iPhone using a compact quota snapshot
- Noticeable pet animation tied to quota state
- Official Codex and Claude pet look, implemented with vector-style animation as the default v1 approach

### Out of Scope

- No iPhone-side parser, login, OAuth, Keychain import, or local file reading
- No widget, StandBy widget, or Live Activity in v1
- No multi-page iPhone information architecture
- No support for Copilot or Antigravity on the iPhone in v1
- No write actions from iPhone back to Mac

## Approved Direction

- Data path: `Mac -> CloudKit -> iPhone`
- Identity/auth model: Mac and iPhone are signed into the same iCloud account
- UI shape: one always-on, landscape full-screen app
- Layout: horizontal `Twin Cockpit`
- Motion level: obvious character motion, but not noisy
- Tool scope: Codex + Claude only

## Product Shape

The iPhone experience is a single full-screen dashboard designed for a phone resting horizontally on a desk. The screen is split into two fixed halves:

- Left: Codex
- Right: Claude

Each half shows:

- The official pet character
- A large remaining quota value
- Reset time
- A persistent energy bar or ring
- State-driven motion

Global chrome stays minimal:

- `OpenPulse` title
- Last synced timestamp
- Subtle stale or sync-delayed warning when needed

There is no navigation in v1. The app is a dedicated ambient display.

## Architecture

### macOS Source of Truth

Existing OpenPulse parsers and refresh logic stay on macOS. `DataSyncService` remains the aggregation point for quota truth.

Add one new publisher layer after quota refresh:

- `QuotaSnapshotPublisher`

Responsibilities:

- Read the latest Codex and Claude quota state after refresh
- Build one compact cross-device snapshot
- Avoid writes when content is unchanged
- Throttle bursty writes
- Persist and retry if CloudKit upload fails

### iPhone Consumer

The iPhone app:

- Reads the latest snapshot from CloudKit
- Maps raw quota state into presentation state
- Renders the `Twin Cockpit` dashboard
- Runs local countdown and stale timers for display only

The iPhone app does not own account logic, quota fetch logic, or parser logic.

## CloudKit Model

Use one compact record type for v1:

- `DeskSnapshot`

One latest record is enough for the first version. It represents the current Mac-published state for the desk display.

### Fields

- `snapshotId`
- `sourceDeviceID`
- `schemaVersion`
- `updatedAt`
- `codexLabel`
- `codexRemaining`
- `codexTotal`
- `codexFraction`
- `codexResetAt`
- `codexStatus`
- `claudeLabel`
- `claudeRemaining`
- `claudeTotal`
- `claudeFraction`
- `claudeResetAt`
- `claudeStatus`

This is intentionally snapshot-shaped, not session-shaped.

## Refresh Strategy

### macOS Publish Rules

- Recompute the snapshot after quota refresh completes
- If the snapshot content is unchanged, skip CloudKit write
- If content changed, publish immediately
- If refreshes happen in bursts, throttle to at most one write every 30 seconds

### iPhone Read Rules

- Fetch once on app foreground
- Listen for CloudKit record changes through the app's CloudKit sync path
- Update relative time and reset countdown locally every 60 seconds

This keeps network writes low while making the ambient display feel current enough for quota monitoring.

## UI Layout

### Main Composition

- Landscape-only full-screen scene
- Left and right cockpit panels with fixed tool assignment
- Large character zone in each panel
- Large numeric quota value below or beside the character
- Reset time grouped tightly with the value
- Energy bar or ring anchored consistently within each panel

### Visual Direction

- Bold, deliberate cockpit split instead of a generic dashboard card grid
- Pet and quota share equal importance
- Background should feel atmospheric, not flat
- Tool-specific color families are allowed, but the screen should remain cohesive as one ambient scene

### Why This Layout

The horizontal split matches the real hardware placement and makes comparison fast:

- left-right scan
- both pets always visible
- no paging
- low cognitive load at a glance

## Motion System

### Design Principle

Motion should be clearly visible from across a desk, but it should not become a distracting loop that steals attention all day.

### Presentation States

Each tool panel maps into one of five states:

- `healthy`
- `warning`
- `critical`
- `exhausted`
- `stale`

### Suggested Thresholds

- `healthy`: fraction `>= 0.5`
- `warning`: fraction `>= 0.2` and `< 0.5`
- `critical`: fraction `< 0.2`
- `exhausted`: remaining is `0`, or upstream state clearly marks exhaustion
- `stale`: snapshot `updatedAt` is older than 10 minutes

### Pet Motion by State

- `healthy`: patrol, bounce, glance, confident ambient motion
- `warning`: shorter patrols, more pauses, visibly reduced calm
- `critical`: quicker motion, alert pulses, visible urgency
- `exhausted`: collapse, sit, dim, or inactive pose
- `stale`: waiting pose, reduced animation, sync delayed hint

The state machine is driven only by synchronized snapshot data plus local stale detection.

## Asset Strategy

- Use official Codex and Claude pet appearances
- Use vector-style motion implementation as the default v1 animation approach
- If exact official assets are not directly reusable, recreate their look closely enough to preserve identity while keeping the animation system practical

Asset packaging should support:

- idle loop
- emphasis or alert loop
- exhausted pose

without forcing a large sprite pipeline in v1.

## Error Handling and Fallbacks

### macOS Side

- If CloudKit write fails, keep the latest local snapshot and retry later
- Failed publish should not break local OpenPulse quota UX

### iPhone Side

- If no snapshot exists yet, show `Waiting for Mac`
- If snapshot is stale, show stale UI and stale pet state instead of pretending the data is fresh
- If one tool is unavailable, the other panel should still render normally

## Implementation Units

### 1. Snapshot Domain

- Cross-device snapshot model
- Snapshot equality and change detection
- Quota-to-status mapping helpers

### 2. macOS Publish Layer

- Build snapshot from existing OpenPulse state
- CloudKit write and retry logic
- Publish throttling

### 3. iPhone App Target

- New target and shared model access
- CloudKit read service
- Landscape-only app shell

### 4. Twin Cockpit UI

- Full-screen split layout
- Shared ambient background
- Tool panel components
- Last sync indicator

### 5. Motion Layer

- Pet state machine
- State-to-animation mapping
- Low-motion fallback if needed

## Verification

### Functional Checks

- Mac publishes a snapshot after real quota refresh
- iPhone receives and renders Codex and Claude together
- Unchanged snapshots do not cause repeated writes
- Snapshot freshness changes the UI into stale mode after 10 minutes
- Quota thresholds move pets between healthy, warning, critical, and exhausted states

### UX Checks

- Readable from desk distance in landscape orientation
- Both pets remain visible without interaction
- Large numeric quota remains the first readable signal
- Motion is noticeable but not visually chaotic during extended display

## Minimal v1 Success Criteria

v1 is successful if:

- OpenPulse on Mac can publish Codex and Claude quota to CloudKit
- An iPhone on the same iCloud account can show a landscape-only full-screen dashboard
- Codex and Claude appear at the same time
- Official pet identity is preserved
- Pet motion changes noticeably with quota state
- The app remains read-only and does not duplicate parser or account logic on iPhone
