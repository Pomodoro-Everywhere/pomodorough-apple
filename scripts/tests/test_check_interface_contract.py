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


class R49AP07DiagnosticClassificationTests(unittest.TestCase):
    def test_reviewed_log_only_members_do_not_require_localization(self) -> None:
        cases = [
            ("Sources/AppModel.swift", '''
struct SyncFailureDiagnostics: Error, LocalizedError, Sendable {
    var errorDescription: String? {
        "sync stage=\\(stage.rawValue) rollback=\\(rollback.rawValue) reason=\\(reason.rawValue) "
            + "pending=\\(pending.map(String.init).joined(separator: "/")) claim=\\(hasClaim) "
            + "core=\\(WorkspaceIntentProvenance.current().prefix(160))"
    }
}
'''),
            ("Sources/WorkspaceIntentModels.swift", '''
struct SuppressedSelectionDiagnostics: Sendable {
    var publicMessage: String {
        "selectedTaskBase reason=suppressedSelectionUsesCanonical pending=\\(pending) proof=\\(proof) "
            + "dependencies=\\(dependencies) claim=\\(hasClaim) head=\\(hasHead) core=\\(provenance)"
    }
}
'''),
        ]
        for path, source in cases:
            with self.subTest(path=path):
                self.assertEqual(checker.find_uncatalogued_computed_literals(source, path), [])
                self.assertEqual(checker.extract_localizable_keys(source), set())

    def test_user_visible_diagnostics_and_errors_still_require_localization(self) -> None:
        cases = [
            ("Sources/AppModel.swift", "UserFacingError", "var errorDescription: String?"),
            ("Sources/WorkspaceIntentModels.swift", "WorkspaceMutationDiagnostics", "func publicMessage() -> String"),
            ("Sources/AppModel.swift", "SyncFailureDiagnostics", "var statusLabel: String"),
            ("Sources/Other.swift", "SyncFailureDiagnostics", "var errorDescription: String?"),
            ("Sources/Other.swift", "SuppressedSelectionDiagnostics", "var publicMessage: String"),
        ]
        for path, owner, declaration in cases:
            source = f'struct {owner} {{\n    {declaration} {{ "Needs attention" }}\n}}'
            with self.subTest(path=path, owner=owner, declaration=declaration):
                self.assertEqual(
                    checker.find_uncatalogued_computed_literals(source, path),
                    [f"uncatalogued computed user-visible literal: {path}:2: Needs attention"],
                )

    def test_diagnostic_scope_does_not_hide_adjacent_or_nested_ui_members(self) -> None:
        source = '''struct SyncFailureDiagnostics {
    var errorDescription: String? { "sync stage=failed" }
    struct UserFacingError {
        var errorDescription: String? { "Nested visible error" }
    }
}
struct UserFacingError {
    var errorDescription: String? { "Adjacent visible error" }
}
'''
        self.assertEqual(
            checker.find_uncatalogued_computed_literals(source, "Sources/AppModel.swift"),
            [
                "uncatalogued computed user-visible literal: Sources/AppModel.swift:4: Nested visible error",
                "uncatalogued computed user-visible literal: Sources/AppModel.swift:8: Adjacent visible error",
            ],
        )

    def test_comment_and_string_lookalikes_cannot_create_diagnostic_scope(self) -> None:
        prefixes = [
            '// struct SyncFailureDiagnostics {\n',
            '/* struct SyncFailureDiagnostics { */\n',
            '/* outer /* nested */ struct SyncFailureDiagnostics { */\n',
            'let example = "struct SyncFailureDiagnostics {"\n',
        ]
        for prefix in prefixes:
            source = prefix + 'var errorDescription: String? { "Visible failure" }\n'
            with self.subTest(prefix=prefix):
                self.assertEqual(
                    checker.find_uncatalogued_computed_literals(source, "Sources/AppModel.swift"),
                    ["uncatalogued computed user-visible literal: Sources/AppModel.swift:2: Visible failure"],
                )

    def test_type_scope_forms_and_closing_brace_keep_exact_member_boundary(self) -> None:
        for kind in ("struct", "class", "enum", "extension"):
            source = f'''{kind} SyncFailureDiagnostics {{
    // }} struct UserFacingError {{
    /* }} */
    var errorDescription: String? {{ "sync stage=\\(values.joined(separator: "}}"))" }}
}}
var errorDescription: String? {{ "Visible after diagnostic" }}
'''
            with self.subTest(kind=kind):
                self.assertEqual(
                    checker.find_uncatalogued_computed_literals(source, "Sources/AppModel.swift"),
                    ["uncatalogued computed user-visible literal: Sources/AppModel.swift:6: Visible after diagnostic"],
                )

    def test_visible_apis_and_localization_calls_inside_diagnostic_still_require_catalog(self) -> None:
        source = '''struct SyncFailureDiagnostics {
    var errorDescription: String? {
        let label = Text("Visible label")
        return String(localized: "Visible failure")
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = root / "Sources"
            sources.mkdir()
            (sources / "AppModel.swift").write_text(source, encoding="utf-8")
            self.assertEqual(
                checker.validate_source_coverage(root, {"strings": {}}),
                [
                    "uncatalogued production-visible key: Sources/AppModel.swift: Visible failure",
                    "uncatalogued production-visible key: Sources/AppModel.swift: Visible label",
                ],
            )

    def test_raw_text_and_accessibility_checks_still_apply_inside_log_only_member(self) -> None:
        source = '''struct SyncFailureDiagnostics {
    var errorDescription: String? {
        Text(ready ? "Ready now" : "Not ready")
            .accessibilityLabel(ready ? "Ready label" : "Not ready label")
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = root / "Sources"
            sources.mkdir()
            (sources / "AppModel.swift").write_text(source, encoding="utf-8")
            self.assertEqual(
                checker.validate_source_coverage(root, {"strings": {}}),
                [
                    "raw a11y conditional literal: Sources/AppModel.swift:4",
                    "raw Text conditional literal: Sources/AppModel.swift:3",
                ],
            )

    def test_watch_refusal_ui_keys_require_catalog_even_beside_logs(self) -> None:
        keys = {f"Watch {action} not applied." for action in ("Start", "Resume", "Finish")}
        source = "\n".join(
            f'logger.error("watch {action.lower()} refused")\n'
            f'errorMessage = String(localized: "Watch {action} not applied.")'
            for action in ("Start", "Resume", "Finish")
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = root / "Sources"
            sources.mkdir()
            (sources / "AppModel.swift").write_text(source, encoding="utf-8")
            self.assertEqual(checker.extract_localizable_keys(source), keys)
            self.assertEqual(
                checker.validate_source_coverage(root, {"strings": {}}),
                [f"uncatalogued production-visible key: Sources/AppModel.swift: {key}" for key in sorted(keys)],
            )
            self.assertEqual(checker.validate_source_coverage(root, {"strings": dict.fromkeys(keys)}), [])


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

    def test_disclosureGroup_visible_literal_requires_catalog(self) -> None:
        # AP89 gate probe: DisclosureGroup was gate-blind (not in VISIBLE_APIS),
        # so a bare literal silently bypassed the contract. Removing it from
        # VISIBLE_APIS must turn this red again.
        self.assertIn("DisclosureGroup", checker.VISIBLE_APIS)
        self.assertEqual(
            checker.extract_localizable_keys('DisclosureGroup("Create another room")\n'),
            {"Create another room"},
        )
        self.assertEqual(
            checker.extract_localizable_keys(
                'DisclosureGroup(String(localized: "Create another room"))\n'
            ),
            {"Create another room"},
        )

    def test_accessibilityLabel_visible_literal_requires_catalog(self) -> None:
        # AP96 gate probe: accessibilityLabel is user-visible, so a bare
        # literal must surface as a catalog key. Removing it from
        # VISIBLE_APIS must turn this red again.
        self.assertIn("accessibilityLabel", checker.VISIBLE_APIS)
        self.assertEqual(
            checker.extract_localizable_keys('.accessibilityLabel("Pomodoro progress")\n'),
            {"Pomodoro progress"},
        )

    def test_idle_status_localized_key_requires_catalog(self) -> None:
        # AP97 probe: the idle dial status flows into readout text + a11y,
        # so String(localized:) must surface it as a catalog key.
        self.assertEqual(
            checker.extract_localizable_keys('status: String(localized: "Idle")\n'),
            {"Idle"},
        )

    def test_controlButton_raw_literal_is_rejected(self) -> None:
        # AP101 gate probe: controlButton titles are user-visible but bypass
        # VISIBLE_APIS, so a bare literal must fail even when catalogued.
        # Removing CONTROL_BUTTON_RAW_RE must turn this red again.
        failures = checker.find_raw_control_button_literals(
            'controlButton("Finish", symbol: "checkmark")\n', "TimerControls.swift"
        )
        self.assertTrue(any("raw controlButton literal" in failure for failure in failures))
        self.assertEqual(
            checker.find_raw_control_button_literals(
                'controlButton(String(localized: "Finish"), symbol: "checkmark")\n',
                "TimerControls.swift",
            ),
            [],
        )

    def test_controlButton_multiline_raw_literal_is_rejected(self) -> None:
        # AP101 follow-up: the per-line gate missed controlButton(\n"..."
        # (parent Start button). The DOTALL full-source search must flag it.
        failures = checker.find_raw_control_button_literals(
            'controlButton(\n                "Start foo",\n                symbol: "play.fill",\n',
            "TimerControls.swift",
        )
        self.assertTrue(any("raw controlButton literal" in failure for failure in failures))
        self.assertEqual(
            checker.find_raw_control_button_literals(
                'controlButton(\n                String(localized: "Start foo"),\n                symbol: "play.fill",\n',
                "TimerControls.swift",
            ),
            [],
        )

    def test_raw_sync_a11y_literal_is_rejected(self) -> None:
        # AP109 gate probe: sync a11y wrappers interpolate without
        # String(localized:), so the spoken wrapper stays English even
        # when the inner label is localized. Removing the probe must
        # turn these red again.
        self.assertEqual(
            checker.find_raw_sync_a11y_literals(
                '.accessibilityLabel(String(localized: "Sync status, \\(label)"))\n',
                "SyncToolbarStatus.swift",
            ),
            [],
        )
        self.assertTrue(
            any(
                "raw sync a11y literal" in failure
                for failure in checker.find_raw_sync_a11y_literals(
                    '.accessibilityLabel("Sync status, \\(label)")\n',
                    "SyncToolbarStatus.swift",
                )
            )
        )
        self.assertTrue(
            any(
                "raw sync a11y literal" in failure
                for failure in checker.find_raw_sync_a11y_literals(
                    '.accessibilityLabel("Sync needs attention. \\(message). Dismiss")\n',
                    "ConflictBanner.swift",
                )
            )
        )
        self.assertEqual(
            checker.find_raw_sync_a11y_literals(
                '.accessibilityLabel(String(localized: "Sync needs attention. \\(message). Dismiss"))\n',
                "ConflictBanner.swift",
            ),
            [],
        )
        self.assertTrue(
            any(
                "raw sync a11y literal" in failure
                for failure in checker.find_raw_sync_a11y_literals(
                    '.accessibilityLabel(model.isSignedIn ? "Account, \\(label)" : "Sign in")\n',
                    "AccountSyncToolbarButton.swift",
                )
            )
        )
        self.assertEqual(
            checker.find_raw_sync_a11y_literals(
                '.accessibilityLabel(model.isSignedIn ? String(localized: "Account, \\(label)") : String(localized: "Sign in"))\n',
                "AccountSyncToolbarButton.swift",
            ),
            [],
        )

    def test_raw_a11y_conditional_literal_is_rejected(self) -> None:
        # AP110-AP114 gate probe: a ternary/?? branch handing a bare
        # literal to an a11y/.help position stays English at runtime,
        # even when the string is catalogued elsewhere. Removing the
        # probe must turn these red again.
        bad = [
            '.accessibilityValue(item.date?.formatted(date: .abbreviated, time: .shortened) ?? "Time not recorded")\n',
            '.accessibilityHint(model.isSignedIn ? "Sync now" : "Sign in to sync across devices")\n',
            '.accessibilityHint(disabled ? "Stop the current timer to change this setting." : "Double tap to select this phase.")\n',
            '.accessibilityHint(\n    disabled\n        ? "Stop the current timer to change this setting."\n        : "Double tap to select this phase."\n    )\n',
            '.help(model.isSignedIn ? model.syncLabel : "Sign in")\n',
            '.accessibilityValue(selected ? "Selected" : "Not selected")\n',
        ]
        for snippet in bad:
            self.assertTrue(
                any(
                    "raw a11y conditional literal" in failure
                    for failure in checker.find_raw_a11y_conditional_literals(snippet, "Probe.swift")
                ),
                snippet,
            )
        good = [
            '.accessibilityValue(item.date?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Time not recorded"))\n',
            '.accessibilityHint(model.isSignedIn ? String(localized: "Sync now") : String(localized: "Sign in to sync across devices"))\n',
            '.accessibilityHint(disabled ? String(localized: "Stop the current timer to change this setting.") : String(localized: "Double tap to select this phase."))\n',
            '.help(model.isSignedIn ? model.syncLabel : String(localized: "Sign in"))\n',
            '.accessibilityLabel(glassID == .primary ? primaryAccessibilityTitle : title)\n',
        ]
        for snippet in good:
            self.assertEqual(
                checker.find_raw_a11y_conditional_literals(snippet, "Probe.swift"),
                [],
                snippet,
            )

    def test_raw_text_conditional_literal_is_rejected(self) -> None:
        # AP115 gate probe: a ternary/?? branch handing a bare
        # literal to Text stays English at runtime, even when the
        # string is catalogued elsewhere. Removing the probe must
        # turn these red again.
        bad = [
            'Text(model.isTimerActive ? "Starts the break." : "Short after focus.")\n',
            'Text(room.roomName ?? "Unnamed room")\n',
            'Text(model.replicationMode == .iroh ? model.irohStatusLabel : "Saved")\n',
            'Text(isCreating.wrappedValue ? "Rotating room" : "Create replacement room")\n',
            'Text(model.errorMessage ?? "Unknown error")\n',
        ]
        for snippet in bad:
            self.assertTrue(
                any(
                    "raw Text conditional literal" in failure
                    for failure in checker.find_raw_text_conditional_literals(snippet, "Probe.swift")
                ),
                snippet,
            )
        good = [
            'Text(model.isTimerActive ? String(localized: "Starts the break.") : String(localized: "Short after focus."))\n',
            'Text(room.roomName ?? String(localized: "Unnamed room"))\n',
            'Text(model.snapshotLoadFailure?.localizedDescription ?? "")\n',
            'Text("Static title")\n',
        ]
        for snippet in good:
            self.assertEqual(
                checker.find_raw_text_conditional_literals(snippet, "Probe.swift"),
                [],
                snippet,
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
