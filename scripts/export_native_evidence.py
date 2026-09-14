#!/usr/bin/env python3
"""Export xcresulttool output and hash the exact native evidence into the job log."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

from verify_shared_core_provenance import core_identity, execution_context, product_wasm, regular_bytes, unique_object


def result_summary(bundle):
    info = plistlib.loads(regular_bytes(bundle / "Info.plist"))
    if not isinstance(info, dict) or not info:
        raise ValueError(f"Malformed result Info.plist: {bundle}")
    result = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle), "--compact"],
        check=True, capture_output=True, timeout=120,
    )
    summary = json.loads(result.stdout, object_pairs_hook=unique_object)
    if not isinstance(summary, dict) or summary.get("result") != "Passed":
        raise ValueError(f"Unsuccessful result: {bundle}")
    counts = [summary.get(field) for field in
              ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")]
    if not all(type(count) is int and count >= 0 for count in counts):
        raise ValueError(f"Malformed result counts: {bundle}")
    if counts[2] != 0 or counts[1] <= 0 or counts[0] != sum(counts[1:]) or summary.get("testFailures") != []:
        raise ValueError(f"Unsuccessful result: {bundle}")
    return summary


def export_evidence(root, name, schemes, core, products):
    identity = core_identity(core)
    files = product_wasm(products, identity["CORE_SHA256"])
    for field in (*identity, "pomodorough_core.wasm"):
        files[f"shared-core/{field}"] = regular_bytes(core / field)
    summaries = {scheme: result_summary(root / f"{scheme}.xcresult") for scheme in schemes}
    for relative, raw in files.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
    manifest = {}
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"Symlink evidence: {path}")
        if path.is_file() and path.stat().st_size and path.name != f"native-evidence-{name}.json":
            with path.open("rb") as source:
                manifest[str(path.relative_to(root))] = hashlib.file_digest(source, "sha256").hexdigest()
    record = {"context": execution_context(), "name": name, "core": identity, "results": summaries,
              "files": manifest}
    raw = json.dumps(record, sort_keys=True).encode()
    (root / f"native-evidence-{name}.json").write_bytes(raw)
    print(f"NATIVE_EVIDENCE name={name} sha256={hashlib.sha256(raw).hexdigest()}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--name", choices=("ios-test-evidence", "native-test-evidence"), required=True)
    parser.add_argument("--scheme", action="append", required=True)
    parser.add_argument("--core", type=Path, default=Path("Resources/SharedCore"))
    parser.add_argument("--product", type=Path, action="append", required=True)
    args = parser.parse_args()
    export_evidence(args.root, args.name, args.scheme, args.core, args.product)


if __name__ == "__main__":
    main()
