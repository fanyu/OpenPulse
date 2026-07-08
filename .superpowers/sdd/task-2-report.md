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

---

Fix pass:
- Updated `project.yml` so XcodeGen now emits the CloudKit entitlement into `OpenPulse/OpenPulse.entitlements` for the macOS app target.
- Added `CODE_SIGNING_ALLOWED: NO` for Debug on `OpenPulse` and `OpenPulseTests` so the required local Debug build/test commands succeed without an iCloud-enabled provisioning profile on this machine.
- Moved desk snapshot publish-state persistence to the post-save success path.
- Added `failedPublishDoesNotThrottleRetry()` to prove failed publishes remain retry-eligible.

Fix-pass verification:
1. Ran `xcodegen generate`
   - Result: succeeded
2. Ran `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseTests -destination 'platform=macOS'`
   - Result: `TEST SUCCEEDED`
3. Ran `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug build`
   - Result: `BUILD SUCCEEDED`

Remaining concern:
- Debug builds/tests are now intentionally unsigned in project settings so local verification can coexist with the CloudKit entitlement on this machine. Release signing behavior was left unchanged.

---

Runtime review fix pass:
- Removed the Debug-only `CODE_SIGNING_ALLOWED: NO` bypass from the macOS app target so a signed Debug build can construct a real `DeskSnapshotPublisher`.
- Switched `DeskSnapshotPublisher.makeIfAvailable()` to the explicit shared container `iCloud.com.fanyu.openpulse.shared` and required both `com.apple.developer.icloud-services` and `com.apple.developer.icloud-container-identifiers` entitlements before constructing the publisher.
- Added the same shared container identifier to repo source of truth for both the macOS entitlements and the iPhone target entitlements manifest so the app family stays on a shared CloudKit container path instead of target-default containers.
- Reworked publisher save flow so publish state is persisted only after a successful CloudKit save.
- Strengthened `failedPublishDoesNotThrottleRetry()` to inject a real save failure and verify the failed publish path remains retry-eligible across repeated attempts.

Runtime fix-pass verification:
1. `xcodegen generate`
   - Exact command from the default shell failed because `xcodegen` is not on `PATH` in this environment (`zsh:1: command not found: xcodegen`).
   - `/opt/homebrew/bin/xcodegen generate` succeeded and regenerated `OpenPulse.xcodeproj`.
2. `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseTests -destination 'platform=macOS'`
   - Failed during app-target signing: the local `Mac Team Provisioning Profile: com.fanyu.openpulse` does not include CloudKit, does not support `iCloud.com.fanyu.openpulse.shared`, and does not include the required iCloud entitlements.
3. `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug build`
   - Failed for the same provisioning-profile reason.
4. `xcodebuild -allowProvisioningUpdates -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug build`
   - Failed with `No Accounts: Add a new account in Accounts settings.` and the same missing-CloudKit-profile errors, confirming the remaining blocker is local Xcode account/provisioning state rather than repo configuration.

Runtime fix-pass concern:
- The repo now preserves the shared CloudKit container and allows a signed Debug app to use the real publisher path, but exact local test/build verification still requires an Apple account plus a provisioning profile for `com.fanyu.openpulse` that includes CloudKit and the shared container `iCloud.com.fanyu.openpulse.shared`.
