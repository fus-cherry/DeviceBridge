# Final Real-Device Validation

## Current Build 7 closure status — 2026-09-08

Build 7 local package is ready. Build 6 CUA verified public long Unicode clipboard roundtrip and
expand/copy/save, screenshot copy/save/cancel, and language/input preservation. New incremental
build-stage samples were 31.128 s cold and 2.596/2.059 s warm with real artifact validation; this is
not full authenticated readiness or a performance-target pass. The new file staging provider passed
a 64 KiB physical backend roundtrip; its updated GUI path still needs Build 7 replacement approval.

Uncompleted: original cross-app paste source, denial/locked/unplug recovery; current iPhone USB-photo
identity matching (GUI asked for reconnect); Build 7 full startup/file-receive UI; Developer ID,
notarization and clean-Mac first use. VM stability remains deferred. Only scoped tasks were checked;
see [the current matrix](release-closure-20260908.md). No fixture app remains; active formal Build 6
was preserved pending replacement coordination.


Date: 2026-09-07

Status: **NOT RUN**

The required device-control path was checked with:

```sh
/opt/homebrew/bin/mobai devices list --json
```

It exited with code 10 because the MobAI desktop API at `127.0.0.1:8686` was not running. No direct
ADB or CoreDevice command was used to inspect or mutate a personal device, and no clipboard, screen,
file, identifier, or application payload was captured.

The following evidence is still required before T074 can be completed (T073 tracks automated checks):

- Android USB and prepared Wi-Fi selection, helper install/update, clipboard read/write, screenshot,
  scoped file transfer, memory sampling, Stop action, and lease expiry;
- Android four-hour wireless run with radio sleep, endpoint change, temporary loss, and USB arrival;
- iOS USB and Wi-Fi discovery, Developer Mode/signing prompts, runner clipboard/screenshot channel,
  CoreDevice file scopes, and switch/disconnect invalidation;
- representative 500 MB transfer, cancellation, restart, permission denial, and payload log audit on
  real devices;
- archive signing, notarization, stapling, Gatekeeper assessment, and launch on a second Mac account.

Tasks T036, T041, T048, T056, T064 and T074 remain open where they depend on the iOS persistent runner
channel or real-device evidence. The iOS completion prerequisites are T082–T084. Quantitative tasks
T086–T090 use [qualification-protocol.md](qualification-protocol.md); this document records their
eventual consolidated result rather than duplicating automated qualification.

T024/T029 were reopened after production-call-site review found the host supervision policy unwired.
T091/T092 must connect and fixture-test it before wireless soak or recovery-race acceptance.
