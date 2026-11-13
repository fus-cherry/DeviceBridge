#!/usr/bin/env python3
"""Local, controlled certificate diagnosis. Never authenticates, signs or exports keys."""
from __future__ import annotations
import argparse
import base64
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile

NAMES = ("APPLE_CERTIFICATE_P12_BASE64", "APPLE_CERTIFICATE_PASSWORD", "APPLE_TEAM_ID")
ERRORS = {
    "local_tool_unavailable_or_timed_out", "required_diagnostic_secret_missing", "team_format_invalid",
    "diagnostic_secret_format_invalid", "certificate_size_out_of_range", "certificate_base64_invalid",
    "temporary_keychain_creation_failed", "temporary_keychain_unlock_failed",
}
PROBE_RESULTS = {
    "probe_matching_named_developer_id_private_key", "probe_no_matching_named_developer_id_private_key",
    "probe_ambiguous_matching_identities", "probe_no_identity", "probe_lookup_failed",
    "probe_keychain_unavailable", "probe_invalid_input",
}

class DiagnosticError(Exception):
    pass

class Commands:
    def run(self, args, *, data=None):
        # No command receives any original Apple Secret via its environment.
        environment = {name: os.environ[name] for name in ("PATH", "HOME", "TMPDIR") if name in os.environ}
        try:
            return subprocess.run(args, input=data, capture_output=True, check=False,
                                  timeout=60, env=environment)
        except (OSError, subprocess.TimeoutExpired):
            raise DiagnosticError("local_tool_unavailable_or_timed_out") from None


def input_values(environment):
    if any(not environment.get(name) for name in NAMES):
        raise DiagnosticError("required_diagnostic_secret_missing")
    values = {name: environment[name] for name in NAMES}
    if not re.fullmatch(r"[A-Z0-9]{10}", values["APPLE_TEAM_ID"]):
        raise DiagnosticError("team_format_invalid")
    if any(c in values["APPLE_CERTIFICATE_PASSWORD"] for c in "\r\n\x00") or "\x00" in values["APPLE_CERTIFICATE_P12_BASE64"]:
        raise DiagnosticError("diagnostic_secret_format_invalid")
    if len(values["APPLE_CERTIFICATE_P12_BASE64"]) > 2 * 1024 * 1024:
        raise DiagnosticError("certificate_size_out_of_range")
    try:
        certificate = base64.b64decode("".join(values["APPLE_CERTIFICATE_P12_BASE64"].split()), validate=True)
    except (ValueError, TypeError):
        raise DiagnosticError("certificate_base64_invalid") from None
    if not 32 <= len(certificate) <= 1024 * 1024:
        raise DiagnosticError("certificate_size_out_of_range")
    return values, certificate


def openssl_classification(result):
    # Raw output remains in memory, is never printed, returned or saved.
    text = (result.stdout + result.stderr).lower()
    if result.returncode == 0:
        if b"mac is absent" in text or b"no mac" in text:
            return "parsed_without_mac_integrity_proof"
        if b"mac:" in text or b"mac iteration" in text or b"mac verified ok" in text:
            return "parsed_mac_verified"
        return "parsed_mac_presence_unknown"
    if any(s in text for s in (b"mac verify error", b"mac verify failure", b"mac verification failed", b"pkcs12_verify_mac")):
        return "password_or_archive_integrity_failure"
    if any(s in text for s in (b"unsupported", b"unknown cipher", b"inner_evp_generic_fetch")):
        return "parser_unsupported_algorithm"
    if any(s in text for s in (b"asn1", b"asn.1", b"wrong tag", b"header too long", b"not enough data")):
        return "malformed_or_non_pkcs12_archive"
    return "parser_failure_unclassified"


def import_classification(result):
    if result.returncode == 0:
        return "imported"
    text = (result.stdout + result.stderr).lower()
    for phrase, category in (
        (b"mac verification failed", "mac_verification_failed"),
        (b"unknown format", "unknown_or_unsupported_format"),
        (b"unable to decode", "decode_failed"),
        (b"user interaction is not allowed", "interaction_denied"),
        (b"specified item already exists", "duplicate_item"),
        (b"authorization denied", "authorization_denied"),
    ):
        if phrase in text:
            return category
    return "import_failure_unclassified"


def diagnose(environment, probe: Path | None, commands=None, temporary_parent=None):
    commands = commands or Commands()
    report = {"openssl": "not_run", "security_import": "not_run", "local_identity": "not_run",
              "cleanup": "not_needed", "apple_authentication_or_signing": "not_attempted"}
    values = {}
    certificate = None
    root = None
    keychain = None
    try:
        values, certificate = input_values(environment)
        root = Path(tempfile.mkdtemp(prefix="devicebridge-p12-diagnostic-", dir=temporary_parent))
        root.chmod(0o700)
        encrypted = root / "identity.p12"
        with encrypted.open("xb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(certificate)
        certificate = None
        password = values["APPLE_CERTIFICATE_PASSWORD"]
        parsed = commands.run(["/usr/bin/openssl", "pkcs12", "-in", str(encrypted), "-info", "-noout", "-passin", "stdin"],
                              data=password.encode("utf-8") + b"\n")
        report["openssl"] = openssl_classification(parsed)
        # No key material, certificate content, algorithm text or tool errors leave memory.
        parsed = None
        if report["openssl"] not in {"parsed_mac_verified", "parser_unsupported_algorithm", "parsed_mac_presence_unknown"}:
            return report
        keychain = root / "diagnostic.keychain-db"
        random_password = secrets.token_urlsafe(48)
        created = commands.run(["/usr/bin/security", "create-keychain", "-p", random_password, str(keychain)])
        if created.returncode:
            raise DiagnosticError("temporary_keychain_creation_failed")
        unlocked = commands.run(["/usr/bin/security", "unlock-keychain", "-p", random_password, str(keychain)])
        if unlocked.returncode:
            raise DiagnosticError("temporary_keychain_unlock_failed")
        imported = commands.run(["/usr/bin/security", "import", str(encrypted), "-k", str(keychain), "-P", password, "-f", "pkcs12", "-T", ""])
        report["security_import"] = import_classification(imported)
        imported = None
        if report["security_import"] == "imported" and probe is None:
            report["local_identity"] = "probe_not_available"
        elif report["security_import"] == "imported":
            checked = commands.run([str(probe), str(keychain), values["APPLE_TEAM_ID"]])
            # Native helper emits only one of these fixed categories; all stderr hidden.
            try:
                category = checked.stdout.decode("ascii").strip()
            except UnicodeError:
                category = ""
            report["local_identity"] = category if checked.returncode == 0 and category in PROBE_RESULTS else "probe_failure_unclassified"
            checked = None
        random_password = None
        password = None
    except DiagnosticError as error:
        report["error"] = str(error) if str(error) in ERRORS else "unexpected_local_diagnostic_failure"
    except BaseException:
        report["error"] = "unexpected_local_diagnostic_failure"
    finally:
        values.clear()
        certificate = None
        if keychain is not None:
            try:
                result = commands.run(["/usr/bin/security", "delete-keychain", str(keychain)])
                report["cleanup"] = "complete" if result.returncode == 0 else "temporary_keychain_cleanup_failed"
            except BaseException:
                report["cleanup"] = "temporary_keychain_cleanup_failed"
        if root is not None:
            try:
                shutil.rmtree(root)
                if report["cleanup"] == "not_needed":
                    report["cleanup"] = "complete"
            except BaseException:
                report["cleanup"] = "private_directory_cleanup_failed"
        environment.clear()
        for name in NAMES:
            os.environ.pop(name, None)
    return report


def main():
    report = None
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--identity-probe", required=True, type=Path)
        args = parser.parse_args()
        if sys.platform != "darwin":
            raise DiagnosticError("required_local_macos_tools_unavailable")
        probe = args.identity_probe.resolve() if args.identity_probe.is_file() else None
        report = diagnose(dict(os.environ), probe, temporary_parent=os.environ.get("RUNNER_TEMP"))
    except BaseException:
        report = {"error": "diagnostic_setup_failed", "apple_authentication_or_signing": "not_attempted"}
    finally:
        for name in NAMES:
            os.environ.pop(name, None)
    print(json.dumps(report, sort_keys=True))
    # Even a local pass is NOT proof of certificate trust, Apple authentication or signing.
    return 0 if report.get("openssl") == "parsed_mac_verified" and report.get("security_import") == "imported" and report.get("local_identity") == "probe_matching_named_developer_id_private_key" and report.get("cleanup") == "complete" else 1

if __name__ == "__main__":
    raise SystemExit(main())
