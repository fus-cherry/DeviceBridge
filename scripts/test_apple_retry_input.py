"""No network or real credentials: exercise signing-only retry trust gates."""
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import zipfile

SPEC = importlib.util.spec_from_file_location("apple_retry", Path(__file__).with_name("verify-apple-retry-input.py"))
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
RENDER_SPEC = importlib.util.spec_from_file_location("apple_retry_render", Path(__file__).with_name("render-apple-sign-retry.py"))
R = importlib.util.module_from_spec(RENDER_SPEC)
RENDER_SPEC.loader.exec_module(R)


def archive(files):
    result = io.BytesIO()
    with zipfile.ZipFile(result, "w", zipfile.ZIP_DEFLATED) as output:
        for name, value in files.items():
            output.writestr(name, value)
    return result.getvalue()


class FakeGitHub:
    def __init__(self, policy, package, outcome):
        self.policy = policy
        self.package = package
        self.outcome = outcome
        self.downloads = []
        self.extra_retry = False
        self.apple_conclusion = "failure"
        self.apple_status = "completed"
        self.build_conclusion = "success"
        self.source_sha = policy["source_sha"]
        self.source_attempt = policy["source_run_attempt"]
        self.artifact_expired = False
        self.artifact_digest_override = None
        self.package_created_at = "2026-11-13T08:18:05Z"
        self.outcome_created_at = "2026-11-13T08:19:55Z"
        self.duplicate_artifact = False
        self.first_build_conclusion = "failure"
        self.first_apple_conclusion = "skipped"
        self.first_apple_steps = []
        self.first_package_conclusion = "skipped"
        self.first_upload_conclusion = "skipped"
        self.first_helper_conclusion = "failure"
        self.first_build_id_override = None
        self.source_checks = 0
        self.change_source_on_recheck = False
        self.job_attempt_override = None

    def jobs(self, attempt):
        p = self.policy
        first = attempt == 1 and p["source_run_attempt"] == 2
        def step(name, conclusion, number, start="2026-11-13T08:18:00Z", end="2026-11-13T08:18:10Z"):
            return {"name": name, "status": "completed", "conclusion": conclusion, "number": number,
                    "started_at": start, "completed_at": end}
        common = {"run_id": p["source_run"], "run_attempt": self.job_attempt_override or attempt, "head_sha": p["source_sha"], "status": "completed"}
        build = dict(common, name="build", id=(self.first_build_id_override or p["first_attempt"]["build_job_id"]) if first else p["source_build_job_id"],
                     conclusion=self.first_build_conclusion if first else self.build_conclusion,
                     started_at="2026-11-13T08:00:00Z" if first else "2026-11-13T08:10:00Z",
                     completed_at="2026-11-13T08:05:00Z" if first else "2026-11-13T08:18:20Z",
                     steps=[step("Test and sign Android helper", self.first_helper_conclusion if first else "success", 8),
                            step("Build and verify DMG", self.first_package_conclusion if first else "success", 18),
                            step(M.PACKAGE_UPLOAD, self.first_upload_conclusion if first else "success", 19)])
        apple = dict(common, name="apple-sign", id=p["first_attempt"]["apple_job_id"] if first else p["prior_apple_job_id"],
                     status="completed" if first else self.apple_status,
                     conclusion=self.first_apple_conclusion if first else self.apple_conclusion,
                     started_at="2026-11-13T08:19:00Z", completed_at="2026-11-13T08:20:00Z",
                     steps=self.first_apple_steps if first else [] if self.apple_conclusion == "skipped" else [
                         step("Sign, notarize and verify approved candidate", "failure", 4, "2026-11-13T08:19:10Z", "2026-11-13T08:19:40Z"),
                         step("Preserve non-secret signing outcome", "success", 5, "2026-11-13T08:19:50Z", "2026-11-13T08:20:00Z")])
        return {"total_count": 2, "jobs": [build, apple]}

    def json(self, path):
        p = self.policy
        if path.endswith("/artifacts?per_page=100"):
            artifacts = [{"id": p["package_artifact_id"], "name": M.package_name(p)}]
            if p["outcome_artifact_id"] is not None:
                artifacts.append({"id": p["outcome_artifact_id"], "name": f"DeviceBridge-apple-signing-outcome-{p['source_run']}"})
            if self.duplicate_artifact:
                artifacts.append({"id": 876, "name": artifacts[0]["name"]})
            return {"total_count": len(artifacts), "artifacts": artifacts}
        if "/actions/artifacts/" in path:
            identifier = int(path.rsplit("/", 1)[1])
            is_package = identifier == p["package_artifact_id"]
            payload = self.package if is_package else self.outcome
            return {
                "id": identifier, "name": M.package_name(p) if is_package else f"DeviceBridge-apple-signing-outcome-{p['source_run']}",
                "expired": self.artifact_expired,
                "digest": self.artifact_digest_override or "sha256:" + hashlib.sha256(payload).hexdigest(),
                "size_in_bytes": len(payload), "workflow_run": {"id": p["source_run"], "head_sha": p["source_sha"]},
                "created_at": self.package_created_at if is_package else self.outcome_created_at,
            }
        if "/jobs?" in path:
            attempt = int(path.split("/attempts/")[1].split("/")[0])
            return self.jobs(attempt)
        if "runs?" in path:
            runs = [{"id": 999, "path": M.workflow_path(p), "run_attempt": 1}]
            if self.extra_retry:
                runs.append({"id": 998, "path": M.workflow_path(p), "run_attempt": 1})
            return {"total_count": len(runs), "workflow_runs": runs}
        self.source_checks += 1
        if self.change_source_on_recheck and self.source_checks > 1:
            self.source_attempt += 1
        return {"id": p["source_run"], "head_sha": self.source_sha, "head_branch": "cloud/0.1.8-candidate", "event": "push",
                "status": "completed", "run_attempt": self.source_attempt, "actor": {"login": M.OWNER}, "path": ".github/workflows/release.yml"}

    def archive(self, identifier, digest, maximum):
        self.downloads.append(identifier)
        return self.package if identifier == self.policy["package_artifact_id"] else self.outcome


class RetryInputTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.policy = {"source_sha": "a" * 40, "source_run": 101, "source_run_attempt": 1, "source_build_job_id": 201, "first_attempt": None,
                       "version": "0.1.8", "build": "141", "prior_apple_job_id": 202,
                       "prior_signing_state": "pre-apple-format-failure", "package_artifact_id": 303,
                       "package_digest": "b" * 64, "outcome_artifact_id": 404, "outcome_digest": "c" * 64}
        self.rebuild_package()
        self.context = {"GITHUB_REPOSITORY": M.REPOSITORY, "GITHUB_ACTOR": M.OWNER, "GITHUB_REF": "refs/heads/" + M.retry_branch(self.policy),
                        "GITHUB_EVENT_NAME": "push", "GITHUB_RUN_ATTEMPT": "1", "GITHUB_RUN_ID": "999"}

    def rebuild_package(self):
        self.files = {
            M.package_name(self.policy) + "-macOS-arm64.dmg": b"unsigned DMG fixture, never executable",
            "build-info.json": json.dumps({"version": "0.1.8", "build": self.policy["build"], "architecture": "arm64",
                                          "commit": self.policy["source_sha"], "macos_signing": "ad-hoc", "apple_notarized": False}).encode(),
            "release-notes.md": b"fixture notes",
        }
        self.files["SHA256SUMS.txt"] = "".join(f"{hashlib.sha256(value).hexdigest()}  {name}\n" for name, value in self.files.items()).encode()
        self.package = archive(self.files)
        self.outcome = archive({"apple-signing-summary.json": json.dumps({"status": "failed", "apple_notarized": False, "error": M.FORMAT_FAILURE})})
        self.policy["package_digest"] = hashlib.sha256(self.package).hexdigest()
        self.policy["outcome_digest"] = hashlib.sha256(self.outcome).hexdigest()
        self.gh = FakeGitHub(self.policy, self.package, self.outcome)

    def second_attempt(self):
        self.policy.update(copy.deepcopy(M.REVIEWED_SECOND_ATTEMPT), source_run_attempt=2)
        self.rebuild_package()
        self.context["GITHUB_REF"] = "refs/heads/" + M.retry_branch(self.policy)

    def policy_path(self, policy=None):
        path = self.root / "reviewed.json"
        path.write_text(json.dumps(policy or self.policy))
        return path

    def test_valid_reviewed_policy_and_package_prepared_without_execution(self):
        parsed = M.policy_from(self.policy_path())
        M.prepare(self.gh, parsed, self.root / "input", self.context)
        self.assertEqual({p.name for p in (self.root / "input").iterdir()}, M.package_files(self.policy))
        self.assertEqual(self.gh.downloads, [404, 303])

    def test_never_started_mode_requires_successful_build_but_no_outcome(self):
        self.policy.update(prior_signing_state="not-started", outcome_artifact_id=None, outcome_digest=None)
        self.gh.apple_conclusion = "skipped"
        parsed = M.policy_from(self.policy_path())
        M.prepare(self.gh, parsed, self.root / "input", self.context)
        self.assertEqual(self.gh.downloads, [303])
        self.gh.build_conclusion = "failure"
        with self.assertRaises(M.PreflightError):
            M.validate_source(self.gh, parsed, 999)

    def test_unfilled_template_is_never_valid_policy(self):
        template = Path(__file__).parent.parent / "docs/ci-templates/apple-retry-policy.json.in"
        with self.assertRaises(M.PreflightError):
            M.policy_from(template)

    def test_policy_has_no_source_build_or_artifact_defaults(self):
        for key in self.policy:
            changed = dict(self.policy)
            del changed[key]
            with self.assertRaises(M.PreflightError, msg=key):
                M.policy_from(self.policy_path(changed))
        for key, value in (("source_sha", "HEAD"), ("source_run", True), ("source_run_attempt", 2), ("package_artifact_id", 0),
                           ("package_digest", "bad"), ("version", "0.1.9"), ("build", "0"),
                           ("prior_signing_state", "notarization-pending")):
            with self.assertRaises(M.PreflightError, msg=key):
                M.policy_from(self.policy_path(dict(self.policy, **{key: value})))

    def test_not_started_cannot_borrow_prior_outcome(self):
        with self.assertRaises(M.PreflightError):
            M.policy_from(self.policy_path(dict(self.policy, prior_signing_state="not-started")))

    def test_only_reviewed_first_packaging_second_attempt_can_pass(self):
        self.second_attempt()
        parsed = M.policy_from(self.policy_path())
        M.prepare(self.gh, parsed, self.root / "input", self.context)
        self.assertEqual(self.gh.downloads, [404, 303])
        for key, value in (("source_sha", "a" * 40), ("source_run", 102), ("build", "143"),
                           ("source_run_attempt", 3), ("first_attempt", None),
                           ("first_attempt", {"build_job_id": 123, "apple_job_id": 124}),
                           ("source_build_job_id", M.REVIEWED_SECOND_ATTEMPT["first_attempt"]["build_job_id"]),
                           ("prior_apple_job_id", M.REVIEWED_SECOND_ATTEMPT["first_attempt"]["apple_job_id"])):
            with self.assertRaises(M.PreflightError, msg=key):
                M.policy_from(self.policy_path(dict(self.policy, **{key: value})))

    def test_second_attempt_rejects_any_prior_package_upload_or_apple_execution(self):
        self.second_attempt()
        for key, value in (("first_build_conclusion", "success"), ("first_apple_conclusion", "failure"),
                           ("first_apple_conclusion", "success"), ("first_package_conclusion", "success"),
                           ("first_upload_conclusion", "success"), ("first_helper_conclusion", "success"),
                           ("first_apple_steps", [{"name": "Set up job"}]), ("first_build_id_override", 123)):
            previous = getattr(self.gh, key)
            setattr(self.gh, key, value)
            with self.assertRaises(M.PreflightError, msg=key):
                M.prepare(self.gh, self.policy, self.root / "input", self.context)
            self.assertEqual(self.gh.downloads, [])
            setattr(self.gh, key, previous)

    def test_artifact_must_be_unique_and_created_in_exact_attempt_upload_step(self):
        self.second_attempt()
        for key, value in (("package_created_at", "2026-11-13T08:04:00Z"),
                           ("outcome_created_at", "2026-11-13T08:04:00Z"),
                           ("outcome_created_at", "2026-11-13T08:19:49Z"),
                           ("package_created_at", "2026-11-13T08:18:11Z"),
                           ("package_created_at", None), ("duplicate_artifact", True)):
            previous = getattr(self.gh, key)
            setattr(self.gh, key, value)
            with self.assertRaises(M.PreflightError, msg=key):
                M.prepare(self.gh, self.policy, self.root / "input", self.context)
            self.assertFalse((self.root / "input").exists())
            setattr(self.gh, key, previous)

    def test_source_rerun_started_during_download_blocks_extraction(self):
        self.gh.change_source_on_recheck = True
        with self.assertRaises(M.PreflightError):
            M.prepare(self.gh, self.policy, self.root / "input", self.context)
        self.assertFalse((self.root / "input").exists())

    def test_attempt_specific_endpoint_cannot_supply_other_attempt_jobs(self):
        self.second_attempt()
        self.gh.job_attempt_override = 1
        with self.assertRaises(M.PreflightError):
            M.prepare(self.gh, self.policy, self.root / "input", self.context)
        self.assertEqual(self.gh.downloads, [])

    def test_certificate_import_retry_only_accepts_exact_reviewed_143_policy(self):
        policy = copy.deepcopy(M.REVIEWED_IMPORT_FAILURE_POLICY)
        self.assertEqual(M.policy_from(self.policy_path(policy)), policy)
        for key, value in (("source_sha", "a" * 40), ("source_run", 102), ("build", "144"),
                           ("source_run_attempt", 2), ("source_build_job_id", 123),
                           ("prior_apple_job_id", 124), ("package_artifact_id", 125),
                           ("package_digest", "a" * 64), ("outcome_artifact_id", 126),
                           ("outcome_digest", "b" * 64)):
            with self.assertRaises(M.PreflightError, msg=key):
                M.policy_from(self.policy_path(dict(policy, **{key: value})))

    def test_certificate_import_summary_exact_six_fields_no_pending_state(self):
        policy = copy.deepcopy(M.REVIEWED_IMPORT_FAILURE_POLICY)
        summary = {"status": "failed", "apple_notarized": False, "commit": policy["source_sha"],
                   "version": "0.1.8", "build": "143", "error": M.CERTIFICATE_IMPORT_FAILURE}
        def payload(value):
            return archive({"apple-signing-summary.json": json.dumps(value)})
        M.validate_prior_outcome(payload(summary), policy)
        for key, value in (("submissions", []), ("submissions", [{"id": "possibly-pending"}]),
                           ("state", "running"), ("error", "Import failed for an unknown reason"),
                           ("error", M.FORMAT_FAILURE), ("status", "success"), ("apple_notarized", True),
                           ("commit", "a" * 40), ("version", "0.1.9"), ("build", "144")):
            with self.assertRaises(M.PreflightError, msg=key):
                M.validate_prior_outcome(payload(dict(summary, **{key: value})), policy)
        for key in summary:
            changed = dict(summary)
            del changed[key]
            with self.assertRaises(M.PreflightError, msg=key):
                M.validate_prior_outcome(payload(changed), policy)
        with self.assertRaises(M.PreflightError):
            M.validate_prior_outcome(payload(summary), dict(policy, source_run=102))
        with self.assertRaises(M.PreflightError):
            M.validate_prior_outcome(payload(summary), self.policy)

    def test_owner_repo_branch_event_attempt_are_all_required(self):
        for key, value in (("GITHUB_REPOSITORY", "other/repo"), ("GITHUB_ACTOR", "other"), ("GITHUB_REF", "refs/heads/main"),
                           ("GITHUB_EVENT_NAME", "workflow_dispatch"), ("GITHUB_RUN_ATTEMPT", "2"), ("GITHUB_RUN_ID", "")):
            with self.assertRaises(M.PreflightError, msg=key):
                M.validate_context(dict(self.context, **{key: value}), self.policy)

    def test_changed_source_attempt_sha_or_failed_build_blocked(self):
        for attribute, value in (("source_attempt", 2), ("source_sha", "d" * 40), ("build_conclusion", "failure")):
            old = getattr(self.gh, attribute)
            setattr(self.gh, attribute, value)
            with self.assertRaises(M.PreflightError):
                M.validate_source(self.gh, self.policy, 999)
            setattr(self.gh, attribute, old)

    def test_running_or_successful_apple_and_second_retry_never_submitted(self):
        for status, conclusion in (("in_progress", None), ("completed", "success"), ("completed", "skipped")):
            self.gh.apple_status, self.gh.apple_conclusion = status, conclusion
            with self.assertRaises(M.PreflightError):
                M.validate_source(self.gh, self.policy, 999)
        self.gh.apple_status, self.gh.apple_conclusion = "completed", "failure"
        self.gh.extra_retry = True
        with self.assertRaises(M.PreflightError):
            M.validate_source(self.gh, self.policy, 999)

    def test_expired_or_digest_mismatching_metadata_blocked_before_download(self):
        for attribute, value in (("artifact_expired", True), ("artifact_digest_override", "sha256:" + "0" * 64)):
            old = getattr(self.gh, attribute)
            setattr(self.gh, attribute, value)
            with self.assertRaises(M.PreflightError):
                M.prepare(self.gh, self.policy, self.root / "input", self.context)
            self.assertEqual(self.gh.downloads, [])
            setattr(self.gh, attribute, old)

    def test_prior_submission_or_success_or_unknown_error_blocks_retry(self):
        summaries = [
            {"status": "accepted", "apple_notarized": True},
            {"status": "failed", "apple_notarized": False, "error": M.FORMAT_FAILURE, "submissions": [{"id": "pending"}]},
            {"status": "failed", "apple_notarized": False, "error": "Unclear upload timeout"},
        ]
        for summary in summaries:
            with self.assertRaises(M.PreflightError):
                M.validate_prior_outcome(archive({"apple-signing-summary.json": json.dumps(summary)}))

    def test_zip_rejects_extra_duplicate_traversal_symlink_and_oversize(self):
        for extra in ("../escape", "unexpected", "folder/file"):
            with self.assertRaises(M.PreflightError):
                M.zip_files(archive(dict(self.files, **{extra: b"bad"})), M.package_files(self.policy), M.MAX_ARCHIVE)
        duplicates = io.BytesIO()
        with zipfile.ZipFile(duplicates, "w") as z:
            import warnings
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                z.writestr("apple-signing-summary.json", b"first")
                z.writestr("apple-signing-summary.json", b"second")
        with self.assertRaises(M.PreflightError):
            M.zip_files(duplicates.getvalue(), {"apple-signing-summary.json"}, 1000)
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, "w") as z:
            info = zipfile.ZipInfo("apple-signing-summary.json")
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(info, b"../escape")
        with self.assertRaises(M.PreflightError):
            M.zip_files(payload.getvalue(), {"apple-signing-summary.json"}, 1000)
        with self.assertRaises(M.PreflightError):
            M.zip_files(self.package, M.package_files(self.policy), 8)

    def test_wrong_package_commit_build_signature_or_checksum_rejected(self):
        for key, value in (("commit", "d" * 40), ("build", "140"), ("apple_notarized", True), ("macos_signing", "Developer ID Application")):
            files = dict(self.files)
            info = json.loads(files["build-info.json"])
            info[key] = value
            files["build-info.json"] = json.dumps(info).encode()
            files["SHA256SUMS.txt"] = "".join(f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in files.items() if name != "SHA256SUMS.txt").encode()
            with self.assertRaises(M.PreflightError):
                M.validate_package(files, self.policy)
        changed = dict(self.files)
        changed[M.package_name(self.policy) + "-macOS-arm64.dmg"] = b"changed"
        with self.assertRaises(M.PreflightError):
            M.validate_package(changed, self.policy)

    def test_no_overwrite_existing_input(self):
        target = self.root / "input"
        target.mkdir()
        with self.assertRaises(M.PreflightError):
            M.prepare(self.gh, self.policy, target, self.context)

    def test_download_never_forwards_github_token_to_external_host(self):
        github = M.GitHub("test-token-canary")
        redirect = urllib.error.HTTPError("api", 302, "redirect", {"Location": "https://blob.example.test/signed"}, None)
        class Reader(io.BytesIO):
            def __enter__(self): return self
            def __exit__(self, *args): self.close()
        with patch.object(M.urllib.request, "build_opener") as opener, patch.object(M.urllib.request, "urlopen", return_value=Reader(b"fixture")) as download:
            opener.return_value.open.side_effect = redirect
            result = github.archive(1, hashlib.sha256(b"fixture").hexdigest(), 100)
        self.assertEqual(result, b"fixture")
        self.assertNotIn("Authorization", download.call_args.args[0].headers)
        self.assertEqual(opener.return_value.open.call_args.args[0].headers["Authorization"], "Bearer test-token-canary")

    def test_renderer_only_creates_frozen_files_and_no_build_or_publish(self):
        workflow, policy = R.render(self.policy_path(), self.root / "rendered")
        content = workflow.read_text()
        self.assertNotIn("__SOURCE_SHA__", content)
        self.assertNotIn("__BUILD__", content)
        self.assertIn("--build 141", content)
        self.assertIn(self.policy["source_sha"], content)
        self.assertNotIn("xcodebuild", content)
        self.assertNotIn("gh release", content)
        self.assertNotIn("workflow_dispatch:", content)
        self.assertIn("github.run_attempt == 1", content)
        self.assertEqual(json.loads(policy.read_text()), self.policy)
        before_sign, sign_and_upload = content.split("- name: Sign original approved 0.1.8 build", 1)
        self.assertNotIn("secrets.APPLE", before_sign)
        self.assertEqual(content.count("secrets.APPLE"), 5)
        self.assertNotIn("actions: write", content)
        with self.assertRaises(R.PREFLIGHT.PreflightError):
            R.render(self.policy_path(), self.root / "rendered")


if __name__ == "__main__":
    unittest.main()
