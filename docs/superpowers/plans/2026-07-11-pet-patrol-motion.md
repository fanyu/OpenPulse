# Pet Patrol Motion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Codex and Claude desk pets visibly patrol and turn around inside their iPhone cards.

**Architecture:** Add a deterministic `PetMovement` value derived from the existing timeline phase and motion style. The two pet views consume only that value for position, facing direction, stride, and shadow scale; no state, timer, snapshot, or CloudKit changes are required.

**Tech Stack:** Swift 6.2, SwiftUI `TimelineView`, Swift Testing, iOS 26.

## Global Constraints

- Healthy patrol travel is bounded to 48 points from center, with a pause at each endpoint.
- Warning and critical motion use shorter routes; exhausted and waiting behavior remains in place.
- The pet stage, quota bubble, progress rows, and sync payload remain unchanged.

---

### Task 1: Define deterministic patrol movement

**Files:**
- Modify: `OpenPulseiPhone/Views/Pets/PetMotion.swift`
- Test: `OpenPulseiPhoneTests/PetMotionTests.swift`

**Interfaces:**
- Produces: `PetMotion.movement(for:phase:) -> PetMovement`.
- Produces: `PetMovement.offset`, `facingScaleX`, `stride`, and `shadowScaleX`.

- [ ] **Step 1: Write failing patrol tests**

```swift
@Test
func patrolPausesThenWalksAcrossTheBoundedStage() {
    let atLeft = PetMotion.movement(for: .patrol, phase: 0)
    let movingRight = PetMotion.movement(for: .patrol, phase: .pi * 0.6)
    let movingLeft = PetMotion.movement(for: .patrol, phase: .pi * 1.6)

    #expect(atLeft.offset.width == -48)
    #expect(atLeft.stride == 0)
    #expect(movingRight.offset.width > -48 && movingRight.offset.width < 48)
    #expect(movingRight.facingScaleX == 1)
    #expect(movingLeft.facingScaleX == -1)
}
```

- [ ] **Step 2: Run the iPhone test scheme and verify it fails**

Run: `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseiPhoneTests -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/OpenPulsePetMotionTests`

Expected: compilation failure because `PetMotion.movement(for:phase:)` does not exist.

- [ ] **Step 3: Implement bounded movement**

```swift
struct PetMovement: Equatable {
    let offset: CGSize
    let facingScaleX: CGFloat
    let stride: CGFloat
    let shadowScaleX: CGFloat
}
```

Implement a four-segment route: left pause, walk right, right pause, walk left. Use `stride == 0` during pauses and preserve existing static exhausted and waiting behavior.

- [ ] **Step 4: Run the iPhone test scheme and verify it passes**

Expected: the patrol test and existing iPhone tests pass.

### Task 2: Apply patrol movement to both pet renderers

**Files:**
- Modify: `OpenPulseiPhone/Views/Pets/CodexPetView.swift`
- Modify: `OpenPulseiPhone/Views/Pets/ClaudePetView.swift`

**Interfaces:**
- Consumes: `PetMotion.movement(for:phase:)`.
- Consumes: `PetMovement.offset`, `facingScaleX`, `stride`, and `shadowScaleX`.

- [ ] **Step 1: Drive body and shadow from the shared movement value**

```swift
let movement = PetMotion.movement(for: motion, phase: phase)

.scaleEffect(x: movement.facingScaleX, y: squash, anchor: .bottom)
.offset(movement.offset)
```

Apply the same horizontal movement to the ground shadow and scale it by `movement.shadowScaleX`.

- [ ] **Step 2: Scale each pet's existing leg cadence by movement stride**

```swift
let limbAngle = PetMotion.limbSwing(for: motion, phase: phase, index: index)
    * movement.stride
```

Pass `movement.stride` to Codex legs, Claude claws, and Claude legs so endpoint pauses are visually still.

- [ ] **Step 3: Run the iPhone test scheme**

Expected: `** TEST SUCCEEDED **`.

### Task 3: Verify shared macOS code remains unaffected

**Files:**
- No additional source files.

- [ ] **Step 1: Run the macOS test scheme**

Run: `xcodebuild test -project OpenPulse.xcodeproj -scheme OpenPulseTests -destination 'platform=macOS' -derivedDataPath /tmp/OpenPulsePetMotionMacTests`

Expected: `** TEST SUCCEEDED **`.
