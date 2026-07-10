# Antigravity In-App Login + Tier-Aware 5h/Weekly Quota — Design

Date: 2026-07-10
Status: Approved (design), pending spec review

## Problem

Today OpenPulse's Antigravity support:

- Only **scans local auth files** at `~/.cli-proxy-api/antigravity-*.json`. There is
  **no in-app way to log in / authorize** a Google account.
- Calls `retrieveUserQuota`, which returns a **flat per-model list** with a single
  rolling window (`tokenType: "WTUS"`, one `resetTime`, one `remainingFraction`). It
  throws away tier and dual-window information.
- Does **not distinguish free vs paid** (Google AI Pro) accounts.

Verified live against `edcfanyu@gmail.com` (2026-07-10): the richer
`retrieveUserQuotaSummary` endpoint returns exactly the structure we want, and
`loadCodeAssist` returns the account tier.

## Goals

1. Read Antigravity quota as **grouped, dual-window** data: for each model group
   ("Gemini Models", "Claude and GPT models"), a **5-hour** limit and a **weekly**
   limit — each with remaining %, reset time, and human-readable description.
2. **Recognize account tier** (free vs Google AI Pro) and show a tier badge.
3. Add an **in-app OAuth login** so a user can authorize a Google account from within
   OpenPulse, not only via an external CLI writing to `~/.cli-proxy-api`.
4. Persist OpenPulse-authorized accounts in **OpenPulse-owned storage + Keychain**,
   and **unify** them with the existing local-scan path.

## Non-Goals

- No local Antigravity 2.0 app / `agy` CLI / IDE language-server probing (CodexBar's
  higher-priority sources). Google OAuth remote is the single quota source here.
- No smart account auto-switching (Codex has this; not requested for Antigravity).
- No change to Antigravity session/task parsing (`brain/` markdown) — unchanged.

## Reference

Modeled on `steipete/CodexBar` (`docs/antigravity.md`) and OpenPulse's own
`CodexAccountService`, which already implements the exact in-app OAuth loopback flow
we mirror (PKCE S256, `NWListener` loopback callback, token exchange, multi-account
store).

---

## Confirmed API shapes (live, 2026-07-10)

### `retrieveUserQuotaSummary` (POST, Bearer, optional `{"project": <id>}`)

```json
{
  "groups": [
    { "displayName": "Gemini Models",
      "buckets": [
        { "bucketId": "gemini-weekly", "window": "weekly",
          "resetTime": "2026-07-16T02:49:09Z", "remainingFraction": 0.71,
          "description": "You have used some of your weekly limit, it will fully refresh in 6 days." },
        { "bucketId": "gemini-5h", "window": "5h",
          "resetTime": "2026-07-10T06:42:14Z", "remainingFraction": 0.58,
          "description": "...5-hour limit, it will fully refresh in 4 hours, 1 minute." }
      ] },
    { "displayName": "Claude and GPT models",
      "buckets": [ { "bucketId": "3p-weekly", "window": "weekly", ... },
                   { "bucketId": "3p-5h", "window": "5h", ... } ] }
  ]
}
```

### `loadCodeAssist` → tier

```json
{ "currentTier": { "id": "free-tier", "name": "Antigravity",
                   "upgradeSubscriptionText": "Upgrade ... with Google AI Pro" },
  "cloudaicompanionProject": "protean-mesh-xggp0" }
```

`isPaid = (currentTier.id != "free-tier")`. Paid AI Pro accounts surface a different
`currentTier.id`/`name` (exact paid id TBD — read from a real Pro account during impl;
until then treat any non-`free-tier` id as paid).

---

## Component design

### 1. Quota data model (`AntigravityParser.swift`)

Replace `AGModelQuota` per-model display with grouped windows. **Retire the per-model
list** — grouped windows fully supersede it (user-approved).

```swift
struct AGWindow: Sendable {
    enum Kind: Sendable { case fiveHour, weekly }
    let kind: Kind
    let remainingFraction: Double?   // clamped 0...1
    let resetTime: Date?             // validated: future only, else nil
    let description: String?
}

struct AGQuotaGroup: Sendable, Identifiable {
    let id: String                   // bucket prefix, e.g. "gemini" / "3p"
    let displayName: String          // "Gemini Models" / "Claude and GPT models"
    let fiveHour: AGWindow?
    let weekly: AGWindow?
}

struct AGTier: Sendable {
    let id: String                   // "free-tier" / paid id
    let name: String
    var isPaid: Bool { id != "free-tier" }
    var badgeLabel: String { isPaid ? "Google AI Pro" : "Free" }
}

struct AGAccountQuota: Sendable, Identifiable {
    let email: String
    let tier: AGTier?
    let groups: [AGQuotaGroup]
    var id: String { email }
}
```

Decoding: new file-private `AGQuotaSummaryResponse` for `retrieveUserQuotaSummary`;
extend `AGSubscriptionInfo` (loadCodeAssist) to decode `currentTier { id, name }`.
`window` string `"5h"`→`.fiveHour`, `"weekly"`→`.weekly`.

Parser flow per account becomes: `loadCodeAssist` (projectId + tier) →
`retrieveUserQuotaSummary` (groups). The old `fetchAvailableModels` +
`retrieveUserQuota` + merge machinery is **removed** (dead once per-model UI is gone).

### 2. Credential source abstraction (unify scan + login)

Introduce an internal credential provider so `fetchAccountQuota` runs uniformly over
both sources:

```swift
struct AGCredential: Sendable {
    enum Source: Sendable { case cliProxy(URL), openPulse }
    let email: String
    let source: Source
    // resolved lazily: refresh/access token from file (cliProxy) or Keychain (openPulse)
}
```

`AntigravityParser.credentials()` merges:
- (a) existing `~/.cli-proxy-api/antigravity-*.json` scan (unchanged reader), and
- (b) OpenPulse-owned accounts (from `AntigravityAccountService`).

De-dupe by email; **OpenPulse-owned wins** (fresher, app-managed). Token refresh
write-back targets the correct store depending on source (file vs Keychain).

### 3. In-app OAuth login — `AntigravityAccountService` (new actor)

Mirrors `CodexAccountService` structure:

- **Authorize:** `https://accounts.google.com/o/oauth2/v2/auth`, PKCE S256, loopback
  `redirect_uri = http://127.0.0.1:<port>`, `client_id`/`client_secret` = the quotio
  client already in `AntigravityParser`, scopes
  `openid email profile https://www.googleapis.com/auth/cloud-platform`.
- **Callback server:** `NWListener` on an ephemeral loopback port (reuse Codex's
  `makeCallbackServer` pattern), capture `code`, return a success HTML page.
- **Exchange:** `code` → tokens at `https://oauth2.googleapis.com/token` (already used
  for refresh — proven).
- **Persist:** metadata → `~/Library/Application Support/OpenPulse/antigravity-accounts.json`
  (`{ email, tier, label, addedAt }[]`); **refresh token → Keychain**, key
  `antigravity_refresh_<email>` (add to `KeychainService.Keys`).
- **API:** `addAccountViaOAuth()`, `listAccounts()`, `deleteAccount(email:)`.

Email derived from the id_token (JWT `email` claim), matching Codex's approach.

### 4. UI

- **Account card** (`ProviderComponents` / `MenuBarView` / `QuotaView`): tier badge
  next to email; for each group, a 5h bar and a weekly bar (remaining %, reset
  countdown, `description` as tooltip). Reuse existing quota-bar components. Remove
  per-model rows (`AGAccountCard` model iteration, `AGModelQuota` row views).
- **Add-account entry:** button in Antigravity provider view + Settings → calls
  `addAccountViaOAuth()`; shows the account list with per-account delete.
- **MenuBar aggregate:** min remaining fraction across all windows of all accounts
  (adapt existing `antigravityAggregateQuota`).

### 5. DataSyncService

`latestAntigravityAccounts: [AGAccountQuota]` unchanged in spirit; refresh path now
also enumerates OpenPulse-owned accounts. Per-account refresh
(`refreshingAntigravityAccountEmails`) unchanged.

---

## Testing

- `AntigravityParserTests`: decode a `retrieveUserQuotaSummary` fixture → 2 groups ×
  2 windows with correct fractions/reset/description; `window` mapping; clamp.
- Tier decode: `loadCodeAssist` fixture free (`free-tier`) vs paid → `isPaid` + badge.
- Credential merge: cliProxy + openPulse same email → single entry, openPulse wins.
- OAuth flow (browser + network) is **not** unit-tested; covered by the spike +
  manual verification (build & run, real login).

## Implementation sequencing

1. **Quota-model upgrade first** (§1, §4 display, §5, tests) — no dependency on login,
   delivers 5h/weekly + tier immediately for already-scanned accounts.
2. **OAuth spike** (§3 risk) — prove loopback authorize works with the quotio Google
   client and the `cloud-platform` scope via one manual login. Gate before building
   multi-account UI.
3. **In-app login + credential unification** (§2, §3, §4 add-account UI).

## Risks

- **R1 — OAuth client loopback support (gating for §3).** The quotio Google client id
  is proven for *refresh*, but the initial browser *authorize* with loopback redirect
  and `cloud-platform` scope is unverified. Mitigation: spike (step 2) before writing
  the flow into the plan. Fallback: discover Antigravity.app's own OAuth client id
  (CodexBar's `ANTIGRAVITY_OAUTH_CLIENT_ID` approach).
- **R2 — Paid tier id unknown.** Only a `free-tier` account was observed. Treat any
  non-`free-tier` id as paid; refine `badgeLabel` once a real Pro account is seen.
- **R3 — Display blast radius.** Retiring per-model rows touches MenuBarView,
  QuotaView, ProviderComponents. Accepted (user-approved); covered by build & run.
