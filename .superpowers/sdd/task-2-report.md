Status: DONE_WITH_CONCERNS

Summary:
- Added `DeskSnapshotPublishStore` and `DeskSnapshotPublisher` to dedupe/publish desk snapshots from macOS.
- Wired publish attempts into `DataSyncService` after successful Codex and Claude refreshes.
- Added CloudKit capability to `OpenPulse/OpenPulse.entitlements`.
- Added publish dedupe coverage to `OpenPulseTests/DeskSnapshotBuilderTests.swift`.
- Added a runtime entitlement gate so the app does not touch CloudKit during tests or on builds where the generated entitlements omit CloudKit.

Files changed:
- `OpenPulse/Data/Services/DeskSnapshotPublishStore.swift`
- `OpenPulse/Data/Services/DeskSnapshotPublisher.swift`
- `OpenPulse/Data/Services/DataSyncService.swift`
- `OpenPulse/App/AppStore.swift`
- `OpenPulse/OpenPulse.entitlements`
- `OpenPulseTests/DeskSnapshotBuilderTests.swift`
- `OpenPulse.xcodeproj/project.pbxproj`

Verification:
1. Red step:
   - Ran `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseTests -destination 'platform=macOS'`
   - Observed expected missing-symbol failure for `DeskSnapshotPublishStore` / `DeskSnapshotPublisher` after adding the new test.
2. Green step:
   - Ran `/opt/homebrew/bin/xcodegen generate && xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseTests -destination 'platform=macOS'`
   - Result: `TEST SUCCEEDED`
3. Build step:
   - Ran `/opt/homebrew/bin/xcodegen generate && xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug build`
   - Result: `BUILD SUCCEEDED`

Concern:
- `xcodegen generate` rewrites `OpenPulse/OpenPulse.entitlements` from `project.yml`, and `project.yml` is outside the allowed Task 2 file list. I restored the checked-in entitlements file after verification, but a future `xcodegen generate` will drop the CloudKit key again until `project.yml` is updated in a follow-up task. The runtime `DeskSnapshotPublisher.makeIfAvailable()` guard prevents crashes in that state, but actual CloudKit publishing still depends on that follow-up.
