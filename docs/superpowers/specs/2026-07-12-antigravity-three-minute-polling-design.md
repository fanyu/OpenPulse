# Antigravity Three-Minute Polling Design

## Goal

Refresh Antigravity quota data every three minutes instead of every five minutes, then ship the change as OpenPulse 1.0.15 (build 16).

## Design

Keep the existing per-tool timer architecture. Change only Antigravity's interval from 300 seconds to 180 seconds; all other tool intervals, launch refreshes, manual refreshes, and file-event handling remain unchanged. Expose the interval lookup internally so the unit-test target can verify the configured value.

## Validation and Release

Run the focused unit test and the full OpenPulse test suite, regenerate the Xcode project, build the Release app, package a DMG, and verify the app signature and DMG. Commit only this change and version bump, tag `v1.0.15`, push `main` and the tag, create a GitHub release, then read back the uploaded asset.
