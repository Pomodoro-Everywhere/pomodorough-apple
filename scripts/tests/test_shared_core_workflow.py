from pathlib import Path
import unittest


ROOT = Path(__file__).parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
CORE_COMMIT = "542aca9a322a1b04c3e53d4a76152f385675d0a1"
CORE_RELEASE_TAG = "v0.10.0"
CORE_SHA256 = "f735303cbd13a1671090b7ecd1e9c96a210ca007d8a35244bdf8028772c66eb6"
class SharedCoreWorkflowTests(unittest.TestCase):
    def assert_portable_provenance_contract(self, workflow: str) -> None:
        normalized = "\n".join(line.strip() for line in workflow.splitlines())
        self.assertIn('verify_wasm_artifact.py "$rebuilt"', normalized)
        self.assertIn(
            'verify_wasm_artifact.py \\\n"$released" \\\n--sha256 "$CORE_SHA256"',
            normalized,
        )
        self.assertIn(
            'cmp "$released" Resources/SharedCore/pomodorough_core.wasm',
            normalized,
        )
        self.assertNotIn("verify_shared_core_provenance.py", normalized)
        for line in normalized.splitlines():
            if line.startswith("cmp "):
                self.assertNotIn("$rebuilt", line)

    def test_checkout_uses_declared_core_commit(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(f'CORE_COMMIT: "{CORE_COMMIT}"', workflow)
        self.assertIn("ref: ${{ env.CORE_COMMIT }}", workflow)
        self.assertIn("cd .build/pomodorough-core", workflow)
        self.assertNotIn("ref: 05bb0cf7e73c99d1ef6c0acbd41a9798614a4359", workflow)

    def test_release_rebuilds_core_and_checks_packaged_apps(self) -> None:
        workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(f'CORE_COMMIT: "{CORE_COMMIT}"', workflow)
        self.assertIn(f'CORE_RELEASE_TAG: "{CORE_RELEASE_TAG}"', workflow)
        self.assertIn(f'CORE_SHA256: "{CORE_SHA256}"', workflow)
        self.assertIn("ref: ${{ env.CORE_COMMIT }}", workflow)
        self.assertIn("cd .build/pomodorough-core", workflow)
        self.assertIn("Verify pinned source and released shared core", workflow)
        self.assertIn("releases/download/$CORE_RELEASE_TAG/pomodorough_core.wasm", workflow)
        self.assert_portable_provenance_contract(workflow)
        self.assertIn("SWIFT_SUPPRESS_WARNINGS=NO", workflow)
        self.assertIn("Verify shared core in staged release applications", workflow)
        self.assertIn('test "$verified_apps" -eq 3', workflow)

    def test_release_packages_ad_hoc_signed_simulator_app_and_smokes_exact_archive(self) -> None:
        workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")

        def assert_contract(candidate: str) -> None:
            required = (
                'codesign --force --deep --sign - "$ios_simulator_staged_app"',
                'codesign --verify --deep --strict "$ios_simulator_staged_app"',
                'Pomodorough-iOS-Simulator-ad-hoc-signed-non-notarized-${RELEASE_TAG}.zip',
                'ditto -x -k "$archive" "$extracted"',
                'codesign --verify --deep --strict "$app"',
                'launch_output="$(xcrun simctl launch',
                'test -n "$launch_pid"',
                '[[ "$launch_pid" =~ ^[0-9]+$ ]]',
                'sleep 2',
                'xcrun simctl terminate "$device_id" "$bundle_id"',
            )
            for clause in required:
                self.assertIn(clause, candidate)
            ordered = required[3:]
            self.assertEqual(
                [candidate.index(clause) for clause in ordered],
                sorted(candidate.index(clause) for clause in ordered),
            )
            self.assertNotIn('codesign --remove-signature "$ios_simulator_staged_app"', candidate)

        assert_contract(workflow)
        survival_clauses = (
            '[[ "$launch_pid" =~ ^[0-9]+$ ]]',
            'sleep 2',
            'xcrun simctl terminate "$device_id" "$bundle_id"',
        )
        for clause in survival_clauses:
            with self.subTest(clause=clause), self.assertRaises(AssertionError):
                assert_contract(workflow.replace(clause, "", 1))

    def test_built_apps_are_checked_for_exact_shared_core(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("Verify shared core in built applications", workflow)
        self.assertIn("find \"$DERIVED_DATA_PATH/Build/Products\"", workflow)
        self.assertIn("-name 'pomodorough_core.wasm'", workflow)
        self.assertIn('test "$actual_sha" = "$CORE_SHA256"', workflow)
        self.assertIn("test \"$verified_apps\" -eq 2", workflow)

    def test_ci_checks_portable_rebuild_and_binds_public_asset_to_embedded_core(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(f'CORE_RELEASE_TAG: "{CORE_RELEASE_TAG}"', workflow)
        self.assertIn("releases/download/$CORE_RELEASE_TAG/pomodorough_core.wasm", workflow)
        self.assert_portable_provenance_contract(workflow)

    def test_portable_provenance_contract_rejects_regressions(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        missing_rebuild = workflow.replace(
            '          python3 .build/pomodorough-core/scripts/verify_wasm_artifact.py "$rebuilt"\n',
            "",
        )
        missing_release_hash = workflow.replace(
            '          python3 .build/pomodorough-core/scripts/verify_wasm_artifact.py \\\n            "$released" \\\n            --sha256 "$CORE_SHA256"\n',
            "",
        )
        compares_rebuild = workflow.replace(
            '          cmp "$released" Resources/SharedCore/pomodorough_core.wasm\n',
            '          cmp "$released" "$rebuilt"\n',
        )
        for mutated in (missing_rebuild, missing_release_hash, compares_rebuild):
            with self.subTest(), self.assertRaises(AssertionError):
                self.assert_portable_provenance_contract(mutated)


if __name__ == "__main__":
    unittest.main()
