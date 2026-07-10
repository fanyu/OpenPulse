# Task 2 Report: Parser fetch path → retrieveUserQuotaSummary + tier

## Status: DONE

## Commit
`0611f1a` — feat(antigravity): fetch quota via retrieveUserQuotaSummary + tier
(1 file changed, 17 insertions(+), 180 deletions(-))

## What changed
`OpenPulse/Data/Parsers/AntigravityParser.swift`:

1. Added `retrieveUserQuotaSummaryEndpoint` constant; removed `fetchModelsEndpoint` and
   `retrieveUserQuotaEndpoint` constants.
2. Replaced `fetchProjectId(token:) -> String?` with
   `fetchProjectAndTier(token:) -> (projectId: String?, tier: AGTier?)`, which decodes
   `AGLoadCodeAssistResponse` and calls `Self.decodeTier(from:)` on the same response body.
   (`AGLoadCodeAssistResponse` was already file-scope/private from Task 1, so no change needed there;
   `AGSubscriptionInfo` was already gone.)
3. Added `fetchQuotaSummary(token:projectId:) -> [AGQuotaGroup]`, POSTing to
   `retrieveUserQuotaSummaryEndpoint` and decoding via `Self.decodeQuotaGroups(from:)`.
4. Rewrote `fetchAccountQuota(from:)` to call `fetchProjectAndTier` + `fetchQuotaSummary` and
   return `AGAccountQuota(email:tier:groups:)` with real data (removed the `groups: []` stub and
   the ponytail comment referencing Task 2/3).
5. Deleted dead per-model machinery: `fetchModelCatalog`, `fetchQuotaBuckets` (used the deleted
   `retrieveUserQuotaEndpoint`, in scope per brief's "now-dead per-model machinery"),
   `mergeModelCatalogs`, `mergeQuotaBuckets`, and structs `AGModelCatalog`,
   `AGModelCatalogResponse`, `AGModelSort`, `AGModelGroup`, `AGModelInfo`, `AGQuotaBucket`,
   `AGUserQuotaResponse`.
6. Kept `AGQuotaFetchResult` — still used by `fetchAllAccountQuotas()`.
7. Updated `toolQuota(from:)` to use `accounts.compactMap(\.geminiRemainingFraction).min()` /
   `.geminiEarliestReset` instead of flattening raw `AGWindow`s.
8. Left the compat shim untouched per instructions: deprecated `AGModelQuota` struct and
   `AGAccountQuota.models` / `.geminiModels` / `.mergedPreferBetter(with:)` remain, still consumed
   by `MenuBarView.swift`, `ProviderComponents.swift`, `QuotaView.swift`, `DataSyncService.swift`
   (migrated in Tasks 3/5).

## Note on `fetchQuotaBuckets`
The brief's file-level delete list didn't name `fetchQuotaBuckets` explicitly, but it is per-model
machinery hitting the now-deleted `retrieveUserQuotaEndpoint` and returning the now-deleted
`[AGQuotaBucket]` type, and nothing else called it — deleted along with `fetchModelCatalog` as
"now-dead per-model machinery."

## Verification
- `xcodebuild build -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug -destination 'platform=macOS'` → **BUILD SUCCEEDED** (full app, including the still-present compat-shim consumers).
- `xcodebuild test ... -only-testing:OpenPulseTests/AntigravityQuotaDecodingTests` → **TEST SUCCEEDED**, 3/3 tests passed (decodesTwoGroupsWithBothWindows, percentTextAndClamp, tierFreeVsPaid). No decode regressions from Task 1.
- Grep confirmed no leftover references to any deleted symbol (`fetchModelCatalog`, `mergeModelCatalogs`, `mergeQuotaBuckets`, `AGModelCatalog*`, `AGModelSort`, `AGModelGroup`, `AGModelInfo`, `AGQuotaBucket`, `AGUserQuotaResponse`, `fetchModelsEndpoint`, `retrieveUserQuotaEndpoint`, `fetchProjectId`, `AGSubscriptionInfo`, `fetchQuotaBuckets`).

## Concerns
None. Only `OpenPulse/Data/Parsers/AntigravityParser.swift` was staged/committed (verified via `git diff --cached --stat`); unrelated pre-existing working-tree changes (project.pbxproj, project.yml, ToolCockpitPanel.swift, new asset dir) were left untouched.
