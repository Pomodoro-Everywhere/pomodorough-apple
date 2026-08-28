#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "check_interface_contract.py"
SPEC = importlib.util.spec_from_file_location("check_interface_contract", SCRIPT)
assert SPEC and SPEC.loader
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)
GENERATOR_SCRIPT = Path(__file__).resolve().parents[1] / "update_localization_catalog.py"


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


class LocalizationContractTests(unittest.TestCase):
    def test_discovers_static_and_interpolated_swiftui_strings(self) -> None:
        source = '''
        Text("Hello")
        Text("\\(count) tasks")
        Image(systemName: "timer")
        String(localized: "Computed status")
        '''
        self.assertEqual(
            checker.extract_localizable_keys(source),
            {"Hello", "%arg tasks", "Computed status"},
        )

    def test_tagged_primary_destination_requires_matching_text_and_tab(self) -> None:
        source = '''
        Picker("Section", selection: $selectedTab) {
            Text("Network")
                .tag(MainTab.network)
            Text("Network status")
        }
        '''
        self.assertTrue(checker.has_tagged_primary_destination(source, "Network", "network"))
        self.assertFalse(checker.has_tagged_primary_destination(source, "Network", "history"))

    def test_shipping_catalog_rejects_non_english_locales(self) -> None:
        catalog = {
            "sourceLanguage": "en",
            "strings": {
                "Greeting": {
                    "localizations": {
                        "en": unit("Greeting"),
                        "ar": unit("\u200f⟦Greeting⟧"),
                    }
                },
            },
        }
        failures = checker.validate_shipping_catalog(catalog)
        self.assertTrue(any("non-shipping locale" in failure for failure in failures))

    def test_pseudo_fixture_requires_key_placeholder_and_plural_parity(self) -> None:
        shipping = {
            "sourceLanguage": "en",
            "strings": {
                "task.count": {
                    "localizations": {
                        "en": {
                            "variations": {
                                "plural": {
                                    "one": unit("%lld task"),
                                    "other": unit("%lld tasks"),
                                }
                            }
                        },
                    }
                }
            },
        }
        pseudo = {
            "locale": "ar-XB",
            "strings": {
                "task.count": {
                    "variations": {
                        "plural": {
                            "one": unit("\u200f⟦%lld task⟧"),
                            "other": unit("\u200f⟦%lld tasks⟧"),
                        }
                    }
                },
            },
        }
        failures = checker.validate_pseudo_fixture(shipping, pseudo)
        self.assertTrue(any("Arabic plural categories" in failure for failure in failures))

    def test_visible_literal_audit_rejects_uncatalogued_key(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = root / "Sources"
            sources.mkdir()
            (sources / "Screen.swift").write_text('Text("Visible but missing")\n', encoding="utf-8")
            catalog = {"sourceLanguage": "en", "strings": {}}
            failures = checker.validate_source_coverage(root, catalog)
            self.assertTrue(any("Visible but missing" in failure for failure in failures))

    def test_computed_user_visible_literal_must_use_localization_api(self) -> None:
        source = '''
        var statusLabel: String {
            if ready { return "Ready now" }
            return String(localized: "Not ready")
        }
        '''
        failures = checker.find_uncatalogued_computed_literals(source, "Model.swift")
        self.assertTrue(any("Ready now" in failure for failure in failures))
        self.assertFalse(any("Not ready" in failure for failure in failures))

    def test_computed_user_visible_literal_without_localized_sibling_is_rejected(self) -> None:
        source = 'var statusLabel: String { return "Ready now" }'
        failures = checker.find_uncatalogued_computed_literals(source, "Model.swift")
        self.assertTrue(any("Ready now" in failure for failure in failures))

    def test_localized_default_value_is_not_reported_as_raw_literal(self) -> None:
        source = '''
        func spokenText() -> String {
            String(localized: "duration.spoken.minutes", defaultValue: "%lld minutes")
        }
        '''
        self.assertEqual(checker.find_uncatalogued_computed_literals(source, "Model.swift"), [])

    def test_complex_interpolation_is_normalized_as_one_placeholder(self) -> None:
        source = '''
        Text("Focus task: \\(task?.title ?? String(localized: \"No task\"))")
        confirmationDialog("Switch to \\(user?.email ?? \"this account\")?")
        '''
        self.assertEqual(
            checker.extract_localizable_keys(source),
            {"Focus task: %arg", "No task", "Switch to %arg?"},
        )

    def test_placeholder_validation_preserves_positional_identity(self) -> None:
        shipping = {
            "sourceLanguage": "en",
            "strings": {
                "two.values": {
                    "localizations": {
                        "en": unit("%1$lld hours %2$lld minutes"),
                    }
                }
            },
        }
        pseudo = {
            "locale": "ar-XB",
            "strings": {"two.values": unit("%1$lld hours %1$lld minutes")},
        }
        failures = checker.validate_pseudo_fixture(shipping, pseudo)
        self.assertTrue(any("placeholder parity" in failure for failure in failures))

    def test_catalog_generator_keeps_pseudo_only_in_test_fixture(self) -> None:
        generator_spec = importlib.util.spec_from_file_location("update_localization_catalog", GENERATOR_SCRIPT)
        assert generator_spec and generator_spec.loader
        generator = importlib.util.module_from_spec(generator_spec)
        generator_spec.loader.exec_module(generator)
        keys = {"Greeting %@": "Greeting %@", "%lld tasks": "%lld tasks"}
        catalog = generator.build_catalog(keys)
        self.assertEqual(
            catalog["strings"]["Greeting %@"]["localizations"]["en"]["stringUnit"]["value"],
            "Greeting %@",
        )
        plural = catalog["strings"]["%lld tasks"]["localizations"]
        self.assertEqual(set(plural["en"]["variations"]["plural"]), {"one", "other"})
        self.assertEqual(set(plural), {"en"})
        pseudo = generator.build_pseudo_fixture(keys)
        self.assertEqual(pseudo["locale"], "ar-XB")
        self.assertEqual(
            set(pseudo["strings"]["%lld tasks"]["variations"]["plural"]),
            {"zero", "one", "two", "few", "many", "other"},
        )


if __name__ == "__main__":
    unittest.main()
