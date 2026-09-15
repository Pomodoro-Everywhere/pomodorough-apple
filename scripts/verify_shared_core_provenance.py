#!/usr/bin/env python3
"""Bind independently resolved Core releases to this run's tested/built products."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re


FIELDS = {"CORE_RELEASE_TAG": r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)",
          "CORE_COMMIT": r"[0-9a-f]{40}", "CORE_SHA256": r"[0-9a-f]{64}"}
SHARDS = ("ios-simulator", "ios-device", "macos", "test-ios", "test-macos")
BUILD_SHARDS = ("ios-simulator", "ios-device", "macos")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate evidence key: {key}")
        result[key] = value
    return result


def regular_bytes(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Missing/non-regular evidence: {path}")
    return path.read_bytes()


def core_identity(directory):
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"Missing/non-regular Core directory: {directory}")
    values = {field: regular_bytes(directory / field).decode("ascii") for field in FIELDS}
    for field, pattern in FIELDS.items():
        if re.fullmatch(pattern, values[field]) is None:
            raise ValueError(f"Malformed {field}")
    wasm = regular_bytes(directory / "pomodorough_core.wasm")
    if not wasm.startswith(b"\0asm\x01\0\0\0") or hashlib.sha256(wasm).hexdigest() != values["CORE_SHA256"]:
        raise ValueError("Resolved Core WASM mismatch")
    return values


def execution_context():
    names = ("GITHUB_REPOSITORY", "GITHUB_SHA", "GITHUB_REF", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT")
    context = {name: os.environ[name] for name in names}
    if not all(context.values()) or not re.fullmatch(r"[0-9a-f]{40}", context["GITHUB_SHA"]):
        raise ValueError("Malformed execution context")
    for name in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"):
        if not re.fullmatch(r"[1-9][0-9]*", context[name]):
            raise ValueError(f"Malformed {name}")
    return context


def product_wasm(products, expected):
    payloads = {}
    for index, product in enumerate(products):
        paths = sorted(product.rglob("pomodorough_core.wasm"))
        if product.is_symlink() or not product.is_dir() or not paths:
            raise ValueError(f"Missing product Core: {product}")
        for path in paths:
            if any((product / parent).is_symlink() for parent in path.relative_to(product).parents):
                raise ValueError(f"Symlink product Core: {path}")
            raw = regular_bytes(path)
            if hashlib.sha256(raw).hexdigest() != expected:
                raise ValueError(f"Product Core mismatch: {path}")
            payloads[f"products/{index}/{path.relative_to(product)}"] = raw
    if not payloads:
        raise ValueError("No products verified")
    return payloads


def export_provenance(core, products, output, shard):
    identity = core_identity(core)
    payloads = product_wasm(products, identity["CORE_SHA256"])
    output.mkdir(parents=True, exist_ok=False)
    for field in (*FIELDS, "pomodorough_core.wasm"):
        (output / field).write_bytes(regular_bytes(core / field))
    record = {"context": execution_context(), "shard": shard, "core": identity,
              "products": {name: hashlib.sha256(raw).hexdigest() for name, raw in payloads.items()}}
    for name, raw in payloads.items():
        path = output / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
    (output / "CORE_EXECUTION.json").write_text(json.dumps(record, sort_keys=True), encoding="utf-8")


def compare_provenance(root, shards=SHARDS):
    expected = None
    for shard in shards:
        directory = root / f"core-provenance-{shard}"
        identity = core_identity(directory)
        if any(path.is_symlink() for path in directory.rglob("*")):
            raise ValueError(f"Symlink provenance: {shard}")
        record = json.loads(regular_bytes(directory / "CORE_EXECUTION.json"), object_pairs_hook=unique_object)
        if not isinstance(record, dict):
            raise ValueError(f"Malformed execution provenance: {shard}")
        if record.get("context") != execution_context() or record.get("shard") != shard:
            raise ValueError(f"Execution provenance mismatch: {shard}")
        if record.get("core") != identity or (expected is not None and identity != expected):
            raise ValueError(f"Core shard mismatch: {shard}")
        products = record.get("products")
        actual = {str(path.relative_to(directory)): hashlib.sha256(regular_bytes(path)).hexdigest()
                  for path in (directory / "products").rglob("pomodorough_core.wasm")}
        if not actual or products != actual or set(actual.values()) != {identity["CORE_SHA256"]}:
            raise ValueError(f"Product provenance mismatch: {shard}")
        expected = identity
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compare", type=Path)
    parser.add_argument("--shards", default="",
                        help="comma-separated subset of shards for --compare (default: all)")
    parser.add_argument("--core", type=Path, default=Path("Resources/SharedCore"))
    parser.add_argument("--product", type=Path, action="append", default=[])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--shard", choices=SHARDS)
    args = parser.parse_args()
    if args.compare:
        shards = tuple(dict.fromkeys(args.shards.split(","))) if args.shards else SHARDS
        unknown = set(shards) - set(SHARDS)
        if not shards or unknown:
            parser.error(f"--shards must be a subset of {','.join(SHARDS)}")
        compare_provenance(args.compare, shards)
    elif args.output and args.shard:
        export_provenance(args.core, args.product, args.output, args.shard)
    elif args.product:
        product_wasm(args.product, core_identity(args.core)["CORE_SHA256"])
    else:
        parser.error("export requires --output and --shard")


if __name__ == "__main__":
    main()
