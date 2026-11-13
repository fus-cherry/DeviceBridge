# Dormant Apple signing-only retry template

These `.in` files do not register or trigger a workflow. There is no default
source commit, run, build number, artifact ID or digest. Do not use failed Build
140: it did not pass its native UI gate and cannot provide an accepted package.
The next successfully validated 0.1.8 build, if any, needs fresh evidence.

Before rendering, the coordinating owner must independently verify and approve:

- The full immutable source SHA, original run ID and exact attempt, plus the
  successful `build` job's exact ID and version/build/arm64 package. Attempt 1 is
  the normal path; only the reviewed Build142 exception below may use attempt 2.
- The latest original `apple-sign` job's ID and completed outcome. If Apple has
  accepted a submission or an upload/wait is uncertain or pending, **do not retry**;
  use the saved submission ID to query that existing request.
- The exact package artifact ID, immutable archive SHA-256, unexpired state and
  source-run binding.
- For the original format-failure mode, the exact non-secret
  outcome artifact ID/digest must prove the known pre-Apple single-line-password
  format rejection with no submission fields. Nothing is inferred from masked
  Secret values. An explicitly verified `not-started` mode permits an original
  skipped Apple job and uses no nonexistent or stale outcome artifact; it still
  requires a successful build and a verified package.

An older outcome artifact can retain the same run-scoped name across attempts.
Its presence, contents or digest alone never proves a later job made no
submission. The preflight therefore requires each package/outcome `created_at`
to fall inside the successful upload step of its exact producing job, using the
attempt-specific jobs endpoint, not `filter=latest`. The producing job ID is
fixed in the policy, the name must be unique within the run, and job state plus
artifact metadata are checked again after download. Missing timestamps or API
clock inconsistencies fail closed; no timing tolerance or latest-file fallback
is silently added.

## Narrow Build142 attempt-2 exception

The only allowed second source attempt is run `43393897512`, source
`479022d1989ccf9ab163bf38ceeb2af329e19016`, Build142. This is a hard restriction,
not a default filled by the renderer. Attempt 1's build job `131781921212` failed
at `Test and sign Android helper` (the reviewed official Maven HTTP429 failure).
Its `Build and verify DMG` and package-upload steps were both skipped, and Apple
job `131789507465` was skipped with no executed steps. Preflight verifies these
exact IDs and states again through the attempt-1 jobs endpoint. The build jobs'
time windows must not overlap. The new attempt-2 build/Apple job IDs and artifact
IDs/digests must still be explicitly reviewed and filled after completion.

For this exception set `source_run_attempt` to integer `2` and `first_attempt` to
`{"build_job_id":131781921212,"apple_job_id":131789507465}`. For an original first
attempt, `first_attempt` must be `null`. Other run/SHA/build combinations, third
or later source attempts, a previous successful build/package upload, or any
previously executed Apple job are rejected. No signed DMG or Apple call has been
made by preparing these templates. This exception does not assert that Build142
will pass its current tests or that it has produced any usable artifact.

Fill every field in a copy of `apple-retry-policy.json.in`. Numeric IDs must be
JSON integers, not strings; version stays `0.1.8`; build is a positive numeric
string. Use `null` for the two outcome fields only in `not-started` mode. Unknown
or unfilled values stop rendering/preflight, rather than selecting latest files.

After explicit approval to queue a new attempt, `render-apple-sign-retry.py`
can produce a frozen policy and a single-use live workflow into a new candidate
checkout. It never commits, pushes or triggers GitHub itself. The allowed branch
is derived exactly as `cloud/0.1.8-apple-retry-build<BUILD>`. Push this branch only
after reviewing the generated workflow and all controls; ordinary release.yml
branch filters do not match it, so the existing app is not rebuilt.

Preflight runs without Apple credentials. It validates API metadata and original
job outcomes, rejects a previous retry on the same fixed workflow/branch and
rejects a second attempt of the signing-only retry itself, downloads the exact artifact archives without forwarding
the GitHub token to blob hosts, checks fixed SHA-256 digests, and safely extracts
only the four approved package files. It rechecks source/job state before local
extraction. This narrows accidental duplicate submissions; it does not authorize
or prevent the owner separately triggering other signing workflows. Do not queue
another original run concurrently or replay an already completed signing retry.

The signing step checks out and runs the **original immutable source signer**, not
an arbitrary changed script from the retry branch. It receives only the existing
five Apple Secrets in that step. It does not trim or rewrite any credential,
alter the iOS owner Team ID, or change `APPLE_TEAM_ID`. App and DMG must both return
Apple Accepted, pass stapling and Gatekeeper verification before upload. The raw
safe outcome (including submission IDs) is preserved even on a signing failure.
No release publication, main merge, package installation or app execution occurs.

Review and test the controls before any real values or queue are approved:

    python3 -m unittest discover -s scripts -p test_apple_retry_input.py -v

These tests use only synthetic packages and mocked API replies, not Secrets,
network requests, Apple submissions, actual artifacts or real device results.

## Narrow Build143 certificate-import exception

The `pre-apple-certificate-import-failure` mode accepts only the complete fixed
`REVIEWED_IMPORT_FAILURE_POLICY` in the verifier: immutable source
`44f515fcad46d806c16e6fccff9ce82e8503a4f0`, run `43400209317`, attempt 1,
build job `131803244551`, Apple job `131817987287`, package `14026812304` and
outcome `14026179737`, with their reviewed archive SHA-256 digests. No field may
be substituted by a later, newer or otherwise similar artifact.

The downloaded original summary must contain exactly six fields: failed status,
`apple_notarized: false`, that full commit, version `0.1.8`, build `143`, and the
exact `Import Developer ID certificate: command failed (exit 1); no secret-bearing
output retained` error. Missing/extra fields, any state/submission data, another
error, another source or another build stop the retry. In that immutable signer,
this failure occurs at `security import`, before identity search, notary credential
validation, app signing or submission. It therefore proves no previous notary
submission for this specific reviewed attempt, not for arbitrary import errors.

The owner approved retrying this already-tested Build143 package after being
shown how to re-export the P12 and update the corresponding Secrets. Nothing
asserts whether the Secrets were changed or that the replacement is valid. The
original signer still performs all certificate/team, signing, Apple acceptance,
stapling and Gatekeeper checks. Do not push a second concurrent queue or rerun the
original workflow. Signed output is withheld unless every original check passes.
