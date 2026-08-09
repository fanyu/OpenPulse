# Codex General Quota Selection

## Goal

Keep OpenPulse's Codex menu-bar percentage aligned with the general Codex quota instead of allowing a model-specific quota, such as GPT-5.3-Codex-Spark, to overwrite it.

## Confirmed Cause

- Codex session JSONL files can contain multiple quota families distinguished by `rate_limits.limit_id`.
- The general quota currently uses `limit_id = "codex"`.
- GPT-5.3-Codex-Spark uses `limit_id = "codex_bengalfox"` and can report 100% remaining while the general quota is lower.
- `CodexParser` currently discards `limit_id` and returns the first rate-limit event found in the most recently modified session file.
- File-system refresh then applies that unrelated quota to the current account.

## Behavior

- Decode `limit_id` and `limit_name` as part of `CodexRateLimits`.
- Treat `limit_id = "codex"` as the general Codex quota used by the existing menu-bar and account synchronization flow.
- Ignore rate-limit events with another nonempty ID, including `codex_bengalfox`, and continue scanning older events and files for the newest general quota.
- Accept events with no `limit_id` as a legacy fallback so older Codex JSONL layouts remain supported.
- Preserve the decoded quota identity when merging reset-credit details.
- Do not change API quota fetching, model-specific quota presentation, account switching, persistence schema, or menu-bar layout.

## Implementation

- Extend `CodexRateLimits` with optional quota identity fields and a small predicate describing whether the record is eligible for the general quota path.
- Apply that predicate inside `CodexParser.parseRateLimitsFromFile` before returning a local snapshot.
- Keep the existing file ordering and freshness checks unchanged.

## Verification

- Add a parser regression test with a newer `codex_bengalfox` file at 100% remaining and an older `codex` file at 66% remaining; the parser must return 66%.
- Add a compatibility test showing that a legacy rate-limit event without `limit_id` remains eligible.
- Run the focused Codex quota tests and verify a nonzero test count.
- Run the full OpenPulse test target and a Debug macOS build.
