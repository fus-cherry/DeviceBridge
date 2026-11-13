"""Synthetic-only formal preflight, A/B evidence and credential-scope contracts."""
import copy
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import urllib.error

ROOT = Path(__file__).parent.parent
SPEC = importlib.util.spec_from_file_location("formal_preflight", ROOT/"scripts/verify-build143-scoped-signing.py")
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)
CANARY = "never-disclose-log-url-token-fixture-canary"


def log_result(value=None):
    return ("2026-11-13T11:00:00.1234567Z " + json.dumps(M.EXPECTED_AB_RESULT if value is None else value) + "\n").encode()


class FakeAB:
    def __init__(self):
        self.run={"id":M.AB_RUN,"head_sha":M.AB_SHA,"head_branch":"cloud/0.1.8-build143-cli-ab-diagnostic","run_attempt":1,
                  "status":"completed","conclusion":"success","event":"push","path":".github/workflows/build143-cli-ab-diagnostic.yml","actor":{"login":M.P.OWNER}}
        self.job={"id":M.AB_JOB,"run_id":M.AB_RUN,"run_attempt":1,"head_sha":M.AB_SHA,"name":"cli-only","status":"completed","conclusion":"success",
                  "steps":[{"name":"Diagnose only temporary CLI signing with timestamp; no notarization submission","number":5,"status":"completed","conclusion":"success"}]}
        self.log=log_result()
        self.downloads=[]
    def json(self,path):
        if "/attempts/" in path:return {"total_count":1,"jobs":[self.job]}
        return self.run
    def job_logs(self,identifier):
        self.downloads.append(identifier)
        return self.log


class ScopedSigningPreflightTests(unittest.TestCase):
    def test_exact_successful_ab_result_from_timestamped_job_log(self):
        M.parse_ab_result(b"irrelevant masked log content\n"+log_result()+b"checkout complete\n")
        api=FakeAB();M.validate_ab_evidence(api)
        self.assertEqual(api.downloads,[M.AB_JOB])

    def test_missing_duplicate_wrong_encoding_or_unstamped_result_is_rejected(self):
        for raw in (b"",log_result()+log_result(),b"\xff",json.dumps(M.EXPECTED_AB_RESULT).encode(),b"x"*(M.MAX_LOG+1)):
            with self.assertRaises(M.P.PreflightError):M.parse_ab_result(raw)

    def test_no_weaker_or_ambiguous_ab_proof_can_enable_secrets(self):
        for key,value in (("search_scope_fix_supported",False),("search_scope_fix_supported",1),
                          ("searchlist_restore","restore_not_verified"),("ownedchain_in_searchlist_before",True),
                          ("default_identity_before",True),("timestamp_requested",False),
                          ("notarization_submission","pending"),("submissions",[]),("extra",CANARY)):
            result=dict(M.EXPECTED_AB_RESULT,**{key:value})
            with self.assertRaises(M.P.PreflightError) as error:M.parse_ab_result(log_result(result))
            self.assertNotIn(CANARY,str(error.exception))
        for key in M.EXPECTED_AB_RESULT:
            result=copy.deepcopy(M.EXPECTED_AB_RESULT);del result[key]
            with self.assertRaises(M.P.PreflightError):M.parse_ab_result(log_result(result))
        result=copy.deepcopy(M.EXPECTED_AB_RESULT);result["baseline"]["observations"]=["unclassified_codesign_failure"]
        with self.assertRaises(M.P.PreflightError):M.parse_ab_result(log_result(result))

    def test_duplicate_json_keys_at_any_depth_or_malformed_candidate_are_rejected(self):
        valid=json.dumps(M.EXPECTED_AB_RESULT,sort_keys=True)
        top='{'+ '"search_scope_fix_supported":false,'+valid[1:]
        nested=valid.replace('"baseline": {','"baseline": {"status":"passed",',1)
        for value in (top,nested):
            raw=("2026-11-13T11:00:00Z "+value+"\n").encode()
            with self.assertRaises(M.P.PreflightError):M.parse_ab_result(raw)
            with self.assertRaises(M.P.PreflightError):M.parse_ab_result(raw+log_result())

    def test_live_replayed_changed_source_or_job_ab_cannot_enable_signing(self):
        for record,key,value in (("run","status","in_progress"),("run","run_attempt",2),("run","head_sha","a"*40),
                                 ("run","conclusion","failure"),("job","id",123),("job","head_sha","a"*40),
                                 ("job","run_attempt",2),("job","conclusion","failure")):
            api=FakeAB();getattr(api,record)[key]=value
            with self.assertRaises(M.P.PreflightError):M.validate_ab_evidence(api)
            self.assertEqual(api.downloads,[])

    def test_log_redirect_never_forwards_token_and_never_prints_response(self):
        redirect=urllib.error.HTTPError("api",302,"redirect",{"Location":"https://blob.example.test/"+CANARY},None)
        class Reader(io.BytesIO):
            def __enter__(self):return self
            def __exit__(self,*args):self.close()
        api=M.EvidenceGitHub(CANARY)
        with patch.object(M.urllib.request,"build_opener") as opener,patch.object(M.urllib.request,"urlopen",return_value=Reader(log_result())) as download:
            opener.return_value.open.side_effect=redirect
            self.assertEqual(api.job_logs(M.AB_JOB),log_result())
        self.assertEqual(opener.return_value.open.call_args.args[0].headers["Authorization"],"Bearer "+CANARY)
        self.assertNotIn("Authorization",download.call_args.args[0].headers)

    def test_unknown_download_error_and_non_https_redirect_are_opaque(self):
        api=M.EvidenceGitHub(CANARY)
        for error in (OSError(CANARY),urllib.error.HTTPError("api",302,"redirect",{"Location":"http://blob.example.test/"+CANARY},None)):
            with patch.object(M.urllib.request,"build_opener") as opener:
                opener.return_value.open.side_effect=error
                with self.assertRaises(M.P.PreflightError) as raised:api.job_logs(M.AB_JOB)
                self.assertNotIn(CANARY,str(raised.exception))

    def test_formal_profile_rejects_other_branch_owner_event_and_attempt(self):
        context={"GITHUB_REPOSITORY":M.P.REPOSITORY,"GITHUB_ACTOR":M.P.OWNER,"GITHUB_REF":"refs/heads/"+M.BRANCH,
                 "GITHUB_EVENT_NAME":"push","GITHUB_RUN_ATTEMPT":"1","GITHUB_RUN_ID":"999"}
        self.assertEqual(M.context_run(context),999)
        for key,value in (("GITHUB_REPOSITORY","other/repo"),("GITHUB_ACTOR","other"),("GITHUB_REF","refs/heads/main"),
                          ("GITHUB_EVENT_NAME","workflow_dispatch"),("GITHUB_RUN_ATTEMPT","2")):
            with self.assertRaises(M.P.PreflightError):M.context_run(dict(context,**{key:value}))

    def test_workflow_pins_new_signer_separate_from_original_package_and_limits_secrets(self):
        workflow=(ROOT/M.WORKFLOW).read_text()
        ordinary,signing=workflow.split("- name: Sign, notarize and fully verify only the already-tested Build143",1)
        self.assertNotIn("secrets.APPLE",ordinary)
        self.assertEqual(signing.count("secrets.APPLE"),5)
        self.assertIn("ref: ${{ github.sha }}",ordinary)
        self.assertIn("164655c7ab7a1fae6ff8b37757be0c44fa6afc6e6e4e9b674a7499d53cab211f",ordinary)
        self.assertIn("--commit "+M.BASE["source_sha"],signing)
        self.assertIn("persist-credentials: false",workflow)
        self.assertIn("github.run_attempt == 1",workflow)
        self.assertIn("github.actor == 'fus-cherry'",workflow)
        self.assertIn("github.ref == 'refs/heads/"+M.BRANCH+"'",workflow)
        for forbidden in ("xcodebuild", "workflow_dispatch:", "actions: write", "gh release", "default-keychain"):
            self.assertNotIn(forbidden,workflow)
        self.assertIn("if: always()",signing.split("- name: Preserve non-secret outcome",1)[1])
        output=signing.split("- name: Upload only fully accepted",1)[1]
        self.assertNotIn("if:",output)
        self.assertIn("${{ runner.temp }}/apple-signed/",output)

if __name__ == "__main__":unittest.main()
