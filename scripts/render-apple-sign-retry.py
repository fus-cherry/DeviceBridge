#!/usr/bin/env python3
"""Render an already reviewed 0.1.8 signing-only retry. Never pushes or queues it."""
import argparse
import importlib.util
import json
from pathlib import Path
import re

SPEC = importlib.util.spec_from_file_location("retry_preflight", Path(__file__).with_name("verify-apple-retry-input.py"))
PREFLIGHT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREFLIGHT)


def render(policy_path: Path, output_root: Path):
    policy = PREFLIGHT.policy_from(policy_path)
    template = Path(__file__).parent.parent / "docs/ci-templates/apple-sign-retry.yml.in"
    text = template.read_text().replace("__BUILD__", policy["build"]).replace("__SOURCE_SHA__", policy["source_sha"])
    if re.search(r"__[A-Z0-9_]+__", text):
        raise PREFLIGHT.PreflightError("Unfilled workflow template placeholder")
    workflow = output_root / PREFLIGHT.workflow_path(policy)
    frozen_policy = output_root / "docs/ci-templates/apple-retry-policy.json"
    if workflow.exists() or frozen_policy.exists():
        raise PREFLIGHT.PreflightError("A rendered workflow or policy already exists; review rather than overwrite")
    workflow.parent.mkdir(parents=True, exist_ok=True)
    frozen_policy.parent.mkdir(parents=True, exist_ok=True)
    workflow.write_text(text)
    frozen_policy.write_text(json.dumps(policy, indent=2) + "\n")
    return workflow, frozen_policy


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reviewed-policy", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    args = parser.parse_args()
    try:
        workflow, policy = render(args.reviewed_policy, args.output_root)
    except (PREFLIGHT.PreflightError, OSError) as error:
        print(str(error))
        return 1
    print(f"Rendered {workflow.name} and fixed policy only. No commit, push, queue, or Apple operation performed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
