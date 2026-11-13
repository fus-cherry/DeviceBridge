"""Synthetic CLI-only hard-stop and no-disclosure contracts. No real signing/Apple calls."""
import copy
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile
import unittest
from unittest.mock import patch
import importlib.util

ROOT = Path(__file__).parent.parent

def load(file, name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

M = load("diagnose-build143-cli.py", "cli_diagnostic")
F = load("test_apple_signing.py", "original_test_fixture")
V = load("verify-release.py", "fixture_verifier")
CANARY = "do-not-disclose-fixture-certificate-canary"

class FakeCommands(F.FakeCommands):
    def __init__(self, app, failure=False, **kwargs):
        super().__init__(app, **kwargs)
        self.failure = failure
    def run(self, args, *, phase, **kwargs):
        if phase == "Copy verified CLI":
            self.calls.append((args, phase))
            shutil.copyfile(args[1], args[2])
            return ""
        return super().run(args, phase=phase, **kwargs)
    def codesign_cli(self, args):
        self.calls.append((args, "Sign bundled CLI"))
        return subprocess.CompletedProcess(args, 1 if self.failure else 0,
                                           stdout=CANARY.encode(), stderr=b"errSecInternalComponent " + CANARY.encode())

class CLIDiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.fixture = F.AppleSigningTests(methodName="runTest")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.Commands, self.Signer = M.classes(F.MODULE, V)

    def invoke(self, commands):
        signer = self.Signer(commands)
        values = {name: F.VALUES[name] for name in M.NAMES}
        capture = io.StringIO()
        with patch.object(F.MODULE.sys, "platform", "darwin"), patch.dict(os.environ, {"RUNNER_TEMP": str(self.fixture.root)}), contextlib.redirect_stdout(capture), contextlib.redirect_stderr(capture):
            signer.run(self.fixture.input, self.fixture.root / "output", "0.1.8", "132", F.COMMIT, values)
        self.assertEqual(capture.getvalue(), "")
        self.assertEqual(list(self.fixture.root.glob("devicebridge-apple-*")), [])
        self.assertEqual(list((self.fixture.root / "output").iterdir()), [])
        self.assertNotIn(CANARY, json.dumps(signer.diagnostic))
        return signer

    def test_cli_failure_is_classified_and_stops_with_cleanup_no_notary(self):
        commands = FakeCommands(self.fixture.app, failure=True)
        signer = self.invoke(commands)
        self.assertEqual(signer.diagnostic["cli_signing"], "failed")
        self.assertEqual(signer.diagnostic["observations"], ["security_framework_internal_component"])
        self.assert_no_notary_or_app_signing(commands)

    def test_cli_success_still_stops_only_diagnostic_copy_and_verifies_team(self):
        commands = FakeCommands(self.fixture.app)
        signer = self.invoke(commands)
        self.assertEqual(signer.diagnostic["cli_signing"], "passed_diagnostic_copy_only")
        self.assertIn("Verify diagnostic CLI", [phase for _, phase in commands.calls])
        self.assertIn("Inspect Developer ID signature", [phase for _, phase in commands.calls])
        self.assert_no_notary_or_app_signing(commands)

    def assert_no_notary_or_app_signing(self, commands):
        phases = [phase for _, phase in commands.calls]
        self.assertEqual(phases.count("Sign bundled CLI"), 1)
        self.assertIn("Delete temporary keychain", phases)
        for phase in ("Validate Apple notarization credentials", "Sign macOS app", "Apple notarization upload", "Prepare app notarization submission", "Sign DMG"):
            self.assertNotIn(phase, phases)
        cli = next(args for args, phase in commands.calls if phase == "Sign bundled CLI")
        self.assertEqual(cli[:3], ["/usr/bin/codesign", "--force", "--sign"])
        self.assertEqual(cli[6:9], ["--options", "runtime", "--timestamp"])
        self.assertEqual(Path(cli[-1]).name, "devicebridge-agent")
        self.assertNotIn("notarytool", repr(commands.calls))
        self.assertFalse(any("list-keychains" in args or "default-keychain" in args for args, _ in commands.calls))

    def test_import_or_identity_failure_never_reaches_codesign_and_cleans(self):
        for options in ({"fail_phase": "Import Developer ID certificate"}, {"wrong_team": True}):
            commands = FakeCommands(self.fixture.app, **options)
            with patch.object(F.MODULE.sys, "platform", "darwin"), patch.dict(os.environ, {"RUNNER_TEMP": str(self.fixture.root)}):
                signer = self.Signer(commands)
                with self.assertRaises(F.MODULE.SigningError):
                    signer.run(self.fixture.input, self.fixture.root / "output", "0.1.8", "132", F.COMMIT, {name:F.VALUES[name] for name in M.NAMES})
            self.assertNotIn("Sign bundled CLI", [phase for _, phase in commands.calls])
            self.assertIn("Delete temporary keychain", [phase for _, phase in commands.calls])
            shutil.rmtree(self.fixture.root / "output")

    def test_command_whitelist_rejects_all_notary_and_app_signing_calls(self):
        commands = self.Commands()
        with patch.object(F.MODULE.subprocess, "run") as run:
            for args, phase in ((["/usr/bin/xcrun", "notarytool", "submit"], "Apple notarization upload"),
                                (["/usr/bin/xcrun", "notarytool", "store-credentials"], "Validate Apple notarization credentials"),
                                (["/usr/bin/codesign", "--force", "--sign", "identity", "app"], "Sign macOS app")):
                with self.assertRaises(F.MODULE.SigningError): commands.run(args, phase=phase)
            run.assert_not_called()

    def test_cli_runner_captures_output_and_no_secret_environment(self):
        args = ["/usr/bin/codesign", "--force", "--sign", F.IDENTITY, "--keychain", "/fixture.keychain", "--options", "runtime", "--timestamp", "/fixture/devicebridge-agent"]
        with patch.dict(os.environ, F.VALUES), patch.object(M.subprocess, "run", return_value=subprocess.CompletedProcess(args, 1, CANARY.encode(), CANARY.encode())) as run:
            result = self.Commands().codesign_cli(args)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(run.call_args.kwargs["capture_output"])
        self.assertTrue(set(F.MODULE.SECRET_NAMES).isdisjoint(run.call_args.kwargs["env"]))
        for change in (["--options", "runtime", "--timestamp=none"], ["--options", "none", "--timestamp"]):
            changed = args[:6] + change + args[9:]
            with self.assertRaises(F.MODULE.SigningError): self.Commands().codesign_cli(changed)

    def test_owner_context_and_workflow_only_three_secrets_no_artifact(self):
        context = {"GITHUB_REPOSITORY":M.P.REPOSITORY,"GITHUB_ACTOR":M.P.OWNER,"GITHUB_REF":"refs/heads/"+M.BRANCH,"GITHUB_EVENT_NAME":"push","GITHUB_RUN_ATTEMPT":"1","GITHUB_RUN_ID":"999"}
        self.assertEqual(M.context_run(context),999)
        for key,value in (("GITHUB_ACTOR","other"),("GITHUB_REF","refs/heads/main"),("GITHUB_RUN_ATTEMPT","2"),("GITHUB_EVENT_NAME","workflow_dispatch")):
            with self.assertRaises(M.P.PreflightError): M.context_run(dict(context,**{key:value}))
        workflow=(ROOT / M.WORKFLOW).read_text()
        ordinary, secret = workflow.split("- name: Diagnose only temporary CLI signing",1)
        self.assertNotIn("secrets.APPLE",ordinary)
        self.assertEqual(secret.count("secrets.APPLE"),3)
        for forbidden in ("secrets.APPLE_ID", "secrets.APPLE_APP_SPECIFIC_PASSWORD", "upload-artifact", "notarytool", "actions: write", "workflow_dispatch:"):
            self.assertNotIn(forbidden,workflow)
        self.assertIn("ref: "+M.BASE["source_sha"],workflow)
        self.assertNotIn('"--timestamp=none"', (ROOT/'scripts/diagnose-build143-cli.py').read_text())

class PreflightNegativeTests(unittest.TestCase):
    def api(self):
        def job(identifier, name, run, sha):
            return {"id":identifier,"name":name,"run_id":run,"head_sha":sha,"run_attempt":1,
                    "status":"completed","conclusion":"failure","steps":[],
                    "started_at":"2026-11-13T09:00:00Z","completed_at":"2026-11-13T11:00:00Z"}
        def step(name, number):
            return {"name":name,"number":number,"status":"completed","conclusion":"success",
                    "started_at":"2026-11-13T10:00:00Z","completed_at":"2026-11-13T10:01:00Z"}
        base=M.BASE
        original={"id":base["source_run"],"head_sha":base["source_sha"],"head_branch":"cloud/0.1.8-candidate",
                  "run_attempt":1,"status":"completed","event":"push","path":".github/workflows/release.yml","actor":{"login":M.P.OWNER}}
        build=job(base["source_build_job_id"],"build",base["source_run"],base["source_sha"])
        build["conclusion"]="success"
        build["steps"]=[step("Build and verify DMG",18),step(M.P.PACKAGE_UPLOAD,19)]
        apple=job(base["prior_apple_job_id"],"apple-sign",base["source_run"],base["source_sha"])
        retry={"id":M.RETRY_RUN,"head_sha":M.RETRY_SHA,"head_branch":"cloud/0.1.8-apple-retry-build143",
               "run_attempt":1,"status":"completed","conclusion":"failure","event":"push",
               "path":".github/workflows/apple-sign-retry-build143.yml","actor":{"login":M.P.OWNER}}
        retried=job(M.RETRY_JOB,"sign-verified-build143",M.RETRY_RUN,M.RETRY_SHA)
        failed=step("Sign original approved 0.1.8 build with the original reviewed signer",5)
        failed["conclusion"]="failure"
        retried["steps"]=[failed,step("Preserve non-secret outcome including notarization submission IDs",6)]
        class API:
            def __init__(self):
                self.original=original;self.retry=retry;self.retried=retried;self.build=build;self.apple=apple
            def json(self,path):
                if "/actions/runs?" in path:return {"total_count":1,"workflow_runs":[{"id":999,"run_attempt":1,"path":M.WORKFLOW}]}
                if f"/{M.RETRY_RUN}/attempts/" in path:return {"total_count":1,"jobs":[self.retried]}
                if "/attempts/" in path:return {"total_count":2,"jobs":[self.build,self.apple]}
                return self.retry if path.endswith(str(M.RETRY_RUN)) else self.original
        return API()

    def test_retry_live_replayed_changed_source_or_job_is_rejected(self):
        M.source_evidence(self.api(),999)
        changes=(("retry","status","in_progress"),("retry","run_attempt",2),("retry","head_sha","a"*40),
                 ("retry","conclusion","success"),("retried","id",123),("retried","head_sha","a"*40),
                 ("retried","run_attempt",2),("original","run_attempt",2),("build","conclusion","failure"))
        for record,key,value in changes:
            api=self.api();getattr(api,record)[key]=value
            with self.assertRaises(M.P.PreflightError,msg=record+key):M.source_evidence(api,999)

    def test_extra_submission_or_state_and_changed_error_cannot_reach_signing(self):
        summary={"status":"failed","apple_notarized":False,"commit":M.BASE["source_sha"],
                 "version":"0.1.8","build":"143","error":M.CLI_ERROR}
        context={"GITHUB_REPOSITORY":M.P.REPOSITORY,"GITHUB_ACTOR":M.P.OWNER,"GITHUB_REF":"refs/heads/"+M.BRANCH,
                 "GITHUB_EVENT_NAME":"push","GITHUB_RUN_ATTEMPT":"1","GITHUB_RUN_ID":"999"}
        for key,value in (("submissions",[]),("submissions",[{"id":"possibly-pending"}]),("submission_state","submitted-pending"),
                          ("state","accepted"),("error","some other codesign failure"),("commit","a"*40),("apple_notarized",True)):
            stream=io.BytesIO()
            with zipfile.ZipFile(stream,"w") as z:z.writestr("apple-signing-summary.json",json.dumps(dict(summary,**{key:value})))
            api=self.api();api.archive=lambda *args:stream.getvalue()
            with tempfile.TemporaryDirectory() as root,patch.object(M.P,"validate_artifact"):
                with self.assertRaises(M.P.PreflightError,msg=key):M.prepare(api,Path(root)/"input",context)
                self.assertFalse((Path(root)/"input").exists())

if __name__ == "__main__": unittest.main()
