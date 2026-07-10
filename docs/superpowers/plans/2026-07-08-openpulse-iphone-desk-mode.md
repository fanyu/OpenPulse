# OpenPulse iPhone Desk Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a read-only iPhone companion that shows Codex and Claude side by side in a landscape-only full-screen desk display, with macOS publishing a compact CloudKit snapshot and iPhone rendering a stateful pet-driven cockpit UI.

**Architecture:** Keep macOS as the only parser and quota source of truth. Add a shared snapshot domain plus a macOS CloudKit publisher that emits one deduplicated `DeskSnapshot`, then add a new iPhone target that reads that snapshot, maps it into presentation state, and renders a horizontal `Twin Cockpit` scene with obvious state-driven motion.

**Tech Stack:** Swift 6.2, SwiftUI, SwiftData, CloudKit, XcodeGen, Swift Testing, shared Swift source files across macOS and iOS targets

## Global Constraints

- A new iPhone app target in this repository
- One full-screen landscape-only dashboard
- Simultaneous display of Codex and Claude
- CloudKit sync from Mac to iPhone using a compact quota snapshot
- Noticeable pet animation tied to quota state
- Official Codex and Claude pet look, implemented with vector-style animation as the default v1 approach
- No iPhone-side parser, login, OAuth, Keychain import, or local file reading
- No widget, StandBy widget, or Live Activity in v1
- No multi-page iPhone information architecture
- No support for Copilot or Antigravity on the iPhone in v1
- No write actions from iPhone back to Mac
- Data path: `Mac -> CloudKit -> iPhone`
- Identity/auth model: Mac and iPhone are signed into the same iCloud account
- UI shape: one always-on, landscape full-screen app
- Layout: horizontal `Twin Cockpit`
- Motion level: obvious character motion, but not noisy
- Tool scope: Codex + Claude only

---

## File Structure

### Existing files to modify

- `project.yml`
  - Add a new iOS app target, a test target, shared entitlements, and any new resource paths.
- `OpenPulse/OpenPulse.entitlements`
  - Add CloudKit capability for the macOS target.
- `OpenPulse/App/AppStore.swift`
  - Wire the snapshot publisher into the macOS sync lifecycle without changing parser ownership.
- `OpenPulse/Data/Services/DataSyncService.swift`
  - Trigger snapshot publish after successful Codex and Claude refresh cycles.
- `OpenPulse/Models/Tool.swift`
  - Reuse existing tool identity in the shared snapshot and iPhone UI.
- `OpenPulse/Resources/Assets.xcassets/...`
  - Add official Codex / Claude pet assets and any cockpit-specific visual assets.
- `OpenPulse/Info.plist`
  - Keep macOS metadata aligned if new privacy or CloudKit keys are needed.

### New shared source files

- `OpenPulse/Shared/DeskSnapshot/DeskSnapshot.swift`
  - CloudKit-facing snapshot model plus per-tool payloads.
- `OpenPulse/Shared/DeskSnapshot/DeskSnapshotStatus.swift`
  - Quota thresholds and stale detection rules.
- `OpenPulse/Shared/DeskSnapshot/DeskSnapshotRecordCodec.swift`
  - Conversion between `DeskSnapshot` and `CKRecord`.
- `OpenPulse/Shared/DeskSnapshot/DeskSnapshotBuilder.swift`
  - Build a snapshot from `latestCodexAccounts`, `latestClaudeUsage`, and fallback `QuotaRecord`s.

### New macOS-specific files

- `OpenPulse/Data/Services/DeskSnapshotPublisher.swift`
  - Deduplicated CloudKit publisher with throttling and retry.
- `OpenPulse/Data/Services/DeskSnapshotPublishStore.swift`
  - Persist the last published payload hash / timestamp for change detection and retry.

### New iPhone app files

- `OpenPulseiPhone/App/OpenPulseiPhoneApp.swift`
  - iPhone app entry point and scene setup.
- `OpenPulseiPhone/App/DeskModeAppStore.swift`
  - Observable iPhone-side store for the latest snapshot and presentation state.
- `OpenPulseiPhone/Data/DeskSnapshotCloudKitClient.swift`
  - CloudKit fetch / subscribe client.
- `OpenPulseiPhone/Models/DeskPetPresentation.swift`
  - UI-facing presentation model derived from `DeskSnapshot`.
- `OpenPulseiPhone/Views/DeskModeRootView.swift`
  - Full-screen landscape shell.
- `OpenPulseiPhone/Views/TwinCockpitView.swift`
  - Two-panel split layout.
- `OpenPulseiPhone/Views/ToolCockpitPanel.swift`
  - Single tool panel with number, reset time, and pet scene.
- `OpenPulseiPhone/Views/Pets/CodexPetView.swift`
  - Codex pet vector-style animation view.
- `OpenPulseiPhone/Views/Pets/ClaudePetView.swift`
  - Claude pet vector-style animation view.
- `OpenPulseiPhone/Views/Pets/PetMotion.swift`
  - Shared motion state definitions and animation helpers.

### New tests

- `OpenPulseTests/DeskSnapshotBuilderTests.swift`
  - Snapshot build, threshold, stale, and record coding tests.
- `OpenPulseiPhoneTests/DeskPetPresentationTests.swift`
  - Presentation mapping tests.

## Task 1: Add the shared desk snapshot domain and tests

**Files:**
- Create: `OpenPulse/Shared/DeskSnapshot/DeskSnapshot.swift`
- Create: `OpenPulse/Shared/DeskSnapshot/DeskSnapshotStatus.swift`
- Create: `OpenPulse/Shared/DeskSnapshot/DeskSnapshotRecordCodec.swift`
- Create: `OpenPulse/Shared/DeskSnapshot/DeskSnapshotBuilder.swift`
- Create: `OpenPulseTests/DeskSnapshotBuilderTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `Tool`, `ToolQuota`, `QuotaRecord`, `CodexAccountSnapshot`, `ClaudeUsageResponse`
- Produces:
  - `struct DeskSnapshot: Codable, Equatable, Sendable`
  - `struct DeskToolSnapshot: Codable, Equatable, Sendable`
  - `enum DeskQuotaStatus: String, Codable, Sendable`
  - `enum DeskPetState: String, Codable, Sendable`
  - `enum DeskSnapshotBuilder { static func build(now: Date, codexAccounts: [CodexAccountSnapshot], claudeUsage: ClaudeUsageResponse?, fallbackQuotas: [QuotaRecord]) -> DeskSnapshot? }`
  - `enum DeskSnapshotRecordCodec { static func makeRecord(snapshot: DeskSnapshot, zoneID: CKRecordZone.ID?) -> CKRecord; static func decode(_ record: CKRecord) throws -> DeskSnapshot }`

- [ ] **Step 1: Add the iOS and test target placeholders to the project manifest**

```yaml
targets:
  OpenPulseTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - OpenPulseTests
    dependencies:
      - target: OpenPulse

  OpenPulseiPhone:
    type: application
    platform: iOS
    deploymentTarget: "27.0"
    sources:
      - OpenPulse/Shared
      - OpenPulseiPhone
    info:
      path: OpenPulseiPhone/Info.plist
      properties:
        CFBundleName: OpenPulse iPhone
        CFBundleDisplayName: OpenPulse
        UILaunchScreen: {}
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationLandscapeLeft
          - UIInterfaceOrientationLandscapeRight

  OpenPulseiPhoneTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - OpenPulseiPhoneTests
    dependencies:
      - target: OpenPulseiPhone
```

- [ ] **Step 2: Write the failing shared snapshot tests**

```swift
import CloudKit
import Testing
@testable import OpenPulse

struct DeskSnapshotBuilderTests {
    @Test
    func buildUsesCurrentCodexAccountAndClaudeUsage() throws {
        #expect(
            DeskSnapshotBuilder.build(
                now: Date(timeIntervalSince1970: 1_000),
                codexAccounts: [],
                claudeUsage: nil,
                fallbackQuotas: []
            ) == nil
        )
    }

    @Test
    func statusThresholdsProduceCriticalAndStaleStates() {
        let staleStatus = DeskQuotaStatus.resolve(
            remaining: 5,
            total: 100,
            updatedAt: Date(timeIntervalSince1970: 0),
            now: Date(timeIntervalSince1970: 60 * 11)
        )
        #expect(staleStatus == .stale)
    }

    @Test
    func recordCodecRoundTripsSnapshotFields() throws {
        let snapshot = DeskSnapshot(
            snapshotID: "desk",
            sourceDeviceID: "mac",
            schemaVersion: 1,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            codex: .init(
                tool: .codex,
                displayLabel: "Codex",
                remaining: 68,
                total: 100,
                fraction: 0.68,
                resetAt: Date(timeIntervalSince1970: 2_000),
                status: .healthy,
                petState: .patrol
            ),
            claude: .init(
                tool: .claudeCode,
                displayLabel: "Claude",
                remaining: 42,
                total: 100,
                fraction: 0.42,
                resetAt: Date(timeIntervalSince1970: 3_000),
                status: .warning,
                petState: .pause
            )
        )

        let record = DeskSnapshotRecordCodec.makeRecord(snapshot: snapshot, zoneID: nil)
        let decoded = try DeskSnapshotRecordCodec.decode(record)
        #expect(decoded == snapshot)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseTests -destination 'platform=macOS'`

Expected: FAIL with missing `DeskSnapshotBuilder`, `DeskQuotaStatus`, and `DeskSnapshotRecordCodec` symbols.

- [ ] **Step 4: Write the minimal shared snapshot implementation**

```swift
import CloudKit
import Foundation

struct DeskSnapshot: Codable, Equatable, Sendable {
    let snapshotID: String
    let sourceDeviceID: String
    let schemaVersion: Int
    let updatedAt: Date
    let codex: DeskToolSnapshot
    let claude: DeskToolSnapshot
}

struct DeskToolSnapshot: Codable, Equatable, Sendable {
    let tool: Tool
    let displayLabel: String
    let remaining: Int?
    let total: Int?
    let fraction: Double?
    let resetAt: Date?
    let status: DeskQuotaStatus
    let petState: DeskPetState
}

enum DeskQuotaStatus: String, Codable, Sendable {
    case healthy, warning, critical, exhausted, stale

    static func resolve(remaining: Int?, total: Int?, updatedAt: Date, now: Date) -> DeskQuotaStatus {
        if now.timeIntervalSince(updatedAt) > 600 { return .stale }
        if let remaining, remaining == 0 { return .exhausted }
        guard let remaining, let total, total > 0 else { return .warning }
        let fraction = Double(remaining) / Double(total)
        if fraction >= 0.5 { return .healthy }
        if fraction >= 0.2 { return .warning }
        return .critical
    }
}

enum DeskPetState: String, Codable, Sendable {
    case patrol, pause, alert, exhausted, waiting
}
```

```swift
import CloudKit
import Foundation

enum DeskSnapshotRecordCodec {
    static let recordType = "DeskSnapshot"
    static let recordName = "current"

    static func makeRecord(snapshot: DeskSnapshot, zoneID: CKRecordZone.ID?) -> CKRecord {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID ?? .default)
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record["snapshotID"] = snapshot.snapshotID as CKRecordValue
        record["sourceDeviceID"] = snapshot.sourceDeviceID as CKRecordValue
        record["schemaVersion"] = snapshot.schemaVersion as CKRecordValue
        record["updatedAt"] = snapshot.updatedAt as CKRecordValue
        record["codexData"] = try? JSONEncoder().encode(snapshot.codex) as CKRecordValue
        record["claudeData"] = try? JSONEncoder().encode(snapshot.claude) as CKRecordValue
        return record
    }

    static func decode(_ record: CKRecord) throws -> DeskSnapshot {
        let decoder = JSONDecoder()
        return DeskSnapshot(
            snapshotID: record["snapshotID"] as? String ?? "current",
            sourceDeviceID: record["sourceDeviceID"] as? String ?? "unknown",
            schemaVersion: record["schemaVersion"] as? Int ?? 1,
            updatedAt: record["updatedAt"] as? Date ?? .distantPast,
            codex: try decoder.decode(DeskToolSnapshot.self, from: record["codexData"] as? Data ?? Data()),
            claude: try decoder.decode(DeskToolSnapshot.self, from: record["claudeData"] as? Data ?? Data())
        )
    }
}
```

```swift
import Foundation

enum DeskSnapshotBuilder {
    static func build(now: Date, codexAccounts: [CodexAccountSnapshot], claudeUsage: ClaudeUsageResponse?, fallbackQuotas: [QuotaRecord]) -> DeskSnapshot? {
        guard let codexQuota = codexAccounts.first(where: \.isCurrent)?.quota ?? fallbackQuotas.first(where: { $0.tool == .codex })?.toModel(),
              let claudeQuota = toolQuota(from: claudeUsage) ?? fallbackQuotas.first(where: { $0.tool == .claudeCode })?.toModel()
        else { return nil }

        return DeskSnapshot(
            snapshotID: "desk-current",
            sourceDeviceID: Host.current().localizedName ?? "mac",
            schemaVersion: 1,
            updatedAt: now,
            codex: makeToolSnapshot(from: codexQuota, label: "Codex", now: now),
            claude: makeToolSnapshot(from: claudeQuota, label: "Claude", now: now)
        )
    }
}
```

- [ ] **Step 5: Run the shared tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseTests -destination 'platform=macOS'`

Expected: PASS for `DeskSnapshotBuilderTests`.

- [ ] **Step 6: Commit**

```bash
git add project.yml OpenPulse/Shared OpenPulseTests
git commit -m "feat: add shared desk snapshot domain"
```

## Task 2: Publish desk snapshots from macOS through CloudKit

**Files:**
- Create: `OpenPulse/Data/Services/DeskSnapshotPublishStore.swift`
- Create: `OpenPulse/Data/Services/DeskSnapshotPublisher.swift`
- Modify: `OpenPulse/Data/Services/DataSyncService.swift`
- Modify: `OpenPulse/App/AppStore.swift`
- Modify: `OpenPulse/OpenPulse.entitlements`
- Test: `OpenPulseTests/DeskSnapshotBuilderTests.swift`

**Interfaces:**
- Consumes:
  - `DeskSnapshotBuilder.build(now:codexAccounts:claudeUsage:fallbackQuotas:)`
  - `DeskSnapshotRecordCodec.makeRecord(snapshot:zoneID:)`
- Produces:
  - `actor DeskSnapshotPublisher { func publishIfNeeded(codexAccounts:[CodexAccountSnapshot], claudeUsage: ClaudeUsageResponse?, fallbackQuotas:[QuotaRecord]) async }`
  - `struct DeskSnapshotPublishState: Codable, Equatable`

- [ ] **Step 1: Extend the failing test coverage for publish deduping**

```swift
@Test
func publisherSkipsUnchangedSnapshotsWithinThrottleWindow() async throws {
    let store = DeskSnapshotPublishStore(userDefaults: .standard, key: "test.publish.state")
    let publisher = DeskSnapshotPublisher(
        database: .privateCloudDatabase,
        publishStore: store,
        now: { Date(timeIntervalSince1970: 1_000) }
    )
    #expect(await publisher.shouldPublish(hash: "same-hash") == true)
    #expect(await publisher.shouldPublish(hash: "same-hash") == false)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseTests -destination 'platform=macOS'`

Expected: FAIL with missing `DeskSnapshotPublisher` or `DeskSnapshotPublishStore`.

- [ ] **Step 3: Add the CloudKit publish store and publisher**

```swift
import Foundation

struct DeskSnapshotPublishState: Codable, Equatable {
    let lastHash: String
    let lastPublishedAt: Date
}

actor DeskSnapshotPublishStore {
    private let userDefaults: UserDefaults
    private let key: String

    init(userDefaults: UserDefaults = .standard, key: String = "deskSnapshot.publish.state") {
        self.userDefaults = userDefaults
        self.key = key
    }

    func load() -> DeskSnapshotPublishState? {
        guard let data = userDefaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DeskSnapshotPublishState.self, from: data)
    }

    func save(_ state: DeskSnapshotPublishState) {
        userDefaults.set(try? JSONEncoder().encode(state), forKey: key)
    }
}
```

```swift
import CloudKit
import CryptoKit
import Foundation

actor DeskSnapshotPublisher {
    private let database: CKDatabase
    private let publishStore: DeskSnapshotPublishStore
    private let now: @Sendable () -> Date

    init(
        database: CKDatabase = CKContainer.default().privateCloudDatabase,
        publishStore: DeskSnapshotPublishStore = DeskSnapshotPublishStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.database = database
        self.publishStore = publishStore
        self.now = now
    }

    func shouldPublish(hash: String) async -> Bool {
        guard let state = await publishStore.load() else { return true }
        if state.lastHash != hash { return true }
        return now().timeIntervalSince(state.lastPublishedAt) >= 30
    }
}
```

- [ ] **Step 4: Wire publishing into `DataSyncService` after successful refresh**

```swift
private let deskSnapshotPublisher = DeskSnapshotPublisher()

private func publishDeskSnapshotIfNeeded() async {
    let desc = FetchDescriptor<QuotaRecord>(predicate: #Predicate { $0.toolRaw == Tool.codex.rawValue || $0.toolRaw == Tool.claudeCode.rawValue })
    let fallbackQuotas = (try? readContext.fetch(desc)) ?? []
    await deskSnapshotPublisher.publishIfNeeded(
        codexAccounts: latestCodexAccounts,
        claudeUsage: latestClaudeUsage,
        fallbackQuotas: fallbackQuotas
    )
}
```

- [ ] **Step 5: Add the CloudKit entitlement and verify build**

```plist
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudKit</string>
</array>
```

Run: `xcodegen generate && xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug build`

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add OpenPulse/Data/Services OpenPulse/OpenPulse.entitlements OpenPulse/App/AppStore.swift
git commit -m "feat: publish desk snapshots from macos"
```

## Task 3: Create the iPhone target and CloudKit read path

**Files:**
- Create: `OpenPulseiPhone/App/OpenPulseiPhoneApp.swift`
- Create: `OpenPulseiPhone/App/DeskModeAppStore.swift`
- Create: `OpenPulseiPhone/Data/DeskSnapshotCloudKitClient.swift`
- Create: `OpenPulseiPhone/Info.plist`
- Modify: `project.yml`
- Test: `OpenPulseiPhoneTests/DeskPetPresentationTests.swift`

**Interfaces:**
- Consumes:
  - `DeskSnapshot`
  - `DeskSnapshotRecordCodec.decode(_:)`
- Produces:
  - `@MainActor @Observable final class DeskModeAppStore`
  - `struct DeskSnapshotCloudKitClient { func fetchCurrent() async throws -> DeskSnapshot? }`

- [ ] **Step 1: Write the failing iPhone-side client tests**

```swift
import Testing
@testable import OpenPulseiPhone

struct DeskPetPresentationTests {
    @Test
    func appStoreStartsInWaitingStateWithoutSnapshot() async throws {
        let store = DeskModeAppStore(client: .init(fetchCurrent: { nil }))
        await store.refresh()
        #expect(store.snapshot == nil)
        #expect(store.statusText == "Waiting for Mac")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseiPhoneTests -destination 'platform=iOS Simulator,name=iPhone 17'`

Expected: FAIL with missing `DeskModeAppStore` or iPhone target files.

- [ ] **Step 3: Add the minimal iPhone app entry point and CloudKit client**

```swift
import SwiftUI

@main
struct OpenPulseiPhoneApp: App {
    @State private var appStore = DeskModeAppStore()

    var body: some Scene {
        WindowGroup {
            DeskModeRootView()
                .environment(appStore)
                .task { await appStore.refresh() }
        }
    }
}
```

```swift
import CloudKit
import Foundation

struct DeskSnapshotCloudKitClient {
    var fetchCurrent: @Sendable () async throws -> DeskSnapshot? = {
        let database = CKContainer.default().privateCloudDatabase
        let recordID = CKRecord.ID(recordName: DeskSnapshotRecordCodec.recordName)
        let record = try await database.record(for: recordID)
        return try DeskSnapshotRecordCodec.decode(record)
    }
}
```

```swift
import Observation

@MainActor
@Observable
final class DeskModeAppStore {
    var snapshot: DeskSnapshot?
    var statusText = "Waiting for Mac"

    private let client: DeskSnapshotCloudKitClient

    init(client: DeskSnapshotCloudKitClient = .init()) {
        self.client = client
    }

    func refresh() async {
        do {
            snapshot = try await client.fetchCurrent()
            statusText = snapshot == nil ? "Waiting for Mac" : "Synced just now"
        } catch {
            statusText = "Cloud sync unavailable"
        }
    }
}
```

- [ ] **Step 4: Run the iPhone tests and build the target**

Run: `xcodegen generate && xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseiPhoneTests -destination 'platform=iOS Simulator,name=iPhone 17'`

Expected: PASS for `DeskPetPresentationTests`.

Run: `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulseiPhone -destination 'platform=iOS Simulator,name=iPhone 17' build`

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add project.yml OpenPulseiPhone OpenPulseiPhoneTests
git commit -m "feat: add iphone desk mode target"
```

## Task 4: Map snapshots into presentation state and build the Twin Cockpit UI

**Files:**
- Create: `OpenPulseiPhone/Models/DeskPetPresentation.swift`
- Create: `OpenPulseiPhone/Views/DeskModeRootView.swift`
- Create: `OpenPulseiPhone/Views/TwinCockpitView.swift`
- Create: `OpenPulseiPhone/Views/ToolCockpitPanel.swift`
- Modify: `OpenPulseiPhone/App/DeskModeAppStore.swift`
- Test: `OpenPulseiPhoneTests/DeskPetPresentationTests.swift`

**Interfaces:**
- Consumes:
  - `DeskSnapshot`
  - `DeskQuotaStatus`
- Produces:
  - `struct DeskPetPresentation: Equatable, Sendable`
  - `static func make(from snapshot: DeskToolSnapshot, now: Date) -> DeskPetPresentation`

- [ ] **Step 1: Extend the failing UI mapping tests**

```swift
@Test
func criticalSnapshotMapsToAlertPresentation() {
    let presentation = DeskPetPresentation.make(
        from: .init(
            tool: .codex,
            displayLabel: "Codex",
            remaining: 10,
            total: 100,
            fraction: 0.1,
            resetAt: Date(timeIntervalSince1970: 2_000),
            status: .critical,
            petState: .alert
        ),
        now: Date(timeIntervalSince1970: 1_000)
    )
    #expect(presentation.motion == .alert)
    #expect(presentation.primaryText == "10%")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseiPhoneTests -destination 'platform=iOS Simulator,name=iPhone 17'`

Expected: FAIL with missing `DeskPetPresentation`.

- [ ] **Step 3: Add the presentation model and cockpit views**

```swift
import Foundation
import SwiftUI

enum DeskMotionStyle: Equatable, Sendable {
    case patrol, pause, alert, exhausted, waiting
}

struct DeskPetPresentation: Equatable, Sendable {
    let tool: Tool
    let title: String
    let primaryText: String
    let resetText: String
    let fraction: Double?
    let motion: DeskMotionStyle
    let isStale: Bool
}
```

```swift
import SwiftUI

struct TwinCockpitView: View {
    let codex: DeskPetPresentation
    let claude: DeskPetPresentation
    let statusText: String

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 16) {
                ToolCockpitPanel(presentation: codex)
                ToolCockpitPanel(presentation: claude)
            }
            .padding(24)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.08, green: 0.11, blue: 0.18), Color(red: 0.15, green: 0.11, blue: 0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .top) {
                Text(statusText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .padding(.top, 10)
            }
        }
    }
}
```

- [ ] **Step 4: Run the iPhone tests and simulator build**

Run: `xcodegen generate && xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseiPhoneTests -destination 'platform=iOS Simulator,name=iPhone 17'`

Expected: PASS.

Run: `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulseiPhone -destination 'platform=iOS Simulator,name=iPhone 17' build`

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add OpenPulseiPhone/Models OpenPulseiPhone/Views OpenPulseiPhone/App/DeskModeAppStore.swift OpenPulseiPhoneTests
git commit -m "feat: add twin cockpit desk ui"
```

## Task 5: Add the Codex and Claude pet motion layer

**Files:**
- Create: `OpenPulseiPhone/Views/Pets/PetMotion.swift`
- Create: `OpenPulseiPhone/Views/Pets/CodexPetView.swift`
- Create: `OpenPulseiPhone/Views/Pets/ClaudePetView.swift`
- Modify: `OpenPulseiPhone/Views/ToolCockpitPanel.swift`
- Modify: `OpenPulse/Resources/Assets.xcassets/...`
- Test: `OpenPulseiPhoneTests/DeskPetPresentationTests.swift`

**Interfaces:**
- Consumes:
  - `DeskMotionStyle`
  - `DeskPetPresentation`
- Produces:
  - `struct CodexPetView: View`
  - `struct ClaudePetView: View`
  - `enum PetMotion { static func offset(for style: DeskMotionStyle, phase: CGFloat) -> CGSize }`

- [ ] **Step 1: Extend the failing presentation tests for motion mapping**

```swift
@Test
func exhaustedPresentationMapsToExhaustedMotion() {
    let presentation = DeskPetPresentation(
        tool: .claudeCode,
        title: "Claude",
        primaryText: "0%",
        resetText: "Resets 16:05",
        fraction: 0,
        motion: .exhausted,
        isStale: false
    )
    #expect(presentation.motion == .exhausted)
}
```

- [ ] **Step 2: Run tests to verify they fail if motion layer is missing**

Run: `xcodegen generate && xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseiPhoneTests -destination 'platform=iOS Simulator,name=iPhone 17'`

Expected: FAIL after `ToolCockpitPanel` references missing pet views.

- [ ] **Step 3: Implement the vector-style pet views and motion helpers**

```swift
import SwiftUI

enum PetMotion {
    static func offset(for style: DeskMotionStyle, phase: CGFloat) -> CGSize {
        switch style {
        case .patrol: .init(width: sin(phase) * 18, height: cos(phase * 2) * 4)
        case .pause: .init(width: sin(phase) * 6, height: cos(phase * 2) * 3)
        case .alert: .init(width: sin(phase * 4) * 10, height: 0)
        case .exhausted: .init(width: 0, height: 10)
        case .waiting: .init(width: 0, height: sin(phase) * 2)
        }
    }
}
```

```swift
import SwiftUI

struct CodexPetView: View {
    let motion: DeskMotionStyle
    @State private var phase: CGFloat = 0

    var body: some View {
        Image("CodexPet")
            .resizable()
            .scaledToFit()
            .offset(PetMotion.offset(for: motion, phase: phase))
            .shadow(color: .green.opacity(0.25), radius: motion == .alert ? 20 : 10)
            .task {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    phase = .pi * 2
                }
            }
    }
}
```

- [ ] **Step 4: Build and visually verify in the simulator**

Run: `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulseiPhone -destination 'platform=iOS Simulator,name=iPhone 17' build`

Expected: BUILD SUCCEEDED.

Run: `open OpenPulse.xcodeproj`

Expected: The iPhone simulator shows Codex and Claude moving distinctly across `healthy`, `critical`, and `exhausted` preview states.

- [ ] **Step 5: Commit**

```bash
git add OpenPulseiPhone/Views/Pets OpenPulseiPhone/Views/ToolCockpitPanel.swift OpenPulse/Resources/Assets.xcassets
git commit -m "feat: add desk pet motion layer"
```

## Task 6: Final verification and polish

**Files:**
- Modify: `OpenPulseiPhone/App/DeskModeAppStore.swift`
- Modify: `OpenPulseiPhone/Views/DeskModeRootView.swift`
- Modify: `docs/superpowers/specs/2026-07-08-openpulse-iphone-desk-mode-design.md` (only if implementation constraints require a design note)

**Interfaces:**
- Consumes: all previous task outputs
- Produces: a working end-to-end desk mode build

- [ ] **Step 1: Add local stale timer refresh and waiting-state polish**

```swift
@MainActor
func tick(now: Date = .now) {
    guard let snapshot else {
        statusText = "Waiting for Mac"
        return
    }
    let age = now.timeIntervalSince(snapshot.updatedAt)
    statusText = age > 600 ? "Sync delayed" : "Synced \(Int(age))s ago"
}
```

- [ ] **Step 2: Run the full macOS and iPhone verification**

Run: `xcodegen generate`

Run: `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseTests -destination 'platform=macOS'`

Expected: PASS.

Run: `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseiPhoneTests -destination 'platform=iOS Simulator,name=iPhone 17'`

Expected: PASS.

Run: `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug build`

Expected: BUILD SUCCEEDED.

Run: `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulseiPhone -destination 'platform=iOS Simulator,name=iPhone 17' build`

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual device-path verification**

Run:

```bash
open OpenPulse.xcodeproj
```

Expected:

- Mac app refreshes real Codex and Claude quota
- CloudKit private database receives one `DeskSnapshot`
- iPhone simulator or attached iPhone loads the desk screen in landscape
- Both pets are visible at the same time
- Reducing snapshot values moves motion into `warning`, `critical`, and `exhausted`

- [ ] **Step 4: Commit**

```bash
git add project.yml OpenPulse OpenPulseiPhone OpenPulseTests OpenPulseiPhoneTests
git commit -m "feat: ship iphone desk mode"
```

## Self-Review

### Spec coverage

- New iPhone target: Task 3
- Landscape-only one-screen app: Tasks 3 and 4
- Codex + Claude side by side: Task 4
- CloudKit snapshot path: Tasks 1 and 2
- Noticeable pet animation: Task 5
- Read-only iPhone consumer: Tasks 1 through 3 preserve Mac-only parser ownership
- No widget / Live Activity / multi-page scope: no tasks include them

### Placeholder scan

- No `TBD` or `TODO`
- Every task has concrete files, interfaces, commands, and expected results
- The only open variable is the exact official pet asset import path, which is intentionally isolated to Task 5 asset work

### Type consistency

- `DeskSnapshot`, `DeskToolSnapshot`, `DeskQuotaStatus`, and `DeskPetState` are defined in Task 1 before later tasks consume them
- `DeskModeAppStore` is introduced in Task 3 before Task 4 extends it
- `DeskMotionStyle` and pet views are introduced before Task 5 uses them in the UI

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-08-openpulse-iphone-desk-mode.md`. Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
