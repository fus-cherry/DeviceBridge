#!/usr/bin/env python3
"""Pure in-memory classification only; does not run codesign, sign or use Secrets.

A future approved signing caller may pass its already captured process output.
Only fixed observations leave this function. Never print, persist or attach the
input, exception, command arguments, certificate name, identity hash or key data.
The observations are not assertions that a particular fix will work.
"""
from __future__ import annotations

# Multiple observations may coexist. For example a chain-building warning plus
# errSecInternalComponent must not be collapsed into an assumed password/ACL bug.
OBSERVATIONS = (
    ("certificate_chain_building_warning", (b"unable to build chain to self-signed root", b"unable to build chain to self signed root")),
    ("security_framework_internal_component", (b"errsecinternalcomponent",)),
    ("keychain_interaction_denied", (b"user interaction is not allowed", b"cssmerr_csp_no_user_interaction", b"errsecinteractionnotallowed")),
    ("identity_or_key_not_found", (b"specified item could not be found in the keychain", b"no identity found", b"errsecitemnotfound")),
    ("certificate_expired_or_untrusted", (b"cssmerr_tp_cert_expired", b"cssmerr_tp_not_trusted", b"certificate has expired", b"certificate is not trusted")),
    ("timestamp_service_unavailable", (b"timestamp service is not available", b"timestamp server could not be reached", b"unable to contact the timestamp server")),
    ("timestamp_response_invalid", (b"invalid timestamp", b"timestamp was invalid", b"timestamp service returned an invalid response")),
    ("extended_attributes_rejected", (b"resource fork, finder information, or similar detritus not allowed",)),
    ("payload_write_denied", (b"permission denied", b"operation not permitted", b"read-only file system")),
    ("code_object_or_bundle_invalid", (b"bundle format unrecognized", b"unrecognized, invalid, or unsuitable", b"unsupported format for signature", b"file is not in an order that can be processed")),
)
ALLOWED = frozenset(name for name, _ in OBSERVATIONS) | {"unclassified_codesign_failure"}


def classify_failure(stdout: bytes, stderr: bytes) -> tuple[str, ...]:
    """Return only whitelist observations; never interpolate source output.

    Caller supplies output only for an already-failed codesign invocation. These
    categories cannot establish certificate authenticity, private-key usability,
    Apple account validity, a successful signature or a notarization outcome.
    In particular errSecInternalComponent alone does not prove an ACL defect.
    """
    if not isinstance(stdout, bytes) or not isinstance(stderr, bytes):
        return ("unclassified_codesign_failure",)
    # A diagnostic upper bound also avoids processing unusually large tool output.
    if len(stdout) + len(stderr) > 1024 * 1024:
        return ("unclassified_codesign_failure",)
    message = (stdout + b"\n" + stderr).lower()
    observations = tuple(name for name, patterns in OBSERVATIONS if any(pattern in message for pattern in patterns))
    return observations or ("unclassified_codesign_failure",)
