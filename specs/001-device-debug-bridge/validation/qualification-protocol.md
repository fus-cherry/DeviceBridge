# Quantitative Qualification Protocol

Date: 2026-09-07. Protocol only; no measurements or acceptance passes are implied.

## Reference Conditions and Evidence

Record the exact app build, macOS/Xcode/ADB/helper versions, Mac chip/RAM, device model/OS, and test
network conditions. Use aliases A/B and anonymous participant numbers; never record UDIDs, endpoints,
nonces, VM URIs, clipboard values, images or transferred contents. Fix the reference matrix before
testing: at least one supported Android and iOS device; Android includes each OEM model intended for
the internal team. A result applies only to the tested matrix.

Use monotonic timestamps captured at the stated boundary. Persist only aggregate durations,
non-sensitive outcome codes, trial numbers, platform/transport labels, and wrong-target/stale counters.
Record numerator AND denominator, raw duration samples, exclusions with predeclared reasons, and the
command/build used. Missing samples or aborted required scenarios are NOT RUN/FAIL, never PASS.
Use synthetic text, generated image/file fixtures and a test Flutter app.

## T086 — First-Use Usability (SC-008)

Recruit 10 first-time users who have not seen the workflow. On a prepared reference host and authorized
device, ask each to select a device, capture a screenshot and transfer clipboard text. Five use
Android, five use iOS. Do not provide documentation or coaching; record platform permission actions
separately. Record whether all three actions completed, assistance requested and where the user got
stuck. Pass requires at least 9/10 users completing all three without external documentation/help.
Testing by contributors alone cannot pass this criterion. Setup capability must exist before trial.

## T087 — Startup, Readiness and Responsiveness (SC-011/012)

- Run 30 process-cold app launches on the declared reference Mac (not OS-cache-cold). Measure process
  launch to visible, keyboard-responsive device view. Every run must be at most 3 seconds; publish
  all values plus median, p95 and maximum. Measure discovery separately; do not end startup timing
  at process creation or window allocation.
- For each platform, perform 30 selections of an already-authorized, command-ready reference device.
  Measure selection commit to each clipboard/VM/screenshot/file readiness result. Terminal
  unsupported/unavailable is an observable result, not a claimed supported capability. Each result
  must be visible within 10 seconds; an independently pending capability must not block the others.
  Also inject one slow probe per kind and verify the other three finish within the bound.
- During memory monitoring and a 500 MB transfer, exercise tab navigation and cancellation. Record
  input-to-visible-response latency, hangs and cancellation outcome. Operationalize “responsive” as
  no main-thread stall over 1 second on these actions; this is a declared test gate, not a new product
  performance claim. Store the trace summary and maximum host RSS.

## T088 — Android Wireless Soak (SC-013)

For each reference Android device, run at least four continuous hours in the selected Wi-Fi session.
Record command-ready observations on a fixed 5-second grid (2,880 expected checks in four hours).
Report successful/expected checks and duration; a missing observation cannot be counted as ready.
When a content operation owns the transport, its successful bound command can supply the observation
without starting a competing health probe. If it supplies no timely evidence, mark that sample unknown
and include it as non-success in the denominator.

Pass requires at least 99% command-ready observations per device. Run at least 100 temporary,
recoverable drops per device and record detection, network availability restoration and verified
command-ready timestamps. Recovery latency runs from first observed failure to verified recovery;
also report restoration-to-recovery time so the unavailable-network period is visible. At least
95/100 eligible drops must recover in at most 15 seconds without manual re-pairing. Plan short
interruptions for this threshold and record longer-loss scenarios separately before testing.

Preclassify tests: temporary link loss/endpoint change are recoverable; revoked pairing, disabled
wireless debugging or Wi-Fi, network isolation and reboot require a device action when indicated by
the platform. Do not relabel a slow recoverable trial after it fails. All classifications and manual
actions remain in the evidence. Include idle/screen-off, long transfer, USB arrival, Stop, host exit
and lease expiry. USB arrival is a separate preference test and cannot boost the Wi-Fi availability
numerator. Do not disable personal network services to inject failures.

## T089 — Recovery Races (SC-014)

Use a deterministic command runner and the production session/recovery orchestration. Run 100 trials:
20 each with delayed old success, delayed old failure, wrong-device endpoint, USB arrival, and
selection away/back during recovery. Vary release ordering and record a reproducible schedule seed
per trial. Capture dispatched target aliases, session generations and publication counters only.
Assert zero commands reach the wrong physical identity and zero pre-reconnect results publish after
generation replacement. At least one assertion per category must fail when its production guard is
removed. A fixture pass qualifies the race invariant; T088/T074 still prove physical connectivity.

## T090 — One-App Installation and Helper Recovery (SC-016/017)

On a second Mac user account/reference host with declared prerequisites, install the exact intended
distribution artifact and connect each already-authorized platform device. Record launch, discovery,
selection and first helper action. The workflow may request unavoidable trust/Developer Mode/signing/
foreground/permission actions, but never manual helper installation or target Flutter source changes.

For each platform test helper absent, compatible, outdated and signing/permission denied; verify that
compatible helpers are reused, others are installed/updated by the Mac workflow, and denials have an
actionable non-success state. Record packaged and installed version numbers, prompts and outcomes.
Pass requires all supported cases; missing iOS provider is NOT RUN, not a platform exemption.
Record archive signature, notarization/stapling and Gatekeeper evidence when qualifying a distributable
build. A local signing-disabled build is only development build evidence.

## Result Record

Each result file names its SC IDs, reference matrix, exact build, date and operator alias, procedure,
sample records or local evidence paths, counts/durations, exclusions, pass/fail decision, and remaining
limitations. T074 links these files and cannot mark final acceptance complete while any required
measurement is absent or failed.
