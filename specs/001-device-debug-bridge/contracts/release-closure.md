# Build 6 release closure contract

Applies to SC-C01–SC-C05 / T115–T128. Existing device, helper and UI contracts remain authoritative.

## Operation and evidence rules

- A preparation measurement starts on explicit selection/preparation and ends at authenticated
  content readiness or terminal failure. Heartbeat timestamps are not its completion event.
- Diagnostics are content-free and bounded. Timing cannot publish readiness or bypass session,
  signature, cancellation, expiry, selected-route or process-liveness checks.
- A reusable build input is not a reusable authenticated channel. Any future build optimization
  preserves immutable per-launch artifacts and fresh bootstrap/identity. Old cleanup cannot remove
  a new attempt's outputs. Unfinished or mismatched source/toolchain/signing/configuration cannot hit.
- Implemented reuse is app-instance-local and serialized through actual build/snapshot completion.
  Every attempt invokes Xcode; failure/cancellation/app restart creates fresh inputs. Snapshots reject
  symlinks, oversized/non-regular xctestrun data and references back to mutable compiler inputs.
- CoreDevice file receive uses an owned temporary destination before the application moves output
  into the service partial path. Cancellation after command completion must prevent that move; the
  service still checks integrity and selected-session validity before committing the chosen file.
- Clipboard reads must verify the declared public source, not overwrite the source before testing
  it. Empty/unavailable is non-success unless an explicit empty text item is returned. Denial advice
  stays capability-local. No automatic permission response or uncertain write retry.
- Export uses a chosen new local file and the current source/session contract. Cancel/failure leaves
  no successful receipt or partial publication; stale device results never become new-device content.
- Mac UI evidence uses Computer Use. Each fixture has an exact owned path/bundle/PID and must be
  exited and checked absent. Never treat a simulated phone as physical evidence.
- A scenario is complete only with its expected result observed on the stated build/control path.
  Backend, simulator, rendered UI, package signature and clean-host evidence are distinct categories.
- Missing Developer ID, notarization credentials, clean host or coordinated phone conditions produce
  an explicit uncompleted prerequisite; they do not authorize permission/credential changes.
