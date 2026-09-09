# iOS Runner Lifecycle Validation

Date: 2026-09-07. Scope: T076/T077 host lifecycle only.

Command: `swift test --package-path packages/DeviceBridgeCore --filter IOSRunnerManagerTests`

Before implementation, five new deterministic tests failed with 18 assertions: stop during build,
stop during open, concurrent prepare, caller cancellation, and old build failure after a replacement
session. Three existing tests passed. The gates deliberately ignored cancellation and returned late.

After implementation, all 11 tests passed. Additional checks cover same-device launch IDs, slow stop
returning after a newer connection, and cleanup/retry after partial launch failure. The build fixture
also observes cancellation on the actual manager-owned task.

Production entry is `IOSRunnerManager.prepare`; the actor owns current launch, preparation task and
connected channel. `buildAndOpen` rechecks attempt/cancellation after external awaits. It publishes
connected only after launcher success. `stop` invalidates state before awaiting attempt-specific
cleanup. Failed/late opens receive idempotent cleanup without touching a newer attempt.

The abstract launcher is still a fixture in these tests. This does not verify a signed install,
physical USB/Wi-Fi route, identity handshake, runner lifetime, system clipboard or real screenshot.
T082/T083/T084/T036 and story real-device tasks remain required.
