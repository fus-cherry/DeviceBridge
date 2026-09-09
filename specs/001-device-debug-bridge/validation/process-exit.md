# Child-Process Exit Regression

Date: 2026-09-07. Scope: T093.

The full Swift suite stalled for over a minute. A process-tree check showed no remaining child
command, while a sampled stack showed `ProcessBox.waitForExit` blocked inside Foundation
`NSConcreteTask.waitUntilExit`. The detached blocking waiter prevented its enclosing task group from
finishing even after the timeout path ran.

The original six command-boundary tests passed when run alone. Adding 30 consecutive `/usr/bin/true`
launches reproduced a second stall; its sampled stack had the same blocking wait. Only these
task-owned stalled test processes were terminated. No device commands were involved.

The process boundary now registers a termination handler before `Process.run()`. A lock protects one
terminal exit status and its waiters. An exit is retained for a waiter that arrives later; pending
waiters resume outside the lock. Repeated waits during failure cleanup consume the same terminal
status without creating another Foundation run-loop wait. Process ownership, argument arrays,
stdout/stderr handling and error mappings are otherwise unchanged.

Verification:

- `swift test --package-path packages/DeviceBridgeCore --filter HostCommandRunnerTests`: PASS,
  7 tests including 30 rapid exits, timeout, cancellation, dual output, nonzero and output limit.
- `swift test --package-path packages/DeviceBridgeCore`: PASS, 112 tests in 25 suites.

The rapid-exit test is a scheduling regression, not proof that every OS-level process failure is
bounded. Termination escalation and incremental output limits are outside this focused change.
