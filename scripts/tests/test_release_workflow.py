from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ReleaseWorkflowTests(unittest.TestCase):
    def test_release_runs_interface_checker_and_checker_tests_directly(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.assertIn("python3 -m unittest discover -s scripts/tests -v", workflow)
        self.assertIn("python3 scripts/check_interface_contract.py", workflow)

    def test_release_publishes_only_after_exact_verification(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        upload = workflow.index('gh release upload "$RELEASE_TAG"')
        verify = workflow.index("verify_release_assets", upload)
        publish = workflow.index("--draft=false", upload)
        self.assertLess(upload, verify)
        self.assertLess(verify, publish)
        gates = (
            'cmp "$RUNNER_TEMP/expected-assets.txt" "$RUNNER_TEMP/actual-assets.txt"',
            'shasum -a 256 -c SHA256SUMS.txt',
            'cmp expected-manifest-assets.txt actual-manifest-assets.txt',
            'verify_attestations "${expected_release_assets[@]}"',
        )
        verifier = workflow.split("verify_release_assets() {", 1)[1]
        positions = [verifier.index(gate) for gate in gates]
        self.assertEqual(positions, sorted(positions))
        self.assertIn('expected_release_assets=("${expected_assets[@]}" "SHA256SUMS.txt")', workflow)
        self.assertIn('gh attestation verify "$asset" --repo "$GITHUB_REPOSITORY" &', workflow)

    def test_release_shards_tests_builds_and_selftest_in_parallel(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        for job in (
            "  preflight:",
            "  selftest:",
            "  test-ios:",
            "  test-ios-18-se:",
            "  test-macos:",
            "  build-ios-simulator:",
            "  build-ios-device:",
            "  build-macos:",
            "  package-sbom:",
            "  package:",
            "  package-and-release:",
        ):
            self.assertIn(job, workflow)
        for needed in (
            "preflight",
            "selftest",
            "test-ios",
            "test-macos",
            "build-ios-simulator",
            "build-ios-device",
            "build-macos",
        ):
            self.assertIn(needed, workflow.split("package-and-release:")[1])
        # test-ios-18-se runs non-gating (0.40.0 SE failures, see suite backlog ../backlog.md):
        # the job must exist above, but the publish gate must not need it.
        publishneeds = workflow.split("package-and-release:")[1]
        self.assertNotIn("- test-ios-18-se", publishneeds)
        # Package starts with builds+SBOM while tests still run; publish
        # gates on tests+package.
        package = workflow.split("  package:")[1].split("  package-and-release:")[0]
        packageneeds = package.split("    runs-on:", 1)[0]
        for needed in ("build-ios-simulator", "build-ios-device", "build-macos", "package-sbom"):
            self.assertIn(f"- {needed}\n", packageneeds)
        self.assertNotIn("- test-ios\n", packageneeds)
        self.assertNotIn("- test-macos\n", packageneeds)

    def test_release_caches_are_keyed_exactly_and_selftest_is_separate(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.assertIn("actions/cache@", workflow)
        self.assertIn(
            "hashFiles('Pomodorough.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')",
            workflow,
        )
        self.assertIn("xcode-26.6", workflow)
        self.assertIn("1.97.1", workflow)
        # DerivedData keys are unified so the gating shards share
        # intermediates instead of recompiling per shard.
        self.assertIn("release-deriveddata-macos-26-xcode-26.6-rust-1.97.1-", workflow)
        self.assertNotIn("release-deriveddata-test-ios-", workflow)
        self.assertNotIn("release-deriveddata-test-macos-", workflow)
        self.assertNotIn("release-deriveddata-build-ios-sim-", workflow)
        self.assertNotIn("release-deriveddata-build-ios-device-", workflow)
        self.assertNotIn("release-deriveddata-build-macos-", workflow)
        selftest = workflow.split("  selftest:")[1].split("\n  test-ios:")[0]
        self.assertIn("python3 -m unittest discover -s scripts/tests -v", selftest)
        preflight = workflow.split("  preflight:")[1].split("\n  selftest:")[0]
        self.assertIn("python3 scripts/check_interface_contract.py", preflight)
        self.assertNotIn("python3 -m unittest discover -s scripts/tests -v", preflight)
        smoke = workflow.split("Clean-install and launch")[1].split("- name: Refresh checksums with SBOM")[0]
        self.assertIn('ps -p "$launch_pid" >/dev/null 2>&1', smoke)
        self.assertNotIn("state = running", smoke)
        # The three archives are independent; packaging compresses them
        # in parallel and joins.
        packaging = workflow.split("Package simulator and unsigned non-notarized apps")[1].split(
            "- name: Verify shared core in staged release applications")[0]
        self.assertIn('"$ios_simulator_zip" &', packaging)
        self.assertIn('device_pid=$!', packaging)
        self.assertIn('macos_pid=$!', packaging)
        self.assertIn('wait "$sim_pid"', packaging)
        self.assertIn('wait "$device_pid"', packaging)
        self.assertIn('wait "$macos_pid"', packaging)


if __name__ == "__main__":
    unittest.main()
