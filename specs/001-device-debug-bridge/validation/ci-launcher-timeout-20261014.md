# CI launcher timeout assertion

## Scope and evidence

GitHub run 38527592207, commit 5bb6bf7, failed only
`IOSRunnerLauncherTests.blockedValidationDoesNotBlockTimeoutOrCancellation(false)`
at its fixed 150 ms completion assertion. All 504 core tests passed locally on the same commit.
This supports a scheduling-sensitive test; it does not prove a production timeout defect.

## Contract and focused change

Production path is `installStartAndOpen` → `loadArtifacts` → current-attempt/deadline
checks → process start → channel open → connected result. The launcher actor owns attempts;
`IOSRunnerArtifactResult` resolves validation, timeout or cancellation exactly once. Late
validation cannot start a process after the result has failed. No production code changes.

Replace the fixed observation sleep with a bounded completion wait while validation remains
blocked. Keep the before/after-release no-process assertions. Give the cancellation case a
30-second startup timeout, longer than the 2-second observation bound, and assert its error
category so timeout cannot substitute for cancellation.

Structural scope: one existing test, no new production API, state owner or dependency.
Counterexamples to verify: disabling the validation timer must fail the timeout case;
disabling its cancellation resolution must fail the cancellation case. Restore each mutation
before committing. Run focused repetitions and the complete core suite, then the GitHub build.

## Local verification

- Related launcher suites: 16 tests passed.
- Complete core suite: 504 tests / 68 suites passed.
- Focused timeout/cancellation test: 20 consecutive repetitions passed.
- Negative controls: suppressing timer resolution failed only the timeout case; suppressing
  cancellation resolution failed only the cancellation case. Both failed at the pre-release
  completion assertion. Production source restored byte-for-byte before the full passing run.
- `git diff --check`: passed.

## Handoff

Pending: successful GitHub build and installation.
Do not install a failed run or identify build 4 as the new GitHub package. Verify the downloaded
package checksum, source commit, application version and signature; preserve the old app.
