# OpenPulse Menu Bar Redesign

Date: 2026-06-18

## Goal

Redesign the menu bar popover so the first information users can scan is quota remaining and reset time. Token usage and equivalent cost remain visible, but only as secondary metadata.

## Approved Direction

- Keep tool ordering fixed by the existing user-controlled menu bar order.
- Do not reorder tools by risk or quota exhaustion.
- For tools with multiple windows, show both windows at the same time.
- Use progress bars with urgency colors, but keep the main text neutral.

## Information Hierarchy

### Primary

- Tool identity
- Remaining quota percentage per window
- Reset time / countdown per window

### Secondary

- Today token usage
- Equivalent cost or other usage metadata
- Config/provider shortcuts

## Layout

- Header becomes a light global status strip.
- Main content becomes one row per tool.
- Each tool card uses a compact header for identity, metadata, and actions.
- Quota panels sit below the header in a two-column grid so they get the full card width.
- Footer actions stay available but visually quieter than the main quota rows.

## Visual Rules

- Progress bar color encodes urgency only:
  - high remaining: green
  - medium: olive / yellow-brown
  - low: rust red
  - unknown: neutral gray
- Percentage and reset text remain the main readable elements.
- Token/cost metadata should never compete with quota values.

## Edge Cases

- Unknown quota: show placeholder value while preserving reset time if available.
- Missing reset time: show quota value and a neutral fallback label.
- Single-window tools may use one full-width quota panel instead of an empty second panel.
- Syncing state stays in the global header rather than repeating inside each tool row.
- Antigravity can expose many account/model rows, so the menu bar shows only the first four visible models per account and sends the rest to the dashboard.
