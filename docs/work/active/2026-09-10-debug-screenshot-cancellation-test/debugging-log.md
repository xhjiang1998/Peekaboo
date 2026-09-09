# Screenshot cancellation test debugging log

## Symptom

GitHub Actions run `34405416978` passed 221 of 222 Mac tests. The only failure was
`ScreenshotConversationServiceTests.swift:469`: the test expected the outer analysis task to throw
`CancellationError`, but it completed normally.

## Hypotheses

1. **Stale assertion after request-token invalidation.** If true, `cancel(sessionID:)` clears the active request ID,
   the internal analyzer still observes cancellation, and `analyze(sessionID:)` deliberately consumes the stale
   request's error instead of propagating it.
2. **Production cancellation regression.** If true, the analyzer task does not observe cancellation and either waits
   for its full delay or persists its late answer.
3. **Cancel-before-registration race.** If true, `cancel(sessionID:)` is a no-op because no active task exists, so the
   status never becomes `.cancelling`.
4. **No-op cancellation overwrites terminal state.** If true, calling cancel without an active task changes a prior
   `.failed` or `.ready` status.

## Verification record

- Hypothesis 1 confirmed: `cancel(sessionID:)` clears `activeRequestIDs[sessionID]` before cancelling the internal
  task. Both the catch and success paths treat a mismatched ID as an invalidated request, clean up, set `.idle`, and
  return normally.
- Hypothesis 2 rejected: an exact-production-source Swift 6.1 proof records that the analyzer catches
  `CancellationError`; the request completes in under 0.1 seconds, no assistant message is stored, and status returns
  to `.idle`.
- Hypothesis 3 rejected for the reported run: the immediately preceding `.cancelling` expectation passed, and that
  state is assigned only when `activeRequestTasks[sessionID]` exists.
- Hypothesis 4 rejected: the guard in `cancel(sessionID:)` preserves terminal state, and the exact-source proof's
  `noOpCancelPreservesFailure` regression passes.

## Root cause

The production behavior intentionally changed to invalidate a cancelled request immediately and suppress any later
success or error from that stale request. The older test still asserted the pre-invalidation outward error contract.
The CI failure is therefore a stale test assertion, not a production cancellation regression.

## Fix

Update the cooperative-cancellation regression to assert the current public contract: the internal analyzer observes
cancellation, the invalidated request completes without leaking an error, no late assistant answer is persisted, and
the service returns to `.idle`. The existing non-cooperative regression continues to prove that a same-session request
cannot build up before the stale task finishes.

## Regression evidence

- Exact-source Swift 6.1 service proof: 10/10 passed, including cooperative cancellation, non-cooperative stale-result
  invalidation/request bounding, and no-op cancellation terminal-state preservation.
- Production source and mechanically syntax-lowered repository test file pass frontend parser validation.
- `git diff --check` passes.
- Native repository tests remain unavailable locally because `Apps/Mac` requires Swift tools 6.2 while this host has
  Swift 6.1; the next remote CI run is the authoritative native gate.

## Lessons

- Cancellation has two observable layers: the internal provider task can receive `CancellationError` while the service
  deliberately consumes that error after invalidating the request token. Tests must assert the service contract and
  separately observe internal cancellation when that distinction matters.
