#!/usr/bin/env python3
"""Sign a verified CI package with Developer ID, notarize, and staple it.

Secrets are read only from the process environment. External command output is
captured, never echoed. This script never changes the default keychain and never
installs or runs the downloaded application. It preserves the full user search
list while temporarily including its own keychain, then verifies exact search
list restoration before deleting that keychain or publishing success metadata.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid

SECRET_NAMES = (
    "APPLE_CERTIFICATE_P12_BASE64", "APPLE_CERTIFICATE_PASSWORD", "APPLE_ID",
    "APPLE_TEAM_ID", "APPLE_APP_SPECIFIC_PASSWORD",
)
MACHO_MAGIC = {
    b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


class SigningError(Exception):
    pass


class Commands:
    def run(self, args: list[str], *, phase: str, timeout: int = 1200, include_stderr: bool = False) -> str:
        try:
            result = subprocess.run(args, check=False, capture_output=True, text=True,
                                    timeout=timeout, env=safe_child_environment())
        except (OSError, subprocess.TimeoutExpired) as error:
            raise SigningError(f"{phase}: tool unavailable or timed out") from error
        if result.returncode:
            # Even an authentication tool's error text may echo account details.
            raise SigningError(f"{phase}: command failed (exit {result.returncode}); no secret-bearing output retained")
        return result.stdout + (result.stderr if include_stderr else "")


def safe_child_environment() -> dict[str, str]:
    # Only notarytool/security receive required credentials as explicit arguments.
    # None of the artifact inspection, packaging, or verification tools inherit Secrets.
    return {k: v for k, v in os.environ.items() if k not in SECRET_NAMES}


class ScopedKeychainSearchList:
    """Preserve a complete user search list around one self-created keychain.

    Construct before create-keychain, which may itself register the new chain.
    No keychain paths or tool output are logged. Commands always use argv, never
    a shell. This helper does not change defaults, trust, ACLs or certificates.
    """

    def __init__(self, commands: Commands):
        self.commands = commands
        self.original = self._read("Snapshot original user keychain search list")

    def _read(self, phase: str) -> tuple[str, ...]:
        raw = self.commands.run(["/usr/bin/security", "list-keychains", "-d", "user"],
                                phase=phase, timeout=60, include_stderr=True)
        try:
            paths = tuple(shlex.split(raw))
        except ValueError as error:
            raise SigningError("User keychain search list is malformed; no paths logged") from error
        if any(not Path(path).is_absolute() or any(c in path for c in "\r\n\x00") for path in paths):
            raise SigningError("User keychain search list contains an unexpected path; no paths logged")
        return paths

    def include(self, keychain: Path) -> None:
        def canonical(path):
            try:
                return str(Path(path).resolve())
            except (OSError, RuntimeError) as error:
                raise SigningError("Unable to resolve temporary keychain search scope; no paths logged") from error

        target = canonical(keychain)
        current = self._read("Inspect temporary keychain search scope")
        # create-keychain may add this chain automatically, in any position.
        # No other existing entry may disappear, move or be replaced.
        is_target = lambda path: canonical(path) == target
        if current != self.original and tuple(p for p in current if not is_target(p)) != self.original:
            raise SigningError("User keychain search list changed unexpectedly; signing withheld")
        if any(is_target(path) for path in current):
            return
        expected = (*current, target)
        self.commands.run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *expected],
                          phase="Append temporary keychain to preserved search list", timeout=60)
        if self._read("Verify temporary keychain search scope") != expected:
            raise SigningError("Temporary keychain search scope did not match the preserved list")

    def restore(self) -> None:
        # Restore even after partial create/append failures. A failed command or
        # read-back must withhold delivery, regardless of any Apple acceptance.
        self.commands.run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *self.original],
                          phase="Restore original user keychain search list", timeout=60)
        if self._read("Verify original user keychain search list") != self.original:
            raise SigningError("Original user keychain search list was not exactly restored")


def load_secrets(environment: dict[str, str]) -> dict[str, str]:
    missing = [name for name in SECRET_NAMES if not environment.get(name, "").strip()]
    if missing:
        raise SigningError("Missing GitHub Secrets: " + ", ".join(missing))
    values = {name: environment[name] for name in SECRET_NAMES}
    if not re.fullmatch(r"[A-Z0-9]{10}", values["APPLE_TEAM_ID"]):
        raise SigningError("APPLE_TEAM_ID must be the 10-character developer Team ID")
    if "@" not in values["APPLE_ID"] or any(c in values["APPLE_ID"] for c in "\r\n\x00"):
        raise SigningError("APPLE_ID must be the notarization account email")
    for name, value in values.items():
        if "\x00" in value or name != "APPLE_CERTIFICATE_P12_BASE64" and ("\r" in value or "\n" in value):
            raise SigningError(f"{name} contains an invalid line break or NUL")
    return values


def decode_certificate(value: str) -> bytes:
    try:
        data = base64.b64decode("".join(value.split()), validate=True)
    except (ValueError, TypeError) as error:
        raise SigningError("APPLE_CERTIFICATE_P12_BASE64 is not valid Base64") from error
    if not 32 <= len(data) <= 1024 * 1024:
        raise SigningError("Certificate file has an unexpected size")
    return data


def verify_input(directory: Path, version: str, build: str, commit: str) -> tuple[Path, dict]:
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[1-9]\d*", build):
        raise SigningError("Invalid release version/build")
    if not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise SigningError("Expected source commit must be a full SHA")
    name = f"DeviceBridge-{version}-build{build}-macOS-arm64.dmg"
    expected = {name, "build-info.json", "release-notes.md"}
    actual = set()
    try:
        manifest = directory / "SHA256SUMS.txt"
        if manifest.is_symlink():
            raise SigningError("Input checksum manifest is a symlink")
        lines = manifest.read_text().splitlines()
        for line in lines:
            match = re.fullmatch(r"([a-f0-9]{64})  ([^/\\]+)", line)
            if not match or match[2] not in expected or match[2] in actual:
                raise SigningError("Unexpected or duplicate artifact checksum entry")
            target = directory / match[2]
            if target.is_symlink() or not target.is_file():
                raise SigningError("Input artifact is missing or is a symlink")
            if sha256(target) != match[1]:
                raise SigningError("CI artifact checksum mismatch")
            actual.add(match[2])
        if actual != expected:
            raise SigningError("CI artifact checksum manifest is incomplete")
        info = json.loads((directory / "build-info.json").read_text())
        if not isinstance(info, dict) or (info.get("version"), info.get("build"), info.get("commit"), info.get("architecture")) != (version, build, commit, "arm64"):
            raise SigningError("CI artifact does not match the approved commit/version/architecture")
        return directory / name, info
    except (OSError, ValueError) as error:
        raise SigningError("Unable to read the verified CI artifact") from error


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def find_identity(output: str, team: str) -> str:
    identities = []
    for line in output.splitlines():
        match = re.search(r'\b([A-Fa-f0-9]{40})\s+"Developer ID Application: [^"\r\n]+ \(([A-Z0-9]{10})\)"', line)
        if match and match[2] == team:
            identities.append(match[1].upper())
    if len(identities) != 1:
        raise SigningError("Expected exactly one valid Developer ID Application identity matching APPLE_TEAM_ID")
    return identities[0]


def native_files(app: Path) -> list[Path]:
    native = []
    for path in app.rglob("*"):
        if path.is_symlink():
            try:
                if not path.resolve(strict=True).is_relative_to(app.resolve()):
                    raise SigningError("App contains an escaping symlink")
            except OSError as error:
                raise SigningError("App contains a broken symlink") from error
            continue
        if path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO_MAGIC:
                    native.append(path)
    expected = {app / "Contents/MacOS/DeviceBridge", app / "Contents/MacOS/devicebridge-agent"}
    if set(native) != expected:
        # No permissive --deep signing: unexpected nested native code needs review.
        raise SigningError("Unexpected native-code layout; review nested code before signing")
    return sorted(native)


def verify_identity(commands: Commands, target: Path, team: str) -> None:
    output = commands.run(["/usr/bin/codesign", "--display", "--verbose=4", str(target)], phase="Inspect Developer ID signature", include_stderr=True)
    if f"TeamIdentifier={team}" not in output.splitlines() or "Authority=Developer ID Application:" not in output:
        raise SigningError("Signed code identity does not match the approved Developer ID team")


class AppleSigner:
    def __init__(self, commands: Commands | None = None):
        self.commands = commands or Commands()
        self.keychain: Path | None = None
        self.search_list: ScopedKeychainSearchList | None = None
        self.mount: Path | None = None
        self.summary = {"status": "not-started", "apple_notarized": False}

    def run(self, directory: Path, output: Path, version: str, build: str, commit: str,
            values: dict[str, str]) -> None:
        if sys.platform != "darwin":
            raise SigningError("Apple signing requires a macOS runner")
        dmg, info = verify_input(directory, version, build, commit)
        if output.exists():
            raise SigningError("Signed output already exists; refusing to overwrite it")
        output.mkdir(parents=True)
        self.summary.update(status="running", commit=commit, version=version, build=build)
        private_root = Path(tempfile.mkdtemp(prefix="devicebridge-apple-", dir=os.environ.get("RUNNER_TEMP")))
        private_root.chmod(0o700)
        try:
            signed_dmg, app_id, dmg_id = self._sign(dmg, output, private_root, info, values)
        finally:
            # Never attach this directory to an artifact, even on failure.
            cleanup_errors = []
            if self.mount is not None:
                try:
                    self.commands.run(["/usr/bin/hdiutil", "detach", str(self.mount)], phase="Detach input DMG", timeout=60)
                    self.mount = None
                except SigningError:
                    cleanup_errors.append("input DMG detach failed")
            if self.search_list is not None:
                try:
                    self.search_list.restore()
                    self.search_list = None
                except SigningError:
                    cleanup_errors.append("original user keychain search list restoration failed")
            if self.keychain is not None:
                try:
                    self.commands.run(["/usr/bin/security", "delete-keychain", str(self.keychain)], phase="Delete temporary keychain", timeout=60)
                    self.keychain = None
                except SigningError:
                    cleanup_errors.append("temporary keychain deletion failed")
            shutil.rmtree(private_root, ignore_errors=True)
            if cleanup_errors:
                self.summary.update(status="failed", apple_notarized=False)
                raise SigningError("Cleanup failed: " + "; ".join(cleanup_errors))
        # No accepted metadata or successful summary before verified cleanup.
        # Existing submission IDs remain in the safe summary even if cleanup fails.
        self._record_acceptance(output, info, signed_dmg, app_id, dmg_id, values["APPLE_TEAM_ID"])

    def _sign(self, dmg: Path, output: Path, work: Path, info: dict, values: dict[str, str]) -> tuple[Path, str, str]:
        run = self.commands.run
        team = values["APPLE_TEAM_ID"]
        certificate = work / "identity.p12"
        with certificate.open("xb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(decode_certificate(values["APPLE_CERTIFICATE_P12_BASE64"]))
        keychain_password = secrets.token_urlsafe(48)
        keychain = work / "signing.keychain-db"
        self.search_list = ScopedKeychainSearchList(self.commands)
        self.keychain = keychain  # clean up even after a partial create/import failure
        run(["/usr/bin/security", "create-keychain", "-p", keychain_password, str(keychain)], phase="Create temporary signing keychain")
        self.search_list.include(keychain)
        run(["/usr/bin/security", "set-keychain-settings", "-lut", "21600", str(keychain)], phase="Limit temporary keychain lifetime")
        run(["/usr/bin/security", "unlock-keychain", "-p", keychain_password, str(keychain)], phase="Unlock temporary signing keychain")
        run(["/usr/bin/security", "import", str(certificate), "-k", str(keychain), "-P", values["APPLE_CERTIFICATE_PASSWORD"], "-T", "/usr/bin/codesign"], phase="Import Developer ID certificate")
        certificate.unlink()
        run(["/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", keychain_password, str(keychain)], phase="Permit signing with this temporary key")
        identity = find_identity(run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning", str(keychain)], phase="Validate Developer ID identity"), team)
        profile = "devicebridge-notary"
        run(["/usr/bin/xcrun", "notarytool", "store-credentials", profile, "--apple-id", values["APPLE_ID"], "--team-id", team,
             "--password", values["APPLE_APP_SPECIFIC_PASSWORD"], "--keychain", str(keychain)], phase="Validate Apple notarization credentials")
        mount = work / "input-mount"
        mount.mkdir()
        self.mount = mount
        run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", str(mount), str(dmg)], phase="Mount verified input DMG")
        stage = work / "stage"
        stage.mkdir()
        app = stage / "DeviceBridge.app"
        run(["/usr/bin/ditto", str(mount / "DeviceBridge.app"), str(app)], phase="Copy verified app")
        run(["/usr/bin/hdiutil", "detach", str(mount)], phase="Detach input DMG")
        self.mount = None
        verify_spec = importlib.util.spec_from_file_location("release_verifier", Path(__file__).with_name("verify-release.py"))
        verifier = importlib.util.module_from_spec(verify_spec)
        verify_spec.loader.exec_module(verifier)
        verifier.verify(app, info["version"], info["build"])
        if verifier.macho_architectures(app / "Contents/MacOS/DeviceBridge") != {"arm64"}:
            raise SigningError("Unexpected main app architecture")
        for target in native_files(app):
            # A containing app is sealed last. Never grant runtime exceptions.
            if target.name != "DeviceBridge":
                run(["/usr/bin/codesign", "--force", "--sign", identity, "--keychain", str(keychain), "--options", "runtime", "--timestamp", str(target)], phase="Sign bundled CLI")
        run(["/usr/bin/codesign", "--force", "--sign", identity, "--keychain", str(keychain), "--options", "runtime", "--timestamp",
             "--entitlements", str(Path(__file__).resolve().parent.parent / "apps/macos/DeviceBridgeApp/DeviceBridgeApp.entitlements"), str(app)], phase="Sign macOS app")
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], phase="Verify signed macOS app")
        verify_identity(self.commands, app, team)
        verify_identity(self.commands, app / "Contents/MacOS/devicebridge-agent", team)
        zip_path = work / "DeviceBridge-notarization.zip"
        run(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(app), str(zip_path)], phase="Prepare app notarization submission")
        app_id = self._notarize(zip_path, keychain, profile)
        run(["/usr/bin/xcrun", "stapler", "staple", str(app)], phase="Staple app notarization ticket")
        run(["/usr/bin/xcrun", "stapler", "validate", str(app)], phase="Validate app notarization ticket")
        run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", str(app)], phase="Gatekeeper app assessment")
        (stage / "Applications").symlink_to("/Applications")
        (stage / "安装说明.txt").write_text(
            "DeviceBridge · Apple Silicon · macOS 14+\n\n"
            "退出旧版本后，将 DeviceBridge.app 拖到 Applications。\n"
            "此包使用 Developer ID Application 签名并通过 Apple 公证。\n"
            "Apple 公证不代表真机功能验收；鸿蒙 HDC、ADB 和 iOS runner 仍需各自工具与设备授权。\n",
            encoding="utf-8")
        signed_dmg = output / dmg.name
        run(["/usr/bin/hdiutil", "create", "-volname", f"DeviceBridge {info['version']}", "-srcfolder", str(stage), "-format", "UDZO", str(signed_dmg)], phase="Package signed DMG")
        run(["/usr/bin/codesign", "--force", "--sign", identity, "--keychain", str(keychain), "--timestamp", str(signed_dmg)], phase="Sign DMG")
        dmg_id = self._notarize(signed_dmg, keychain, profile)
        run(["/usr/bin/xcrun", "stapler", "staple", str(signed_dmg)], phase="Staple DMG notarization ticket")
        run(["/usr/bin/xcrun", "stapler", "validate", str(signed_dmg)], phase="Validate DMG notarization ticket")
        run(["/usr/bin/codesign", "--verify", "--strict", str(signed_dmg)], phase="Verify signed DMG")
        verify_identity(self.commands, signed_dmg, team)
        run(["/usr/bin/hdiutil", "verify", str(signed_dmg)], phase="Verify DMG image integrity")
        run(["/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", str(signed_dmg)], phase="Gatekeeper DMG assessment")
        return signed_dmg, app_id, dmg_id

    def _record_acceptance(self, output: Path, info: dict, signed_dmg: Path, app_id: str, dmg_id: str, team: str) -> None:
        info.update(macos_signing="Developer ID Application", apple_notarized=True, apple_team_id=team,
                    app_notarization_id=app_id, dmg_notarization_id=dmg_id)
        (output / "build-info.json").write_text(json.dumps(info, indent=2) + "\n")
        (output / "release-notes.md").write_text(
            f"# DeviceBridge {info['version']} · Build {info['build']}\n\n"
            "macOS 14+ / Apple Silicon。Developer ID Application 签名，Apple 公证已接受并附加票据。\n\n"
            f"源码提交：`{info['commit']}`。自动化验证不替代真机验收。\n")
        files = [signed_dmg, output / "build-info.json", output / "release-notes.md"]
        (output / "SHA256SUMS.txt").write_text("".join(f"{sha256(path)}  {path.name}\n" for path in files))
        self.summary.update(status="accepted", apple_notarized=True, app_notarization_id=app_id, dmg_notarization_id=dmg_id)

    def _notarize(self, target: Path, keychain: Path, profile: str) -> str:
        # Upload once, retain the submission ID, then wait separately. If waiting
        # times out, the safe outcome record supports status lookup instead of
        # silently resubmitting an operation that may already have succeeded.
        self.summary["submission_state"] = "upload-outcome-uncertain"
        raw = self.commands.run(["/usr/bin/xcrun", "notarytool", "submit", str(target), "--keychain-profile", profile,
                                 "--keychain", str(keychain), "--output-format", "json"],
                                phase="Apple notarization upload", timeout=900)
        try:
            upload = json.loads(raw)
            identifier = str(uuid.UUID(upload.get("id", "")))
        except (ValueError, TypeError, AttributeError) as error:
            raise SigningError("Apple returned no valid notarization submission ID; do not blindly retry upload") from error
        self.summary.setdefault("submissions", []).append({"file": target.name, "id": identifier})
        self.summary["submission_state"] = "submitted-pending"
        raw = self.commands.run(["/usr/bin/xcrun", "notarytool", "wait", identifier, "--keychain-profile", profile,
                                 "--keychain", str(keychain), "--timeout", "20m", "--output-format", "json"],
                                phase="Wait for Apple notarization", timeout=1300)
        try:
            result = json.loads(raw)
        except ValueError as error:
            raise SigningError("Apple returned an invalid notarization response; query the saved submission ID") from error
        if not isinstance(result, dict) or result.get("status") != "Accepted":
            self.summary.update(submission_state="not-accepted", rejected_submission_id=identifier)
            raise SigningError("Apple notarization did not return Accepted; signed release withheld")
        self.summary["submission_state"] = "accepted"
        return identifier


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--summary", type=Path, required=True)
    args = parser.parse_args()
    signer = AppleSigner()
    try:
        values = load_secrets(dict(os.environ))
        # Remove secrets from this process environment before spawning any tools.
        for name in SECRET_NAMES:
            os.environ.pop(name, None)
        signer.run(args.input.resolve(), args.output.resolve(), args.version, args.build, args.commit, values)
    except (SigningError, OSError, ValueError) as error:
        signer.summary.update(status="failed", apple_notarized=False, error=str(error) if isinstance(error, SigningError) else "Artifact/signing preparation failed")
        print(signer.summary["error"], file=sys.stderr)
        return 1
    finally:
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        args.summary.write_text(json.dumps(signer.summary, indent=2) + "\n")
    print("Developer ID signing, Apple notarization, stapling and Gatekeeper verification succeeded.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
