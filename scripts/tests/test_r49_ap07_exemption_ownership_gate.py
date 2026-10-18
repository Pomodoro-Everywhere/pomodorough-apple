#!/usr/bin/env python3
"""R49-AP07 permanent adversarial ownership gate for the interface scanner.

Owns exemption-ownership coverage: exactly seven log-only direct members stay
exempt, while nested actors, qualified extensions, same-named unrelated
owners, and user-visible missing keys fail closed. Real Watch keys and pseudo
values stay synchronized. Isolated catalog deletions stay baseline-red and
clearing the classification restores rejection (scanner-leak baseline).
"""
from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "check_interface_contract.py"
SPEC = importlib.util.spec_from_file_location("r49_ap07_ownership_gate", SCRIPT)
assert SPEC and SPEC.loader
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)

EXPECTED_TUPLES = (
    ("Sources/AppModel.swift", "SyncFailureDiagnostics", "errorDescription"),
    ("Sources/WorkspaceIntentModels.swift", "SuppressedSelectionDiagnostics", "publicMessage"),
    ("Sources/AppModel.swift", "AccountSwitchConfirmDiagnostics", "errorDescription"),
    ("Sources/AppModel.swift", "BootstrapInstallDiagnostics", "errorDescription"),
    ("Sources/AppModel.swift", "IrohForegroundRefreshDiagnostics", "errorDescription"),
    ("Sources/AccountLifecycleController.swift", "BootstrapBatchPlanDiagnostics", "errorDescription"),
    ("Sources/RoomReplicationController.swift", "IrohForegroundSyncDiagnostics", "errorDescription"),
)
WATCH_KEYS = (
    "Watch Start not applied.",
    "Watch Resume not applied.",
    "Watch Finish not applied.",
)
MUTATION_KEYS = (
    "mutation category=%arg reason=%arg ",
    "pending=%arg/%arg/%arg/",
    "%arg/%arg queued=%arg ",
    "applied=%arg ignoredRetarget=%arg ",
    "core=%arg",
)


def expected_computed(path: str, line: int, value: str) -> str:
    return f"uncatalogued computed user-visible literal: {path}:{line}: {value}"


def coverage_failures(source: str, path: str, catalog: dict | None = None) -> list[str]:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source, encoding="utf-8")
        return checker.validate_source_coverage(root, {"strings": {}} if catalog is None else catalog)


class R49AP07ExactExemptionGateTests(unittest.TestCase):
    def test_exact_seven_log_only_tuples(self) -> None:
        self.assertEqual(set(checker.LOG_ONLY_COMPUTED_MEMBERS), set(EXPECTED_TUPLES))
        self.assertEqual(len(checker.LOG_ONLY_COMPUTED_MEMBERS), 7)
        app_explanation = checker.LOG_ONLY_COMPUTED_MEMBERS[EXPECTED_TUPLES[0]]
        selection_explanation = checker.LOG_ONLY_COMPUTED_MEMBERS[EXPECTED_TUPLES[1]]
        self.assertIn("reportSyncBoundaryFailure", app_explanation)
        self.assertIn("reportSuppressedSelection", selection_explanation)
        for key, explanation in checker.LOG_ONLY_COMPUTED_MEMBERS.items():
            with self.subTest(key=key):
                self.assertTrue(explanation.strip())

    def test_exact_direct_members_stay_exempt(self) -> None:
        for path, owner, member in EXPECTED_TUPLES:
            cases = [
                f"struct {owner} {{ var {member}: String {{ \"log only reason=refused\" }} }}",
                f"extension {owner} {{ var {member}: String {{ \"log only reason=refused\" }} }}",
                f"extension {owner} where Self: Error {{ var {member}: String {{ \"log only reason=refused\" }} }}",
            ]
            for source in cases:
                with self.subTest(path=path, source=source):
                    self.assertEqual(checker.find_uncatalogued_computed_literals(source, path), [])
                    self.assertEqual(coverage_failures(source, path), [])

    def test_direct_member_after_nested_scope_stays_exempt(self) -> None:
        for path, owner, member in EXPECTED_TUPLES:
            source = (
                f"struct {owner} {{ enum Inner {{ case alpha }} "
                f"var {member}: String {{ \"log only reason=refused\" }} }}"
            )
            with self.subTest(path=path):
                self.assertEqual(checker.find_uncatalogued_computed_literals(source, path), [])
                self.assertEqual(coverage_failures(source, path), [])

    def test_real_production_files_have_expected_classified_each(self) -> None:
        expected_counts = {
            "Sources/AppModel.swift": 4,
            "Sources/WorkspaceIntentModels.swift": 1,
            "Sources/AccountLifecycleController.swift": 1,
            "Sources/RoomReplicationController.swift": 1,
        }
        for path, count in expected_counts.items():
            source = (checker.ROOT / path).read_text(encoding="utf-8")
            with self.subTest(path=path):
                self.assertEqual(len(checker.log_only_computed_declarations(source, path)), count)
                self.assertEqual(checker.find_uncatalogued_computed_literals(source, path), [])


class R49AP07FailClosedOwnershipTests(unittest.TestCase):
    def test_nested_scopes_fail_closed(self) -> None:
        for path, owner, member in EXPECTED_TUPLES:
            cases = [
                f"struct {owner} {{ struct Inner {{ var {member}: String {{ \"Visible nested struct\" }} }} }}",
                f"struct {owner} {{ class Inner {{ var {member}: String {{ \"Visible nested class\" }} }} }}",
                f"struct {owner} {{ enum Inner {{ var {member}: String {{ \"Visible nested enum\" }} }} }}",
                f"struct {owner} {{ actor Inner {{ var {member}: String {{ \"Visible nested actor\" }} }} }}",
                f"struct Outer {{ struct {owner} {{ var {member}: String {{ \"Visible same nested\" }} }} }}",
                f"struct Outer {{ actor {owner} {{ var {member}: String {{ \"Visible same actor\" }} }} }}",
            ]
            for source in cases:
                with self.subTest(path=path, source=source):
                    value = source.split('"Visible ')[1].split('"')[0]
                    full = f"Visible {value}"
                    wanted = [expected_computed(path, 1, full)]
                    self.assertEqual(checker.find_uncatalogued_computed_literals(source, path), wanted)
                    self.assertEqual(coverage_failures(source, path), wanted)

    def test_qualified_nested_extensions_fail_closed(self) -> None:
        values = ("Visible qualified", "Visible deep", "Visible spaced", "Visible generic")
        for path, owner, member in EXPECTED_TUPLES:
            cases = [
                f"extension {owner}.Inner {{ var {member}: String {{ \"{values[0]}\" }} }}",
                f"extension {owner}.Inner.Deep {{ var {member}: String {{ \"{values[1]}\" }} }}",
                f"extension {owner} /* scope */ . Inner {{ var {member}: String {{ \"{values[2]}\" }} }}",
                f"extension {owner}<Value>.Inner {{ var {member}: String {{ \"{values[3]}\" }} }}",
            ]
            for source, value in zip(cases, values):
                with self.subTest(path=path, source=source):
                    wanted = [expected_computed(path, 1, value)]
                    self.assertEqual(checker.find_uncatalogued_computed_literals(source, path), wanted)
                    self.assertEqual(coverage_failures(source, path), wanted)

    def test_same_named_unrelated_owners_fail_closed(self) -> None:
        cases = [
            ("Sources/Other.swift", "SyncFailureDiagnostics", "var errorDescription: String?"),
            ("Sources/AppModel.swift", "SyncFailureDiagnosticsExtra", "var errorDescription: String?"),
            ("Sources/AppModel.swift", "SyncFailureDiagnostics", "var statusLabel: String"),
            ("Sources/AppModel.swift", "SyncFailureDiagnostics", "func errorDescription() -> String"),
            ("Sources/WorkspaceIntentModels.swift", "WorkspaceMutationDiagnostics", "func publicMessage() -> String"),
        ]
        for path, owner, declaration in cases:
            source = f"struct {owner} {{ {declaration} {{ \"Needs attention\" }} }}"
            with self.subTest(path=path, owner=owner, declaration=declaration):
                wanted = [expected_computed(path, 1, "Needs attention")]
                self.assertEqual(checker.find_uncatalogued_computed_literals(source, path), wanted)
                self.assertEqual(coverage_failures(source, path), wanted)

    def test_generic_top_level_owner_fails_closed(self) -> None:
        for path, owner, member in EXPECTED_TUPLES:
            source = f"struct {owner}<Value> {{ var {member}: String {{ \"Visible generic top\" }} }}"
            with self.subTest(path=path):
                wanted = [expected_computed(path, 1, "Visible generic top")]
                self.assertEqual(checker.find_uncatalogued_computed_literals(source, path), wanted)


class R49AP07RealKeySynchronizationTests(unittest.TestCase):
    def test_three_watch_keys_and_pseudo_stay_synchronized(self) -> None:
        catalog = json.loads((checker.ROOT / "Resources/Localizable.xcstrings").read_text(encoding="utf-8"))
        pseudo = json.loads((checker.ROOT / "UITests/Fixtures/Localizable.ar-XB.json").read_text(encoding="utf-8"))
        self.assertEqual(checker.validate_shipping_catalog(catalog), [])
        self.assertEqual(checker.validate_pseudo_fixture(catalog, pseudo), [])
        for key in WATCH_KEYS:
            with self.subTest(key=key):
                self.assertIn(key, catalog["strings"])
                self.assertIn(key, pseudo["strings"])
                self.assertEqual(checker.string_units(catalog["strings"][key]["localizations"]["en"]), [key])
                self.assertEqual(checker.string_units(pseudo["strings"][key]), ["\u200f⟦" + key + "⟧"])
        source = "\n".join(f'String(localized: "{key}")' for key in WATCH_KEYS)
        self.assertEqual(checker.extract_localizable_keys(source), set(WATCH_KEYS))

    def test_mutation_fragments_stay_synchronized(self) -> None:
        catalog = json.loads((checker.ROOT / "Resources/Localizable.xcstrings").read_text(encoding="utf-8"))
        pseudo = json.loads((checker.ROOT / "UITests/Fixtures/Localizable.ar-XB.json").read_text(encoding="utf-8"))
        for key in MUTATION_KEYS:
            with self.subTest(key=key):
                self.assertIn(key, catalog["strings"])
                self.assertIn(key, pseudo["strings"])

    def test_isolated_catalog_deletions_are_baseline_red(self) -> None:
        for key in (*WATCH_KEYS, *MUTATION_KEYS):
            with self.subTest(key=key):
                source = f'String(localized: "{key}")\n'
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    sources = root / "Sources"
                    sources.mkdir()
                    (sources / "Probe.swift").write_text(source, encoding="utf-8")
                    missing = {"strings": {}}
                    got = checker.validate_source_coverage(root, missing)
                    self.assertIn(f"uncatalogued production-visible key: Sources/Probe.swift: {key}", got)
                    present = {"strings": {key: {}}}
                    self.assertEqual(checker.validate_source_coverage(root, present), [])

    def test_isolated_pseudo_deletion_fails_fixture_parity(self) -> None:
        catalog = json.loads((checker.ROOT / "Resources/Localizable.xcstrings").read_text(encoding="utf-8"))
        pseudo = json.loads((checker.ROOT / "UITests/Fixtures/Localizable.ar-XB.json").read_text(encoding="utf-8"))
        for key in WATCH_KEYS:
            with self.subTest(key=key):
                partial = {"locale": pseudo["locale"], "strings": dict(pseudo["strings"])}
                del partial["strings"][key]
                failures = checker.validate_pseudo_fixture(catalog, partial)
                self.assertTrue(any("shipping and pseudo fixture keys differ" in failure for failure in failures))

    def test_scanner_leak_baseline_restores_rejection(self) -> None:
        for path, owner, member in EXPECTED_TUPLES:
            source = f"struct {owner} {{ var {member}: String {{ \"log only reason=refused\" }} }}"
            with self.subTest(path=path):
                self.assertEqual(checker.find_uncatalogued_computed_literals(source, path), [])
                with patch.dict(checker.LOG_ONLY_COMPUTED_MEMBERS, {}, clear=True):
                    wanted = [expected_computed(path, 1, "log only reason=refused")]
                    self.assertEqual(checker.find_uncatalogued_computed_literals(source, path), wanted)

    def test_real_diagnostic_literals_return_without_classification(self) -> None:
        sources = {
            "Sources/AppModel.swift": 9,
            "Sources/WorkspaceIntentModels.swift": 2,
            "Sources/AccountLifecycleController.swift": 2,
            "Sources/RoomReplicationController.swift": 1,
        }
        for path, count in sources.items():
            source = (checker.ROOT / path).read_text(encoding="utf-8")
            with self.subTest(path=path):
                with patch.dict(checker.LOG_ONLY_COMPUTED_MEMBERS, {}, clear=True):
                    self.assertEqual(len(checker.find_uncatalogued_computed_literals(source, path)), count)


if __name__ == "__main__":
    unittest.main()
