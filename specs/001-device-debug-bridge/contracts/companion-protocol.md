# Managed Helper Protocol Contract

## Capability lifecycle correction — 2026-09-16

Installing, starting, foregrounding and authenticating a helper are operation preparation, not device
connection. Automatic selection/readiness work may inspect host/tool/package metadata but cannot
start the Android Activity or iOS runner. Clipboard success requires an explicit text item (including
an explicitly represented empty item) or a verified write receipt; inaccessible/null/redacted data
is `actionRequired`/`permissionDenied`, never an empty success. Android notification permission is
outside clipboard bootstrap and belongs only to explicit keep-alive start.
Successful iOS clipboard results include
`foregroundDisposition: "runnerRemainsForeground"`; the host surfaces that truthful terminal state
and never claims to restore the prior application when the platform exposes no verified restoration
mechanism. Android results omit the field because its foreground behavior is already explicit in
helper preparation.

## Scope

Version 1 supports only:

- helper-scoped device identity and version negotiation;
- clipboard text read and write;
- screenshot capture through the iOS XCUITest runner;
- narrow file hashing/inbox references when advertised; and
- a visible, lease-bounded Android Wi-Fi keep-alive session.

The protocol does not provide arbitrary device control, background clipboard monitoring, access to
other apps' protected data, or a general remote shell. The developer operates only the Mac app;
`AndroidHelperManager` and `IOSRunnerManager` own helper installation and lifecycle.

## Shared Envelope

Every request contains:

```json
{
  "protocolVersion": 1,
  "requestId": "random single-use identifier",
  "sessionNonce": "random per-session secret",
  "helperDeviceId": "helper-scoped GUID",
  "action": "identity | clipboard.read | clipboard.write | screenshot.capture | file.hash | keepAlive.start | keepAlive.renew | keepAlive.stop | keepAlive.status | stop",
  "createdAt": "ISO-8601 UTC timestamp",
  "expiresAt": "ISO-8601 UTC timestamp",
  "payload": {}
}
```

Every result contains:

```json
{
  "protocolVersion": 1,
  "requestId": "matching request identifier",
  "status": "success | actionRequired | permissionDenied | cancelled | expired | invalid | failure",
  "completedAt": "ISO-8601 UTC timestamp",
  "payload": {},
  "error": {
    "code": "stable safe code",
    "message": "safe user-facing text",
    "recoveryAction": "optional named action"
  }
}
```

`payload` is present only where the action and status permit it. `error` is present only for
non-success results.

## Validation

The helper rejects a request before reading its payload when:

- `protocolVersion` is not exactly 1;
- the request ID was already completed;
- the nonce does not match the active channel/session;
- the helper device ID does not match;
- timestamps are invalid or the request is expired;
- action is outside the platform allow-list; or
- encoded envelope or action payload exceeds its limit.

Default expiry is 30 seconds for identity, clipboard, screenshot, and status operations and 5 minutes
for explicit file operations. Clock skew up to 2 minutes may be accepted only while request age is
still bounded by the active channel.

## Payload Rules

### `identity`

Ordinary identity/heartbeat request payload is empty. The first iOS identity handshake additionally
carries the current public launch identifier and a fresh random challenge, as required by
[the iOS channel contract](ios-runner-channel.md); its response must bind both before readiness.
This iOS bootstrap exception does not change the existing Android identity payload. Success reports the helper device ID, semantic helper version, supported
protocol versions, and advertised actions. Android may advertise clipboard, file hash, and keep-alive;
iOS runner version 1 advertises clipboard, screenshot, status, and stop.

### `clipboard.read`

Request payload is empty. The helper must be foreground when the platform requires it and maps a
pending platform privacy prompt to `actionRequired`. Success returns complete current text up to
1 MiB UTF-8 and a capture timestamp. Android joins all current textual ClipData items with newlines;
it does not retrieve URI streams or clipboard history. Larger text fails explicitly without truncation.

### `clipboard.write`

Request payload contains at most 1 MiB UTF-8 text and an optional sensitivity hint. Success
contains only `{"written": true}` and never echoes the text.

### `screenshot.capture`

Advertised only by the iOS runner. Request payload is empty. Success returns validated PNG bytes or an
operation-scoped attachment reference and capture timestamp. Protected-content or locked-device
behavior is reported explicitly.

### `file.hash`

Request payload contains one unexpired opaque helper file reference and algorithm `sha256`. Success
returns byte length and lowercase SHA-256 digest. The reference is never an unrestricted device path.

### Android keep-alive actions

`keepAlive.start` requires the helper to be visible for first-use acknowledgement or after reboot. It
creates a random lease ID and reports expiry, foreground-notification visibility, and Wi-Fi-lock
state. It never reports ADB as healthy. Renew extends expiry by at most 30 seconds; status does not
renew; stop is idempotent and releases all resources.

The helper stops an unrenewed lease after 30 seconds. The Mac app renews every 10 seconds while the
matching selected wireless session remains active.

## Android Transport

- The Mac app allocates a host port and forwards it through the selected ADB transport to a
  package-owned local-abstract helper socket.
- The Mac app detects installed version, installs or updates the embedded APK, and starts the helper
  activity only when a foreground action is required.
- Frames are a four-byte unsigned big-endian length followed by UTF-8 JSON, with a 6 MiB + 64 KiB
  envelope limit. This accommodates worst-case six-byte JSON escaping for 1 MiB of control text;
  the lower action-text quota still applies. Android helper versionCode 3 implements this contract.
- Clipboard payloads stay in memory and never appear in intents, `am` arguments, logcat, settings, or
  diagnostics.
- The forward is removed when selection or transport generation changes.
- Session end, explicit Stop, or lease expiry releases the Wi-Fi lock and stops the foreground
  service. A helper crash cannot leave a process-owned lock held.
- The helper has no LAN listener, accessibility, keyboard, device-owner, or broad storage privilege.

## iOS Runner Transport

The concrete lifecycle, framing, transport experiment, and go/no-go checks are specified in
[ios-runner-channel.md](ios-runner-channel.md). The channel remains unimplemented until those checks
pass; the following rules are acceptance requirements, not evidence of an available provider.

- `IOSRunnerManager` checks the embedded runner version and signing readiness, then uses Xcode's
  build-for-testing/test workflow to install and start the runner on the selected device.
- The runner accepts requests only through a session-scoped host-to-device channel supplied by the
  selected iOS transport provider; it never opens a general LAN service.
- Host and runner complete the identity, version, and nonce handshake before requests.
- Closing, deselecting, transport replacement, or explicit stop terminates the channel and invalidates
  its nonce.
- If signing, Developer Mode, trust, or transport is unavailable, the result is `actionRequired` or
  `helperRequired`; installation alone is never reported as command-ready.
- Clipboard reads may show platform permission UI and finish only after the developer responds.

## Security and Compatibility

- Nonces use cryptographically secure randomness and are never persisted past the host session.
- Raw device IDs, nonces, clipboard text, file/image bytes, and VM Service URIs are redacted from logs.
- A user cancellation or permission denial is terminal and cannot become success.
- No helper action uploads data or starts unattended remote control.
- A major protocol mismatch produces `helperRequired`; the responsible manager then installs the
  embedded compatible version when possible and reports any remaining device action.
- Unknown fields are ignored only for a supported enclosing action version. Missing required fields
  produce `invalid`.
