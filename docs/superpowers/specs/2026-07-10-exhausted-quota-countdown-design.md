# Exhausted Quota Countdown

## Goal

Make a zero remaining 5-hour quota feel intentional by showing the time until reset and an exhausted pet state in the iPhone desk display.

## Behavior

- Activate only when the 5-hour quota is available, its remaining value is zero, and `resetAt` is in the future.
- Replace the pet-stage percentage bubble with a `RESET IN` countdown in `HH:MM:SS`.
- Update the countdown once per second. Apply a subtle red pulse and vertical breathing motion without changing the card layout.
- Keep the 5-hour progress bar empty and use the existing exhausted pet motion.
- At reset, stop the countdown and return to the regular percentage bubble on the next snapshot refresh.
- Do not change weekly-quota presentation or CloudKit payloads.

## Implementation

- Add a focused presentation helper that derives whether the session should display a reset countdown and formats the remaining duration.
- Render the existing `quotaBubble` through a one-second `TimelineView`, selecting countdown or percentage content from that helper.
- Reuse the existing exhausted accent and pet motion so the state is visually consistent with the progress bar.

## Verification

- Unit-test zero remaining with a future reset date, expired reset date, and nonzero remaining.
- Run the iPhone test scheme to confirm the shared desk presentation still builds and existing pet-status behavior passes.
