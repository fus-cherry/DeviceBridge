# Computer Use native-service crash investigation — 2026-09-08

## Initial conclusion (before the build 6 workaround)

The observed `native pipe closed before response` is downstream of an actual
SkyComputerUseService crash. Repeated reports share an Array.remove(at:) assertion
and the same first native caller offset. No local fix has been verified.
Window-tree processing is a working hypothesis, not a symbolicated root cause.
The exact offending element, invalid index and source-level defect remain unknown.

## Environment and integrity

- macOS 26.6 (25G72), arm64.
- Desktop app: 26.901.51231, /Applications/ChatGPT.app.
- Unified Computer Use plugin: 26.901.51231; @oai/sky: 0.6.26.
- Native service: 26.831.1000926 (1000926), UUID 10a60435-199f-373b-b92d-2ec7971e1670.
- Installed service and desktop-bundled service binaries have identical SHA-256:
  `25e9141499b94c396f39afbdb7b19ed8f49e45dc8c61be61028ceab8f3807ce6`.
- Both app bundles pass `codesign --verify --deep --strict`.
  Different plugin/native version strings alone do not establish an incompatibility.

## Reproduction and controls

All UI probes used cua_repl. No alternative desktop input or permission change was used.

1. Reset CUA JavaScript session and get DeviceBridge Build 4 by exact app path.
   Fresh attempts sometimes return the initial device list successfully.
2. Raise window / click device row: no observable selection change.
3. Screenshot retrieval, later action or target-state retrieval produces a closed pipe.
   A double-click + Return batch failed; the exact action completed before failure is unknown.
4. User restarted Codex and exited DeviceBridge. Reopening reproduced the sequence.
5. Fresh control in this investigation: get Finder succeeded; a second full Finder
   AX read with disableDiffing:true also succeeded. Selecting DeviceBridge next
   failed, producing report SkyComputerUseService-2026-09-08-183126.ips.
   This target-specific control does not prove all other apps work or identify a
   particular SwiftUI element. disableDiffing was tested only on Finder, not DeviceBridge.

Resetting the JS session does not repair the native crash. The inspected native transport
already drops closed transports and requests the host to ensure the native service on
new connections; therefore a generic retry patch would not address the reproducible defect.
The same installed and bundled bytes provide no evidence that reinstalling the same version
would help. Initial AX reads and Finder control provide no evidence supporting a permission reset.

## Crash evidence

Inspected 25 reports; 25 share the checked four-frame signature.

```text
EXC_BREAKPOINT / SIGTRAP
libswiftCore: _assertionFailure
libswiftCore: Array.remove(at:)
SkyComputerUseService + 6550512 (0x63f3f0)
SkyComputerUseService + 7502544
SkyComputerUseService + 6519592
SkyComputerUseService + 6518936
SkyComputerUseService + 6523280
libswiftCore: Sequence._compactMap
... recurring native / compactMap frames ...
```

The current binary does not resolve these native callers using atos. Symbols/strings indicate
AX-tree processing exists in the binary but do not map the fault to a named routine.
Raw reports stay in ~/Library/Logs/DiagnosticReports; this summary omits UI contents and
unrelated process details. No report has been sent externally.

## Repair boundary and next discriminating evidence

No service binary, signed desktop app, plugin cache, permissions or DeviceBridge production
source was modified. The official setup/troubleshooting documentation does not describe this
specific native assertion: https://learn.chatgpt.com/docs/computer-use .
A service build with symbols or an official fixed version is needed to locate/fix the native
caller directly. A future target-side workaround needs a reduced UI reproducer demonstrating
which element triggers the fault; the present evidence does not justify speculative UI changes.
When a candidate fix is available, repeat the exact DeviceBridge selection, full AX read,
window screenshot and harmless input sequence, with Finder as the control. Require no new
matching native crash before resuming the phone clipboard/screenshot acceptance.

## Public issue follow-up — 2026-09-08

GitHub issue and comments API checked: #28933, #32293 and #34432 remain open.
Their retrieved comments contain reporter/community analysis and a duplicate-detection bot,
not an OpenAI maintainer confirmation of a shipped fix.

- https://github.com/openai/codex/issues/28933 — June 18 minimal SwiftUI topology reproduction.
- https://github.com/openai/codex/issues/32293#issuecomment-4940886542 — July 11 reporter
  disassembly identifies an invalid collection-removal index; exact-path targeting and
  duplicate-installation isolation did not prevent the failure.
- https://github.com/openai/codex/issues/34432#issuecomment-5345313743 — August 19 community
  A/B report matches Array.remove(at:) plus recursive compactMap. Replacing a GroupBox
  around a mixed AppKit text/scroll subtree with equivalent layout reportedly preserved
  the full accessibility tree and prevented that reproduction. This is a workaround,
  not an upstream fix or proof of the current DeviceBridge trigger.

DeviceBridge ClipboardView uses GroupBox and a TextEditor descendant. This gives a concrete
local A/B candidate, but the macOS native subtree and other failing surfaces still need
controlled verification. No code change was made during this research.

No specific matching fix was found in https://learn.chatgpt.com/docs/changelog .
The absence of a found record does not establish that no private fix exists.

## Local GroupBox A/B candidate — build 5

Baseline: a fresh CUA session targeting the running build 4 again returned
`Sky Computer Use native pipe closed before response` before editing.
Candidate: ClipboardView alone replaces its outer GroupBox with a layout VStack,
padding, rounded background and decorative border. Existing text editor, buttons,
identifiers, handlers, sheets and invalidation hooks remain unchanged. Only the
decorative border is hidden from accessibility; no interactive descendants are hidden.

Release 0.1.2 (5) compiled successfully; strict deep codesign verification passed
for both the build product and copied app. Candidate app:
`dist/DeviceBridge-0.1.2-build5-cua-20260908/DeviceBridge.app`.

Post-change Computer Use verification is pending. The old build 4 remains running,
so the user was asked to exit it manually before the candidate is launched. This is
a candidate workaround and is not yet confirmed to avoid the service crash.

## Discriminating fixture checks and final candidate — build 6

Build 5 failed: initial no-selection AX tree returned, device-row click produced no visible
change, then full AX read closed the native pipe. The clipboard-only GroupBox substitution
was insufficient. That experimental ClipboardView change has now been reversed exactly.

A separate CUA-only harness compiled the production views and WorkspaceViewModel against
the Core static product. It uses --fixture-devices and a HostCommandRunning implementation
that throws for every host command; the selected device is the synthetic iOS Test Device.
These windows cannot prove actual iPhone transfer. Harness and generated source snapshots
remain under `.build/cua-isolation-20260908/` for this investigation. They are not packaged
in the delivered production app.

| Fixture surface | Observation |
|---|---|
| Clipboard alone with layout wrapper | Full AX, setValue and window screenshot succeeded |
| Full workspace with clipboard layout wrapper; original readiness GroupBox | Initial getApp failed with native pipe closed |
| Full workspace with both clipboard and readiness layout wrappers | AX, editing, window screenshot and full AX succeeded; simulated capture produced preview |
| Full workspace with original clipboard GroupBox; only readiness layout wrapper | AX, editing, window screenshot, module switch, simulated capture, return to preserved editor text all succeeded |

The first successful fixture capture action once returned AXError.failure although a fresh
full AX snapshot verified its completed preview; this is distinct from a native service crash.
The final readiness-only variant's capture returned a normal diff containing the preview.

This supports changing the **Automatic readiness** GroupBox only. Production WorkspaceView
now uses a plain VStack with the same heading and module controls. No descendants are
hidden, no callbacks/state ownership changed, and all existing ClipboardView grouping,
editor and feedback identifiers remain as before build 5. The concrete test distinguishes
this container from the initially suspected text-editor wrapper.

Release 0.1.2 (6) compiled and strict deep signature verification passed on source and copied
app: `dist/DeviceBridge-0.1.2-build6-cua-20260908/DeviceBridge.app`. Formal app / physical
device verification is pending the user's requested quit of build 5. Do not call the real
clipboard or connection problem fixed based on these synthetic-device checks.

## Build 6 formal app verification — passed scoped checks

After the user quit build 5, process inventory confirmed no DeviceBridge process. Computer Use
opened the exact copied build 6 (PID 162), selected the physical iPhone, read the full selected
device AX tree and captured the app window. The former failure sequence now succeeded.
The helper remained PID 97317 through the test and subsequent process verification.

On the already-authorized public-text trial:

1. Set the editor to `DeviceBridge test 20260908 build6` (33 UTF-8 bytes).
2. Send to iPhone; UI reported Sent.
3. Clear the editor; UI showed zero bytes.
4. Read from iPhone; UI reported Read and returned the exact 33-byte fixture.
5. Switch to screenshots and perform ten captures. Each returned a preview plus a fresh
   timestamp and 1170×2532 dimensions.
6. Return to clipboard, clear it again and read. The exact same fixture returned.

Capture-click plus AX-result-confirmation times (milliseconds):
`1954, 1894, 2414, 1923, 2027, 1852, 1964, 1974, 1954, 2027`.
Range 1.852–2.414 seconds; mean 1.9983 seconds. These measurements include CUA overhead
and are not pure device capture latency. Selection was observed at 18:49:22 and the ready
page showed a connection check at 18:50:07; preparation was not precisely benchmarked.

Only the Automatic readiness GroupBox is replaced in the final production change. The
clipboard GroupBox is restored. This is a verified target-app workaround, not a repair to
OpenAI's native service binary. Long-duration stability, arbitrary clipboard formats and
protected/locked/denied states are not established by the short positive test.

DMG: `dist/DeviceBridge-0.1.2-build6-macOS-arm64-20260908.dmg`; SHA sidecar adjacent.
Three successful fixture apps were quit via CUA. The failing CUA Workspace Layout fixture
window remains available as a counterexample; it may be closed manually. Dock inspection
for cleanup timed out, but subsequent supported fixture-app quit actions succeeded.
