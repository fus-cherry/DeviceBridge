#!/usr/bin/env python3
"""One fixed Build143 formal-signing preflight. No Apple credentials or submissions here."""
from __future__ import annotations
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import urllib.error

HERE = Path(__file__).resolve().parent
BRANCH = "cloud/0.1.8-build143-scoped-signing"
WORKFLOW = ".github/workflows/build143-scoped-signing.yml"
PREVIOUS_DIAG_RUN = 43412048178
PREVIOUS_DIAG_SHA = "c7c7d9ddd71c0dbc132dc5788ed603dba8a3754d"
PREVIOUS_DIAG_JOB = 131840607083
RETRY_RUN = 43410018077
RETRY_SHA = "2d78f06405451bd46d3e71bb773a0d3098cc3967"
RETRY_JOB = 131833794507
RETRY_OUTCOME = 14028767654
RETRY_DIGEST = "e2f944e19cc3e366783fd1f65f5407f6aaf5141c993fdffaccbcd84744e4b0c5"
CLI_ERROR = "Sign bundled CLI: command failed (exit 1); no secret-bearing output retained"
NAMES = ("APPLE_CERTIFICATE_P12_BASE64", "APPLE_CERTIFICATE_PASSWORD", "APPLE_TEAM_ID")


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


P = load(HERE / "verify-apple-retry-input.py", "cli_preflight")
BASE = dict(P.REVIEWED_IMPORT_FAILURE_POLICY)


def context_run(context):
    if tuple(context.get(k) for k in ("GITHUB_REPOSITORY", "GITHUB_ACTOR", "GITHUB_REF", "GITHUB_EVENT_NAME", "GITHUB_RUN_ATTEMPT")) != (
            P.REPOSITORY, P.OWNER, "refs/heads/" + BRANCH, "push", "1"):
        raise P.PreflightError("Diagnostic owner, repository, branch, event or attempt is not approved")
    if not re.fullmatch(r"[1-9][0-9]*", context.get("GITHUB_RUN_ID", "")):
        raise P.PreflightError("Diagnostic run ID is missing")
    return int(context["GITHUB_RUN_ID"])


def source_evidence(github, current_run):
    original = github.json(f"/repos/{P.REPOSITORY}/actions/runs/{BASE['source_run']}")
    if tuple(original.get(k) for k in ("id", "head_sha", "head_branch", "run_attempt", "status", "event", "path")) != (
            BASE["source_run"], BASE["source_sha"], "cloud/0.1.8-candidate", 1, "completed", "push", ".github/workflows/release.yml") or original.get("actor", {}).get("login") != P.OWNER:
        raise P.PreflightError("Original fixed Build143 source changed")
    build, apple = P.attempt_jobs(github, BASE, 1)
    if (build.get("id"), build.get("conclusion"), apple.get("id"), apple.get("conclusion")) != (
            BASE["source_build_job_id"], "success", BASE["prior_apple_job_id"], "failure"):
        raise P.PreflightError("Original fixed Build143 jobs changed")
    P.step(build, "Build and verify DMG", "success")
    package_window = P.upload_window(build, P.PACKAGE_UPLOAD)
    retry = github.json(f"/repos/{P.REPOSITORY}/actions/runs/{RETRY_RUN}")
    if tuple(retry.get(k) for k in ("id", "head_sha", "head_branch", "run_attempt", "status", "conclusion", "event", "path")) != (
            RETRY_RUN, RETRY_SHA, "cloud/0.1.8-apple-retry-build143", 1, "completed", "failure", "push", ".github/workflows/apple-sign-retry-build143.yml") or retry.get("actor", {}).get("login") != P.OWNER:
        raise P.PreflightError("The previous signing retry is not the exact terminal failed attempt")
    jobs = github.json(f"/repos/{P.REPOSITORY}/actions/runs/{RETRY_RUN}/attempts/1/jobs?per_page=100")
    if jobs.get("total_count") != 1 or not isinstance(jobs.get("jobs"), list) or len(jobs["jobs"]) != 1:
        raise P.PreflightError("Unable to bind the previous signing retry job")
    job = jobs["jobs"][0]
    if tuple(job.get(k) for k in ("id", "run_id", "run_attempt", "head_sha", "name", "status", "conclusion")) != (
            RETRY_JOB, RETRY_RUN, 1, RETRY_SHA, "sign-verified-build143", "completed", "failure"):
        raise P.PreflightError("Previous signing retry job changed")
    P.step(job, "Sign original approved 0.1.8 build with the original reviewed signer", "failure")
    outcome_window = P.upload_window(job, "Preserve non-secret outcome including notarization submission IDs")
    previous = github.json(f"/repos/{P.REPOSITORY}/actions/runs/{PREVIOUS_DIAG_RUN}")
    if tuple(previous.get(k) for k in ("id", "head_sha", "head_branch", "run_attempt", "status", "conclusion", "event", "path")) != (
            PREVIOUS_DIAG_RUN, PREVIOUS_DIAG_SHA, "cloud/0.1.8-build143-cli-diagnostic", 1, "completed", "failure", "push", ".github/workflows/build143-cli-diagnostic.yml") or previous.get("actor", {}).get("login") != P.OWNER:
        raise P.PreflightError("Previous CLI diagnostic is not the exact terminal attempt")
    previous_jobs = github.json(f"/repos/{P.REPOSITORY}/actions/runs/{PREVIOUS_DIAG_RUN}/attempts/1/jobs?per_page=100")
    if previous_jobs.get("total_count") != 1 or not isinstance(previous_jobs.get("jobs"), list) or len(previous_jobs["jobs"]) != 1:
        raise P.PreflightError("Unable to bind previous CLI diagnostic job")
    previous_job = previous_jobs["jobs"][0]
    if tuple(previous_job.get(k) for k in ("id", "run_id", "run_attempt", "head_sha", "name", "status", "conclusion")) != (
            PREVIOUS_DIAG_JOB, PREVIOUS_DIAG_RUN, 1, PREVIOUS_DIAG_SHA, "cli-only", "completed", "failure"):
        raise P.PreflightError("Previous CLI diagnostic job changed")
    P.step(previous_job, "Diagnose only temporary CLI signing with timestamp; no notarization submission", "failure")
    query = urllib.parse.urlencode({"branch": BRANCH, "event": "push", "per_page": 100})
    runs = github.json(f"/repos/{P.REPOSITORY}/actions/runs?{query}")
    if not isinstance(runs.get("workflow_runs"), list) or runs.get("total_count", 101) > 100:
        raise P.PreflightError("Unable to exclude a previous CLI diagnostic")
    matching = [r for r in runs["workflow_runs"] if r.get("path") == WORKFLOW]
    if len(matching) != 1 or (matching[0].get("id"), matching[0].get("run_attempt")) != (current_run, 1):
        raise P.PreflightError("Another CLI diagnostic exists; inspect its result instead of replaying")
    return package_window, outcome_window


def prepare(github, output, context):
    current = context_run(context)
    validate_ab_evidence(github)
    windows = source_evidence(github, current)
    prior = dict(BASE, source_run=RETRY_RUN, source_sha=RETRY_SHA)
    name = f"DeviceBridge-build143-apple-retry-outcome-{RETRY_RUN}"
    P.validate_artifact(github, prior, RETRY_OUTCOME, name, RETRY_DIGEST, 64 * 1024, windows[1])
    raw = github.archive(RETRY_OUTCOME, RETRY_DIGEST, 64 * 1024)
    summary_files = P.zip_files(raw, {"apple-signing-summary.json"}, 64 * 1024)
    expected = {"status": "failed", "apple_notarized": False, "commit": BASE["source_sha"], "version": "0.1.8", "build": "143", "error": CLI_ERROR}
    if json.loads(summary_files["apple-signing-summary.json"]) != expected:
        raise P.PreflightError("Previous retry does not prove exact pre-notarization CLI failure")
    P.validate_artifact(github, BASE, BASE["package_artifact_id"], P.package_name(BASE), BASE["package_digest"], P.MAX_ARCHIVE, windows[0])
    package = github.archive(BASE["package_artifact_id"], BASE["package_digest"], P.MAX_ARCHIVE)
    files = P.zip_files(package, P.package_files(BASE), P.MAX_ARCHIVE)
    P.validate_package(files, BASE)
    if source_evidence(github, current) != windows:
        raise P.PreflightError("Source upload windows changed during diagnostic preflight")
    P.validate_artifact(github, prior, RETRY_OUTCOME, name, RETRY_DIGEST, 64 * 1024, windows[1])
    P.validate_artifact(github, BASE, BASE["package_artifact_id"], P.package_name(BASE), BASE["package_digest"], P.MAX_ARCHIVE, windows[0])
    validate_ab_evidence(github)
    if output.exists():
        raise P.PreflightError("Diagnostic input already exists")
    output.mkdir(mode=0o700, parents=True)
    for name, value in files.items():
        with (output / name).open("xb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(value)


AB_RUN = 43413993185
AB_SHA = "6cbe60201a6b2f141bc00e3cb33adf9c5df8dee5"
AB_JOB = 131847188277
MAX_LOG = 1024 * 1024
EXPECTED_AB_RESULT = json.loads('{"baseline":{"observations":["identity_or_key_not_found"],"status":"failed"},"cli_signing":"passed_strict_team_verified_diagnostic_copy_only","default_identity_after":true,"default_identity_before":false,"notarization_submission":"not_attempted","ownedchain_in_searchlist_after":true,"ownedchain_in_searchlist_before":false,"search_scope":{"status":"passed_strict_team_verified_diagnostic_copy_only"},"search_scope_fix_supported":true,"searchlist_change":"owned_chain_appended_preserving_all_items","searchlist_restore":"verified_exact_original","timestamp_requested":true}')

class EvidenceGitHub(P.GitHub):
    def job_logs(self, job_id):
        # Raw logs stay in memory; no auth header is forwarded to blob hosts.
        try:
            opener = urllib.request.build_opener(P.NoRedirect)
            try:
                response = opener.open(self._request(f"/repos/{P.REPOSITORY}/actions/jobs/{job_id}/logs"), timeout=30)
            except urllib.error.HTTPError as redirect:
                if redirect.code != 302:
                    raise P.PreflightError("A/B evidence log download did not return the required redirect") from None
                location = redirect.headers.get("Location", "")
                parsed = urllib.parse.urlsplit(location)
                if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
                    raise P.PreflightError("A/B log redirect is not a valid HTTPS download")
                response = urllib.request.urlopen(urllib.request.Request(location), timeout=60)
            with response:
                raw = response.read(MAX_LOG + 1)
            if len(raw) > MAX_LOG:
                raise P.PreflightError("A/B evidence logs exceed the reviewed size limit")
            return raw
        except (OSError, ValueError):
            raise P.PreflightError("Unable to retrieve A/B evidence; no token, signed URL or log content retained") from None


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("Duplicate JSON object key")
        value[key] = item
    return value


def parse_ab_result(raw):
    if not isinstance(raw, bytes) or len(raw) > MAX_LOG:
        raise P.PreflightError("A/B evidence log data is invalid")
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeError:
        raise P.PreflightError("A/B evidence log encoding is invalid") from None
    results = []
    for line in lines:
        match = re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z\s+(\{.*\})", line)
        if match:
            try:
                value = json.loads(match[1], object_pairs_hook=unique_object)
            except ValueError:
                if '"search_scope_fix_supported"' in match[1]:
                    raise P.PreflightError("A/B evidence contains malformed or duplicate-key result data") from None
                continue
            if isinstance(value, dict) and "search_scope_fix_supported" in value:
                results.append(value)
    expected = json.dumps(EXPECTED_AB_RESULT, sort_keys=True, separators=(",", ":"))
    if len(results) != 1 or json.dumps(results[0], sort_keys=True, separators=(",", ":")) != expected:
        raise P.PreflightError("A/B evidence does not prove the exact reviewed search-scope result and restoration")


def validate_ab_evidence(github):
    run = github.json(f"/repos/{P.REPOSITORY}/actions/runs/{AB_RUN}")
    if tuple(run.get(k) for k in ("id", "head_sha", "head_branch", "run_attempt", "status", "conclusion", "event", "path")) != (
            AB_RUN, AB_SHA, "cloud/0.1.8-build143-cli-ab-diagnostic", 1, "completed", "success", "push", ".github/workflows/build143-cli-ab-diagnostic.yml") or run.get("actor", {}).get("login") != P.OWNER:
        raise P.PreflightError("A/B workflow source or successful terminal attempt changed")
    jobs = github.json(f"/repos/{P.REPOSITORY}/actions/runs/{AB_RUN}/attempts/1/jobs?per_page=100")
    if jobs.get("total_count") != 1 or not isinstance(jobs.get("jobs"), list) or len(jobs["jobs"]) != 1:
        raise P.PreflightError("Unable to bind the successful A/B job")
    job = jobs["jobs"][0]
    if tuple(job.get(k) for k in ("id", "run_id", "run_attempt", "head_sha", "name", "status", "conclusion")) != (
            AB_JOB, AB_RUN, 1, AB_SHA, "cli-only", "completed", "success"):
        raise P.PreflightError("A/B successful job changed")
    P.step(job, "Diagnose only temporary CLI signing with timestamp; no notarization submission", "success")
    parse_ab_result(github.job_logs(AB_JOB))


def main():
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--output", type=Path, required=True)
        args = parser.parse_args()
        prepare(EvidenceGitHub(os.environ.get("GH_TOKEN", "")), args.output, dict(os.environ))
    except BaseException:
        print("Fixed Build143 signing preflight failed; no token, log content or signed URL retained")
        return 1
    print("Fixed Build143 package, no-submission failures and exact successful A/B restoration evidence verified.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
