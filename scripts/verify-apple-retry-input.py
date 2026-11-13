#!/usr/bin/env python3
"""Fail-closed, non-secret preflight for one explicitly bound 0.1.8 signing retry.

No Apple credentials are consumed here. Artifact IDs/digests and prior outcome
must be reviewed and filled before rendering a live workflow. The app is never
executed, and no previously pending notarization may be resubmitted.
"""
from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import urllib.error
import urllib.parse
import urllib.request
import zipfile

REPOSITORY = "fus-cherry/DeviceBridge"
OWNER = "fus-cherry"
FORMAT_FAILURE = "APPLE_APP_SPECIFIC_PASSWORD contains an invalid line break or NUL"
CERTIFICATE_IMPORT_FAILURE = "Import Developer ID certificate: command failed (exit 1); no secret-bearing output retained"
# Import failed before store-credentials/find-identity/notary in this immutable
# original signer. This exception is bound to all reviewed Build143 inputs.
REVIEWED_IMPORT_FAILURE_POLICY = {
    "source_sha": "44f515fcad46d806c16e6fccff9ce82e8503a4f0",
    "source_run": 43400209317,
    "source_run_attempt": 1,
    "version": "0.1.8",
    "build": "143",
    "source_build_job_id": 131803244551,
    "first_attempt": None,
    "prior_apple_job_id": 131817987287,
    "prior_signing_state": "pre-apple-certificate-import-failure",
    "package_artifact_id": 14026812304,
    "package_digest": "a1901d792fa5e82711736960fbbc32cd6a109398dd7f4674d4ec7a447bddefa7",
    "outcome_artifact_id": 14026179737,
    "outcome_digest": "de3061c8c6777caf8000a940fab5d782783385e291f4d1d5e31326879bf4cb7a",
}
MAX_ARCHIVE = 96 * 1024 * 1024
MAX_JSON = 2 * 1024 * 1024
PACKAGE_UPLOAD = "Run actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
# One reviewed exception only, not a general license to reuse rerun artifacts.
# Attempt 1 failed before packaging and its Apple job never started. The final
# attempt-2 artifact/job IDs and archive digests still have no defaults.
REVIEWED_SECOND_ATTEMPT = {
    "source_sha": "479022d1989ccf9ab163bf38ceeb2af329e19016",
    "source_run": 43393897512,
    "build": "142",
    "first_attempt": {"build_job_id": 131781921212, "apple_job_id": 131789507465},
}


class PreflightError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class GitHub:
    def __init__(self, token: str):
        if not token:
            raise PreflightError("GitHub read token is missing")
        self.token = token

    def _request(self, path: str):
        if not path.startswith(f"/repos/{REPOSITORY}/") or any(c in path for c in "\r\n"):
            raise PreflightError("Unexpected GitHub API path")
        return urllib.request.Request("https://api.github.com" + path, headers={
            "Authorization": "Bearer " + self.token,
            "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
        })

    def json(self, path: str):
        try:
            with urllib.request.build_opener(NoRedirect).open(self._request(path), timeout=30) as response:
                data = response.read(MAX_JSON + 1)
            if len(data) > MAX_JSON:
                raise PreflightError("GitHub metadata exceeds its size limit")
            return json.loads(data)
        except (OSError, ValueError) as error:
            raise PreflightError("Unable to read required GitHub metadata; no token or response logged") from error

    def archive(self, artifact_id: int, expected_digest: str, maximum: int) -> bytes:
        # Authenticated request is never forwarded to an external blob host.
        try:
            opener = urllib.request.build_opener(NoRedirect)
            try:
                response = opener.open(self._request(f"/repos/{REPOSITORY}/actions/artifacts/{artifact_id}/zip"), timeout=30)
            except urllib.error.HTTPError as redirect:
                if redirect.code != 302:
                    raise PreflightError("GitHub artifact download did not return the required redirect") from None
                location = redirect.headers.get("Location", "")
                parsed = urllib.parse.urlsplit(location)
                if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
                    raise PreflightError("Artifact redirect is not a valid HTTPS download")
                # New request deliberately has no Authorization header.
                response = urllib.request.urlopen(urllib.request.Request(location), timeout=60)
            with response:
                payload = response.read(maximum + 1)
            if len(payload) > maximum:
                raise PreflightError("Artifact archive exceeds its download limit")
            if hashlib.sha256(payload).hexdigest() != expected_digest:
                raise PreflightError("Downloaded archive does not match the fixed reviewed SHA-256")
            return payload
        except (OSError, ValueError) as error:
            raise PreflightError("Artifact download failed; no signed URL or token logged") from error


def integer(value, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise PreflightError(f"Fill the reviewed positive numeric {name}; placeholders are forbidden")
    return value


def digest(value, name: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[a-f0-9]{64}", value):
        raise PreflightError(f"Fill the reviewed lowercase SHA-256 {name}; placeholders are forbidden")
    return value


def policy_from(path: Path) -> dict:
    try:
        policy = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise PreflightError("Unable to read the reviewed retry policy") from error
    required = {"source_sha", "source_run", "source_run_attempt", "version", "build", "source_build_job_id", "first_attempt", "prior_apple_job_id",
                "prior_signing_state", "package_artifact_id", "package_digest", "outcome_artifact_id", "outcome_digest"}
    if not isinstance(policy, dict) or set(policy) != required:
        raise PreflightError("Retry policy has missing or unexpected fields")
    if not isinstance(policy["source_sha"], str) or not re.fullmatch(r"[a-f0-9]{40}", policy["source_sha"]):
        raise PreflightError("Fill the exact reviewed source SHA; placeholders are forbidden")
    if policy["version"] != "0.1.8" or not isinstance(policy["build"], str) or not re.fullmatch(r"[1-9][0-9]*", policy["build"]):
        raise PreflightError("Fill the reviewed 0.1.8 build number; no default or other version allowed")
    for name in ("source_run", "source_run_attempt", "source_build_job_id", "prior_apple_job_id", "package_artifact_id"):
        integer(policy[name], name)
    if policy["source_run_attempt"] == 1:
        if policy["first_attempt"] is not None:
            raise PreflightError("An original first attempt must not carry rerun evidence")
    elif policy["source_run_attempt"] == 2:
        if any(policy[key] != value for key, value in REVIEWED_SECOND_ATTEMPT.items()):
            raise PreflightError("Only the reviewed Build142 first-packaging rerun is supported; no generic rerun authorization")
        if policy["source_build_job_id"] == policy["first_attempt"]["build_job_id"] or policy["prior_apple_job_id"] == policy["first_attempt"]["apple_job_id"]:
            raise PreflightError("Rerun jobs must have their own reviewed IDs")
    else:
        raise PreflightError("A third or later source attempt is not supported")
    digest(policy["package_digest"], "package_digest")
    if policy["prior_signing_state"] in {"pre-apple-format-failure", "pre-apple-certificate-import-failure"}:
        integer(policy["outcome_artifact_id"], "outcome_artifact_id")
        digest(policy["outcome_digest"], "outcome_digest")
        if policy["prior_signing_state"] == "pre-apple-certificate-import-failure" and policy != REVIEWED_IMPORT_FAILURE_POLICY:
            raise PreflightError("Certificate-import retry is restricted to the exact reviewed Build143 policy")
    elif policy["prior_signing_state"] == "not-started":
        if policy["outcome_artifact_id"] is not None or policy["outcome_digest"] is not None:
            raise PreflightError("A never-started Apple job must not use a stale outcome artifact")
    else:
        raise PreflightError("Prior signing state could conceal a pending or accepted submission")
    return policy


def retry_branch(policy: dict) -> str:
    return "cloud/0.1.8-apple-retry-build" + policy["build"]


def workflow_path(policy: dict) -> str:
    return ".github/workflows/apple-sign-retry-build" + policy["build"] + ".yml"


def package_name(policy: dict) -> str:
    return "DeviceBridge-0.1.8-build" + policy["build"]


def package_files(policy: dict) -> set[str]:
    return {package_name(policy) + "-macOS-arm64.dmg", "build-info.json", "release-notes.md", "SHA256SUMS.txt"}


def validate_context(context: dict, policy: dict) -> int:
    if (context.get("GITHUB_REPOSITORY"), context.get("GITHUB_ACTOR"), context.get("GITHUB_REF"),
        context.get("GITHUB_EVENT_NAME"), context.get("GITHUB_RUN_ATTEMPT")) != (
            REPOSITORY, OWNER, "refs/heads/" + retry_branch(policy), "push", "1"):
        raise PreflightError("Retry is restricted to one new owner-triggered push on the approved branch")
    value = context.get("GITHUB_RUN_ID", "")
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise PreflightError("Missing retry workflow run ID")
    return int(value)


def timestamp(value) -> datetime:
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z", value):
        raise PreflightError("A required GitHub provenance timestamp is missing or malformed")
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise PreflightError("A required GitHub provenance timestamp is invalid") from error


def attempt_jobs(github, policy: dict, attempt: int):
    # Never use filter=latest to infer a historical attempt's job outcomes.
    jobs = github.json(f"/repos/{REPOSITORY}/actions/runs/{policy['source_run']}/attempts/{attempt}/jobs?per_page=100")
    if not isinstance(jobs, dict) or not isinstance(jobs.get("jobs"), list) or jobs.get("total_count", 101) > 100:
        raise PreflightError("Unable to establish all attempt-specific job outcomes")
    builds = [j for j in jobs["jobs"] if j.get("name") == "build"]
    apples = [j for j in jobs["jobs"] if j.get("name") == "apple-sign"]
    if len(builds) != 1 or len(apples) != 1:
        raise PreflightError("Attempt does not contain exactly the reviewed build and Apple jobs")
    for job in (builds[0], apples[0]):
        if (job.get("run_id"), job.get("run_attempt"), job.get("head_sha"), job.get("status")) != (policy["source_run"], attempt, policy["source_sha"], "completed"):
            raise PreflightError("An attempt-specific job has a different source or is not completed")
    return builds[0], apples[0]


def step(job: dict, name: str, conclusion: str) -> dict:
    steps = job.get("steps")
    if not isinstance(steps, list):
        raise PreflightError("Required job steps are missing")
    matching = [s for s in steps if s.get("name") == name]
    if len(matching) != 1 or (matching[0].get("status"), matching[0].get("conclusion")) != ("completed", conclusion):
        raise PreflightError("A required packaging or signing step did not have the reviewed outcome")
    integer(matching[0].get("number"), "step number")
    return matching[0]


def upload_window(job: dict, name: str):
    upload = step(job, name, "success")
    start, end = timestamp(upload.get("started_at")), timestamp(upload.get("completed_at"))
    if not timestamp(job.get("started_at")) <= start <= end <= timestamp(job.get("completed_at")):
        raise PreflightError("Artifact upload time is outside its exact producing job")
    return start, end


def validate_source(github, policy: dict, current_run: int) -> dict:
    source = github.json(f"/repos/{REPOSITORY}/actions/runs/{policy['source_run']}")
    if not isinstance(source, dict) or (
        source.get("id"), source.get("head_sha"), source.get("head_branch"), source.get("event"),
        source.get("status"), source.get("run_attempt"), source.get("actor", {}).get("login"), source.get("path")) != (
            policy["source_run"], policy["source_sha"], "cloud/0.1.8-candidate", "push", "completed",
            policy["source_run_attempt"], OWNER, ".github/workflows/release.yml"):
        raise PreflightError("Original workflow source, attempt or completion state changed; review again before retry")
    build, apple = attempt_jobs(github, policy, policy["source_run_attempt"])
    if (build.get("id"), build.get("conclusion")) != (policy["source_build_job_id"], "success"):
        raise PreflightError("Original build did not complete successfully; no package may be signed")
    if (apple.get("id"), apple.get("status"), apple.get("conclusion")) != (
        policy["prior_apple_job_id"], "completed", "skipped" if policy["prior_signing_state"] == "not-started" else "failure"):
        raise PreflightError("Original Apple job is new, running, accepted or otherwise not the reviewed failed attempt")
    if policy["prior_signing_state"] == "not-started" and apple.get("steps") not in (None, []):
        raise PreflightError("A never-started Apple job must not contain executed steps")
    packaged = step(build, "Build and verify DMG", "success")
    uploaded = step(build, PACKAGE_UPLOAD, "success")
    if packaged["number"] >= uploaded["number"]:
        raise PreflightError("Package upload is not after successful package verification")
    windows = {"package": upload_window(build, PACKAGE_UPLOAD), "outcome": None}
    if policy["prior_signing_state"] in {"pre-apple-format-failure", "pre-apple-certificate-import-failure"}:
        signed = step(apple, "Sign, notarize and verify approved candidate", "failure")
        saved = step(apple, "Preserve non-secret signing outcome", "success")
        if signed["number"] >= saved["number"]:
            raise PreflightError("Signing outcome upload is not after the failed signing step")
        windows["outcome"] = upload_window(apple, "Preserve non-secret signing outcome")
    if policy["source_run_attempt"] == 2:
        first_build, first_apple = attempt_jobs(github, policy, 1)
        previous = policy["first_attempt"]
        if (first_build.get("id"), first_build.get("conclusion"), first_apple.get("id"), first_apple.get("conclusion")) != (
            previous["build_job_id"], "failure", previous["apple_job_id"], "skipped"):
            raise PreflightError("Attempt 1 previously built successfully or executed Apple; do not reuse this rerun path")
        step(first_build, "Test and sign Android helper", "failure")
        step(first_build, "Build and verify DMG", "skipped")
        step(first_build, PACKAGE_UPLOAD, "skipped")
        if first_apple.get("steps") not in (None, []):
            raise PreflightError("Attempt 1 Apple job contains executed steps")
        if timestamp(first_build.get("completed_at")) > timestamp(build.get("started_at")):
            raise PreflightError("First and second attempt build windows overlap")
    query = urllib.parse.urlencode({"branch": retry_branch(policy), "event": "push", "per_page": 100})
    runs = github.json(f"/repos/{REPOSITORY}/actions/runs?{query}")
    if not isinstance(runs, dict) or not isinstance(runs.get("workflow_runs"), list) or runs.get("total_count", 101) > 100:
        raise PreflightError("Unable to exclude a prior signing retry")
    matching = [r for r in runs["workflow_runs"] if r.get("path") == workflow_path(policy)]
    if len(matching) != 1 or matching[0].get("id") != current_run or matching[0].get("run_attempt") != 1:
        raise PreflightError("Another signing retry already exists; query its outcome instead of resubmitting")
    return windows


def validate_artifact(github, policy: dict, artifact_id: int, name: str, sha256: str, maximum: int, window: tuple) -> None:
    metadata = github.json(f"/repos/{REPOSITORY}/actions/artifacts/{artifact_id}")
    if not isinstance(metadata, dict) or (metadata.get("id"), metadata.get("name"), metadata.get("expired"),
        metadata.get("digest"), metadata.get("workflow_run", {}).get("id"), metadata.get("workflow_run", {}).get("head_sha")) != (
            artifact_id, name, False, "sha256:" + sha256, policy["source_run"], policy["source_sha"]):
        raise PreflightError("Artifact identity, immutable digest, source or expiration does not match the reviewed input")
    size = metadata.get("size_in_bytes")
    if isinstance(size, bool) or not isinstance(size, int) or not 0 < size <= maximum:
        raise PreflightError("Artifact size is outside the approved limit")
    if not window[0] <= timestamp(metadata.get("created_at")) <= window[1]:
        raise PreflightError("Artifact was not created during this exact reviewed attempt's successful upload step")
    artifacts = github.json(f"/repos/{REPOSITORY}/actions/runs/{policy['source_run']}/artifacts?per_page=100")
    if not isinstance(artifacts, dict) or not isinstance(artifacts.get("artifacts"), list) or artifacts.get("total_count", 101) > 100:
        raise PreflightError("Unable to exclude duplicate or historical same-name artifacts")
    same_name = [item for item in artifacts["artifacts"] if item.get("name") == name]
    if len(same_name) != 1 or same_name[0].get("id") != artifact_id:
        raise PreflightError("The run does not contain exactly one artifact with this approved name and ID")


def zip_files(payload: bytes, expected_names: set[str], maximum: int) -> dict[str, bytes]:
    try:
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            infos = archive.infolist()
            if len(infos) != len(expected_names) or {i.filename for i in infos} != expected_names:
                raise PreflightError("Artifact ZIP must contain exactly the approved files")
            files = {}
            total = 0
            for info in infos:
                mode = info.external_attr >> 16
                if (info.is_dir() or "/" in info.filename or "\\" in info.filename or info.flag_bits & 1 or
                    stat.S_ISLNK(mode) or stat.S_IFMT(mode) not in (0, stat.S_IFREG) or
                    info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)):
                    raise PreflightError("Artifact ZIP contains an unsafe entry")
                if info.file_size < 0 or info.file_size > maximum or total + info.file_size > maximum:
                    raise PreflightError("Artifact ZIP exceeds the extraction limit")
                with archive.open(info) as stream:
                    data = stream.read(info.file_size + 1)
                if len(data) != info.file_size:
                    raise PreflightError("Artifact ZIP entry size is inconsistent")
                files[info.filename] = data
                total += len(data)
            return files
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        raise PreflightError("Artifact is not a valid bounded ZIP") from error


def validate_prior_outcome(payload: bytes, policy: dict | None = None) -> None:
    files = zip_files(payload, {"apple-signing-summary.json"}, 64 * 1024)
    try:
        summary = json.loads(files["apple-signing-summary.json"])
    except (ValueError, TypeError) as error:
        raise PreflightError("Unable to validate the prior non-secret signing outcome") from error
    # Exact field sets only: unexpected state/submissions/IDs may conceal an
    # accepted or uncertain upload and must never be erased by another submission.
    if policy is not None and policy.get("prior_signing_state") == "pre-apple-certificate-import-failure":
        if policy != REVIEWED_IMPORT_FAILURE_POLICY:
            raise PreflightError("Certificate-import outcome requires the exact reviewed Build143 policy")
        expected = {"status": "failed", "apple_notarized": False, "error": CERTIFICATE_IMPORT_FAILURE,
                    "commit": policy["source_sha"], "version": "0.1.8", "build": "143"}
    else:
        expected = {"status": "failed", "apple_notarized": False, "error": FORMAT_FAILURE}
    if summary != expected:
        raise PreflightError("Prior outcome does not prove the exact reviewed pre-Apple failure; do not resubmit")


def validate_package(files: dict[str, bytes], policy: dict) -> None:
    expected_files = package_files(policy)
    if set(files) != expected_files:
        raise PreflightError("Package file set is incomplete")
    expected = expected_files - {"SHA256SUMS.txt"}
    seen = set()
    try:
        for line in files["SHA256SUMS.txt"].decode("utf-8").splitlines():
            match = re.fullmatch(r"([a-f0-9]{64})  ([^/\\]+)", line)
            if not match or match[2] not in expected or match[2] in seen:
                raise PreflightError("Package checksum manifest is unexpected")
            if hashlib.sha256(files[match[2]]).hexdigest() != match[1]:
                raise PreflightError("Package checksum mismatch")
            seen.add(match[2])
        if seen != expected:
            raise PreflightError("Package checksum manifest is incomplete")
        info = json.loads(files["build-info.json"])
    except (ValueError, UnicodeError) as error:
        raise PreflightError("Package metadata is malformed") from error
    if not isinstance(info, dict) or (info.get("version"), info.get("build"), info.get("architecture"),
        info.get("commit"), info.get("macos_signing"), info.get("apple_notarized")) != (
            "0.1.8", policy["build"], "arm64", policy["source_sha"], "ad-hoc", False):
        raise PreflightError("Package is not the exact approved unsigned build")


def prepare(github, policy: dict, output: Path, context: dict) -> None:
    current_run = validate_context(context, policy)
    windows = validate_source(github, policy, current_run)
    if policy["prior_signing_state"] in {"pre-apple-format-failure", "pre-apple-certificate-import-failure"}:
        validate_artifact(github, policy, policy["outcome_artifact_id"], f"DeviceBridge-apple-signing-outcome-{policy['source_run']}", policy["outcome_digest"], 64 * 1024, windows["outcome"])
        outcome = github.archive(policy["outcome_artifact_id"], policy["outcome_digest"], 64 * 1024)
        validate_prior_outcome(outcome, policy)
    validate_artifact(github, policy, policy["package_artifact_id"], package_name(policy), policy["package_digest"], MAX_ARCHIVE, windows["package"])
    package = github.archive(policy["package_artifact_id"], policy["package_digest"], MAX_ARCHIVE)
    files = zip_files(package, package_files(policy), MAX_ARCHIVE)
    validate_package(files, policy)
    # Re-check source/job/singleton state immediately before local extraction.
    if validate_source(github, policy, current_run) != windows:
        raise PreflightError("Producing job upload windows changed during preflight")
    validate_artifact(github, policy, policy["package_artifact_id"], package_name(policy), policy["package_digest"], MAX_ARCHIVE, windows["package"])
    if policy["prior_signing_state"] in {"pre-apple-format-failure", "pre-apple-certificate-import-failure"}:
        validate_artifact(github, policy, policy["outcome_artifact_id"], f"DeviceBridge-apple-signing-outcome-{policy['source_run']}", policy["outcome_digest"], 64 * 1024, windows["outcome"])
    if output.exists():
        raise PreflightError("Retry input directory already exists; refusing to overwrite")
    output.mkdir(parents=True, mode=0o700)
    for name, data in files.items():
        target = output / name
        with target.open("xb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(data)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        policy = policy_from(args.policy)
        prepare(GitHub(os.environ.get("GH_TOKEN", "")), policy, args.output, dict(os.environ))
    except PreflightError as error:
        print(str(error))  # controlled categories only, never remote text or credentials
        return 1
    print("Verified fixed approved artifact and prior no-submission state; input ready. No application executed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
