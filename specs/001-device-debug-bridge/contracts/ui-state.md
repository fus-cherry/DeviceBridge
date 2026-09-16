# UI State Contract

## Capability lifecycle correction — 2026-09-16

- Selecting or recovering a device never starts or foregrounds a mobile helper/runner.
- `Available on demand` enables the capability's explicit primary action and explains that the action
  may temporarily foreground a managed helper. It is not rendered as Ready.
- Status, action availability, disabled reason and recovery action come from one capability snapshot.
- A connection-level block is incorporated into that projection; it cannot leave a green Ready label
  beside a disabled primary action without an adjacent reason.
- Same-device selection on a healthy current transport changes no session, input, preview or helper.
- Clipboard foreground preparation begins only after Read/Send. Screenshot runner preparation begins
  only after Capture unless an already-owned compatible runner is reused.

## Window Layout

The Mac application uses one primary window:

```text
┌ Device sidebar ──────┬ Active device header ───────────────────────┐
│ device cards         │ name · platform · transport · health        │
│ wired/wireless       ├──────────────────────────────────────────────┤
│ health/capabilities  │ Clipboard | Screenshot | Files | Memory      │
│ refresh/setup        │ active panel                                 │
│                      ├──────────────────────────────────────────────┤
│                      │ operation status / safe diagnostic summary   │
└──────────────────────┴──────────────────────────────────────────────┘
```

The header and active panel must always show the same selected-device identity suffix. A panel cannot
render actionable content while no active session exists.

## Global Workspace States

| State | Required UI |
|-------|-------------|
| Starting | Non-blocking toolchain and discovery progress |
| No devices | Empty state with refresh and platform setup guidance |
| Devices found, none selected | Device cards enabled; feature panels inactive |
| Selecting | Selected card pending; old device-scoped payload hidden |
| Active, preparing | Header bound to one generation; independent readiness indicators may be pending |
| Active, healthy | Header, capabilities, and panels bound to one generation; last successful health time visible |
| Active, suspect | New destructive/large work paused; health check in progress without hiding current results |
| Reconnecting | Old generation invalidated; retry attempt and next retry visible; new operations blocked |
| Recovered | Same physical device confirmed on a new transport generation; readiness probes rerunning |
| Invalidating | New commands blocked; affected operations cancelling |
| Disconnected | Last device identity visible with reconnect/refresh guidance |
| Tool missing | Platform remains visible with missing-tool recovery; other platform can still work |

## Device Card

Each card displays:

- name and non-sensitive identity suffix;
- Android or iOS;
- wired, wireless, or both-known;
- active transport with wired preference;
- available, degraded, offline, unauthorized, or action-required health;
- helper state when relevant.
- last successful command time and healthy, suspect, reconnecting, recovered, or action-required
  supervisor state;
- Android wireless keep-alive status and a visible Stop action when its lease is active.

Two same-named devices remain separate. A provisional Android transport candidate cannot be visually
presented as merged until managed-helper identity or explicit user association proves the relationship.

## Capability Presentation

| Availability | Button behavior | Required message |
|--------------|-----------------|------------------|
| Available | Enabled | Optional concise precondition |
| Experimental | Enabled only after explicit acknowledgement | Provider and compatibility warning |
| Helper required | Recovery action enabled | Let the Mac app install, update, sign, or start the managed helper |
| Action required | Recovery action enabled | Unlock, pair, trust, enable, foreground, or grant |
| Restricted | Disabled | Platform or policy reason |
| Offline | Disabled | Reconnect guidance |
| Unsupported | Disabled | Honest platform/version limitation |

The UI never converts a non-success operation into a green/success state.

## Device Switch Invalidation

On a selection request:

1. Hide or visibly invalidate clipboard text immediately.
2. Keep saved artifacts, but label their original device.
3. Cancel memory sampling and clear its live trend.
4. Mark active transfers as cancelling; do not migrate them.
5. Increment generation and show selecting.
6. Publish the new header and panels only after the new session commits.
7. Ignore any late result carrying the previous generation.

## Feature Panel Contracts

### Automatic Readiness

- The four readiness cards are also module selectors. Clipboard is selected initially; only its
  panel occupies the content region. Selected border/fill and checkmark supplement an accessible
  selected state. Restricted/unavailable modules are navigable but their content actions stay gated.
- Module selection is presentation-only: probes never change it, and switching does not recreate
  the device session, clear inputs/previews or stop monitoring. Inactive panes are collapsed,
  noninteractive and absent from accessibility navigation. Hidden album thumbnail work pauses;
  returning resumes its current page, not page zero.

- Clipboard, Flutter VM, screenshot, and file-scope readiness begin automatically after selection and
  after a recovered generation commits.
- Each indicator independently shows pending, probing, available, action required, unavailable, or
  failed; one probe never blocks the others or the whole active session.
- The panel states that readiness checks do not read clipboard text, take or retain a screenshot, list
  user files, or download file contents.
- A manually initiated content action is visually distinct from an automatic readiness probe.

### Clipboard

- Shows read time and source device for current text.
- Provides explicit Read and Send actions; automatic readiness checks never poll clipboard content.
- Clears or masks text on device/generation change.
- Shows platform permission prompts as waiting-for-user, not stalled.
- Never retains text in history or diagnostics.
- Reads complete current textual items up to 1 MiB UTF-8, never a truncated success. Longer input
  shows an explicit limit and file-transfer recovery. The editor scrolls independently, supports
  expansion, Copy all and explicit Save text. Saving revalidates the captured device/export epoch.

### Screenshot

- Shows source device, capture time, provider state, and preview.
- Capture writes a new candidate without replacing the current preview.
- Only a validated image replaces the preview.
- Failure preserves the previous valid preview and shows the failed operation separately.
- Save and Copy Image act on the original bytes, not a thumbnail.
- iOS runner setup state is shown separately from warm capture state.

### Files

- Shows direction, source, destination scope, active device, phase, and terminal state.
- Indeterminate progress is acceptable when the host tool has no stable byte-progress contract.
- Cancel is available when the provider can terminate safely.
- Partial files are never shown as completed artifacts.
- Replace-existing requires explicit confirmation.

### Memory

- Requires a selected running app.
- Distinguishes Android PSS/RSS from Flutter VM heap/external/RSS.
- Shows sample timestamp and source.
- Missing fields display unavailable, never zero.
- App exit or PID/start-identity change closes the old series and displays restarted/stopped.
- Deep analysis links to Flutter DevTools or platform profiling tools; it does not imply equivalent
  metrics across providers.

### Connection Maintenance

- Shows active transport, last healthy command, next health check, consecutive failures when nonzero,
  reconnect attempt, and whether a device action is required.
- Normal healthy probes remain quiet; state changes and recoveries appear in the status area.
- Periodic inventory scans do not show refresh spinners/overlays or publish timestamp-only row
  changes. Initial/manual refresh may show progress. Actual device/route/status changes remain visible;
  the store still receives current observations and sidebar ordering stays stable across selection.
- Android wireless keep-alive explains its persistent notification and battery cost and is stoppable
  from both the Mac app and the device notification.
- The UI never says “connection guaranteed.” It names conditions outside the tool's control, including
  disabled Wi-Fi/wireless debugging, network isolation, revoked pairing, reboot, and OEM termination.
- A long active operation suppresses the normal heartbeat and is itself the health signal; the UI
  does not report a false disconnect merely because the heartbeat was deferred.

## Operation Status

Every terminal operation displays exactly one of:

- succeeded;
- failed with safe reason;
- cancelled;
- disconnected;
- stale/ignored.

Stale results may be shown in a developer diagnostics view but cannot display their payload or update a
feature panel. Operation history is bounded and contains only metadata safe for diagnostics.

## Accessibility and Keyboard

- All device cards, tabs, actions, capability badges, progress, and errors have semantic labels.
- Status is not conveyed by color alone.
- Keyboard navigation reaches device selection, tabs, primary action, and cancel.
- Focus moves to an actionable error/recovery summary after a failed command.
