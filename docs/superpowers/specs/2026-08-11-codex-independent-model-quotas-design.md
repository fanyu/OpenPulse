# Codex Independent Model Quotas Design

## Goal

OpenPulse must keep Codex's general quota and model-specific quotas separate. When GPT-5.3-Codex-Spark exposes the `codex_bengalfox` rate limit, the menu bar must show a dedicated Spark row instead of allowing that limit, or an older general event in the same JSONL file, to replace the general Codex percentage.

## Confirmed Runtime Evidence

- Codex JSONL emits the general quota as `limit_id = "codex"`.
- Spark emits an independent quota as `limit_id = "codex_bengalfox"` and `limit_name = "GPT-5.3-Codex-Spark"`.
- The observed Spark window is weekly and currently reports `used_percent = 0`.
- A Spark event updates the containing JSONL file's modification date even when the newest general event in that file is hours older.
- OpenPulse currently selects files by modification date and then returns the first eligible general event found inside the selected file. This can promote an old general event to fresh data.
- The current `wham/usage` response can contain Spark under `additional_rate_limits` while omitting the general `rate_limit` entirely.

## Product Behavior

The Codex menu-bar card presents independent quota identities rather than one flattened pair of windows.

- The general quota keeps the existing Codex identity and uses `limit_id = "codex"` or a legacy event without an ID.
- Spark appears as a separate row only when an observation for `codex_bengalfox` exists.
- The Spark label uses the upstream `limit_name`, shortened to `Spark` in the compact menu-bar title.
- Each identity renders only the windows it actually owns. A weekly-only quota renders one weekly panel and never appears as a five-hour panel.
- A last-known JSONL value remains visible after five minutes. Its footer shows a relative observation age such as `更新于 3 小时前`.
- Once a window's `reset_at` has passed, the existing reset treatment remains: show `100%` and `已重置` until a new observation arrives.
- Unknown model-specific IDs use their `limit_name`; if no name exists, OpenPulse uses the nonempty `limit_id`. The first release does not add provider-specific icons, colors, or settings.

The compact layout is:

```text
Codex
  通用额度    [5小时余量, when present] [本周余量, when present]
  Spark       [本周余量]
                           更新于 3 小时前
```

## Data Model

`CodexRateLimits` remains the account-level container so existing account switching and persistence continue to work. It gains model-specific observations instead of flattening `additional_rate_limits` into its general `primary` and `secondary` fields.

Add a Codable and Sendable value with these responsibilities:

```swift
struct CodexNamedRateLimit: Codable, Sendable, Identifiable {
    let id: String
    let name: String?
    let primary: CodexWindow?
    let secondary: CodexWindow?
    let observedAt: Date?
}
```

`CodexRateLimits` gains:

```swift
let observedAt: Date?
let additionalLimits: [CodexNamedRateLimit]?
```

Both properties are optional so existing `~/.openpulse/codex-accounts.json` records decode without migration. General windows stay in `primary` and `secondary`; named model quotas stay in `additionalLimits`.

Named limits are persisted inside the owning account's `lastUsage` so last-known values survive an OpenPulse restart. They must not become synthetic accounts or independent `QuotaRecord` rows: the existing account-key cleanup would remove them, and smart-switch scoring must continue to consume only the general windows.

Window accessors classify every available window exactly once using the known Codex durations: 300 minutes for the five-hour window and 10,080 minutes for the seven-day window. They must not independently choose the same sole window for both accessors, and an unknown duration must not be guessed into either slot. With one 10,080-minute window, `fiveHourWindow` is `nil` and `oneWeekWindow` returns that window.

## JSONL Parsing

The parser continues using `~/.codex/sessions` and archived JSONL as the primary local event source.

1. Decode the top-level event `timestamp` in addition to `rate_limits`.
2. Inspect all candidate JSONL files instead of returning from the newest modified file.
3. For every `token_count` event with usable rate limits, form an observation keyed by normalized `limit_id`.
4. Treat `codex`, an empty ID, and a missing ID as the general identity. Treat every other nonempty ID as an independent named identity.
5. Select the newest observation for each identity by event timestamp. Use file modification time only as a fallback for legacy events that lack a timestamp. If timestamps tie, use file modification time and then line order as deterministic tie breakers.
6. Return one merged local snapshot containing the latest general observation plus the latest observation for each independent identity.

The parser may keep the existing 14-day file-search bound and 200-file bound for cost control. The five-minute `CodexLocalQuotaFreshness` cutoff must no longer determine whether a last-known observation is retained.

## API And Local Merge

The API decoder preserves identity:

- `rate_limit` maps only to the general windows.
- Every `additional_rate_limits` item maps to `CodexNamedRateLimit` using `metered_feature` as `id` and `limit_name` as `name`.
- API observations use the successful fetch time as `observedAt`.

Merging is per identity, not all-or-nothing:

- If the API returns a general rate limit, it is the newest general observation for that fetch.
- If the API omits the general rate limit, retain the last-known JSONL or persisted general observation.
- If a newer JSONL general event arrives after an API fetch, use that event.
- Apply the same newest-observation rule independently to Spark and every other named limit.
- Reset credits and plan metadata keep their current preservation behavior.
- API `lastFetchedAt` and account `updatedAt` are synchronization metadata, not quota observation timestamps. Failed API refreshes must not make an older quota observation appear newer.

This design removes the current five-minute replacement gate. It does not remove JSONL, and it does not require the Router meter for quota percentages.

## Menu-Bar Integration

The existing `CodexQuotaCard` and `CodexAccountQuotaCard` keep their account and provider controls. Their quota content changes to a small reusable renderer that:

- renders the general identity first;
- renders named identities below it in stable name order;
- omits a five-hour panel when `fiveHourWindow` is absent;
- omits a weekly panel when `oneWeekWindow` is absent;
- shows the observation-age footer for last-known data;
- preserves the current expired-window presentation.

The implementation must work with the existing uncommitted Router Provider changes in `DataSyncService.swift` and `MenuBarView.swift`. It must not revert, reformat, or replace those changes.

The main Quota window remains behaviorally unchanged in this feature. Its data model must continue decoding and rendering the general quota, but adding named-limit detail rows there is outside this scope.

## Error And Stale-State Handling

- A malformed JSONL line is skipped without discarding valid observations in the same file.
- Missing timestamps fall back to file modification time and remain eligible.
- A named observation without usable windows is not shown.
- A missing general observation does not allow Spark to masquerade as the general quota.
- A sync cycle with no new event for an existing identity retains its last-known observation instead of replacing it with an empty group.
- Old observations remain visible with their age so the UI is honest about freshness.
- A reset timestamp in the past uses the existing `100% / 已重置` state.

## Tests

Parser tests must prove:

- a newer Spark append cannot make an older general event win over a newer general event in another file;
- general and Spark observations are both returned;
- event timestamp wins over file modification time;
- legacy events without timestamp use file modification time;
- a missing or empty `limit_id` remains general;
- malformed lines do not break valid observations;
- a weekly-only observation does not populate `fiveHourWindow`.

API/model tests must prove:

- `rate_limit` remains general;
- `additional_rate_limits` preserves `metered_feature`, `limit_name`, windows, and fetch time;
- API omission of general quota preserves the last-known general observation;
- merge selection happens independently per identity.
- named limits never affect smart-switch scoring or the general account `QuotaRecord`.

Menu-bar tests or extracted presentation tests must prove:

- general renders before Spark;
- Spark produces one weekly row when it has only a weekly window;
- no fake five-hour value appears;
- an old observation produces relative update text;
- expired windows retain the reset presentation.
- strict duration selection remains compatible with DotText, desk snapshots, notifications, account cards, and smart-switch consumers of the general windows.

Focused and full macOS test runs must use isolated DerivedData paths. After each `xcodebuild test`, check `/Users/fanyu/Library/Developer/XCTestDevices` only after all Xcode test processes are idle, and clean it only under the repository's AGENTS.md thresholds.

## Non-Goals

- Do not derive quota percentages from Router `usage-events.jsonl`.
- Do not change official Codex App quota behavior.
- Do not add a Router OAuth or provider feature.
- Do not redesign the overall menu-bar card.
- Do not change smart account switching policy in this feature.
- Do not publish a release, alter version numbers, or touch distribution assets.
