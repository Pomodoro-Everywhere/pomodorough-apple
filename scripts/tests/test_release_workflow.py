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


if __name__ == "__main__":
    unittest.main()
