# Task 6 Report

## Summary

Task 6 is implemented at repo scope. The iPhone scheme/test path now generates explicit shared schemes and resolves to iOS simulator destinations instead of macOS-only auto-scheme destinations. Desk mode also now updates its local status text on a 1-second stale timer and shows a polished waiting state while no snapshot is available.

The remaining macOS signed Debug CloudKit verification is still blocked by local provisioning/profile state, not by repo configuration. I kept CloudKit entitlements/runtime behavior intact and proved the unsigned repo build/test path succeeds.

## Files Changed

- `project.yml`
- `OpenPulse.xcodeproj/project.pbxproj` (regenerated via `xcodegen generate`)
- `OpenPulse.xcodeproj/xcshareddata/xcschemes/OpenPulse.xcscheme`
- `OpenPulse.xcodeproj/xcshareddata/xcschemes/OpenPulseTests.xcscheme`
- `OpenPulse.xcodeproj/xcshareddata/xcschemes/OpenPulseiPhone.xcscheme`
- `OpenPulse.xcodeproj/xcshareddata/xcschemes/OpenPulseiPhoneTests.xcscheme`
- `OpenPulseiPhone/App/DeskModeAppStore.swift`
- `OpenPulseiPhone/Views/DeskModeRootView.swift`
- `OpenPulseiPhoneTests/DeskPetPresentationTests.swift`

## Implementation Notes

### iPhone scheme/platform fix

- Added explicit shared schemes for:
  - `OpenPulse`
  - `OpenPulseTests`
  - `OpenPulseiPhone`
  - `OpenPulseiPhoneTests`
- Added explicit build defaults that XcodeGen was not supplying in this environment:
  - `PRODUCT_NAME`
  - `SDKROOT`
  - `SUPPORTED_PLATFORMS`
  - `LD_RUNPATH_SEARCH_PATHS`
  - test host / bundle loader wiring
  - minimal Debug/Release config settings (`ENABLE_TESTABILITY`, `SWIFT_OPTIMIZATION_LEVEL`, etc.)
- Regenerated the project with `xcodegen generate`.

### Desk mode stale-timer polish

- Added `DeskModeAppStore.tick(now:)` with the Task 6 strings:
  - `Waiting for Mac`
  - `Sync delayed`
  - `Synced {N}s ago`
- Switched `refresh()` to call `tick(now:)` after fetch.
- Added a root-view 1-second task loop so the status text ages locally.
- Added a small waiting-state `ProgressView`.

### Test coverage added

- Added iPhone tests for:
  - delayed snapshot status after 10 minutes
  - recent snapshot status countdown text

## Verification

### Required commands from brief

1. `xcodegen generate`
   - PASS

2. `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseTests -destination 'platform=macOS'`
   - FAIL
   - External blocker:
     - `Provisioning profile "Mac Team Provisioning Profile: com.fanyu.openpulse" doesn't include the iCloud capability.`
     - `... doesn't support the iCloud.com.fanyu.openpulse iCloud Container.`
     - `... doesn't include the com.apple.developer.icloud-container-identifiers and com.apple.developer.icloud-services entitlements.`

3. `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseiPhoneTests -destination 'platform=iOS Simulator,name=iPhone 17'`
   - PASS
   - Swift Testing run: 6 tests passed.

4. `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug build`
   - FAIL
   - Same external provisioning/profile blocker as macOS tests above.

5. `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulseiPhone -destination 'platform=iOS Simulator,name=iPhone 17' build`
   - PASS
   - `BUILD SUCCEEDED`

### Supplemental proof for repo-side correctness

1. `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseTests -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
   - PASS
   - Swift Testing run: 9 tests passed.

2. `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulse -configuration Debug build CODE_SIGNING_ALLOWED=NO`
   - PASS
   - `BUILD SUCCEEDED`

3. `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulseiPhone -showdestinations`
   - PASS
   - Now lists `iOS Simulator` destinations including `iPhone 17`; no longer macOS-only.

4. `xcrun simctl install 1095EC14-8DB9-480E-A270-082B61EF76C3 <built OpenPulseiPhone.app>`
   - PASS

5. `xcrun simctl launch 1095EC14-8DB9-480E-A270-082B61EF76C3 com.fanyu.OpenPulseiPhone`
   - PASS
   - Returned PID `57005`

## Manual/device-path verification status

- Ran `open OpenPulse.xcodeproj`.
- Proved the generated iPhone scheme now builds an installable simulator app and launches it via `simctl`.
- I could not fully assert the brief’s visual desk-mode content checks (`DeskSnapshot` arrival, both pets visible, warning/critical/exhausted transitions) in this non-interactive run because:
  - signed macOS CloudKit publishing is blocked by the local provisioning profile
  - the simulator content depends on that external CloudKit path

## External Blocker

The remaining blocker is local Apple signing/provisioning state for the macOS app:

- The selected provisioning profile for `com.fanyu.openpulse` does not include the iCloud capability/container entitlements required by `OpenPulse/OpenPulse.entitlements`.
- Repo-side entitlements, target wiring, and unsigned build/test paths are consistent and working.
- I did not disable CloudKit/runtime functionality to force a green signed build.

## Fix Pass: Xcode 26 baseline restore

- Restored the repo metadata baseline from the temporary Xcode 16 downgrade back to the stated Xcode 26 configuration:
  - `project.yml`: `xcodeVersion: "26.0"`
  - regenerated project metadata: `LastUpgradeCheck = 2600`
  - regenerated shared schemes: `LastUpgradeVersion = 2600`
- Preserved the working iPhone simulator scheme/test path while doing the metadata cleanup; no platform wiring was reverted.

### Verification rerun after restore

1. `xcodegen generate`
   - PASS

2. `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseiPhoneTests -destination 'platform=iOS Simulator,name=iPhone 17'`
   - PASS
   - Swift Testing run: 6 tests passed.

3. `xcodebuild -project OpenPulse.xcodeproj -scheme OpenPulseiPhone -destination 'platform=iOS Simulator,name=iPhone 17' build`
   - PASS
   - `BUILD SUCCEEDED`

### Remaining concern

- The signed macOS CloudKit verification remains blocked by the same external local provisioning/profile state documented above. Repo-side cleanup in this pass does not change that blocker.
