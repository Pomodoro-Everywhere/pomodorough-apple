from pathlib import Path
import unittest


ROOT = Path(__file__).parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
CORE_COMMIT = "9a01dc8da0f1612e7a301c19cf42f3b522e61684"
CORE_SHA256 = "89fb6300324042b61d62070242cccad10e30f125885bb1b7a05af67b077bac83"


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
        self.assertIn("Verify shared core in staged release applications", workflow)
        self.assertIn('test "$verified_apps" -eq 3', workflow)

    def test_built_apps_are_checked_for_exact_shared_core(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("Verify shared core in built applications", workflow)
        self.assertIn("find \"$DERIVED_DATA_PATH/Build/Products\"", workflow)
        self.assertIn("-name 'pomodorough_core.wasm'", workflow)
        self.assertIn('test "$actual_sha" = "$CORE_SHA256"', workflow)
        self.assertIn("test \"$verified_apps\" -eq 2", workflow)


if __name__ == "__main__":
    unittest.main()
