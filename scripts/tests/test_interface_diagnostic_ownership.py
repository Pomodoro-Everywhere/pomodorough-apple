#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "check_interface_contract.py"
SPEC = importlib.util.spec_from_file_location("interface_diagnostic_ownership", SCRIPT)
assert SPEC and SPEC.loader
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)

CLASSIFIED_MEMBERS = (
    ("Sources/AppModel.swift", "SyncFailureDiagnostics", "errorDescription"),
    ("Sources/WorkspaceIntentModels.swift", "SuppressedSelectionDiagnostics", "publicMessage"),
)


class DiagnosticOwnershipTests(unittest.TestCase):
    def assert_visible(self, source: str, path: str, line: int, value: str) -> None:
        expected = [f"uncatalogued computed user-visible literal: {path}:{line}: {value}"]
        self.assertEqual(checker.find_uncatalogued_computed_literals(source, path), expected)
        target = checker.ROOT / path
        with patch.object(checker.Path, "rglob", return_value=[target]):
            with patch.object(checker.Path, "read_text", return_value=source):
                self.assertEqual(checker.validate_source_coverage(checker.ROOT, {"strings": {}}), expected)

    def test_nested_actor_members_remain_user_visible(self) -> None:
        for path, owner, member in CLASSIFIED_MEMBERS:
            source = f'''struct {owner} {{
 actor VisibleFailure {{
 nonisolated var {member}: String {{ "Visible actor failure" }}
 }}
}}
struct Screen: View {{ var body: some View {{ Text({owner}.VisibleFailure().{member}) }} }}
'''
            with self.subTest(path=path):
                self.assert_visible(source, path, 3, "Visible actor failure")

    def test_qualified_nested_extensions_remain_user_visible(self) -> None:
        for path, owner, member in CLASSIFIED_MEMBERS:
            source = f'''struct {owner} {{ struct VisibleFailure {{}} }}
extension {owner}.VisibleFailure {{
 var {member}: String {{ "Visible extension failure" }}
}}
struct Screen: View {{ var body: some View {{ Text({owner}.VisibleFailure().{member}) }} }}
'''
            with self.subTest(path=path):
                self.assert_visible(source, path, 3, "Visible extension failure")

    def test_qualified_extension_spacing_cannot_change_owner_identity(self) -> None:
        for path, owner, member in CLASSIFIED_MEMBERS:
            for separator in (".", " . ", ".\n", " /* scope */ . "):
                source = f'extension {owner}{separator}VisibleFailure {{ var {member}: String {{ "Visible nested error" }} }}'
                with self.subTest(path=path, separator=separator):
                    self.assert_visible(source, path, source.count("\n") + 1, "Visible nested error")

    def test_local_variables_and_local_types_are_not_direct_type_members(self) -> None:
        for path, owner, member in CLASSIFIED_MEMBERS:
            sources = (
                f'struct {owner} {{ func makeFailure() {{ var {member}: String {{ "Visible local failure" }} }} }}',
                f'func makeFailure() {{ struct {owner} {{ var {member}: String {{ "Visible local failure" }} }} }}',
                f'struct {owner} {{ let render = {{ var {member}: String {{ "Visible local failure" }} }} }}',
            )
            for source in sources:
                with self.subTest(path=path, source=source):
                    self.assert_visible(source, path, 1, "Visible local failure")

    def test_nested_protocol_and_generic_type_members_are_not_classified(self) -> None:
        for path, owner, member in CLASSIFIED_MEMBERS:
            for nested in ("protocol VisibleFailure", "struct VisibleFailure<T>"):
                source = f'struct {owner} {{ {nested} {{ var {member}: String {{ "Visible nested error" }} }} }}'
                with self.subTest(path=path, nested=nested):
                    self.assert_visible(source, path, 1, "Visible nested error")

    def test_unsupported_extension_target_is_not_treated_as_owner_prefix(self) -> None:
        for path, owner, member in CLASSIFIED_MEMBERS:
            source = f'extension {owner}<Value>.VisibleFailure {{ var {member}: String {{ "Visible specialized error" }} }}'
            with self.subTest(path=path):
                self.assert_visible(source, path, 1, "Visible specialized error")

    def test_exact_direct_members_keep_log_only_classification(self) -> None:
        self.assertEqual(set(checker.LOG_ONLY_COMPUTED_MEMBERS), set(CLASSIFIED_MEMBERS))
        for path, owner, member in CLASSIFIED_MEMBERS:
            for kind in ("struct", "class", "enum", "actor", "extension"):
                source = f'{kind} {owner} {{ var {member}: String {{ "log only reason=refused" }} }}'
                with self.subTest(path=path, kind=kind):
                    self.assertEqual(checker.find_uncatalogued_computed_literals(source, path), [])


if __name__ == "__main__":
    unittest.main()
