# Feature Specification: Device Debug Bridge

## Build 6 remaining-work closure (2026-09-08)

The user requested SpecKit planning and implementation of the audited remaining work. Existing
requirements remain authoritative; this section adds completion criteria without erasing prior evidence.

- SC-C01 / US1: measure selection-to-content-ready with a monotonic clock, separating build and
  launch/open cost. Report cold and repeated preparations independently. Preserve selected-device
  authentication, per-attempt cleanup and all cancellation/stale-result guards when optimizing.
  The previously observed ~45-second timestamp difference is not a phased benchmark or a success claim.
- SC-C02 / US2: qualify a known public text copied by another phone app through the visible Mac read
  action, plus long Unicode, explicit empty/unavailable feedback and Command-Return send. Do not read
  unrelated private contents or automatically approve paste prompts. The user's original source app
  is an external reproduction input; a same-origin roundtrip does not substitute for it.
- SC-C03 / US1–US4: record actual denial/locked/disconnect/recovery outcomes when the user can supply
  those conditions, and preserve focused deterministic cancellation/stale-result tests. Keep simulated
  evidence distinct from physical evidence; unavailable physical conditions remain open.
- SC-C04 / US2–US4, US6: use Computer Use for visible text expand/copy/save, screenshot copy/save,
  image preview/export, file controls, and Chinese/English layout. Reconcile historical UI failures
  using current controls and readiness; do not run global macOS XCTest input. Exit owned fixture apps.
- SC-C05: ship a verified local artifact and current completion matrix. Developer ID signing,
  notarization and clean-Mac first use require the corresponding existing identity/environment;
  local development/ad-hoc signing is not evidence of those passes.

VM stability (T064) remains explicitly deferred. iOS wireless content is currently unsupported;
qualify that boundary and record any separately approved wireless implementation scope before changing
transport/security design. The release closure contract is [here](contracts/release-closure.md).

## Approved module navigation (2026-09-07)

- FR-U04: The four automatic-readiness cards switch the content module; only one module is shown,
  with Clipboard selected initially. Selection has a visible border, fill and non-color marker.
  Unavailable modules can be opened to inspect restrictions, but unavailable actions stay disabled.
- SC-U02: Switching modules preserves clipboard/file inputs, image preview/page and memory monitoring;
  inactive modules occupy no layout space or keyboard/accessibility navigation. Readiness refreshes
  never change the selected module. Hidden album thumbnails pause and return to the same page.

## Approved trial-feedback acceptance (2026-09-07)

- FR-U01: Read the complete current textual clipboard (all current text items, not history).
  Support up to 1 MiB UTF-8; excess is an explicit failure, never truncation. Provide an independently
  scrollable/expanded editor, Copy all and explicit Save text; do not auto-poll content.
- FR-U02: Periodic device discovery is visually silent and does not republish timestamp-only inventory
  changes, reorder unchanged rows or lose selection. Manual/initial loading and real status changes
  remain visible; probes and recovery continue.
- FR-U03: Images mode shows a paged thumbnail album with clear selected border/checkmark and original
  download. Images/File transfer uses a genuine selected control, not disabled styling. Load is
  explicit; only the current page is read with bounded work/cache and stale-result protection.
- SC-U01: Test exact long Unicode/current multi-item text and explicit excess, unchanged periodic
  publications, real route/status changes, thumbnail page/cache bounds and selection/source races.
  Release and headless production-model checks must pass; visual acceptance is the user's trial.

## User clarification: Phone images are the primary file workflow (2026-09-07)

US4 must prioritize discovering and retrieving images already on the phone, including photos and
screenshots. Known-path Downloads/app-container transfer alone does not meet this requirement.
Android browsing is implemented; iOS remains unqualified. The user subsequently approved album grid →
preview → original download in FR-U03. The platform design is recorded in `plan.md` and
`contracts/phone-images.md`; new permissions and experimental iOS access still require their own gates.

- FR-P01: Users must be able to discover accessible phone images without typing each remote path.
- FR-P02: The image workflow must support preview and explicit original-file export, with available
  image metadata and source-device attribution. General bidirectional file transfer remains available.
- FR-P03: Distinguish denied, limited, unsupported, disconnected and genuinely empty image sources.
  Do not imply all photos are accessible when only a subset is available.
- SC-P01: On each supported physical platform, discover an existing photo and a screenshot, preview
  them, export their originals, and verify the exported images and source attribution. A generated
  binary file round-trip is not substitute evidence.
- SC-P02: Device switching must invalidate pending image results; no automatic full-library download
  or permission approval is implied by connection/readiness probing.

## Approved addition: Interface language (2026-09-07)

User story: As a team member, I can use the Mac workspace in Simplified Chinese or English without
changing the connected device or interrupting my work. This addition is independent of iOS transport work.

- FR-L01: Offer System, 简体中文 and English before and after selecting a device; default to System.
- FR-L02: Resolve Chinese system preferences to Simplified Chinese; otherwise fall back to English.
  Remember explicit choices across app launches; invalid stored choices fall back to System.
- FR-L03: Immediately translate app-owned controls, readiness, feedback, diagnostics and accessibility
  labels in all five workspace panels. Existing messages also change language.
- FR-L04: Preserve device/application names, identifiers, file paths, clipboard text and data bytes.
  Language selection must not select/reconnect devices, restart monitoring or cancel transfers.
- FR-L05: OS-owned menu/panel chrome and mobile Helper UI follow their host OS and are outside this
  Mac workspace switch. Unknown external diagnostics retain their original safe text.
- SC-L01: A user can switch either direction within two interactions and see updates without relaunch.
- SC-L02: Relaunch retains the chosen language; returning to System restores system-based selection.
- SC-L03: Fixture tests preserve selected device, edited clipboard and path while switching; existing
  connection/content tests remain green. Chinese text remains readable at the default window size.

**Feature Branch**: `001-device-debug-bridge`

**Created**: 2026-09-04

**Status**: Draft

**Input**: User description: "Create a lightweight internal developer utility delivered as one Mac
application. It connects to real Android and iOS devices over wired or wireless debugging without
requiring changes to each Flutter project. It supports device switching, clipboard exchange,
screenshots, image and file transfer, Flutter VM and application memory inspection, automatically
probes readiness, deploys removable device helpers when required, and actively maintains the
session, with special attention to recovering unstable Android wireless-debugging connections."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Connect and Switch Devices Reliably (Priority: P1)

As a Flutter developer, I can see every authorized Android and iOS device connected to my computer,
understand whether each device uses a wired or wireless connection, and switch the active device
without confusing data or operations between devices.

**Why this priority**: Every other function depends on an accurate, stable device session. This is
the smallest useful foundation and the highest-risk part of a multi-device tool.

**Independent Test**: Connect at least two authorized devices, switch between them, disconnect and
reconnect one device, and verify that selection, connection health, and available actions always
match the intended physical device.

**Acceptance Scenarios**:

1. **Given** one authorized device is attached by cable, **When** the utility opens, **Then** the
   device appears with its platform, name, connection health, wired transport, and available actions.
2. **Given** the same device is available by cable and wirelessly, **When** it is discovered, **Then**
   the utility selects the wired path and shows that wired is the active transport.
3. **Given** two or more devices are available, **When** the developer selects another device,
   **Then** all displayed details and subsequent operations belong only to the newly selected device.
4. **Given** an operation is running, **When** the active device disconnects or the developer switches
   devices, **Then** the old operation is cancelled or marked stale and cannot publish its result under
   the new device.
5. **Given** a device is eligible for wireless debugging, **When** the developer follows the displayed
   setup guidance, **Then** the device can appear as a wireless connection with its current health.
6. **Given** an authorized device becomes active, **When** session preparation completes, **Then**
   clipboard, Flutter VM, screenshot, and permitted file-access readiness are checked automatically
   without automatically reading clipboard contents, capturing an image, or downloading files.
7. **Given** an Android wireless session becomes temporarily unreachable, **When** the device and
   computer remain on the trusted network with wireless debugging enabled, **Then** the utility
   detects the loss, attempts bounded recovery, and restores the same device session without manual
   re-pairing whenever the platform still permits it.
8. **Given** the active device has been idle, **When** the developer returns to testing, **Then** the
   utility shows whether the session remained command-ready, recovered automatically, or now needs a
   specific manual action.
9. **Given** a supported capability requires a mobile helper, **When** the developer invokes that
   capability for the first time, **Then** the Mac application installs or updates the helper and
   explains only the platform trust, signing, foreground, or permission action that still requires
   the developer.
10. **Given** an ordinary Flutter development project, **When** the developer connects its running
    debug or profile application, **Then** the primary workflows do not require adding a package,
    initialization call, or other source-code change to that project.

---

### User Story 2 - Exchange Clipboard Text (Priority: P2)

As a Flutter developer, I can read text from the selected device clipboard and write text from the
computer to that device clipboard, subject to the permissions and restrictions of the platform.

**Why this priority**: Clipboard exchange removes a frequent, high-friction step during real-device
debugging and transfers small but important values quickly.

**Independent Test**: On each supported platform, copy a unique text value in both directions and
verify the exact value arrives on the selected device or computer without affecting another device.

**Acceptance Scenarios**:

1. **Given** clipboard reading is available and authorized, **When** the developer requests the
   selected device clipboard, **Then** the exact text is displayed locally with an explicit read time.
2. **Given** the developer enters text, **When** they send it to the selected device, **Then** the
   device clipboard contains that exact text and the utility confirms completion.
3. **Given** the platform blocks clipboard access, **When** the developer attempts the operation,
   **Then** the utility explains the restriction and the recovery action without claiming success.
4. **Given** clipboard data was read, **When** the developer switches devices, **Then** the previous
   value is cleared from the active view or visibly labelled as belonging to the previous device.

---

### User Story 3 - Capture and Retrieve Visual Artifacts (Priority: P3)

As a Flutter developer, I can trigger a screenshot of the selected device, preview it on the
computer, and save or copy it for debugging and issue reporting.

**Why this priority**: Screenshots are the most common visual artifact needed while testing layout
and platform-specific behavior.

**Independent Test**: Display a unique screen on each of two devices, capture from each device, and
verify the correct image can be previewed and saved with its device and capture time identified.

**Acceptance Scenarios**:

1. **Given** screenshot capture is available, **When** the developer triggers capture, **Then** the
   resulting image is previewed and labelled with the source device and capture time.
2. **Given** a captured image is shown, **When** the developer saves or copies it, **Then** the
   resulting image is identical to the preview.
3. **Given** capture fails or permission is denied, **When** the failure occurs, **Then** the utility
   preserves the previous valid preview and displays an actionable error for the failed attempt.

---

### User Story 4 - Transfer Images and Files (Priority: P4)

As a Flutter developer, I can send a selected computer file to an authorized location associated
with the selected device and retrieve an authorized device file or image to a chosen computer
location, with progress and integrity feedback.

**Why this priority**: File exchange supports test fixtures, exported logs, generated files, and
visual assets after the core connection and quick-exchange workflows are trustworthy.

**Independent Test**: Transfer representative text, binary, and image files in both directions,
cancel one transfer, and verify completed files are byte-identical while partial results are not
reported as complete.

**Acceptance Scenarios**:

1. **Given** a source file and a permitted destination are selected, **When** transfer starts,
   **Then** the utility shows the source, destination, active device, progress, and final outcome.
2. **Given** a transfer completes, **When** the destination file is opened, **Then** its content is
   identical to the source and it is accessible from the intended destination.
3. **Given** a transfer is cancelled, times out, or loses its connection, **When** it terminates,
   **Then** it is not marked complete and any partial result is clearly identified or removed.
4. **Given** the requested location is not accessible on the selected platform, **When** it is
   selected, **Then** the utility blocks the operation and explains the permitted scope.

---

### User Story 5 - Inspect Application Memory (Priority: P5)

As a Flutter developer, I can select an authorized running application on the active device and see
its current memory usage and recent trend while reproducing a behavior.

**Why this priority**: Memory inspection is valuable for diagnosing leaks and regressions but is less
frequent than connection, clipboard, screenshot, and file workflows.

**Independent Test**: Select a running development application, collect memory samples while its
workload changes, stop or restart it, and verify the readings, unavailable states, and timestamps
track the selected process only.

**Acceptance Scenarios**:

1. **Given** an eligible application is running, **When** the developer selects it, **Then** the
   utility displays current memory usage, sample time, and a recent trend.
2. **Given** monitoring is active, **When** the application exits or restarts, **Then** the previous
   process readings stop and the utility identifies the changed process state.
3. **Given** the platform does not expose memory information for the selected application, **When**
   inspection is requested, **Then** the utility displays the limitation rather than a fabricated or
   stale value.

### Edge Cases

- A device appears through wired and wireless transports at the same time.
- Two devices report the same display name but have different stable identities.
- A device remains listed by the host after its connection has become unusable.
- Authorization, trust, developer mode, or a capability-specific permission is missing or revoked.
- A device locks, sleeps, reboots, changes network, or changes transport during an operation.
- An Android wireless endpoint changes its address or port while the pairing remains valid.
- Wireless discovery works but the device rejects commands, or commands work while discovery
  announcements temporarily disappear.
- Repeated keep-alive probes time out while a long screenshot or file operation is still making
  progress.
- USB reconnects while a wireless recovery attempt is in progress.
- An earlier asynchronous result arrives after device switching, disconnect, or operation cancellation.
- Clipboard text is empty, very large, contains Unicode, or contains sensitive-looking content.
- A screenshot is requested while the device screen is locked or protected content is visible.
- A source file disappears, a destination already exists, storage becomes full, or the transfer is
  larger than expected.
- A selected application is not running, restarts with a new process, or cannot be inspected.
- A platform update removes or restricts a previously available operation.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The utility MUST discover all currently authorized Android and iOS devices available
  to the computer through supported wired and wireless connections.
- **FR-002**: Every discovered device MUST display a stable identity, user-recognizable name,
  platform, authorization state, active transport, connection health, and current capabilities.
- **FR-003**: When both wired and wireless connections are usable for the same device, the utility
  MUST prefer wired transport while still indicating the alternate connection.
- **FR-004**: The developer MUST be able to select exactly one active device, and all device data and
  commands MUST be visibly scoped to that active device.
- **FR-005**: Switching or disconnecting a device MUST prevent unfinished or late results from that
  device from appearing as results for another session.
- **FR-006**: The utility MUST refresh discovery and connection health automatically and MUST also
  provide a manual refresh action.
- **FR-007**: For wireless-capable devices, the utility MUST show whether wireless debugging is ready
  and provide actionable setup or recovery guidance when it is not ready.
- **FR-008**: The utility MUST expose a per-device capability status for clipboard read, clipboard
  write, screenshot, image or file retrieval, file sending, and application memory inspection.
- **FR-009**: The developer MUST be able to read clipboard text from and write clipboard text to the
  selected device when the platform and authorization state permit it.
- **FR-010**: Clipboard payloads MUST remain local, MUST NOT be written to diagnostic logs, and MUST
  be cleared or re-labelled when device selection changes.
- **FR-011**: The developer MUST be able to trigger a screenshot of the selected device, preview the
  result, and save or copy the exact captured image.
- **FR-012**: Saved screenshots MUST include enough source metadata in the interface to identify the
  device and capture time without embedding private payload data into logs.
- **FR-013**: The developer MUST be able to send a selected computer file to a permitted destination
  associated with the selected device and retrieve an authorized device file to a chosen computer
  destination.
- **FR-014**: File and image transfers MUST display source, destination, active device, progress or
  indeterminate activity, cancellation availability, and a terminal success or failure state.
- **FR-015**: A completed transfer MUST preserve source content exactly; an interrupted or invalid
  transfer MUST NOT be presented as complete.
- **FR-016**: The developer MUST be able to choose from eligible running applications on the active
  device and view current memory usage with sample time and recent trend when supported.
- **FR-017**: Memory monitoring MUST stop or reset when the selected device changes, the application
  exits, or the inspected process identity changes.
- **FR-018**: Unsupported, restricted, or unavailable operations MUST be disabled or blocked with a
  platform-specific reason and, when possible, an actionable recovery step.
- **FR-019**: Long-running operations MUST keep the interface responsive and MUST surface activity,
  timeout, cancellation, disconnect, and final outcome states.
- **FR-020**: The utility MUST NOT upload device content or operation data and MUST NOT retain
  clipboard values, screenshots, transferred content, or memory samples beyond the active session
  unless the developer explicitly saves them.
- **FR-021**: The utility MUST provide concise diagnostic information for failed operations without
  recording clipboard payloads, file contents, image contents, or secrets.
- **FR-022**: The primary workflows MUST be available from one application window without requiring
  account creation, cloud service access, or unattended device control.
- **FR-023**: After an authorized device becomes active, the utility MUST automatically probe
  clipboard exchange, Flutter VM availability, screenshot capture readiness, and permitted mobile
  file-access scopes and display each result independently.
- **FR-024**: Automatic readiness probes MUST validate availability without reading or retaining
  clipboard contents, creating a user artifact, or enumerating/downloading file contents unless the
  developer explicitly initiates that data operation.
- **FR-025**: The utility MUST maintain a lightweight health supervision loop for the active
  connection and distinguish healthy, suspect, reconnecting, recovered, action-required, and
  disconnected states.
- **FR-026**: Health supervision MUST yield to active operations, MUST NOT start duplicate probes, and
  MUST NOT report a connection failure solely because a known long-running operation occupies the
  transport.
- **FR-027**: When an Android wireless connection becomes unhealthy, the utility MUST retry the known
  endpoint with bounded backoff, refresh discoverable endpoints, verify the stable device identity,
  and resume new operations only after a target-specific command succeeds.
- **FR-028**: A recoverable wireless interruption MUST preserve the selected physical device while
  invalidating the old transport generation so that late results cannot publish after reconnection.
- **FR-029**: The utility MUST prefer a newly healthy wired connection for subsequent operations, but
  MUST NOT silently migrate an operation already in progress between transports.
- **FR-030**: Android keep-alive support MUST be visible and stoppable, and the utility MUST explain
  that device power policy, disabled Wi-Fi, disabled wireless debugging, network isolation, reboot,
  or revoked pairing can still require manual recovery.
- **FR-031**: Closing the desktop utility, deselecting a device, or explicitly stopping maintenance
  MUST stop its health supervision, pending reconnect attempts, and any associated mobile keep-alive
  session.
- **FR-032**: The utility MUST be installed and operated as one Mac application; normal use MUST NOT
  require the developer to separately install or launch a general-purpose companion application.
- **FR-033**: When a capability requires a mobile helper, the Mac application MUST detect the helper,
  install or update the compatible helper build, start it when the platform permits, and report any
  trust, signing, foreground, or permission step that still requires developer action.
- **FR-034**: Device helpers MUST be limited to debugging functions, MUST be removable, MUST expose
  their active background behavior to the developer, and MUST stop leases or continuous activity when
  the Mac session ends or the developer requests it.
- **FR-035**: The primary workflows MUST NOT require modifying the Flutter project being debugged. A
  future project-integrated extension MAY add deeper app-specific data, but its absence MUST NOT block
  device discovery, switching, screenshot, supported clipboard exchange, permitted file transfer,
  host-visible memory inspection, or Flutter VM discovery.

### Key Entities

- **Device**: A physical Android or iOS device, identified independently from its display name and
  associated with its authorization state and available transports.
- **Connection Session**: The current usable relationship with one device, including selected
  transport, health, lifecycle state, capabilities, and generation used to reject stale results.
- **Connection Supervisor**: The active session's health, keep-alive, recovery schedule, last
  successful command, and reason for any manual intervention.
- **Device Capability**: Whether a specific operation is available, restricted, unavailable, or
  requires action, together with the human-readable reason.
- **Target Application**: An eligible application process selected for inspection, including its
  identity, running state, and relationship to the active device session.
- **Device Operation**: A screenshot, clipboard, transfer, or memory request with source device,
  lifecycle, progress, cancellation, timestamps, and terminal outcome.
- **Artifact**: A screenshot, image, or retrieved file made available for local preview or explicit
  saving and associated with its source device and operation.
- **Memory Sample**: A timestamped memory reading associated with one target application process and
  used to form a short-lived recent trend.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a controlled test, 95% of already-authorized wired devices appear with correct
  identity and connection status within 5 seconds of launching or manually refreshing the utility.
- **SC-002**: Across 100 consecutive wired operations on a stable device, at least 99 complete on the
  intended device without an incorrect-device result or silent failure.
- **SC-003**: After switching the active device, the interface reflects the new selection within
  1 second and zero results from the previous session appear as results for the new device.
- **SC-004**: Developers can complete a supported clipboard transfer in either direction within
  3 seconds for text payloads up to 100,000 characters.
- **SC-005**: Developers can trigger, preview, and save a supported screenshot within 5 seconds,
  excluding time spent choosing a save destination.
- **SC-006**: Completed file transfers up to 500 MB are byte-identical to their sources in all
  acceptance tests, and no interrupted transfer is reported as complete.
- **SC-007**: Available memory information is refreshed and visibly timestamped at least once every
  3 seconds while monitoring is active.
- **SC-008**: In usability testing, at least 90% of first-time users complete device selection,
  screenshot capture, and one clipboard transfer without external documentation.
- **SC-009**: Permission denial, disconnect, timeout, cancellation, and unsupported-capability tests
  produce an explicit non-success state in 100% of cases.
- **SC-010**: A privacy review finds zero clipboard payloads, transferred file contents, screenshot
  contents, or secrets in default diagnostic logs or unrequested network traffic.
- **SC-011**: On a reference computer, the utility reaches an interactive device view within
  3 seconds and remains responsive during discovery, monitoring, and large transfers.
- **SC-012**: Clipboard, Flutter VM, screenshot, and file-access readiness results are visible within
  10 seconds of selecting an already-authorized, command-ready device, with one result allowed to
  remain independently pending or unavailable without blocking the others.
- **SC-013**: In a four-hour Android wireless-debugging test on each reference device, the session is
  command-ready for at least 99% of sampled checks, and recoverable transport drops return to a
  command-ready state within 15 seconds in at least 95% of trials without manual re-pairing.
- **SC-014**: Across 100 injected wireless drop-and-recovery trials, zero stale pre-reconnect results
  update the recovered session and zero operations are sent to a different physical device.
- **SC-015**: Automatic health and readiness probing retrieves zero clipboard payloads, screenshot
  artifacts, or file contents before an explicit developer data action.
- **SC-016**: A first-time developer can install one Mac application, connect an already-authorized
  device, and reach the device workspace without manually installing a separate mobile application or
  modifying the Flutter project under test.
- **SC-017**: In helper-required acceptance tests, an absent or outdated helper is installed or
  updated from the Mac workflow, and every remaining device-side action is stated explicitly rather
  than failing as an unexplained setup error.

## Assumptions

- The initial release targets a single developer using a macOS computer and personally controlled or
  explicitly authorized Android and iOS devices.
- The developer has enabled the trust, developer, pairing, and debugging settings required by each
  device platform before using restricted capabilities.
- Wired connectivity remains the reliability baseline. Wireless sessions are actively supervised and
  recovered when possible, but still depend on device eligibility, valid pairing, and local network
  conditions.
- The initial release is for a small trusted development group. The Mac application may automatically
  deploy a removable debug helper or test runner to an authorized device. A persistent Android status
  notification during keep-alive and the associated additional battery use are acceptable tradeoffs
  when clearly shown and stoppable.
- The developer may still need to enable platform trust, Developer Mode, debugging, signing, or a
  foreground permission prompt; "one Mac application" means those steps are guided and orchestrated
  from one workflow, not that mobile operating-system security requirements are bypassed.
- A project-integrated Flutter debug package is outside the required baseline and may be specified
  later only for deeper access to application-private state or custom diagnostics.
- "Keep active" means continuously detect health and recover eligible failures; it cannot override a
  user disabling Wi-Fi or wireless debugging, network isolation, revoked authorization, or a device
  reboot that requires user interaction.
- Clipboard access may differ by platform and device state. The product reports actual capability
  rather than promising unrestricted system-wide access on every device.
- File access is limited to locations the platform and developer authorization make available; broad
  browsing of protected device storage is outside the initial scope.
- Application memory inspection applies to eligible running development applications and may not be
  available for protected or unrelated processes.
- Captured or transferred content is session-only unless the developer explicitly chooses a local
  save destination.
- Account systems, cloud synchronization, unattended remote control, destructive device management,
  and production fleet management are outside the initial release.
