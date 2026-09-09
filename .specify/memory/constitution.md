<!--
Sync Impact Report
- Version change: template (unversioned) -> 1.0.0
- Modified principles:
  - Template placeholders -> I. Stable Connection Is the Product
  - Template placeholders -> II. One Authoritative Device Session
  - Template placeholders -> III. Local, Explicit, and Least-Privilege Access
  - Template placeholders -> IV. Honest Cross-Platform Capabilities
  - Template placeholders -> V. Small, Verifiable Vertical Slices
- Added sections:
  - Product and Platform Constraints
  - Delivery and Quality Gates
- Removed sections: none
- Follow-up TODOs: none
-->
# Flutter Device Utility Constitution

## Core Principles

### I. Stable Connection Is the Product
Every device operation MUST run through a connection whose current transport and health are visible.
Wired transport MUST be preferred when both wired and wireless paths are available. A disconnect,
transport change, timeout, or stale device result MUST be surfaced and MUST NOT be reported as a
successful operation. Rationale: a debugging tool is useful only when developers can trust its state.

### II. One Authoritative Device Session
Each physical device MUST have one authoritative session owner for connection state, capabilities,
active operations, and cancellation. Candidate devices, connected devices, and the selected device
MUST be represented as distinct states. Results arriving after device switching, disconnect, or
cancellation MUST be discarded. Rationale: multi-device support cannot allow data from one device to
appear under another device.

### III. Local, Explicit, and Least-Privilege Access
The tool MUST operate only on devices explicitly authorized by the developer. Clipboard contents,
screenshots, files, images, memory samples, identifiers, and logs MUST remain local by default and
MUST NOT be uploaded or retained beyond their stated purpose without an explicit user action.
Permission denial MUST degrade only the affected capability and MUST provide a clear recovery path.
Rationale: developer-device data routinely contains credentials and private user information.

### IV. Honest Cross-Platform Capabilities
The interface MUST expose only operations that the active platform, transport, authorization state,
and device state can actually perform. Android and iOS MAY have different capability sets; unsupported
or restricted operations MUST be labelled with the reason and MUST NOT be simulated as success.
Platform-specific adapters MUST preserve a shared operation contract for success, progress,
cancellation, and failure. Rationale: truthful limitations are safer than misleading parity.

### V. Small, Verifiable Vertical Slices
Delivery MUST proceed as independently usable slices that connect discovery, state, operation,
feedback, and tests. The first slice MUST establish reliable discovery and device switching before
data-transfer features are added. Each slice MUST include focused automated checks and a reproducible
real-device verification procedure. Rationale: small slices keep a low-volume utility maintainable
while exposing device-integration failures early.

## Product and Platform Constraints

- The product is a local developer utility, not a remote device-management or surveillance system.
- Initial scope MUST cover multiple connected Android and iOS devices on a macOS host.
- Wired connections are the reliability baseline; Android and iOS wireless debugging are secondary
  transports and MUST show their availability and setup requirements.
- Initial user-facing capabilities are device discovery and switching, connection health, screenshot
  capture, clipboard read/write where the platform permits it, image browsing or retrieval, file
  transfer, and application memory inspection.
- Destructive device operations, unattended remote access, app-store device management, cloud sync,
  and broad filesystem access are out of scope unless introduced by a later specification.
- The desktop interface MUST remain responsive while devices connect, disconnect, or perform long
  transfers. Every long operation MUST support progress or indeterminate activity, timeout, and
  cancellation where the underlying platform permits cancellation.

## Delivery and Quality Gates

1. Each feature MUST begin with testable scenarios and explicit platform capability assumptions.
2. Stateful flows MUST identify the production entry point, authoritative state owner, publication
   point, stale-result guard, failure mapping, and terminal user-visible effect before implementation.
3. Automated tests MUST protect shared state and command contracts. Adapter integration tests MUST
   cover success, permission denial, timeout, disconnect, malformed output, and cancellation.
4. Real-device checks MUST cover at least one supported Android device and one supported iOS device
   for platform-shared features; a documented platform restriction MAY replace an impossible check.
5. Logs MUST be diagnostic without recording clipboard payloads, transferred file contents, image
   contents, secrets, or other sensitive data by default.
6. Scope additions MUST demonstrate a concrete user scenario and MUST not weaken connection
   reliability, state ownership, privacy, or truthful capability reporting.

## Governance

This constitution governs all specifications, plans, tasks, implementation, and review in this
repository. Amendments MUST state the motivation and impact, update the Sync Impact Report, and use
semantic versioning: MAJOR for incompatible governance changes, MINOR for new or materially expanded
rules, and PATCH for non-semantic clarification. Every planning and completion review MUST verify the
applicable principles and quality gates. Any exception MUST be documented in the active feature plan
with evidence, scope, risk, and an expiry or removal condition.

**Version**: 1.0.0 | **Ratified**: 2026-09-04 | **Last Amended**: 2026-09-04
