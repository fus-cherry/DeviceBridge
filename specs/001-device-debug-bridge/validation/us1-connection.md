# US1 Connection Validation

**Date**: 2026-09-07  
**Host**: Apple silicon Mac, macOS 26.6, Xcode 26.6

## Automated checks

| Check | Result | Evidence |
|---|---|---|
| Core package tests | PASS | `swift test --package-path packages/DeviceBridgeCore`; 43 tests in 11 suites |
| Native Mac app and UI tests | PASS | `xcodebuild test -quiet -project apps/macos/DeviceBridge.xcodeproj -scheme DeviceBridge -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO`; fixture refresh/switch test and live-device switch test passed |
| Target-specific readiness | PASS | Android tests require `adb -t <transport_id> get-state`; iOS tests require bounded `devicectl device info details --device <identifier>`; nonzero, malformed, timeout, and cancellation do not publish ready state |
| Session invalidation | PASS | Selection generation, disconnect, transport replacement, operation invalidation, and stale-token publication tests passed |
| Supervision state machine | PASS | Single-flight admission, operation yield, two-failure invalidation, 1/2/4/8-second bounded backoff, verified recovery, and USB preemption tests passed |

## Real-device checks

The inventory and selection checks were read-only and their output was reduced to counts and states;
no device identifier was retained in this record.

| Check | Result |
|---|---|
| Android inventory | 1 authorized USB device; no Android Wi-Fi transport present |
| iOS inventory | 4 paired records with Developer Mode enabled; 1 wired record; no active wireless tunnel |
| Native app discovery | PASS; the live app populated the real sidebar |
| Target-command-gated selection | PASS; the UI automation switched between at least two distinct command-ready devices |
| Wired preference | PASS in fixtures and present in the real inventory |
| Wireless reconnect fault injection | NOT RUN; no active Android Wi-Fi or iOS tunnel was available during this run |

## Remaining qualification risk

The call-site review initially reopened T024/T029 because only the policy was tested. The follow-up
now implements the Android production maintenance actor and workspace wiring, with 131 passing core
tests in 28 suites. [Current maintenance evidence](android-connection-maintenance.md) supersedes the
snapshot-only implementation assessment, not the original real-device observations above.

T091/T024 are complete at core command-fixture scope. T092 now passes its recovery/rebind/device-switch
UI test individually and within the eight-test fixture suite. The prior automation startup timeout
did not recur; [UI evidence](ui-automation.md) records the rerun without attributing an unproven cause.
T029 and wireless fault injection, including T088/T089, remain unqualified. No fresh real-device result
was obtained in this follow-up.
