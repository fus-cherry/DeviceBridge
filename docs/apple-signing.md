# Developer ID signing and Apple notarization

The ordinary Build and Release job remains ad-hoc and never receives the five
Apple Secrets. A fresh `apple-sign` job runs only after the entire build job
succeeds, and only for `fus-cherry/DeviceBridge`, actor `fus-cherry`, and the
explicitly approved `cloud/0.1.8-candidate` branch. Its push starts the approved
signing attempt; a manual dispatch on that same branch requires `sign_apple=true`.
Other development branches, pull requests, main, and tags do not enter this job.
No Release is created or main merged by the signing job.

The app's built-in iOS runner development team is a separate configuration. The owner's current private build uses `5F6294RLX4` for local iOS runner builds and ignores the old editable preference. That does not alter `APPLE_TEAM_ID`, select a Mac Developer ID certificate, or provide any signing key/provisioning profile. Mac distribution still requires the actual P12 identity to match its configured Apple Secret.

## Credential scope

Configure these existing repository Secrets directly in GitHub, never in chat or
source files:

- `APPLE_CERTIFICATE_P12_BASE64`: Developer ID Application certificate and its
  private key, exported as a password-protected P12, then Base64 encoded.
- `APPLE_CERTIFICATE_PASSWORD`: the P12 export password.
- `APPLE_ID`: the Apple account used for notarization.
- `APPLE_TEAM_ID`: the ten-character developer Team ID.
- `APPLE_APP_SPECIFIC_PASSWORD`: an app-specific notarization password, not the
  normal Apple account password.

The job checks presence without printing values. Import must yield exactly one
valid Developer ID Application identity for the specified team. Apple credentials
are validated before signing. Membership, existence of Secret names, or a passing
unsigned build does not prove any of this succeeds.

The signing runner executes no build dependencies or downloaded app. Actions
are pinned to commits. Checkout has no persisted credentials. There is no cache
restore in the signing job. Only the signing step maps Apple Secrets. Its child
tools do not inherit them; required values are passed to Apple's tools without
shell interpolation or tracing, and tool output is captured rather than echoed.
A temporary private keychain is used explicitly on an isolated, short-lived CI
runner. The complete original user keychain search list is preserved. Only the
self-created chain is temporarily appended when missing, then the exact original
list is restored and read back before that chain is deleted. Default keychain,
trust settings, roots and existing keychain access controls are not changed.
No user computer or persistent runner is used. Certificate files and this
keychain are removed in a finally block, including after failures. Accepted
release metadata is written only after restoration and keychain cleanup succeed;
previous notarization submission IDs remain available even if cleanup fails. No private temp directory
is uploaded. Cancellation that terminates the runner is also contained by the
ephemeral GitHub-hosted runner, not a persistent user computer.

Repository Secrets are inherently usable by workflow authors with sufficient
repository access. The branch/actor guard narrows this implemented flow but is
not a replacement for GitHub branch protection. For an ongoing release service,
move the five Secrets to a protected Environment with a required reviewer and a
restricted deployment branch; that account setting requires separate setup.
Do not create new broad permissions or enable untrusted PR code to sign.

## Verification gates

1. Download only this run's build artifact and check the three checksum entries,
   version, build, architecture and full source commit. Reject symlinks, unexpected
   entries and stale artifacts.
2. Mount its DMG read-only, copy the app, and revalidate its helper manifest.
3. Fail closed if the native-code layout changes from the reviewed App and CLI.
   Explicitly sign the bundled CLI and App with Developer ID, secure timestamp and
   hardened runtime. Use the reviewed empty app entitlements, not runtime exceptions.
4. Submit a ZIP of the App with `notarytool`; require status `Accepted`, staple
   and validate the App ticket, then require Gatekeeper executable assessment.
5. Create and sign a fresh DMG containing that stapled App, submit the DMG, again
   require `Accepted`, staple/validate it, and require codesign, hdiutil and
   Gatekeeper DMG assessments.
6. Only after all gates succeed create signed build metadata/checksums and upload
   the `-Apple-notarized` artifact. Signing failure never falls back to ad-hoc
   under that artifact name. The separate normal build artifact stays explicitly
   ad-hoc.

The non-secret outcome summary contains only commit/version/build, success or a
sanitized failure category, and Apple submission IDs. Upload and wait are separate:
a wait timeout retains the submission ID for later status lookup, without blindly
resubmitting a possibly successful upload. It never includes private
keys, passwords, account email or raw credential-tool logs. A rejection requires
review, not relabeling an unsigned package as signed.

This signs the macOS App and bundled CLI. It does not configure the separate iOS
runner's physical-device development signing, and does not establish true-device
feature acceptance.

## Local contract tests

`python3 -m unittest discover -s scripts -p test_apple_signing.py -v`

These use fake commands and fixture packages to validate failure handling,
credential redaction/scope, checksum and identity checks, explicit notarization
and stapling gates, cleanup and upload scope. They do not pretend to contact
Apple or replace the macOS signing job.

## Official references

- [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Apple notarytool migration and keychain credentials](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
- [GitHub certificate handling on isolated macOS runners](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)

## Build143 scoped signing-only repair

The app package remains the already-tested Build143 from immutable app source
`44f515fcad46d806c16e6fccff9ce82e8503a4f0`; it is not recompiled. The reviewed,
repaired signing controls are a separate immutable workflow-run commit
(`github.sha`), with the signer file additionally pinned by SHA-256. Do not
mislabel the repaired script as the unchanged original Build143 signer.

The one-shot `cloud/0.1.8-build143-scoped-signing` workflow checks exact package
and prior failure IDs/digests, successful terminal A/B source/job IDs, and the
unique exact controlled A/B log result before any Apple Secrets are mapped.
That experiment found the original CLI identity lookup missing, then verified
that retaining all search entries and including the owned chain made a new CLI
copy pass strict signature/Team checks. It also verified exact list restoration.
This diagnostic did not sign the complete App or submit any notarization request.
Only actual App and DMG Accepted results plus all original stapling, Gatekeeper,
identity and integrity gates can establish release success.

The new workflow never creates a Release or merges main. Failed or pending Apple
submissions must be inspected using their retained IDs, not blindly replayed.
The isolated runner is used exclusively for this flow; snapshot restoration does
not claim support for arbitrary concurrent keychain-list modifications.
