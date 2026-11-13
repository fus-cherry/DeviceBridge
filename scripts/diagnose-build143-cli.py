#!/usr/bin/env python3
"""One fixed Build143 CLI diagnostic. May contact certificate/TSA services, never notarizes."""
from __future__ import annotations
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse

HERE = Path(__file__).resolve().parent
BRANCH = "cloud/0.1.8-build143-cli-diagnostic"
WORKFLOW = ".github/workflows/build143-cli-diagnostic.yml"
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
C = load(HERE / "classify-apple-codesign-failure.py", "cli_classifier")
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
    if output.exists():
        raise P.PreflightError("Diagnostic input already exists")
    output.mkdir(mode=0o700, parents=True)
    for name, value in files.items():
        with (output / name).open("xb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(value)


# Actual commands are constrained to the original setup, the CLI operation and cleanup.
PREFIXES = {
    "Create temporary signing keychain": ["/usr/bin/security", "create-keychain"],
    "Limit temporary keychain lifetime": ["/usr/bin/security", "set-keychain-settings"],
    "Unlock temporary signing keychain": ["/usr/bin/security", "unlock-keychain"],
    "Import Developer ID certificate": ["/usr/bin/security", "import"],
    "Permit signing with this temporary key": ["/usr/bin/security", "set-key-partition-list"],
    "Validate Developer ID identity": ["/usr/bin/security", "find-identity"],
    "Mount verified input DMG": ["/usr/bin/hdiutil", "attach"],
    "Copy verified CLI": ["/usr/bin/ditto"],
    "Detach input DMG": ["/usr/bin/hdiutil", "detach"],
    "Delete temporary keychain": ["/usr/bin/security", "delete-keychain"],
    "Verify diagnostic CLI": ["/usr/bin/codesign", "--verify", "--strict"],
    "Inspect Developer ID signature": ["/usr/bin/codesign", "--display", "--verbose=4"],
}


def classes(original, verifier):
    class DiagnosticCommands(original.Commands):
        failure_phase = "unclassified"
        def run(self, args, *, phase, **kwargs):
            prefix = PREFIXES.get(phase)
            if prefix is None or args[:len(prefix)] != prefix:
                raise original.SigningError("Diagnostic command not approved")
            try:
                return super().run(args, phase=phase, **kwargs)
            except BaseException:
                self.failure_phase = phase
                raise
        def codesign_cli(self, args):
            if len(args) != 10 or args[:3] != ["/usr/bin/codesign", "--force", "--sign"] or args[4] != "--keychain" or args[6:9] != ["--options", "runtime", "--timestamp"] or Path(args[9]).name != "devicebridge-agent":
                raise original.SigningError("Diagnostic CLI flags not approved")
            try:
                return subprocess.run(args, capture_output=True, check=False, timeout=120,
                                      env=original.safe_child_environment())
            except BaseException:
                self.failure_phase = "Sign bundled CLI"
                raise original.SigningError("Diagnostic CLI tool failed without retained output") from None

    class CLIOnlySigner(original.AppleSigner):
        diagnostic = {"cli_signing": "not_run", "notarization_submission": "not_attempted", "timestamp_requested": True}
        def _sign(self, dmg, output, work, info, values):
            self.diagnostic = dict(self.diagnostic)
            run = self.commands.run
            team = values["APPLE_TEAM_ID"]
            certificate = work / "identity.p12"
            with certificate.open("xb") as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(original.decode_certificate(values["APPLE_CERTIFICATE_P12_BASE64"]))
            password = original.secrets.token_urlsafe(48)
            self.keychain = work / "signing.keychain-db"
            keychain = self.keychain
            run(["/usr/bin/security", "create-keychain", "-p", password, str(keychain)], phase="Create temporary signing keychain")
            run(["/usr/bin/security", "set-keychain-settings", "-lut", "21600", str(keychain)], phase="Limit temporary keychain lifetime")
            run(["/usr/bin/security", "unlock-keychain", "-p", password, str(keychain)], phase="Unlock temporary signing keychain")
            run(["/usr/bin/security", "import", str(certificate), "-k", str(keychain), "-P", values["APPLE_CERTIFICATE_PASSWORD"], "-T", "/usr/bin/codesign"], phase="Import Developer ID certificate")
            certificate.unlink()
            run(["/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, str(keychain)], phase="Permit signing with this temporary key")
            identity = original.find_identity(run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning", str(keychain)], phase="Validate Developer ID identity"), team)
            self.mount = work / "input-mount"
            self.mount.mkdir()
            run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(self.mount), str(dmg)], phase="Mount verified input DMG")
            app = self.mount / "DeviceBridge.app"
            verifier.verify(app, info["version"], info["build"])
            original.native_files(app)
            cli = work / "devicebridge-agent"
            run(["/usr/bin/ditto", str(app / "Contents/MacOS/devicebridge-agent"), str(cli)], phase="Copy verified CLI")
            if original.sha256(cli) != original.sha256(app / "Contents/MacOS/devicebridge-agent"):
                raise original.SigningError("Diagnostic CLI copy checksum mismatch")
            run(["/usr/bin/hdiutil", "detach", str(self.mount)], phase="Detach input DMG")
            self.mount = None
            result = self.commands.codesign_cli(["/usr/bin/codesign", "--force", "--sign", identity, "--keychain", str(keychain), "--options", "runtime", "--timestamp", str(cli)])
            if result.returncode:
                self.diagnostic.update(cli_signing="failed", observations=list(C.classify_failure(result.stdout, result.stderr)))
                return  # Hard stop. No app signing, packaging or notarization code exists here.
            run(["/usr/bin/codesign", "--verify", "--strict", str(cli)], phase="Verify diagnostic CLI")
            original.verify_identity(self.commands, cli, team)
            self.diagnostic["cli_signing"] = "passed_diagnostic_copy_only"
            return
    return DiagnosticCommands, CLIOnlySigner


def diagnose(source, directory):
    original = load(source / "scripts/sign-apple-release.py", "fixed_original_signer")
    verifier = load(source / "scripts/verify-release.py", "fixed_release_verifier")
    values = {}
    outer = None
    report = {"cli_signing": "not_run", "notarization_submission": "not_attempted", "timestamp_requested": True}
    commands = None
    try:
        if any(not os.environ.get(name) for name in NAMES):
            raise ValueError("missing")
        values = {name: os.environ[name] for name in NAMES}
        if not re.fullmatch(r"[A-Z0-9]{10}", values["APPLE_TEAM_ID"]) or any(c in values["APPLE_CERTIFICATE_PASSWORD"] for c in "\r\n\x00"):
            raise ValueError("format")
        for name in original.SECRET_NAMES:
            os.environ.pop(name, None)
        Commands, Signer = classes(original, verifier)
        commands = Commands()
        signer = Signer(commands)
        outer = Path(tempfile.mkdtemp(prefix="devicebridge-cli-control-", dir=os.environ.get("RUNNER_TEMP")))
        outer.chmod(0o700)
        signer.run(directory, outer / "unused-output", "0.1.8", "143", BASE["source_sha"], values)
        report = signer.diagnostic
    except BaseException:
        report["error"] = "diagnostic_preparation_verification_or_cleanup_failed"
        phase = getattr(commands, "failure_phase", "unclassified")
        report["phase"] = phase if phase in PREFIXES or phase == "Sign bundled CLI" else "unclassified"
    finally:
        values.clear()
        for name in (*NAMES, "APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD"):
            os.environ.pop(name, None)
        if outer is not None:
            try:
                shutil.rmtree(outer)
            except BaseException:
                report["error"] = "diagnostic_control_cleanup_failed"
    return report


def main():
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("mode", choices=("preflight", "diagnose"))
        parser.add_argument("--input", required=True, type=Path)
        parser.add_argument("--source", type=Path)
        args = parser.parse_args()
        if args.mode == "preflight":
            prepare(P.GitHub(os.environ.get("GH_TOKEN", "")), args.input, dict(os.environ))
            print("Fixed Build143 package and terminal no-submission retry evidence verified; no app executed.")
            return 0
        if sys.platform != "darwin" or args.source is None:
            raise ValueError("platform")
        report = diagnose(args.source, args.input)
        print(json.dumps(report, sort_keys=True))
        return 0 if report.get("cli_signing") == "passed_diagnostic_copy_only" and "error" not in report else 1
    except BaseException:
        print("Diagnostic preflight or setup failed; no secret-bearing output retained")
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
