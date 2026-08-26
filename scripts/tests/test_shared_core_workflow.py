import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
CORE_COMMIT = "49efee8c5ac390d5dd7bd5c1a3537fb889fa6f10"
CORE_SHA256 = "50519a0c12b0e38d3281d2205f5597f03bb5e8cdd7e9e57f86bb4458fd0dad64"
PROVENANCE_SCRIPT = ROOT / "scripts" / "verify_shared_core_provenance.py"
VALID_WASM = b"\0asm\x01\0\0\0"
DIFFERENT_VALID_WASM = VALID_WASM + b"\0\x01\0"


class SharedCoreWorkflowTests(unittest.TestCase):
    def test_checkout_uses_declared_core_commit(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(f'CORE_COMMIT: "{CORE_COMMIT}"', workflow)
        self.assertIn("ref: ${{ env.CORE_COMMIT }}", workflow)
        self.assertIn("cd .build/pomodorough-core", workflow)
        self.assertNotIn("ref: 05bb0cf7e73c99d1ef6c0acbd41a9798614a4359", workflow)

    def test_release_rebuilds_core_and_checks_packaged_apps(self) -> None:
        workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(f'CORE_COMMIT: "{CORE_COMMIT}"', workflow)
        self.assertIn(f'CORE_SHA256: "{CORE_SHA256}"', workflow)
        self.assertIn("ref: ${{ env.CORE_COMMIT }}", workflow)
        self.assertIn("cd .build/pomodorough-core", workflow)
        self.assertIn("Rebuild and verify pinned shared core", workflow)
        self.assertIn("verify_wasm_artifact.py", workflow)
        self.assertIn("scripts/verify_shared_core_provenance.py", workflow)
        self.assertIn("SWIFT_SUPPRESS_WARNINGS=NO", workflow)
        self.assertIn("Verify shared core in staged release applications", workflow)
        self.assertIn('test "$verified_apps" -eq 3', workflow)

    def test_built_apps_are_checked_for_exact_shared_core(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("Verify shared core in built applications", workflow)
        self.assertIn("find \"$DERIVED_DATA_PATH/Build/Products\"", workflow)
        self.assertIn("-name 'pomodorough_core.wasm'", workflow)
        self.assertIn('test "$actual_sha" = "$CORE_SHA256"', workflow)
        self.assertIn("test \"$verified_apps\" -eq 2", workflow)

    def test_ci_binds_rebuild_to_embedded_core(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("scripts/verify_shared_core_provenance.py", workflow)
        self.assertIn('"$rebuilt"', workflow)

    def test_provenance_rejects_different_valid_wasm(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rebuilt = root / "rebuilt.wasm"
            embedded = root / "embedded.wasm"
            rebuilt.write_bytes(VALID_WASM)
            embedded.write_bytes(DIFFERENT_VALID_WASM)
            result = subprocess.run(
                [
                    sys.executable,
                    str(PROVENANCE_SCRIPT),
                    "--sha256",
                    hashlib.sha256(VALID_WASM).hexdigest(),
                    str(rebuilt),
                    str(embedded),
                ],
                capture_output=True,
                check=False,
                text=True,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from rebuild", result.stderr)


if __name__ == "__main__":
    unittest.main()
