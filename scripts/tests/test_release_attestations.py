from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSETS = (
    "Pomodorough-iOS-Simulator-ad-hoc-signed-non-notarized-v1.2.3.zip",
    "Pomodorough-iOS-unsigned-v1.2.3.ipa",
    "Pomodorough-macOS-unsigned-non-notarized-v1.2.3.zip",
    "pomodorough-apple.spdx.json",
    "SHA256SUMS.txt",
)

GH_STUB = r'''
import fcntl
import json
import os
import shutil
import sys
import time
from pathlib import Path

root = Path(os.environ["RUNNER_TEMP"])
args = sys.argv[1:]

def record(event, asset=""):
    with (root / "events").open("a+") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.write(json.dumps([event, asset]) + "\n")

def read_events():
    with (root / "events").open() as stream:
        fcntl.flock(stream, fcntl.LOCK_SH)
        return [json.loads(line) for line in stream]

if args[:2] == ["attestation", "verify"]:
    assert args[3:] == ["--repo", "test/apple"]
    asset = args[2]
    assert Path(asset).is_file()
    record("start", asset)
    # A barrier proves real overlap, not merely short elapsed runtime.
    deadline = time.monotonic() + 5
    while True:
        events = read_events()
        if sum(event == "start" for event, _ in events) >= 3:
            break
        if time.monotonic() > deadline:
            record("barrier-timeout", asset)
            sys.exit(9)
        time.sleep(0.01)
    # Failed children finish first, exposing early-exit and incomplete-wait bugs.
    time.sleep(0.01 if asset == os.environ.get("FAIL_ASSET") else 0.15)
    record("finish", asset)
    sys.exit(7 if asset == os.environ.get("FAIL_ASSET") else 0)
elif args[:2] == ["release", "download"]:
    destination = Path(args[args.index("--dir") + 1])
    for asset in (root / "assets").iterdir():
        shutil.copyfile(asset, destination / asset.name)
elif args[:2] == ["release", "view"]:
    if "isDraft" in args:
        if os.environ.get("RELEASE_STATE") == "missing":
            sys.exit(1)
        print(os.environ.get("RELEASE_STATE", "draft"))
elif args[:2] == ["release", "create"]:
    assert "--draft" in args and "--verify-tag" in args
    record("create")
elif args[:2] == ["release", "edit"]:
    assert "--draft=false" in args
    record("publish")
elif args[:2] == ["release", "upload"]:
    record("upload")
elif args[0] == "api":
    print("Release notes")
elif args == ["test-shell-exit"]:
    record("exit")
else:
    raise AssertionError(args)
'''


class ReleaseAttestationTests(unittest.TestCase):
    def run_release(self, *, failure="", state="draft", corruption=""):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        step = workflow.split("      - name: Create GitHub Release\n", 1)[1]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0])
        script = "trap 'gh test-shell-exit' EXIT\n" + script
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assets = root / "assets"
            assets.mkdir()
            manifest = []
            for name in ASSETS[:-1]:
                payload = name.encode()
                (assets / name).write_bytes(payload)
                manifest.append(f"{hashlib.sha256(payload).hexdigest()}  ./{name}\n")
            (assets / ASSETS[-1]).write_text("".join(manifest))
            self.corrupt_assets(assets, manifest, corruption)
            provenance = root / "core-provenance-ios-simulator"
            provenance.mkdir()
            (provenance / "CORE_RELEASE_TAG").write_text("fixture-core")
            (provenance / "CORE_COMMIT").write_text("fixture-commit")
            gh = root / "gh"
            gh.write_text(f"#!{sys.executable}\n" + textwrap.dedent(GH_STUB))
            gh.chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                       RUNNER_TEMP=str(root), RELEASE_DIR=str(assets),
                       RELEASE_TAG="v1.2.3", GITHUB_REPOSITORY="test/apple",
                       FAIL_ASSET=failure, RELEASE_STATE=state)
            result = subprocess.run(["/bin/bash", "-c", script], env=env,
                                    capture_output=True, text=True, timeout=20)
            events_path = root / "events"
            events = [json.loads(line) for line in events_path.read_text().splitlines()]
            return result, events

    def corrupt_assets(self, assets, manifest, corruption):
        if corruption == "extra":
            (assets / "unexpected.zip").write_text("unexpected")
        elif corruption == "missing":
            (assets / ASSETS[0]).unlink()
        elif corruption == "checksum":
            (assets / ASSETS[0]).write_text("tampered")
        elif corruption == "manifest":
            (assets / ASSETS[-1]).write_text("".join(manifest[:-1]))

    def assert_drained(self, events):
        active = peak = 0
        finished = []
        for event, asset in events:
            if event == "start":
                active += 1
                peak = max(peak, active)
            elif event == "finish":
                active -= 1
                finished.append(asset)
            elif event in ("publish", "exit"):
                self.assertEqual(active, 0)
                self.assertCountEqual(finished, ASSETS)
        self.assertEqual(active, 0)
        self.assertEqual(peak, 3)
        for kind in ("start", "finish"):
            self.assertCountEqual([asset for event, asset in events if event == kind], ASSETS)
        self.assertNotIn("barrier-timeout", [event for event, _ in events])

    def test_success_waits_for_all_attestations_before_publish(self):
        for state in ("missing", "draft"):
            with self.subTest(state=state):
                result, events = self.run_release(state=state)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_drained(events)
                self.assertEqual(events[-2:], [["publish", ""], ["exit", ""]])
                self.assertEqual(["create", ""] in events, state == "missing")

    def test_each_failure_drains_all_children_and_blocks_publish(self):
        for asset in ASSETS:
            with self.subTest(asset=asset):
                result, events = self.run_release(failure=asset)
                self.assertNotEqual(result.returncode, 0)
                self.assert_drained(events)
                self.assertNotIn(["publish", ""], events)

    def test_published_release_is_verified_without_republishing(self):
        for failure in ("", ASSETS[-1]):
            with self.subTest(failure=failure):
                result, events = self.run_release(state="published", failure=failure)
                self.assertEqual(result.returncode == 0, not failure, result.stderr)
                self.assert_drained(events)
                self.assertNotIn(["upload", ""], events)
                self.assertNotIn(["publish", ""], events)

    def test_inventory_and_checksum_failures_prevent_attestation_and_publish(self):
        for corruption in ("extra", "missing", "checksum", "manifest"):
            with self.subTest(corruption=corruption):
                result, events = self.run_release(corruption=corruption)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(events, [["upload", ""], ["exit", ""]])


if __name__ == "__main__":
    unittest.main()
