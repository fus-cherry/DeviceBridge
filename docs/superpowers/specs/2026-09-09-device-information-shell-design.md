# Device information and Android Shell

> 已暂停的早期草稿，不能作为实现依据。用户要求改用 SpecKit；当前权威入口为 [002 需求规格](../../../specs/002-device-info-shell/spec.md)。本草稿未经评审，保留仅为记录，不继续按其中任务编码。

The user requests detailed device parameters, screen pixels, system versions, and Android shell support. The user selected a command panel with output, exit status, cancellation, and history. This work extends the existing macOS workspace and does not change target Flutter projects.

## Visible behavior

- Add Device Information for Android and iPhone, with explicit Load/Refresh, grouped rows, selectable values, copying the report, loading/error/partial-data presentation, and a capture time.
- Groups: identity/model/manufacturer; OS/version/build/security level; screen native/effective pixels and density/scale; CPU/architecture/core count; physical RAM and data-volume storage; battery; selected connection. Device-reported data only. Missing or restricted fields are explicitly unavailable; no inferred specifications or fabricated zeros.
- Android uses exact-transport ADB read commands. Physical and overridden screen sizes/densities are separate. Storage means the mounted data filesystem, not advertised flash capacity.
- iPhone uses structured CoreDevice details for basic information. The existing authenticated runner supplies UIKit/Foundation runtime information (screen native bounds, logical points/scale, CPU count, RAM, data volume, battery) when available. Basic details remain readable if signing or runner preparation is unavailable. Read-only metadata does not activate an application, capture the screen, or read clipboard/photo/file contents.
- Add Android Shell only for Android. Each explicitly submitted command runs in a fresh noninteractive device shell, with normal Android shell privileges. Multiline scripts/pipes/redirection are supported by the device shell. No Mac shell evaluates user text. Display separate stdout/stderr, exit code, duration and target; cancellation, timeout and output-limit errors are explicit.
- One command at a time per panel; do not retry commands automatically. History is bounded and held only for the selected session, never logged or persisted. New commands do not inherit `cd` or environment mutations from prior commands. Cancel closes the owned ADB command; it cannot undo completed effects or promise to stop detached remote jobs.

## State and effects

Workspace owns selection and creates one information model and one optional shell model for a committed ConnectionSession. DeviceSessionStore remains the sole session/generation and operation-reservation owner. Each model owns only its own state and tasks. Information providers own external reads and parsing, not selection.

Entry: user Load/Run → model admission → capture exact session → store reservation → validate token before external work → exact-route provider/ADB process → recheck cancellation and store eligibility → release reservation and publish into the same model. A model revision prevents late task results after Cancel/Stop from changing current UI. Rebinding, selection, disconnect and workspace Stop invalidate models before cleanup. A stale or cancelled command is never replayed on a recovered route.

Limits: shell input 16 KiB UTF-8, command execution 30 seconds, combined output 1 MiB, at most 20 retained commands and 2 MiB total retained history text/output. Information reads have bounded output and deadlines. Partial read failures must be represented as partial data and not interpreted as empty/zero values.

## Integration and validation

Keep existing clipboard, screenshot, files/images, memory and runner readiness ownership. Add new model files rather than moving old workspace logic. Add operation kinds for information and shell so connection probes cannot run while those operations own a reservation. Screen metadata joins the existing authenticated iOS request slot and bounded replay/deadline validation; it never enters clipboard foreground handling.

Prove: Android parsing handles overrides, missing fields, units and malformed values; raw shell script reaches only the captured ADB transport unchanged; nonzero exits retain both streams; stale sessions cannot start or publish; cancellation prevents late publication; reservations release on all terminal paths; iOS metadata requires negotiation, validates its schema and does not block heartbeat/Stop. Exercise model flows without desktop input, compile host and iOS runner, and preserve the existing test suite.

Only read-only physical probes are suitable for this feature's validation. No test may run arbitrary user commands, restart business apps, install helpers, or manipulate the existing desktop app incidentally. New Release publication requires separate authorization.

References: [ADB shell options](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/user/adb.1.md), [UIScreen native pixels](https://developer.apple.com/documentation/uikit/uiscreen/nativebounds), and local `xcrun devicectl device info details --help` (structured JSON is its supported scripting interface).
