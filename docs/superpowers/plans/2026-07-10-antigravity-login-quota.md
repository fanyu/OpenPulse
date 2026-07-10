# Antigravity In-App Login + Tier-Aware 5h/Weekly Quota — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read Antigravity quota as grouped 5-hour + weekly windows with free/paid tier recognition, and add an in-app Google OAuth login so accounts can be authorized inside OpenPulse (not only scanned from `~/.cli-proxy-api`).

**Architecture:** Switch `AntigravityParser` from `retrieveUserQuota` (flat per-model) to `retrieveUserQuotaSummary` (grouped dual-window) plus `loadCodeAssist.currentTier`. Add an `AntigravityAccountService` actor mirroring the existing `CodexAccountService` loopback OAuth flow, storing metadata in `~/.openpulse/antigravity-accounts.json` and refresh tokens in Keychain. Unify OAuth-authorized accounts with the existing local scan via an `AGCredential` provider.

**Tech Stack:** Swift 6.2, strict concurrency (`complete`), SwiftUI, SwiftData, `Network.framework` (`NWListener`), `CryptoKit` (PKCE S256), macOS 26+. Design doc: `docs/superpowers/specs/2026-07-10-antigravity-login-quota-design.md`.

## Global Constraints

- Swift 6 strict concurrency `complete` — all new types crossing actor boundaries are `Sendable`.
- Keychain service name is `com.fanyu.openpulse` (via `KeychainService`); never store credentials elsewhere.
- OpenPulse-owned store dir is `~/.openpulse/` (`URL.homeDirectory.appending(path: ".openpulse")`), matching `CodexAccountService`.
- Reuse the OAuth client already in `AntigravityParser`: id `1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com`, secret `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`. Do NOT hardcode a second copy — expose it from one place.
- `isPaid = (currentTier.id != "free-tier")`; badge label `"Google AI Pro"` when paid else `"Free"`.
- After any code change: build (`xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug build`) and run the app (user memory: 每次改完代码必须 build 并 run app).
- Tests live in `OpenPulseTests/`, use `Testing` framework (`import Testing` + `@Test`/`#expect`) matching existing `DeskSnapshotBuilderTests.swift`. Verify which by reading an existing test first.

---

# Phase 1 — Quota model upgrade (no login dependency)

Ships 5h/weekly windows + tier badge for already-scanned accounts.

### Task 1: New grouped-window quota types + decoders

**Files:**
- Modify: `OpenPulse/Data/Parsers/AntigravityParser.swift` (replace `AGModelQuota`/model-catalog logic; add `AGWindow`, `AGQuotaGroup`, `AGTier`; rework `AGAccountQuota`)
- Test: `OpenPulseTests/AntigravityQuotaDecodingTests.swift` (create)

**Interfaces:**
- Produces:
  - `struct AGWindow: Sendable { enum Kind { case fiveHour, weekly }; let kind: Kind; let remainingFraction: Double?; let resetTime: Date?; let description: String? }` with computed `remainingPercentText: String`, `validatedResetDate: Date?`, `resetCountdown: String?`.
  - `struct AGQuotaGroup: Sendable, Identifiable { let id: String; let displayName: String; let fiveHour: AGWindow?; let weekly: AGWindow? }`
  - `struct AGTier: Sendable { let id: String; let name: String; var isPaid: Bool; var badgeLabel: String }`
  - `struct AGAccountQuota: Sendable, Identifiable { let email: String; let tier: AGTier?; let groups: [AGQuotaGroup]; var id: String }`
  - `static func decodeQuotaGroups(from data: Data) throws -> [AGQuotaGroup]` and `static func decodeTier(from data: Data) -> AGTier?` on `AntigravityParser` (static so tests can call without network).

- [ ] **Step 1: Write the failing test**

Create `OpenPulseTests/AntigravityQuotaDecodingTests.swift`:

```swift
import Testing
import Foundation
@testable import OpenPulse

struct AntigravityQuotaDecodingTests {
    private let summaryJSON = """
    {"groups":[
      {"displayName":"Gemini Models","buckets":[
        {"bucketId":"gemini-weekly","window":"weekly","resetTime":"2999-07-16T02:49:09Z","remainingFraction":0.7138273,"description":"weekly prose"},
        {"bucketId":"gemini-5h","window":"5h","resetTime":"2999-07-10T06:42:14Z","remainingFraction":0.5812507,"description":"5h prose"}]},
      {"displayName":"Claude and GPT models","buckets":[
        {"bucketId":"3p-weekly","window":"weekly","resetTime":"2999-07-16T05:52:06Z","remainingFraction":0.66538054},
        {"bucketId":"3p-5h","window":"5h","resetTime":"2999-07-10T07:40:22Z","remainingFraction":1}]}]}
    """.data(using: .utf8)!

    @Test func decodesTwoGroupsWithBothWindows() throws {
        let groups = try AntigravityParser.decodeQuotaGroups(from: summaryJSON)
        #expect(groups.count == 2)
        let gemini = try #require(groups.first { $0.displayName == "Gemini Models" })
        #expect(gemini.id == "gemini")
        #expect(gemini.fiveHour?.kind == .fiveHour)
        #expect(gemini.fiveHour?.remainingFraction == 0.5812507)
        #expect(gemini.fiveHour?.description == "5h prose")
        #expect(gemini.weekly?.remainingFraction == 0.7138273)
        #expect(gemini.weekly?.validatedResetDate != nil)   // year 2999 = future
        let thirdParty = try #require(groups.first { $0.id == "3p" })
        #expect(thirdParty.fiveHour?.remainingFraction == 1)
        #expect(thirdParty.fiveHour?.description == nil)
    }

    @Test func percentTextAndClamp() throws {
        let groups = try AntigravityParser.decodeQuotaGroups(from: summaryJSON)
        let gemini = try #require(groups.first { $0.id == "gemini" })
        #expect(gemini.fiveHour?.remainingPercentText == "58%")
    }

    @Test func tierFreeVsPaid() {
        let free = AntigravityParser.decodeTier(from: #"{"currentTier":{"id":"free-tier","name":"Antigravity"}}"#.data(using: .utf8)!)
        #expect(free?.isPaid == false)
        #expect(free?.badgeLabel == "Free")
        let paid = AntigravityParser.decodeTier(from: #"{"currentTier":{"id":"legacy-tier","name":"Google AI Pro"}}"#.data(using: .utf8)!)
        #expect(paid?.isPaid == true)
        #expect(paid?.badgeLabel == "Google AI Pro")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulse -destination 'platform=macOS' -only-testing:OpenPulseTests/AntigravityQuotaDecodingTests 2>&1 | tail -20`
Expected: FAIL — `decodeQuotaGroups` / types not found (compile error).

- [ ] **Step 3: Add the new types + decoders**

In `AntigravityParser.swift`, add near the other public quota structs (replace the `AGModelQuota` struct entirely and the `AGModelCatalog`-based `mergeQuotaBuckets(_:with:)`; keep the `parseISO8601Flexible` and `countdownString` free functions they already use):

```swift
struct AGWindow: Sendable {
    enum Kind: Sendable { case fiveHour, weekly }
    let kind: Kind
    let remainingFraction: Double?
    let resetTime: Date?
    let description: String?

    var remainingPercentText: String {
        guard let f = remainingFraction else { return "—" }
        return "\(Int((min(1, max(0, f)) * 100).rounded()))%"
    }
    /// Future-only; Antigravity sometimes returns reference-date placeholders.
    var validatedResetDate: Date? {
        guard let resetTime, resetTime > Date() else { return nil }
        return resetTime
    }
    var resetCountdown: String? {
        validatedResetDate.map { countdownString(to: $0) }
    }
}

struct AGQuotaGroup: Sendable, Identifiable {
    let id: String            // bucket prefix, e.g. "gemini" / "3p"
    let displayName: String
    let fiveHour: AGWindow?
    let weekly: AGWindow?
}

struct AGTier: Sendable {
    let id: String
    let name: String
    var isPaid: Bool { id != "free-tier" }
    var badgeLabel: String { isPaid ? "Google AI Pro" : "Free" }
}

struct AGAccountQuota: Sendable, Identifiable {
    let email: String
    let tier: AGTier?
    let groups: [AGQuotaGroup]
    var id: String { email }

    /// Gemini group's worst remaining fraction (drives menu-bar aggregate).
    var geminiRemainingFraction: Double? {
        guard let g = groups.first(where: { $0.id == "gemini" }) else { return nil }
        return [g.fiveHour?.remainingFraction, g.weekly?.remainingFraction].compactMap { $0 }.min()
    }
    var geminiEarliestReset: Date? {
        guard let g = groups.first(where: { $0.id == "gemini" }) else { return nil }
        return [g.fiveHour?.validatedResetDate, g.weekly?.validatedResetDate].compactMap { $0 }.min()
    }
}
```

Add the static decoders (place after the struct definitions):

```swift
extension AntigravityParser {
    static func decodeQuotaGroups(from data: Data) throws -> [AGQuotaGroup] {
        let resp = try JSONDecoder().decode(AGQuotaSummaryResponse.self, from: data)
        return resp.groups.map { group in
            let byWindow = Dictionary(grouping: group.buckets, by: \.window)
            func window(_ key: String, _ kind: AGWindow.Kind) -> AGWindow? {
                guard let b = byWindow[key]?.first else { return nil }
                return AGWindow(
                    kind: kind,
                    remainingFraction: b.remainingFraction.map { min(1, max(0, $0)) },
                    resetTime: b.resetTime.flatMap(parseISO8601Flexible),
                    description: b.description
                )
            }
            return AGQuotaGroup(
                id: group.buckets.first?.bucketId.components(separatedBy: "-").first ?? group.displayName,
                displayName: group.displayName,
                fiveHour: window("5h", .fiveHour),
                weekly: window("weekly", .weekly)
            )
        }
    }

    static func decodeTier(from data: Data) -> AGTier? {
        guard let info = try? JSONDecoder().decode(AGLoadCodeAssistResponse.self, from: data),
              let tier = info.currentTier else { return nil }
        return AGTier(id: tier.id, name: tier.name)
    }
}

private struct AGQuotaSummaryResponse: Decodable {
    struct Group: Decodable { let displayName: String; let buckets: [Bucket] }
    struct Bucket: Decodable {
        let bucketId: String
        let window: String
        let resetTime: String?
        let remainingFraction: Double?
        let description: String?
    }
    let groups: [Group]
}

private struct AGLoadCodeAssistResponse: Decodable {
    struct Tier: Decodable { let id: String; let name: String }
    let currentTier: Tier?
    let cloudaicompanionProject: String?
}
```

Note: `parseISO8601Flexible` and `countdownString(to:)` are existing free functions in the codebase — reuse, do not redefine. `AGLoadCodeAssistResponse` supersedes `AGSubscriptionInfo` (which only had `cloudaicompanionProject`); update `fetchProjectId` in Task 3 to decode the new type. Delete the old `AGSubscriptionInfo` struct.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulse -destination 'platform=macOS' -only-testing:OpenPulseTests/AntigravityQuotaDecodingTests 2>&1 | tail -20`
Expected: PASS (3 tests). Build will still fail elsewhere (old `AGModelQuota` references) — that's fixed in Tasks 2–3; run only this test file here.

- [ ] **Step 5: Commit**

```bash
git add OpenPulse/Data/Parsers/AntigravityParser.swift OpenPulseTests/AntigravityQuotaDecodingTests.swift
git commit -m "feat(antigravity): grouped 5h/weekly quota + tier decoders"
```

---

### Task 2: Parser fetch path → summary + tier; drop per-model machinery

**Files:**
- Modify: `OpenPulse/Data/Parsers/AntigravityParser.swift` (`fetchAccountQuota`, `fetchProjectId`, add `fetchQuotaSummary`; delete `fetchModelCatalog`, `mergeModelCatalogs`, `mergeQuotaBuckets`, `AGModelCatalog*`, `AGQuotaBucket`, `AGUserQuotaResponse`, `fetchModelsEndpoint`, `retrieveUserQuotaEndpoint`)
- Modify: add `retrieveUserQuotaSummaryEndpoint` constant

**Interfaces:**
- Consumes: `AntigravityParser.decodeQuotaGroups`, `decodeTier` (Task 1)
- Produces: `func fetchAccountQuota(from:) async throws -> AGAccountQuota` (unchanged signature, new body); `func fetchQuota(forAccountEmail:) async throws -> AGAccountQuota` (unchanged).

- [ ] **Step 1: Add endpoint + fetchQuotaSummary, rewrite fetchProjectId to also return tier**

Add constant beside the others:
```swift
private let retrieveUserQuotaSummaryEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
```

Change `fetchProjectId` to return both project id and tier (rename to `fetchProjectAndTier`):
```swift
private func fetchProjectAndTier(token: String) async throws -> (projectId: String?, tier: AGTier?) {
    var request = URLRequest(url: URL(string: loadCodeAssistEndpoint)!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["metadata": ["ideType": "ANTIGRAVITY"]])
    request.timeoutInterval = 10

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { return (nil, nil) }
    guard (200..<300).contains(http.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw AntigravityError.apiFailed("loadCodeAssist HTTP \(http.statusCode): \(body.prefix(200))")
    }
    let info = try? JSONDecoder().decode(AGLoadCodeAssistResponse.self, from: data)
    let tier = Self.decodeTier(from: data)
    return (info?.cloudaicompanionProject, tier)
}
```
Make `AGLoadCodeAssistResponse` file-scope (not nested) so both `decodeTier` and this method use it. Delete the old `AGSubscriptionInfo`.

Add:
```swift
private func fetchQuotaSummary(token: String, projectId: String?) async throws -> [AGQuotaGroup] {
    var request = URLRequest(url: URL(string: retrieveUserQuotaSummaryEndpoint)!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    var payload: [String: Any] = [:]
    if let projectId { payload["project"] = projectId }
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
    request.timeoutInterval = 10

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw AntigravityError.apiFailed("No HTTP response from retrieveUserQuotaSummary")
    }
    if http.statusCode == 403 { throw AntigravityError.apiFailed("403 Forbidden – check Google auth") }
    guard (200..<300).contains(http.statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? ""
        throw AntigravityError.apiFailed("retrieveUserQuotaSummary HTTP \(http.statusCode): \(body.prefix(200))")
    }
    return try Self.decodeQuotaGroups(from: data)
}
```

- [ ] **Step 2: Rewrite `fetchAccountQuota` body**

Replace the model-catalog/bucket portion with:
```swift
private func fetchAccountQuota(from file: URL) async throws -> AGAccountQuota {
    let rawData = try Data(contentsOf: file)
    var auth = try JSONDecoder().decode(AntigravityAuthFile.self, from: rawData)
    guard !auth.accessToken.isEmpty else { throw AntigravityError.tokenParseFailure }

    if auth.isExpired, let refreshToken = auth.refreshToken, !refreshToken.isEmpty {
        let (newToken, expiresIn) = try await refreshAccessToken(refreshToken: refreshToken)
        auth.accessToken = newToken
        persistRefreshedToken(at: file, originalData: rawData, newToken: newToken, expiresIn: expiresIn)
    }

    let token = auth.accessToken
    let email = auth.email ?? emailFromFilename(file.deletingPathExtension().lastPathComponent)
    let (projectId, tier) = try await fetchProjectAndTier(token: token)
    let groups = try await fetchQuotaSummary(token: token, projectId: projectId)
    return AGAccountQuota(email: email, tier: tier, groups: groups)
}
```

- [ ] **Step 3: Delete now-dead code**

Delete: `fetchModelCatalog`, `mergeModelCatalogs`, `mergeQuotaBuckets(primary:secondary:)`, `mergeQuotaBuckets(_:with:)`, structs `AGModelCatalog`, `AGModelCatalogResponse`, `AGModelSort`, `AGModelGroup`, `AGModelInfo`, `AGQuotaBucket`, `AGUserQuotaResponse`, constants `fetchModelsEndpoint`, `retrieveUserQuotaEndpoint`. Remove `AGAccountQuota.geminiModels`/`mergedPreferBetter` and `AGAccountQuota.models`-based helpers (replaced by group helpers in Task 1). Update `fetchAllAccountQuotas`/`toolQuota(from:)` to use `geminiRemainingFraction` (Task 2 Step 4).

- [ ] **Step 4: Update `toolQuota(from:)`**

```swift
private func toolQuota(from accounts: [AGAccountQuota]) -> ToolQuota {
    let minFraction = accounts.compactMap(\.geminiRemainingFraction).min()
    let resetAt = accounts.compactMap(\.geminiEarliestReset).min()
    let remainingPct = minFraction.map { Int(($0 * 100).rounded()) }
    return ToolQuota(
        id: Tool.antigravity.rawValue, tool: .antigravity,
        accountKey: nil, accountLabel: nil,
        remaining: remainingPct, total: remainingPct == nil ? nil : 100,
        unit: .requests, resetAt: resetAt, updatedAt: Date(),
        raw: accounts as (any Sendable)
    )
}
```

- [ ] **Step 5: Compile the parser in isolation**

Run: `xcodebuild build -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug 2>&1 | grep -E "AntigravityParser.swift.*error" | head`
Expected: no errors originating in `AntigravityParser.swift` (DataSyncService/View errors remain, fixed in Tasks 3–4).

- [ ] **Step 6: Commit**

```bash
git add OpenPulse/Data/Parsers/AntigravityParser.swift
git commit -m "feat(antigravity): fetch quota via retrieveUserQuotaSummary + tier"
```

---

### Task 3: DataSyncService aggregate adaptation

**Files:**
- Modify: `OpenPulse/Data/Services/DataSyncService.swift` (`antigravityAggregateQuota`, `mergeAntigravityAccounts` if it references models)

**Interfaces:**
- Consumes: `AGAccountQuota.geminiRemainingFraction`, `geminiEarliestReset` (Task 1)

- [ ] **Step 1: Rewrite `antigravityAggregateQuota`**

Replace body (around line 734):
```swift
private func antigravityAggregateQuota(from accounts: [AGAccountQuota]) -> ToolQuota {
    let minFraction = accounts.compactMap(\.geminiRemainingFraction).min()
    let resetAt = accounts.compactMap(\.geminiEarliestReset).min()
    let remainingPct = minFraction.map { Int(($0 * 100).rounded()) }
    return ToolQuota(
        id: Tool.antigravity.rawValue, tool: .antigravity,
        accountKey: nil, accountLabel: nil,
        remaining: remainingPct, total: remainingPct == nil ? nil : 100,
        unit: .requests, resetAt: resetAt, updatedAt: Date(),
        raw: accounts as (any Sendable)
    )
}
```

- [ ] **Step 2: Fix `mergeAntigravityAccounts`**

It calls `currentAccount.mergedPreferBetter(with: refreshedAccount)` which was deleted. Since refresh replaces wholesale, change that case to prefer refreshed:
```swift
case let (_, refreshedAccount?):
    refreshedAccount
```
Collapse the two `refreshedAccount?` cases. If `mergeAntigravityAccounts` becomes unused after this, delete it (grep first: `grep -n mergeAntigravityAccounts OpenPulse/Data/Services/DataSyncService.swift`).

- [ ] **Step 3: Build (expect only View errors remain)**

Run: `xcodebuild build -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug 2>&1 | grep -E "DataSyncService.swift.*error" | head`
Expected: no errors in `DataSyncService.swift`.

- [ ] **Step 4: Commit**

```bash
git add OpenPulse/Data/Services/DataSyncService.swift
git commit -m "feat(antigravity): aggregate quota from gemini group windows"
```

---

### Task 4: Reusable window UI + tier badge

**Files:**
- Create: `OpenPulse/Views/Components/AGQuotaViews.swift` (shared components)

**Interfaces:**
- Produces:
  - `struct AGTierBadge: View { let tier: AGTier? }`
  - `struct AGWindowRow: View { let title: String; let window: AGWindow? }`
  - `struct AGGroupCard: View { let group: AGQuotaGroup }` (renders displayName + 5h row + weekly row)
  - `struct AGAccountQuotaBody: View { let account: AGAccountQuota }` (email + tier badge + all groups) — the single reusable body embedded by every AG view site.

- [ ] **Step 1: Write the components**

```swift
import SwiftUI

struct AGTierBadge: View {
    let tier: AGTier?
    var body: some View {
        if let tier {
            Text(tier.badgeLabel)
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(tier.isPaid ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08),
                            in: Capsule())
                .foregroundStyle(tier.isPaid ? Color.accentColor : .secondary)
        }
    }
}

struct AGWindowRow: View {
    let title: String
    let window: AGWindow?
    private var color: Color {
        let f = window?.remainingFraction ?? 1
        return f < 0.1 ? .red : (f < 0.3 ? .orange : Color("AntigravityPurple"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(window?.remainingPercentText ?? "—").font(.system(size: 10, weight: .bold))
                if let cd = window?.resetCountdown {
                    Text(cd).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            QuotaProgressBar(fraction: window?.remainingFraction, color: color)
        }
        .help(window?.description ?? "")
    }
}

struct AGGroupCard: View {
    let group: AGQuotaGroup
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.displayName).font(.system(size: 11, weight: .bold))
            AGWindowRow(title: "5 小时", window: group.fiveHour)
            AGWindowRow(title: "每周", window: group.weekly)
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AGAccountQuotaBody: View {
    let account: AGAccountQuota
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(account.email).font(.system(size: 13, weight: .bold)).lineLimit(1)
                AGTierBadge(tier: account.tier)
                Spacer()
            }
            ForEach(account.groups) { AGGroupCard(group: $0) }
        }
    }
}
```

- [ ] **Step 2: Build the file in isolation**

Run: `xcodebuild build -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug 2>&1 | grep -E "AGQuotaViews.swift.*error" | head`
Expected: no errors in `AGQuotaViews.swift` (site errors elsewhere remain).

- [ ] **Step 3: Commit**

```bash
git add OpenPulse/Views/Components/AGQuotaViews.swift
git commit -m "feat(antigravity): reusable 5h/weekly window + tier badge views"
```

---

### Task 5: Swap AG view sites to grouped windows

Retires per-model rows and the model-hiding UI (approved). Four sites consume `AGAccountQuota`.

**Files:**
- Modify: `OpenPulse/Views/Providers/ProviderComponents.swift` (`AGAccountCard`, its container)
- Modify: `OpenPulse/Views/MenuBar/MenuBarView.swift` (`AntigravityMultiAccountCard`, `AntigravityAggregateCard`, `AntigravityAccountSection`, `AntigravityAggregatedModel*`)
- Modify: `OpenPulse/Views/Quota/QuotaView.swift` (`AntigravityDetailCard`)

**Interfaces:**
- Consumes: `AGAccountQuotaBody`, `AGGroupCard`, `AGTierBadge` (Task 4)

- [ ] **Step 1: ProviderComponents `AGAccountCard`**

Replace the entire `AGAccountCard` struct (currently model-grid + hiding) with a thin wrapper. Keep the account-visibility toggle; drop model hiding:
```swift
struct AGAccountCard: View {
    let account: AGAccountQuota
    let isAccountHidden: Bool
    let onToggleAccount: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AGTierBadge(tier: account.tier)
                Spacer()
                Toggle("", isOn: Binding(get: { !isAccountHidden }, set: { onToggleAccount($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            AGAccountQuotaBody(account: account)
        }
        .padding(14)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.05), lineWidth: 1))
    }
}
```
Update its call site (the `ForEach(accounts)` around line 473) to the new initializer — drop `syncModelConfig`/`globalHiddenModelIdsRaw` args. Delete the now-unused `syncModelConfig`/`syncModelConfig` toggle and `hiddenModelIds` state in the container; keep `hiddenAccountEmails`.

- [ ] **Step 2: QuotaView `AntigravityDetailCard`**

Replace the card's model list (`ForEach(model...)` using `model.resetCountdown`, line ~688) with `AGAccountQuotaBody(account: account)`. Keep the header (logo, today tokens, refresh button, `isRefreshing`). Remove references to `account.models`.

- [ ] **Step 3: MenuBarView AG cards**

- `AntigravityAccountSection`: replace its per-model body with `AGAccountQuotaBody(account: account)`.
- `AntigravityMultiAccountCard`: unchanged structure (it already loops accounts → `AntigravityAccountSection`).
- `AntigravityAggregateCard` + `AntigravityAggregatedModel` + `AntigravityAggregatedModelRow`: delete the per-model aggregation. Replace `AntigravityAggregateCard` body with a compact per-account list reusing `AGAccountQuotaBody`, or (simpler) make the aggregate card render `AntigravityMultiAccountCard`'s content. Delete `AntigravityAggregatedModel`/`Row` structs and the `ag.hiddenModelIds` `@AppStorage`. Keep `ag.hiddenAccountEmails` filtering.

Grep after: `grep -rn "\.models\|AGModelQuota\|hiddenModelIds\|AntigravityAggregatedModel" OpenPulse --include=*.swift` → must return nothing.

- [ ] **Step 4: Full build**

Run: `xcodebuild build -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug 2>&1 | tail -15`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Run the app and verify**

Run the app (via `mcp__xcode__RunProject` or the run skill). Open the Antigravity provider view and menu bar. Expected: each account shows a tier badge + "Gemini Models"/"Claude and GPT models" cards, each with 5 小时 and 每周 bars, percentages matching the live API (e.g. Gemini ≈ 58% / 71%).

- [ ] **Step 6: Commit**

```bash
git add OpenPulse/Views
git commit -m "feat(antigravity): show grouped 5h/weekly windows + tier badge in UI"
```

---

# Phase 2 — OAuth loopback spike (gating, mostly manual)

Proves the quotio Google client permits an interactive loopback authorize before we build the login UI (design R1).

### Task 6: Extract shared OAuth loopback helpers

**Files:**
- Create: `OpenPulse/Data/Services/OAuthLoopbackSupport.swift`
- Modify: `OpenPulse/Data/Services/CodexAccountService.swift` (remove the extracted private types, import nothing new — same target)

**Interfaces:**
- Produces (moved verbatim from `CodexAccountService.swift`, made non-private / file-internal):
  - `final class SimpleHTTPServer` (its initializer + `start()`/`stop()` + `HTTPRequest`/`HTTPResponse` helpers)
  - `final class OAuthCallbackBox<T>` (`wait(timeoutSeconds:)`, `succeed`, `fail`)
  - `enum OAuthPKCE { static func randomBase64URL(byteCount:) -> String; static func sha256Base64URL(_:) -> String }`

- [ ] **Step 1: Move the types**

Cut `SimpleHTTPServer`, `OAuthCallbackBox`, and the `randomBase64URL`/`sha256Base64URL` statics out of `CodexAccountService.swift` into the new file. Wrap the two crypto statics in `enum OAuthPKCE`. Update `CodexAccountService`'s two call sites `Self.randomBase64URL(...)`/`Self.sha256Base64URL(...)` → `OAuthPKCE.randomBase64URL(...)`/`OAuthPKCE.sha256Base64URL(...)`.

- [ ] **Step 2: Build (Codex flow must still compile)**

Run: `xcodebuild build -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug 2>&1 | tail -8`
Expected: `BUILD SUCCEEDED`. (No behavior change — pure move. This is the regression check.)

- [ ] **Step 3: Commit**

```bash
git add OpenPulse/Data/Services/OAuthLoopbackSupport.swift OpenPulse/Data/Services/CodexAccountService.swift
git commit -m "refactor: extract shared OAuth loopback helpers"
```

---

### Task 7: Spike — interactive Google authorize with the quotio client

**Files:** none committed (throwaway). Use a temporary standalone Swift script or a hidden debug button.

- [ ] **Step 1: Build the authorize URL and open it**

Construct: `https://accounts.google.com/o/oauth2/v2/auth?response_type=code&client_id=<quotio id>&redirect_uri=http://127.0.0.1:<port>&scope=openid%20email%20profile%20https://www.googleapis.com/auth/cloud-platform&code_challenge=<S256>&code_challenge_method=S256&state=<rand>&access_type=offline&prompt=consent`. Start an `NWListener` on `<port>` (reuse `SimpleHTTPServer`), open the URL with `NSWorkspace.shared.open`, log the captured `code`.

- [ ] **Step 2: Exchange code → tokens**

POST to `https://oauth2.googleapis.com/token` with `grant_type=authorization_code`, `code`, `redirect_uri`, `client_id`, `client_secret`, `code_verifier`. Confirm the response contains `refresh_token` and `access_token`.

- [ ] **Step 3: Confirm the token works**

Call `loadCodeAssist` + `retrieveUserQuotaSummary` with the new access token. Expect a 200 with groups.

- [ ] **Step 4: Decision gate**

- **PASS** (loopback + scope accepted, refresh_token returned, quota fetch works) → proceed to Phase 3 as written.
- **FAIL** (invalid_client / redirect_uri_mismatch / access_denied for scope) → STOP. Update the design R1 fallback: discover Antigravity.app's own OAuth client id (Info.plist / binary strings) à la CodexBar's `ANTIGRAVITY_OAUTH_CLIENT_ID`, then revise Phase 3 constants. Report findings to the user before continuing.

No commit (spike is throwaway). Record the outcome in the plan checkbox notes.

---

# Phase 3 — In-app login + credential unification

Only after Task 7 PASSES.

### Task 8: `AntigravityAccountService` (OAuth + store + Keychain)

**Files:**
- Create: `OpenPulse/Data/Services/AntigravityAccountService.swift`
- Modify: `OpenPulse/Data/Services/KeychainService.swift` (add key helper)

**Interfaces:**
- Consumes: `SimpleHTTPServer`, `OAuthCallbackBox`, `OAuthPKCE` (Task 6); `AntigravityParser` OAuth client constants (expose them — see Step 1).
- Produces:
  - `struct AGStoredAccount: Codable, Sendable { let email: String; var label: String; var tierId: String?; var tierName: String?; let addedAt: Date; var updatedAt: Date }`
  - `actor AntigravityAccountService { func addAccountViaOAuth(timeoutSeconds: TimeInterval = 600) async throws -> AGStoredAccount; func listAccounts() async -> [AGStoredAccount]; func deleteAccount(email: String) async; func refreshToken(for email: String) async -> String? }`
  - `static func keychainKey(email: String) -> String` → `"antigravity_refresh_\(email)"`

- [ ] **Step 1: Expose the OAuth client from one place**

In `AntigravityParser.swift`, change `oauthClientId`/`oauthClientSecret`/`tokenEndpoint` from `private` instance lets to a shared `enum AntigravityOAuth { static let clientId = ...; static let clientSecret = ...; static let tokenEndpoint = ...; static let scopes = "openid email profile https://www.googleapis.com/auth/cloud-platform" }` at file scope. Update `AntigravityParser` references. This removes the "two hardcoded copies" risk (Global Constraints).

- [ ] **Step 2: Write the account service**

```swift
import Foundation
import AppKit
import CryptoKit

actor AntigravityAccountService {
    private let fileManager: FileManager
    private let session: URLSession
    private let supportDir: URL
    private let storeURL: URL

    init(fileManager: FileManager = .default, session: URLSession = .shared) {
        self.fileManager = fileManager
        self.session = session
        supportDir = URL.homeDirectory.appending(path: ".openpulse")
        storeURL = supportDir.appending(path: "antigravity-accounts.json")
    }

    static func keychainKey(email: String) -> String { "antigravity_refresh_\(email)" }

    func listAccounts() async -> [AGStoredAccount] { loadStore() }

    func deleteAccount(email: String) async {
        var store = loadStore()
        store.removeAll { $0.email == email }
        saveStore(store)
        KeychainService.delete(key: Self.keychainKey(email: email))
    }

    func refreshToken(for email: String) async -> String? {
        try? KeychainService.retrieve(key: Self.keychainKey(email: email))
    }

    func addAccountViaOAuth(timeoutSeconds: TimeInterval = 600) async throws -> AGStoredAccount {
        let verifier = OAuthPKCE.randomBase64URL(byteCount: 32)
        let challenge = OAuthPKCE.sha256Base64URL(verifier)
        let state = OAuthPKCE.randomBase64URL(byteCount: 32)
        let callback = OAuthCallbackBox<GoogleTokens>()
        let (server, port) = try makeCallbackServer(callback: callback, verifier: verifier, state: state)
        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let authorizeURL = makeAuthorizeURL(redirectURI: redirectURI, challenge: challenge, state: state)

        try await server.start()
        defer { server.stop() }
        guard NSWorkspace.shared.open(authorizeURL) else { throw ServiceError.openFailed }

        let tokens = try await callback.wait(timeoutSeconds: timeoutSeconds)
        let email = try Self.email(fromIDToken: tokens.idToken)
        guard let refresh = tokens.refreshToken, !refresh.isEmpty else { throw ServiceError.noRefreshToken }
        try KeychainService.store(key: Self.keychainKey(email: email), value: refresh)

        var store = loadStore()
        store.removeAll { $0.email == email }
        let account = AGStoredAccount(email: email, label: email, tierId: nil, tierName: nil,
                                      addedAt: Date(), updatedAt: Date())
        store.append(account)
        saveStore(store)
        return account
    }

    // MARK: callback server (mirrors CodexAccountService.makeCallbackServer)
    private func makeCallbackServer(callback: OAuthCallbackBox<GoogleTokens>, verifier: String, state: String)
        throws -> (SimpleHTTPServer, UInt16) {
        var port: UInt16 = 8123
        let maxPort: UInt16 = 8135
        var lastError: Error?
        while port <= maxPort {
            do {
                let redirectURI = "http://127.0.0.1:\(port)/callback"
                let server = try SimpleHTTPServer(port: port) { [session] request in
                    let params = Dictionary(uniqueKeysWithValues: request.queryItems.compactMap { i in i.value.map { (i.name, $0) } })
                    guard request.path == "/callback" else { return .text(statusCode: 404, text: "Not Found") }
                    guard params["state"] == state else { callback.fail(ServiceError.stateMismatch); return .text(statusCode: 400, text: "State mismatch") }
                    guard let code = params["code"], !code.isEmpty else {
                        let msg = params["error_description"] ?? params["error"] ?? "Missing code"
                        callback.fail(ServiceError.callbackFailed(msg)); return .text(statusCode: 400, text: msg)
                    }
                    do {
                        let tokens = try await Self.exchangeCode(session: session, code: code, verifier: verifier, redirectURI: redirectURI)
                        callback.succeed(tokens)
                        return .html(statusCode: 200, body: "<html><body><h3>OpenPulse 登录成功，可以回到应用。</h3></body></html>")
                    } catch { callback.fail(error); return .text(statusCode: 500, text: error.localizedDescription) }
                }
                return (server, port)
            } catch { lastError = error; port += 1 }
        }
        throw lastError ?? ServiceError.callbackFailed("无法启动本地回调服务。")
    }

    private func makeAuthorizeURL(redirectURI: String, challenge: String, state: String) -> URL {
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: AntigravityOAuth.clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: AntigravityOAuth.scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        return c.url!
    }

    private static func exchangeCode(session: URLSession, code: String, verifier: String, redirectURI: String) async throws -> GoogleTokens {
        var req = URLRequest(url: URL(string: AntigravityOAuth.tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": AntigravityOAuth.clientId, "client_secret": AntigravityOAuth.clientSecret,
            "code_verifier": verifier,
        ]
        req.httpBody = form.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $1)" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.callbackFailed("token exchange HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0): \(String(decoding: data, as: UTF8.self).prefix(160))")
        }
        return try JSONDecoder().decode(GoogleTokens.self, from: data)
    }

    static func email(fromIDToken idToken: String) throws -> String {
        let parts = idToken.components(separatedBy: ".")
        guard parts.count >= 2 else { throw ServiceError.callbackFailed("bad id_token") }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String else { throw ServiceError.callbackFailed("no email in id_token") }
        return email
    }

    private func loadStore() -> [AGStoredAccount] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        return (try? JSONDecoder().decode([AGStoredAccount].self, from: data)) ?? []
    }
    private func saveStore(_ store: [AGStoredAccount]) {
        try? fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: storeURL) }
    }

    struct GoogleTokens: Decodable {
        let accessToken: String
        let refreshToken: String?
        let idToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case refreshToken = "refresh_token"; case idToken = "id_token" }
    }
    enum ServiceError: LocalizedError {
        case openFailed, noRefreshToken, stateMismatch, callbackFailed(String)
        var errorDescription: String? {
            switch self {
            case .openFailed: "无法打开浏览器完成 Google 登录。"
            case .noRefreshToken: "Google 未返回 refresh_token（请确认已授予离线访问）。"
            case .stateMismatch: "登录状态校验失败。"
            case .callbackFailed(let m): m
            }
        }
    }
}

struct AGStoredAccount: Codable, Sendable {
    let email: String
    var label: String
    var tierId: String?
    var tierName: String?
    let addedAt: Date
    var updatedAt: Date
}
```

Add `CharacterSet.urlQueryValueAllowed` if not present (a small helper) or reuse the existing `percentEncode` from CodexAccountService by moving it into `OAuthLoopbackSupport.swift` in Task 6 (preferred — add `OAuthPKCE.formEncode(_:)`). If moved, replace the body-building line with `OAuthPKCE.formEncode(form)`.

- [ ] **Step 2: Build**

Run: `xcodebuild build -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug 2>&1 | tail -8`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Manual OAuth verification**

Run the app, trigger `addAccountViaOAuth()` (temporarily from a debug button or the Task 9 UI), complete a real Google login. Expect: Keychain has `antigravity_refresh_<email>`, `~/.openpulse/antigravity-accounts.json` lists the account.

- [ ] **Step 4: Commit**

```bash
git add OpenPulse/Data/Services/AntigravityAccountService.swift OpenPulse/Data/Services/KeychainService.swift OpenPulse/Data/Parsers/AntigravityParser.swift
git commit -m "feat(antigravity): in-app Google OAuth login + account store"
```

---

### Task 9: Unify credentials (scan + OAuth) in the parser

**Files:**
- Modify: `OpenPulse/Data/Parsers/AntigravityParser.swift` (`authFilesByEmail` → `credentials()`, `fetchAllAccountQuotas`, `fetchAccountQuota`, `fetchQuota(forAccountEmail:)`)
- Test: `OpenPulseTests/AntigravityCredentialMergeTests.swift` (create)

**Interfaces:**
- Consumes: `AntigravityAccountService.listAccounts()`, `.refreshToken(for:)` (Task 8)
- Produces:
  - `enum AGCredentialSource: Sendable { case cliProxy(URL); case openPulse }`
  - `struct AGCredential: Sendable { let email: String; let source: AGCredentialSource }`
  - `static func mergeCredentials(cliProxy: [AGCredential], openPulse: [AGCredential]) -> [AGCredential]` (pure, testable — openPulse wins per email)

- [ ] **Step 1: Write the failing merge test**

```swift
import Testing
@testable import OpenPulse
import Foundation

struct AntigravityCredentialMergeTests {
    @Test func openPulseWinsOnDuplicateEmail() {
        let url = URL(fileURLWithPath: "/tmp/antigravity-a_gmail_com.json")
        let cli = [AGCredential(email: "a@gmail.com", source: .cliProxy(url)),
                   AGCredential(email: "b@gmail.com", source: .cliProxy(url))]
        let op  = [AGCredential(email: "a@gmail.com", source: .openPulse)]
        let merged = AntigravityParser.mergeCredentials(cliProxy: cli, openPulse: op)
        #expect(merged.count == 2)
        let a = merged.first { $0.email == "a@gmail.com" }
        if case .openPulse = a?.source {} else { Issue.record("expected openPulse source to win") }
    }
}
```

- [ ] **Step 2: Run — expect fail (types/func missing)**

Run: `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulse -destination 'platform=macOS' -only-testing:OpenPulseTests/AntigravityCredentialMergeTests 2>&1 | tail -12`
Expected: FAIL (compile).

- [ ] **Step 3: Implement credentials + merge**

Add to `AntigravityParser`:
```swift
enum AGCredentialSource: Sendable { case cliProxy(URL); case openPulse }
struct AGCredential: Sendable { let email: String; let source: AGCredentialSource }

static func mergeCredentials(cliProxy: [AGCredential], openPulse: [AGCredential]) -> [AGCredential] {
    var byEmail: [String: AGCredential] = [:]
    for c in cliProxy { byEmail[c.email] = c }
    for c in openPulse { byEmail[c.email] = c }   // openPulse overwrites
    return Array(byEmail.values).sorted { $0.email < $1.email }
}
```
Give `AntigravityParser` an optional `accountService: AntigravityAccountService?` (injected; default `AntigravityAccountService()`). Add:
```swift
private func credentials() async -> [AGCredential] {
    let cli = ((try? FileManager.default.contentsOfDirectory(at: proxyDir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasPrefix("antigravity-") && $0.pathExtension == "json" }
        .map { AGCredential(email: emailFromFilename($0.deletingPathExtension().lastPathComponent), source: .cliProxy($0)) }
    let op = await (accountService?.listAccounts() ?? []).map { AGCredential(email: $0.email, source: .openPulse) }
    return Self.mergeCredentials(cliProxy: cli, openPulse: op)
}
```
Refactor `fetchAccountQuota` to take an `AGCredential`: for `.cliProxy(url)` use the existing file-read/refresh path; for `.openPulse` read the refresh token from Keychain via `accountService?.refreshToken(for:)`, mint an access token with `refreshAccessToken`, then run `fetchProjectAndTier`/`fetchQuotaSummary`. Update `fetchAllAccountQuotas` to iterate `await credentials()`. Update `fetchQuota(forAccountEmail:)` to find the matching credential.

- [ ] **Step 4: Run tests to verify pass**

Run: `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulse -destination 'platform=macOS' -only-testing:OpenPulseTests/AntigravityCredentialMergeTests 2>&1 | tail -12`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add OpenPulse/Data/Parsers/AntigravityParser.swift OpenPulseTests/AntigravityCredentialMergeTests.swift
git commit -m "feat(antigravity): unify cli-proxy scan with in-app OAuth accounts"
```

---

### Task 10: Add-account UI + account list

**Files:**
- Modify: `OpenPulse/Views/Providers/ProviderComponents.swift` (Antigravity provider content: add "添加 Antigravity 账号" button + delete)
- Modify: `OpenPulse/App/AppStore.swift` or `DataSyncService` (hold an `AntigravityAccountService` reference so views can call it and trigger a resync after login/delete)

**Interfaces:**
- Consumes: `AntigravityAccountService.addAccountViaOAuth()`, `listAccounts()`, `deleteAccount(email:)`

- [ ] **Step 1: Expose the service**

Add `let antigravityAccountService = AntigravityAccountService()` to the type that owns services (mirror how `CodexAccountService` is exposed — grep `CodexAccountService(` to find the owner and follow that exact pattern). Ensure the parser used by `DataSyncService` is constructed with the same `accountService` instance so login is visible to quota refresh.

- [ ] **Step 2: Add the button + list**

In the Antigravity provider content view, above the account cards:
```swift
Button {
    Task {
        do { _ = try await appStore.antigravityAccountService.addAccountViaOAuth()
             await appStore.syncService?.refreshTool(.antigravity) }
        catch { AppLogger.shared.warning("[antigravity] login failed: \(error.localizedDescription)") }
    }
} label: { Label("添加 Antigravity 账号", systemImage: "person.badge.plus") }
.buttonStyle(.borderedProminent)
```
Add a per-account delete affordance on OpenPulse-owned accounts (a trash button that calls `deleteAccount(email:)` then triggers resync). Use the exact resync method name that exists (grep `func refreshTool` / `func refresh` in `DataSyncService`; if none matches, use the existing full-refresh entry point).

- [ ] **Step 3: Build + run + verify end-to-end**

Run app → click 添加账号 → complete Google login → account appears with tier badge + 5h/weekly windows, no per-model rows. Delete it → disappears; Keychain key removed.

- [ ] **Step 4: Commit**

```bash
git add OpenPulse/Views OpenPulse/App
git commit -m "feat(antigravity): in-app add/remove account UI"
```

---

## Self-Review

**Spec coverage:**
- Grouped 5h/weekly windows → Tasks 1–5. ✔
- Tier free/paid recognition + badge → Task 1 (`AGTier`), Task 4 (`AGTierBadge`), Tasks 5/10 (display). ✔
- In-app OAuth login → Tasks 6–8. ✔
- OpenPulse-owned storage + Keychain → Task 8. ✔
- Unify scan + login → Task 9. ✔
- Add/remove account UI → Task 10. ✔
- OAuth feasibility risk (R1) → Task 7 gate. ✔
- Retire per-model rows (approved) → Task 5. ✔
- Non-goal (no local language-server probing) → honored; remote OAuth only. ✔

**Type consistency:** `AGWindow`/`AGQuotaGroup`/`AGTier`/`AGAccountQuota` defined in Task 1, consumed unchanged in Tasks 2–5, 9. `AGCredential`/`AGCredentialSource` Task 9. `AGStoredAccount`/`GoogleTokens` Task 8. `SimpleHTTPServer`/`OAuthCallbackBox`/`OAuthPKCE` moved in Task 6, consumed in Task 8. `AntigravityOAuth` constants introduced Task 8 Step 1, consumed Task 8. `decodeQuotaGroups`/`decodeTier` Task 1, consumed Task 2. Aggregate uses `geminiRemainingFraction`/`geminiEarliestReset` consistently (Tasks 1/2/3).

**Placeholder scan:** No TBD/TODO in steps. The one open unknown (exact paid tier id — design R2) is handled by the `isPaid = id != "free-tier"` rule, no placeholder. Two "grep to confirm the exact existing method/owner name" instructions (Task 5/10) are deliberate: they adapt to names this plan can't see without guessing; each names the grep and the fallback.

**Scope:** Single feature, three phases, one plan. Phase 1 is independently shippable; Phases 2–3 gated on the spike.
