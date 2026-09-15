import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import export_native_evidence as evidence
import verify_shared_core_provenance as provenance


CONTEXT = {"GITHUB_REPOSITORY": "example/apple", "GITHUB_SHA": "a" * 40,
           "GITHUB_REF": "refs/tags/v1.2.3", "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}
WASM = b"\0asm\x01\0\0\0"


class CoreProvenanceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.core = self.root / "core"
        self.core.mkdir()
        self.identity = {"CORE_RELEASE_TAG": "v1.2.3", "CORE_COMMIT": "b" * 40,
                         "CORE_SHA256": hashlib.sha256(WASM).hexdigest()}
        for field, value in self.identity.items():
            (self.core / field).write_text(value)
        (self.core / "pomodorough_core.wasm").write_bytes(WASM)
        self.app = self.root / "Pomodorough.app"
        self.app.mkdir()
        (self.app / "pomodorough_core.wasm").write_bytes(WASM)
        self.environment = patch.dict(os.environ, CONTEXT)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def export_shards(self):
        for shard in provenance.SHARDS:
            provenance.export_provenance(self.core, [self.app], self.root / f"core-provenance-{shard}", shard)

    def test_all_five_shards_agree(self):
        self.export_shards()
        self.assertEqual(provenance.compare_provenance(self.root), self.identity)
        self.assertEqual(provenance.compare_provenance(self.root, provenance.BUILD_SHARDS), self.identity)

    def test_build_subset_ignores_test_skew_but_rejects_build_skew(self):
        self.export_shards()
        directory = self.root / "core-provenance-test-ios"
        original = (directory / "CORE_EXECUTION.json").read_bytes()
        record = json.loads(original)
        record["core"]["CORE_COMMIT"] = "d" * 40
        (directory / "CORE_COMMIT").write_text("d" * 40)
        (directory / "CORE_EXECUTION.json").write_text(json.dumps(record))
        try:
            with self.assertRaisesRegex(ValueError, "Core shard mismatch"):
                provenance.compare_provenance(self.root)
            self.assertEqual(provenance.compare_provenance(self.root, provenance.BUILD_SHARDS), self.identity)
        finally:
            (directory / "CORE_COMMIT").write_text(self.identity["CORE_COMMIT"])
            (directory / "CORE_EXECUTION.json").write_bytes(original)
        build_dir = self.root / "core-provenance-macos"
        build_original = (build_dir / "CORE_EXECUTION.json").read_bytes()
        build_record = json.loads(build_original)
        build_record["core"]["CORE_COMMIT"] = "d" * 40
        (build_dir / "CORE_COMMIT").write_text("d" * 40)
        (build_dir / "CORE_EXECUTION.json").write_text(json.dumps(build_record))
        try:
            with self.assertRaisesRegex(ValueError, "Core shard mismatch"):
                provenance.compare_provenance(self.root, provenance.BUILD_SHARDS)
        finally:
            (build_dir / "CORE_COMMIT").write_text(self.identity["CORE_COMMIT"])
            (build_dir / "CORE_EXECUTION.json").write_bytes(build_original)

    def test_all_builds_agree_but_either_test_differs(self):
        self.export_shards()
        for shard in ("test-ios", "test-macos"):
            for field, value in (("CORE_COMMIT", "d" * 40), ("CORE_RELEASE_TAG", "v1.2.4")):
                with self.subTest(shard=shard, field=field):
                    directory = self.root / f"core-provenance-{shard}"
                    original = (directory / "CORE_EXECUTION.json").read_bytes()
                    record = json.loads(original)
                    record["core"][field] = value
                    (directory / field).write_text(value)
                    (directory / "CORE_EXECUTION.json").write_text(json.dumps(record))
                    with self.assertRaisesRegex(ValueError, "Core shard mismatch"):
                        provenance.compare_provenance(self.root)
                    (directory / field).write_text(self.identity[field])
                    (directory / "CORE_EXECUTION.json").write_bytes(original)

    def test_self_consistent_test_wasm_skew_rejected(self):
        self.export_shards()
        directory = self.root / "core-provenance-test-ios"
        shutil.rmtree(directory)
        changed = WASM + b"\0\x01\0"
        (self.core / "pomodorough_core.wasm").write_bytes(changed)
        (self.app / "pomodorough_core.wasm").write_bytes(changed)
        (self.core / "CORE_SHA256").write_text(hashlib.sha256(changed).hexdigest())
        provenance.export_provenance(self.core, [self.app], directory, "test-ios")
        with self.assertRaisesRegex(ValueError, "Core shard mismatch"):
            provenance.compare_provenance(self.root)

    def test_missing_tampered_malformed_provenance_rejected(self):
        self.export_shards()
        directory = self.root / "core-provenance-test-macos"
        for field in (*provenance.FIELDS, "pomodorough_core.wasm", "CORE_EXECUTION.json",
                      "products/0/pomodorough_core.wasm"):
            path = directory / field
            original = path.read_bytes()
            for replacement in (None, b"bogus", b""):
                with self.subTest(field=field, replacement=replacement):
                    path.unlink()
                    if replacement is not None:
                        path.write_bytes(replacement)
                    with self.assertRaises((ValueError, OSError)):
                        provenance.compare_provenance(self.root)
                    path.write_bytes(original)

    def test_wrong_run_source_attempt_repository_and_shard_rejected(self):
        self.export_shards()
        path = self.root / "core-provenance-ios-device/CORE_EXECUTION.json"
        original = path.read_bytes()
        for field in (*CONTEXT, "shard"):
            with self.subTest(field=field):
                record = json.loads(original)
                (record if field == "shard" else record["context"])[field] = "wrong"
                path.write_text(json.dumps(record))
                with self.assertRaisesRegex(ValueError, "Execution provenance"):
                    provenance.compare_provenance(self.root)

    def test_each_product_requires_actual_matching_wasm(self):
        missing = self.root / "Missing.app"
        missing.mkdir()
        with self.assertRaisesRegex(ValueError, "Missing product Core"):
            provenance.product_wasm([self.app, missing], self.identity["CORE_SHA256"])
        (missing / "pomodorough_core.wasm").write_bytes(b"wrong")
        with self.assertRaisesRegex(ValueError, "Product Core mismatch"):
            provenance.product_wasm([self.app, missing], self.identity["CORE_SHA256"])

    def test_result_export_uses_xcresulttool_and_seals_actual_bytes(self):
        root = self.root / "results"
        bundle = root / "Pomodorough-iOS.xcresult"
        (bundle / "Data").mkdir(parents=True)
        (bundle / "Info.plist").write_bytes(plistlib.dumps({"version": {"major": 3}}))
        (bundle / "Data/data.0").write_bytes(b"fixture")
        (root / "xcodebuild.log").write_text("fixture")
        summary = {"result": "Passed", "failedTests": 0, "passedTests": 1,
                   "totalTestCount": 1, "skippedTests": 0, "expectedFailures": 0, "testFailures": []}
        result = subprocess.CompletedProcess([], 0, json.dumps(summary).encode())
        with patch.object(evidence.subprocess, "run", return_value=result) as run:
            evidence.export_evidence(root, "ios-test-evidence", ["Pomodorough-iOS"], self.core, [self.app])
        self.assertEqual(run.call_args.args[0], ["xcrun", "xcresulttool", "get", "test-results", "summary",
                                               "--path", str(bundle), "--compact"])
        record = json.loads((root / "native-evidence-ios-test-evidence.json").read_bytes())
        self.assertEqual(record["context"], CONTEXT)
        for path, digest in record["files"].items():
            self.assertEqual(hashlib.sha256((root / path).read_bytes()).hexdigest(), digest)

    @unittest.skipUnless(shutil.which("xcrun"), "requires native xcresulttool")
    def test_real_xcresulttool_rejects_bogus_bundle_not_just_filename(self):
        bundle = self.root / "Bogus.xcresult"
        (bundle / "Data").mkdir(parents=True)
        (bundle / "Info.plist").write_bytes(plistlib.dumps({"version": {"major": 3}}))
        (bundle / "Data/data.0").write_bytes(b"not xcresult")
        with self.assertRaises(subprocess.CalledProcessError):
            evidence.result_summary(bundle)

    def test_result_export_rejects_malformed_and_failed_summaries(self):
        bundle = self.root / "Result.xcresult"
        bundle.mkdir()
        (bundle / "Info.plist").write_bytes(plistlib.dumps({"version": {"major": 3}}))
        for raw in (b"bogus", b"{}", b'{"result":"Failed","failedTests":1,"passedTests":1}'):
            with self.subTest(raw=raw), patch.object(evidence.subprocess, "run", return_value=
                                                   subprocess.CompletedProcess([], 0, raw)):
                with self.assertRaises(ValueError):
                    evidence.result_summary(bundle)

    def test_workflow_gates_all_exports_before_packaging(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/release.yml").read_text()
        package = workflow.split("  package:")[1].split("  package-and-release:")[0]
        publish = workflow.split("  package-and-release:")[1]
        # Package fail-fasts on the three build shards while tests still run;
        # the full five-shard skew gate blocks publish, not packaging.
        for shard in provenance.BUILD_SHARDS:
            self.assertIn(f"      - build-{shard}\n", package)
            self.assertIn(f"name: shared-core-provenance-{shard}\n", package)
        for shard in ("test-ios", "test-macos"):
            self.assertNotIn(f"      - {shard}\n", package.split("    runs-on:", 1)[0])
        self.assertIn("Compare built Core provenance", package)
        self.assertIn('--shards ios-simulator,ios-device,macos', package)
        self.assertLess(package.index("Compare built Core provenance"),
                        package.index("Package simulator and unsigned non-notarized apps"))
        for shard in provenance.SHARDS:
            self.assertIn(f"name: shared-core-provenance-{shard}\n", publish)
        self.assertIn("Compare all tested and built Core provenance", publish)
        self.assertIn("Compare sealed release with agreed Core", publish)
        self.assertLess(publish.index("Compare all tested and built Core provenance"),
                        publish.index("Attest artifact provenance"))
        self.assertLess(publish.index("Verify and restore sealed release"),
                        publish.index("Compare all tested and built Core provenance"))


if __name__ == "__main__":
    unittest.main()
