# Android Keep-Alive Validation

Date: 2026-09-07

## Automated evidence

- `KeepAliveServiceTest` passes seven JVM cases covering start, 30-second renewal,
  wrong-lease rejection, expiry, idempotent stop, repeated start, simulated reboot/crash, and
  orderly shutdown.
- `AndroidKeepAliveControllerTests` passes six Swift cases covering Wi-Fi-only activation,
  10-second renewal, device-switch cleanup, idempotent stop, start/stop races, and rejection of a
  lease whose notification is not visible.
- `./gradle testDebugUnitTest assembleDebug` passes for the Android helper.
- `swift test --package-path packages/DeviceBridgeCore` passes 100 tests in 24 suites.
- The macOS UI suite passes all six tests after keep-alive state and controls were integrated.

The Android service uses a `connectedDevice` foreground service, a visible notification with a Stop
action, a non-reference-counted high-performance Wi-Fi lock, `START_NOT_STICKY`, and an exact
lease-expiry callback. The Mac controller renews only the selected Wi-Fi session and stops the lease
before its ADB forward is removed during switching or shutdown.

## Remaining real-device evidence

No Android device was controlled from this run because the configured MobAI desktop service was not
available. A real-device qualification still needs to confirm notification permission behavior,
vendor battery policy, lock release, ADB endpoint recovery, and the four-hour stability target from
`quickstart.md`.

