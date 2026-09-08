#!/usr/bin/env python3
"""Resolve Swift packages without trusting a broken macOS sandbox.

Hosted macOS runners can ship a broken sandbox subsystem
(`sandbox-exec: sandbox_apply: Operation not permitted`), which kills
`xcodebuild -resolvePackageDependencies` before it compiles anything.

Strategy, fail-closed on versions:
1. Verify Package.resolved is committed, clean, and well-formed.
2. When every pinned checkout already exists at its pinned revision,
   skip network resolution entirely (no sandbox-exec is reachable).
3. Otherwise run the given xcodebuild resolution command. When that
   fails, pre-warm the checkouts with plain git (no sandbox) at the
   exact pinned revisions instead of building wrong versions.
4. Byte-compare Package.resolved before and after: resolution must
   never silently move pins. Any drift fails loudly so updated pins
   land via a reviewed commit, not a CI side effect.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path


DEFAULT_LOCK = Path(
    "Pomodorough.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)
REVISION = re.compile(r"[0-9a-f]{40}")
ORIGIN_HASH = re.compile(r"[0-9a-f]{64}")
SANDBOX_SIGNATURES = (
    "sandbox-exec",
    "sandbox_apply",
    "Operation not permitted",
    "Could not resolve package dependencies",
)


class ResolutionError(RuntimeError):
    pass


def checkout_dir_name(location: str) -> str:
    name = location.rstrip("/").rsplit("/", 1)[-1]
    return name[:-4] if name.endswith(".git") else name


def read_pins(lock: Path) -> tuple[bytes, list[tuple[str, str, str]]]:
    try:
        raw = lock.read_bytes()
    except OSError as error:
        raise ResolutionError(f"Cannot read {lock}: {error}") from error
    try:
        document = json.loads(raw)
    except (UnicodeDecodeError, ValueError) as error:
        raise ResolutionError(f"Malformed {lock}: {error}") from error
    if not isinstance(document, dict) or document.get("version") != 3:
        raise ResolutionError(f"Malformed {lock}: expected version 3")
    origin = document.get("originHash")
    if not isinstance(origin, str) or not ORIGIN_HASH.fullmatch(origin):
        raise ResolutionError(f"Malformed {lock}: bad originHash")
    pins = document.get("pins")
    if not isinstance(pins, list) or not pins:
        raise ResolutionError(f"Malformed {lock}: empty pins")
    parsed = []
    for pin in pins:
        state = pin.get("state") if isinstance(pin, dict) else None
        identity = pin.get("identity") if isinstance(pin, dict) else None
        location = pin.get("location") if isinstance(pin, dict) else None
        revision = state.get("revision") if isinstance(state, dict) else None
        if (
            not isinstance(identity, str)
            or not identity
            or not isinstance(location, str)
            or not location
            or not isinstance(revision, str)
            or not REVISION.fullmatch(revision)
        ):
            raise ResolutionError(f"Malformed {lock}: bad pin {identity!r}")
        parsed.append((identity, location, revision))
    return raw, parsed


def verify_lock(lock: Path) -> tuple[bytes, list[tuple[str, str, str]]]:
    if lock.is_symlink() or not lock.is_file():
        raise ResolutionError(f"Missing or non-regular {lock}")
    tracked = subprocess.run(
        ["git", "ls-files", "--error-unmatch", "--", str(lock)],
        capture_output=True,
        text=True,
        check=False,
    )
    if tracked.returncode:
        raise ResolutionError(f"Uncommitted {lock}: not tracked by git")
    status = subprocess.run(
        ["git", "status", "--porcelain", "--", str(lock)],
        capture_output=True,
        text=True,
        check=False,
    )
    if status.returncode or status.stdout.strip():
        raise ResolutionError(f"Uncommitted {lock}: working tree differs from HEAD")
    return read_pins(lock)


def checkout_revision(path: Path) -> str | None:
    result = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        return None
    revision = result.stdout.strip()
    return revision if REVISION.fullmatch(revision) else None


def missing_pins(
    checkouts: Path, pins: list[tuple[str, str, str]]
) -> list[tuple[str, str, str]]:
    missing = []
    for identity, location, revision in pins:
        path = checkouts / checkout_dir_name(location)
        if checkout_revision(path) != revision:
            missing.append((identity, location, revision))
    return missing


def prewarm_pin(checkouts: Path, pin: tuple[str, str, str]) -> None:
    identity, location, revision = pin
    dest = checkouts / checkout_dir_name(location)
    if checkout_revision(dest) == revision:
        return
    if dest.exists() or dest.is_symlink():
        shutil.rmtree(dest, ignore_errors=False)
    dest.parent.mkdir(parents=True, exist_ok=True)
    clone = subprocess.run(
        ["git", "clone", "--quiet", location, str(dest)],
        capture_output=True,
        text=True,
        check=False,
    )
    if clone.returncode:
        raise ResolutionError(f"Cannot clone {identity}: {clone.stderr.strip()}")
    checkout = subprocess.run(
        ["git", "-C", str(dest), "checkout", "--quiet", "--detach", revision],
        capture_output=True,
        text=True,
        check=False,
    )
    if checkout.returncode or checkout_revision(dest) != revision:
        raise ResolutionError(f"Cannot pin {identity} at {revision}")


def run_command(argv: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, capture_output=True, text=True, check=False)


def is_sandbox_failure(output: str) -> bool:
    return any(marker in output for marker in SANDBOX_SIGNATURES)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    parser.add_argument("--checkouts-dir", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if not args.command or args.command[0] != "--":
        parser.error("resolution command must follow a lone -- separator")
    args.command = args.command[1:]
    if not args.command:
        parser.error("missing resolution command after --")
    return args


def resolve(
    lock: Path, checkouts: Path, command: list[str]
) -> str:
    raw, pins = verify_lock(lock)
    if not missing_pins(checkouts, pins):
        return f"Swift packages already pinned at {len(pins)} revisions; skipping resolution"
    result = run_command(command)
    if result.returncode == 0:
        after = lock.read_bytes()
        if after != raw:
            raise ResolutionError(
                "Resolution moved Package.resolved pins; commit the updated lock"
            )
        return "Swift package resolution succeeded without moving pins"
    output = result.stdout + result.stderr
    reason = "sandbox signature" if is_sandbox_failure(output) else "failure"
    print(f"xcodebuild resolution failed ({reason}); pre-warming exact pins", flush=True)
    for pin in missing_pins(checkouts, pins):
        prewarm_pin(checkouts, pin)
    if lock.read_bytes() != raw:
        raise ResolutionError("Pre-warm moved Package.resolved pins")
    return f"Pre-warmed {len(pins)} Swift packages at pinned revisions"


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        print(resolve(args.lock, args.checkouts_dir, args.command), flush=True)
    except ResolutionError as error:
        print(f"resolve_swift_packages: {error}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
