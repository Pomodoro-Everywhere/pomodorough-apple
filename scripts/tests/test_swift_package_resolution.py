from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts import resolve_swift_packages


ROOT = Path(__file__).resolve().parents[2]
LOCK = Path(
    "Pomodorough.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)


def workflow_steps(name: str) -> list[str]:
    workflow = (ROOT / ".github/workflows" / name).read_text(encoding="utf-8")
    return workflow.split("      - name: ")[1:]


def xcodebuild_steps(name: str) -> list[str]:
    return [step for step in workflow_steps(name) if "          xcodebuild\n" in step]


class ResolutionWorkflowTests(unittest.TestCase):
    def assert_pinned_builds(self, name: str) -> None:
        for step in xcodebuild_steps(name):
            with self.subTest(step=step.split("\n", 1)[0]):
                if "-resolvePackageDependencies" in step:
                    self.assertIn("scripts/resolve_swift_packages.py", step)
                    self.assertNotIn("-disableAutomaticPackageResolution", step)
                else:
                    self.assertIn("-disableAutomaticPackageResolution", step)

    def test_ci_builds_never_auto_resolve(self) -> None:
        self.assert_pinned_builds("ci.yml")

    def test_release_builds_never_auto_resolve(self) -> None:
        self.assert_pinned_builds("release.yml")

    def test_resolve_step_names_sandbox_distrust(self) -> None:
        for name in ("ci.yml", "release.yml"):
            workflow = (ROOT / ".github/workflows" / name).read_text(encoding="utf-8")
            self.assertIn("without trusting a broken sandbox", workflow)


class PinParsingTests(unittest.TestCase):
    def write_lock(self, directory: Path, pins: object) -> Path:
        lock = directory / "Package.resolved"
        document = {"originHash": "a" * 64, "pins": pins, "version": 3}
        lock.write_text(json.dumps(document), encoding="utf-8")
        return lock

    def test_valid_lock_reports_pins(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            lock = self.write_lock(
                Path(raw_tmp),
                [
                    {
                        "identity": "pkg",
                        "kind": "remoteSourceControl",
                        "location": "https://example.test/pkg.git",
                        "state": {"revision": "b" * 40, "version": "1.0.0"},
                    }
                ],
            )
            _, pins = resolve_swift_packages.read_pins(lock)
            self.assertEqual(
                pins, [("pkg", "https://example.test/pkg.git", "b" * 40)]
            )

    def test_checkout_name_strips_git_suffix(self) -> None:
        self.assertEqual(
            resolve_swift_packages.checkout_dir_name("https://example.test/Foo.git"),
            "Foo",
        )
        self.assertEqual(
            resolve_swift_packages.checkout_dir_name("https://example.test/bar"),
            "bar",
        )

    def test_malformed_locks_are_rejected(self) -> None:
        bad_pins: tuple[object, ...] = (
            [],
            [{"identity": "pkg"}],
            [
                {
                    "identity": "pkg",
                    "kind": "remoteSourceControl",
                    "location": "https://example.test/pkg.git",
                    "state": {"revision": "not-a-revision"},
                }
            ],
        )
        for pins in bad_pins:
            with self.subTest(pins=pins), tempfile.TemporaryDirectory() as raw_tmp:
                lock = self.write_lock(Path(raw_tmp), pins)
                with self.assertRaises(resolve_swift_packages.ResolutionError):
                    resolve_swift_packages.read_pins(lock)

    def test_sandbox_signatures_are_detected(self) -> None:
        self.assertTrue(
            resolve_swift_packages.is_sandbox_failure(
                "sandbox-exec: sandbox_apply: Operation not permitted"
            )
        )
        self.assertFalse(resolve_swift_packages.is_sandbox_failure("Build succeeded"))


class ResolveFlowTests(unittest.TestCase):
    def test_complete_checkouts_skip_resolution_command(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            checkouts = tmp / "checkouts" / "pkg"
            checkouts.mkdir(parents=True)
            subprocess.run(["git", "init", "-q", str(checkouts)], check=True)
            subprocess.run(
                ["git", "-C", str(checkouts), "commit", "-q", "--allow-empty",
                 "-m", "pin"],
                check=True,
            )
            revision = subprocess.run(
                ["git", "-C", str(checkouts), "rev-parse", "HEAD"],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
            pins = [("pkg", "https://example.test/pkg.git", revision)]
            lock = tmp / "Package.resolved"
            lock.write_text(
                json.dumps(
                    {
                        "originHash": "a" * 64,
                        "pins": [
                            {
                                "identity": "pkg",
                                "kind": "remoteSourceControl",
                                "location": "https://example.test/pkg.git",
                                "state": {"revision": revision},
                            }
                        ],
                        "version": 3,
                    }
                ),
                encoding="utf-8",
            )
            with mock.patch.object(
                resolve_swift_packages, "verify_lock", return_value=(b"raw", pins)
            ):
                message = resolve_swift_packages.resolve(
                    lock, tmp / "checkouts", ["false"]
                )
            self.assertIn("skipping resolution", message)

    def test_moved_pins_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            tmp = Path(raw_tmp)
            lock = tmp / "Package.resolved"
            lock.write_bytes(b"committed")
            pins = [("pkg", "https://example.test/pkg.git", "b" * 40)]
            completed = subprocess.CompletedProcess(
                args=[], returncode=0, stdout="", stderr=""
            )
            with (
                mock.patch.object(
                    resolve_swift_packages,
                    "verify_lock",
                    return_value=(b"committed", pins),
                ),
                mock.patch.object(
                    resolve_swift_packages,
                    "missing_pins",
                    return_value=pins,
                ),
                mock.patch.object(
                    resolve_swift_packages, "run_command", return_value=completed
                ),
                mock.patch.object(Path, "read_bytes", return_value=b"changed"),
            ):
                with self.assertRaises(resolve_swift_packages.ResolutionError):
                    resolve_swift_packages.resolve(lock, tmp, ["true"])


if __name__ == "__main__":
    unittest.main()
