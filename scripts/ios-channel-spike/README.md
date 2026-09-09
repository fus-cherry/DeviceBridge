# T082 USB identity-only experiment

This is contributor test tooling, not a production channel, app feature or recipient dependency.
It never sends clipboard/screenshot/file commands or real nonce values. The iOS test is skipped
unless explicitly enabled through its probe environment. No Mac desktop UI automation is used.

## Headless regression

From the workspace root (system Python 3, Swift compiler; no package installation):

```sh
swiftc helpers/ios/DeviceBridgeRunnerUITests/USBIdentityProbeServer.swift \
  scripts/ios-channel-spike/ProbeServerMain.swift -o /tmp/devicebridge-identity-probe-server
DEVICEBRIDGE_PROBE_SERVER=/tmp/devicebridge-identity-probe-server \
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s scripts/ios-channel-spike -p 'test_*.py'
```

Tests use real local sockets to protect exact USB selection, frame boundaries/limits, persistent
exchange, action/canary/sequence rejection, stop, EOF and idle/partial-frame expiry. They do not
qualify a physical transport. A local-only executable is compiled from the same server source
included in the signed iOS runner, without importing XCTest or launching a Mac app.

## Explicit physical run

First refresh `devicectl device info details` for the explicitly designated physical phone into
a local JSON file. Verify paired/wired/Developer Mode state. Build the iOS runner **Debug** using
the user's selected existing personal development identity/profile. No provisioning updates or
certificate/device registration is part of this script. Supply its exact `Build/Products` path.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/ios-channel-spike/run_physical_probe.py \
  --details-json /tmp/devicebridge-t082-details.json \
  --products /tmp/devicebridge-personal-runner-debug/Build/Products \
  --mode stop --home
```

Repeat with `--mode orphan` to withhold heartbeats, or `--mode reject` to send an unsupported
test action with no payload. `--home` presses Home **on the designated phone**, not on the Mac;
omit it if that phone-side action is undesired. It does not prove locked-screen or long-term uptime.
The harness consumes the exact existing test product and changes only generated test configuration
to resolve build-product paths and discard XCTest attachments (`keepNever`). Diagnostic artifacts
remain in the printed private temporary directory. They contain Xcode device/signing metadata and
the intentionally public canary; do not share them without redaction.

The host captures and targets one exact USB device on every connect, refuses absent/ambiguous USB
routes, and never falls back to Wi-Fi. The phone test owns one IPv4 **127.0.0.1** listener and one
client. It closes the listener immediately after accept. A 30-second idle/partial-frame lease,
90-second maximum connected lifetime, 60-second accept deadline and bounded frame sizes ensure
the experiment is finite. Socket work runs off the iOS main actor. No readiness is published to
Workspace; this server cannot carry production content or be reused as authentication.

## Critical bootstrap result

The public canary sent via `TEST_RUNNER_DEVICEBRIDGE_PUBLIC_CANARY` was found in the physical run's
exported xcresult **action log**, under `commandInvocationDetails.commandDetails`, associated with
the runner environment. It was absent from the authored `.xctestrun` and captured xcodebuild stdout.
Therefore environment-only bootstrap **fails** the no-persisted-secret contract. Do not replace
the public canary with a session nonce, clipboard value or VM URI. Log redaction after the fact is
not a substitute for preventing secret persistence.

See [the experiment evidence](../../specs/001-device-debug-bridge/validation/ios-channel-spike.md)
for physical results and remaining authenticated/wireless gates.

## Replacement secure identity experiment

The external-PSK TLS 1.3 candidate is rejected (Apple TN3213; matching-key local probe failed).
`test_tls_psk.py` remains an opt-in diagnostic, skipped unless `DEVICEBRIDGE_TLS_PROBE` is supplied;
it is not a passing security test or a production dependency.

The replacement uses Apple's swift-certificates source package and Network TLS 1.3 with mutually
pinned ephemeral certificates. Private keys stay in Swift process memory. Only public launch/certificate
metadata is published to the exact runner app container; Python relays TLS ciphertext only.

```sh
swift test --package-path packages/DeviceBridgeSecureChannel
swift build --package-path packages/DeviceBridgeSecureChannel --product DeviceBridgeTLSProbe
PYTHONDONTWRITEBYTECODE=1 python3 scripts/ios-channel-spike/run_secure_physical_probe.py \
  --details-json /tmp/devicebridge-t082-details.json \
  --products /tmp/devicebridge-personal-runner-debug/Build/Products \
  --host-probe packages/DeviceBridgeSecureChannel/.build/debug/DeviceBridgeTLSProbe
```

Refresh exact device details and incrementally build the updated iOS Debug runner first, using only
the selected existing signing identity/profile. The opt-in secure test presses Home on that phone,
not the Mac. It admits 31 fixed-size public identity frames and has a hard 90-second deadline.
No content capabilities are enabled. The first physical pass does not qualify secure idle leases,
long-term background operation, cable changes or Wi-Fi. See the evidence for precise limitations.

For the native exact-USB / single-loopback-client relay (contributor experiment only):

```sh
swift build --package-path scripts/ios-channel-spike/NativeUSBProbe
```

Pass `--native-usb-probe scripts/ios-channel-spike/NativeUSBProbe/.build/debug/NativeUSBProbe`
to the secure physical command above. It receives the captured UDID and launch UUID on stdin, copies
only that launch's public record from the exact runner container, and compares it with the harness
control copy before connecting. Forwarded bytes are never printed or retained. Therefore the native
ciphertext persistence check is explicitly `notCapturedNative`; do not report it as inspected. The
relay must terminate cleanly in addition to the TLS/application and physical XCTest checks. A clean
byte-relay completion alone is not authenticated request success. Phone content and Wi-Fi are still
outside this experiment.

Add `--mode identity` after rebuilding the iOS Debug runner to select
`testSecureUSBManagedIdentityProbe`. This mode uses the actual fresh in-memory nonce/challenge
handshake through `PinnedTLSFrameStream`, followed by a bound Stop (two exchanges, not 31). Its
public audit marker is the Stop request UUID; the nonce/challenge are never emitted. Only identity
and stop are advertised. It is still an opt-in diagnostic, not the production managed-channel test,
and does not qualify clipboard, screenshots, leases, Flutter VM discovery or Wi-Fi. The existing
normal/heartbeat/orphan/invalid/partial/disconnect modes remain unchanged.
