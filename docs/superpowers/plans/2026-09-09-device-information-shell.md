# Device Information and Android Shell Implementation Plan

> 已暂停的早期草稿，不能作为实现依据。用户要求改用 SpecKit；当前权威入口为 [002 需求规格](../../../specs/002-device-info-shell/spec.md)。本草稿未经评审，保留仅为记录，不继续按其中任务编码。

**Goal:** Read detailed Android/iPhone information and run explicit Android shell commands in the existing workspace.

**Architecture:** Session-bound information and shell models use DeviceSessionStore reservations. Separate providers own bounded platform reads; Workspace creates and invalidates the models. The existing authenticated iOS runner gains a read-only metadata action.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing, existing ADB/CoreDevice tools and TLS runner. No new runtime dependency.

**Spec:** [Design and acceptance criteria](../specs/2026-09-09-device-information-shell-design.md).

## Constraints

Preserve the README AI attribution edit. No commits, pushes, releases, destructive cleanup, device writes or desktop control. Work on `codex/device-info-shell`. Retain existing behavioral tests. Command input 16 KiB, timeout 30 seconds, output 1 MiB, history 20 entries / 2 MiB. Runtime fields are actual queried values with explicit unavailable states.

## Tasks

- [ ] **1. Information provider and runtime metadata.** Add `Models/DeviceInformation.swift`, `Operations/AndroidDeviceInformationProvider.swift`, `Operations/IOSDeviceInformationProvider.swift`, and parser/provider tests under DeviceBridgeCore. Add the `device.info` action and strict typed runtime payload to DeviceBridgeProtocol; negotiate and dispatch through IOSRunnerSessionServer/IOSRunnerChannel. Add the UIKit adapter to the runner. Test overrides/malformed/missing data and wire admission before implementing behavior.
- [ ] **2. Android command panel vertical slice.** Add `Operations/AndroidShellService.swift`, its Core tests, `ViewModels/AndroidShellViewModel.swift`, `Views/AndroidShellView.swift`, and headless model checks. Public entry `execute(_ command: String) async throws -> HostCommandResult` captures one immutable session. `run`, `cancel`, `stop`, `clearHistory` and history selection remain model-owned. Write regressions for exact transport/script, nonzero streams, stale admission/publication, cancellation and retained-history limits before implementing.
- [ ] **3. Workspace integration and information view.** Add `ViewModels/DeviceInformationViewModel.swift` and `Views/DeviceInformationView.swift`. Construct modules after session commit, invalidate on every selection/stop/disconnect, bind runtime channel only after authenticated runner readiness. Extend retained module navigation responsively, with Android-only Shell and bilingual copy. Extend headless scripts' explicit source inputs. Verify late completion after switching and correct platform visibility.
- [ ] **4. Verification and documentation.** Run focused tests first, then affected Swift package suites, headless selection/runner checks, host Release build and iOS simulator build/tests as appropriate. Independently review the command/session boundary and iOS protocol changes. Add concise user instructions for information availability and command semantics to README/development docs; record tested limits and qualification gaps.

## Discriminating checks

`swift test --package-path packages/DeviceBridgeCore --filter DeviceInformation`

`swift test --package-path packages/DeviceBridgeCore --filter AndroidShell`

`swift test --package-path packages/DeviceBridgeProtocol`

`swift test --package-path packages/DeviceBridgeSecureChannel --no-parallel`

`bash scripts/check-device-selection.sh`

`bash scripts/check-ios-runner-workspace.sh`

Headless model checks must gate fake external boundaries with continuations, invalidate the session, then release late replies and assert no report/history publication; a timing-only sleep is not proof. Parsing checks assert semantic values (native vs overridden pixels, byte quantities, unknown battery) rather than copied implementation steps. Shell tests assert no execution after invalidation and no automatic retry, not merely the number of mock invocations.
