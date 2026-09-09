# Final Automated Validation

## Build 7 closure checks — 2026-09-08

Current full Core run: **381 tests / 57 suites passed**, explicit `--no-parallel`, exit zero
(`/tmp/devicebridge-closure-core-serial.log`). The default concurrent run still exposed a pre-existing
short-deadline VM fixture admission failure; it is retained, not relabeled as a product or VM stability
pass. The dedicated activation/launcher tests now establish their held boundary with a one-second
execution budget while retaining early-expiry coverage.

New build reuse regressions: 33 focused tests passed; two manager instances share inputs but keep
immutable snapshots. Independent falsification/review resolved bounded configuration parsing and
canonical path escapes. File staging: 10 provider/service checks passed and a new real 64 KiB
provider roundtrip matched every byte. Language catalog: 6 tests passed after iPhone empty-state copy
was corrected. Headless inventory/clipboard/memory and iOS workspace capability/Stop/stale-result
checks passed. No app was launched for these checks, no Mac input synthesized, and real VM remained
deferred. Mac Release Build 7 and UI build-for-testing compiled successfully; no Mac XCTest executed.

Local Build 7 app strict signature, packaged app signature and DMG CRC verification passed.
DMG SHA-256: `04297ffd484713c046393b1afd7ac253d10fcd81c9846f5d397d672afd4b6212`.
Helper packaging: 6 tests run, 1 opt-in build test skipped; a separate actual Release build passed.
Detailed scope and remaining physical cases: [release closure](release-closure-20260908.md).


Date: 2026-09-07

## Latest Android image implementation — 16:20

Core: **171 discovered / 163 executed / 8 physical tests skipped**, 35 suites, exit zero.
Android production USB image list/preview/original export passed (135 entries; 1,167,564-byte
1080×2400 screenshot, source/export SHA-256 verified). Native image UI and Chinese/English copy
implemented. Headless production-view-model checks passed plus 20 repeated runs, including preview
replacement cancellation, exclusive export, explicit overwrite and stale save/confirmation rejection.
No desktop UI was launched; iOS images, camera fixture, wireless and isolated UI QA remain pending.
Release build-for-testing explicitly reported **TEST BUILD SUCCEEDED** (compiled app + UI targets,
no UI execution). Final physical rerun: **4 checks passed, 2 mutation checks skipped** — Android
image round-trip, screenshot, memory continuity and iPhone command readiness. These are not iOS
photo/content or wireless qualification.
See [phone-images.md](phone-images.md). Historical results below retain their original scope.

## Latest image-design probe follow-up — 15:33

Default core: **151 discovered / 144 executed / 7 physical cases skipped**, 31 suites, exit zero at
15:33:37. One separately opted-in Android image feasibility case read an existing screenshot, matched
source length/SHA-256 and decoded a thumbnail; camera-photo fixture and iOS photo access remain
unqualified. This planning probe is not a production image-provider or UI pass. See
[phone-images.md](phone-images.md). No production app code, permissions or UI automation changed.

## Latest physical-defect fixes — 15:19

Core: **149 discovered / 144 executed / 5 physical cases explicitly skipped**, 30 suites, exit zero
at 15:18:42. Release build: **PASS**, background build only. Explicit physical run at 15:19:06:
**5/5 PASS**, following an earlier 5/5 pass at 15:15:53. The production helper readiness and process
lifetime fixes now pass without a diagnostic readiness workaround. See
[physical-background.md](physical-background.md) for scope and red/green evidence.
No Mac UI tests ran; T073/T097 remain open. Phone-image browsing was unimplemented in that earlier run,
and this is not iOS content, Flutter VM or wireless endurance qualification.

## Physical follow-up and safe default tests

Background production-adapter checks now have real-device evidence and exposed two product gaps
(helper cold-start readiness and memory lifetime identity). See [physical-background.md](physical-background.md).
At 15:00:44 the ordinary core suite exited zero: 141 discovered tests, including 5 explicitly skipped
physical cases (136 executed), in 30 suites. The skipped cases do not count as real-device passes.
No desktop UI regression was rerun after the user prohibited global input takeover. T073 remains open.

## Latest language-slice rerun

Core: **136 tests / 29 suites PASS** at 14:40:56. Release compilation and bundled Chinese catalog:
**PASS**. Latest full fixture UI run at 14:45:29: **7/9 PASS, 2 FAIL** (keyboard-send feedback and
the language test's initial memory sample, before language switching). The preceding full run passed
the enhanced language test but failed a screenshot AX snapshot query (8/9); screenshot then passed
individually and in the latest run. Cause remains unresolved; these mixed runs are not a green suite.
T073 is reopened; T097 also awaits Chinese visual review because the desktop control pipe is unavailable.
See [localization.md](localization.md) for exact bundles, evidence and remaining limits.

The table below is the **earlier pre-localization baseline**, not the latest all-surface result.

## Results

| Surface | Command | Result |
|---|---|---|
| Swift core | `swift test --package-path packages/DeviceBridgeCore` | PASS — 131 tests, 28 suites; fresh run after Android maintenance and mDNS fallback fixes |
| Privacy audit | Core suite `PrivacyAuditTests` | PASS — 3 tests; payload fixture and untrusted helper-error leakage checks |
| Android helper | Gradle 8.11.1 `testDebugUnitTest assembleDebug assembleRelease` | PASS — 10 JVM tests; Debug and Release APK tasks completed |
| iOS runner | `xcodebuild test` on iPhone 16 simulator, iOS 18.5 | PASS — 6 tests |
| macOS UI | Fixture-only `xcodebuild test` on Apple Silicon macOS 26.6; exact command in [ui-automation.md](ui-automation.md) | PASS — 8 tests, 0 failures, including new recovery/rebind/device-switch test; live test explicitly excluded |
| macOS Release | `xcodebuild ... -configuration Release CODE_SIGNING_ALLOWED=NO build` | PASS |
| Helper package | Independent manifest/artifact checks | PASS — Android version 2, iOS protocol 1, APK SHA-256 matched manifest |
| Release policy | `xcodebuild -showBuildSettings` | PASS — Hardened Runtime on, sandbox off, base entitlements not injected |

The unsigned Android Release output is expected when the four internal signing variables documented
in `README.md` are absent. The distributable Mac archive must package the signed team APK by setting
`DEVICE_BRIDGE_ANDROID_HELPER_APK` and `DEVICE_BRIDGE_ANDROID_HELPER_METADATA`.

## Environment-only warnings

Xcode 26.6 repeatedly reported that no debugger version was available while running UI tests. The
test processes still completed successfully. macOS UI tests require normal local ad-hoc signing;
disabling code signing causes the UI runner to be killed before test bootstrap.

## Qualification status

T073 owns automated qualification only; it passed at the earlier baseline and is now reopened as above. Real-device
acceptance remains in T041/T048/T056/T064 and T074; quantitative checks are T086–T090. No real-device
result is inferred from simulator or fixture tests. Future implementation changes require fresh
checks on their affected surfaces before final acceptance.

The first full rerun hung in `Process.waitUntilExit()` after its child had exited. The focused rapid
exit regression reproduced the hang. After replacing blocking waits with exit observation installed
before launch, the full suite passed with 112 tests. See [process-exit.md](process-exit.md) and
[ios-runner-lifecycle.md](ios-runner-lifecycle.md) for scoped regression evidence.

The previously unwired supervisor now has an Android production command loop and workspace call
sites. T091/T024 core checks pass; T092 now passes its new test individually and within the fixture
suite. Earlier XCTest initialization timeouts and the native automation pipe failure are historical;
the latest runner completed without permission changes by the agent. See [UI evidence](ui-automation.md)
and [maintenance evidence](android-connection-maintenance.md). Final acceptance still requires the
concrete iOS channel and real-device/quantitative evidence. The current UI suite also reports a QoS
priority-inversion runtime warning during clipboard interaction; assertions pass, but this is not
evidence that responsiveness qualification T087 is complete.
