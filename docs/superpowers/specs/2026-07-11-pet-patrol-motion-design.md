# Pet Patrol Motion Design

## Goal

Replace the iPhone desk pets' floating horizontal oscillation with contained, readable walking behavior inside each pet stage.

## Behavior

- Keep every pet inside the existing pet-stage safe area, clear of the quota bubble, titles, and progress rows.
- Healthy pets walk a 48-point left-to-right patrol route, pause briefly at each end, flip direction, and continue.
- Warning pets use a shorter, quicker route to appear restless.
- Critical pets use an urgent, jittery short run.
- Exhausted pets stay in place with the existing tired pose and reset countdown.
- Waiting pets retain their quiet idle behavior.
- Walking changes horizontal position, horizontal facing direction, leg cadence, body bob, and ground-shadow compression together.

## Implementation

- Extend `PetMotion` with deterministic position, facing, and cadence helpers derived only from the existing timeline phase and motion style.
- Apply those helpers equally to the Codex and Claude pet containers; keep their existing character-specific leg rendering.
- Leave the card layout, quota bubble, sync model, and CloudKit payload untouched.

## Verification

- Unit-test healthy patrol direction reversal and bounded horizontal offset.
- Run the iPhone simulator test scheme after the motion changes.
