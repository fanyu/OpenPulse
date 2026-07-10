# Antigravity Consumer Pro Badge Design

## Goal

Show `Google AI Pro` for Antigravity accounts whose live quota response demonstrates the consumer Pro entitlement even when Google reports `currentTier.id = free-tier`.

## Classification

An account displays `Google AI Pro` when either condition is true:

1. Its reported tier is not `free-tier`, preserving the existing paid-tier behavior.
2. Both the Gemini group and the third-party (`3p`) group contain usable `5h` and `weekly` quota windows.

All other `free-tier` accounts display `Free`. Missing groups or missing windows must not be treated as Pro.

## Design

The classification belongs on `AGAccountQuota`, because it combines tier metadata with quota groups. `AGTier` remains responsible only for the tier returned by `loadCodeAssist`. Views consume the account-level badge label and paid state rather than reproducing entitlement rules.

## Scope

- Update Antigravity account badge classification.
- Update the shared Antigravity badge view to accept an account.
- Cover consumer Pro, ordinary free, incomplete quota, and non-free tier behavior with unit tests.
- Do not change quota percentages, reset handling, API requests, account persistence, or unrelated UI.

## Verification

Run the focused Antigravity tests, then the complete OpenPulse macOS test suite and Debug build.
