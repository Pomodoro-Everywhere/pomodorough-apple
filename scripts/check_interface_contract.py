#!/usr/bin/env python3
"""Action-independent Apple interface/accessibility/localization contract checks."""
from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]

VISIBLE_APIS = (
    "Text", "Label", "Button", "Toggle", "Picker", "Section", "TextField", "SecureField",
    "LabeledContent", "Link", "ProgressView", "ContentUnavailableView", "navigationTitle",
    "accessibilityLabel", "accessibilityValue", "accessibilityHint", "help", "alert",
    "confirmationDialog",
)
VISIBLE_CALL_START_RE = re.compile(
    rf"(?:\b(?:{'|'.join(VISIBLE_APIS)})|\.(?:{'|'.join(VISIBLE_APIS)}))\s*\(\s*"
    r"(?:(?:String|LocalizedStringResource)\s*\(\s*localized\s*:\s*)?"
)
LOCALIZED_RE = re.compile(
    r'(?:String|LocalizedStringResource)\s*\(\s*localized\s*:\s*"((?:\\.|[^"\\])*)"',
    re.DOTALL,
)
SWIFT_LITERAL_RE = re.compile(r'"((?:\\.|[^"\\])*)"', re.DOTALL)
PRINTF_RE = re.compile(r"%(?:(\d+)\$)?(?:[-+#0 ']*\d*(?:\.\d+)?)?(?:hh|h|ll|l|q|z|t|j)?(arg|[@diuoxXfFeEgGaAcCsSp])")
USER_VISIBLE_NAME_RE = re.compile(
    r"(?:title|label|message|description|detail|hint|status|summary|accessibility|spoken|compact|text)$",
    re.IGNORECASE,
)
TECHNICAL_NAME_RE = re.compile(r"(?:symbol|identifier|id|key|url|path|scheme|platform)$", re.IGNORECASE)
VAR_STRING_DECLARATION_RE = re.compile(
    r"\bvar\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*String\??\s*\{"
)
FUNC_STRING_DECLARATION_RE = re.compile(
    r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\([^{}]*\)\s*(?:async\s+)?(?:throws\s+)?->\s*String\??\s*\{"
)


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def strip_debug_regions(source: str) -> str:
    """Exclude previews/debug fixtures without hiding production code around them."""
    lines = source.splitlines(keepends=True)
    output: list[str] = []
    depth = 0
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("#if DEBUG"):
            depth += 1
            continue
        if depth and stripped.startswith("#if"):
            depth += 1
            continue
        if depth and stripped.startswith("#endif"):
            depth -= 1
            continue
        if not depth:
            output.append(line)
    return "".join(output)


def swift_string_at(source: str, opening: int) -> tuple[str, int] | None:
    """Return a Swift string literal's contents/end, including nested interpolation text."""
    if opening >= len(source) or source[opening] != '"':
        return None
    index = opening + 1
    interpolation_depth = 0
    nested_string = False
    escaped = False
    while index < len(source):
        character = source[index]
        if nested_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                nested_string = False
            index += 1
            continue
        if interpolation_depth:
            if character == '"':
                nested_string = True
            elif character == "(":
                interpolation_depth += 1
            elif character == ")":
                interpolation_depth -= 1
            index += 1
            continue
        if character == "\\" and index + 1 < len(source):
            if source[index + 1] == "(":
                interpolation_depth = 1
                index += 2
            else:
                index += 2
            continue
        if character == '"':
            return source[opening + 1:index], index + 1
        index += 1
    return None


def replace_swift_interpolations(value: str) -> str:
    """Normalize balanced Swift interpolations, including expressions with strings/calls."""
    output: list[str] = []
    index = 0
    while index < len(value):
        if value.startswith("\\(", index):
            depth = 1
            cursor = index + 2
            in_string = False
            escaped = False
            while cursor < len(value) and depth:
                character = value[cursor]
                if in_string:
                    if escaped:
                        escaped = False
                    elif character == "\\":
                        escaped = True
                    elif character == '"':
                        in_string = False
                elif character == '"':
                    in_string = True
                elif character == "(":
                    depth += 1
                elif character == ")":
                    depth -= 1
                cursor += 1
            output.append("%arg")
            index = cursor
        else:
            output.append(value[index])
            index += 1
    return "".join(output)


def normalize_key(value: str) -> str:
    value = replace_swift_interpolations(value)
    value = PRINTF_RE.sub("%arg", value)
    return value.replace("%1$arg", "%arg").replace("%2$arg", "%arg")


def literals_after(matches: Any, source: str) -> set[str]:
    values: set[str] = set()
    for match in matches:
        opening = match.end()
        if opening < len(source) and source[opening] == '"':
            parsed = swift_string_at(source, opening)
            if parsed is not None:
                values.add(normalize_key(parsed[0]))
    return values


def extract_localizable_keys(source: str) -> set[str]:
    source = strip_debug_regions(source)
    keys = literals_after(VISIBLE_CALL_START_RE.finditer(source), source)
    action_starts = re.finditer(r"\.accessibilityAction\s*\(\s*named\s*:\s*", source)
    keys.update(literals_after(action_starts, source))
    keys.update(normalize_key(match.group(1)) for match in LOCALIZED_RE.finditer(source))
    return {key for key in keys if key}


def string_units(node: Any) -> list[str]:
    if not isinstance(node, dict):
        return []
    values: list[str] = []
    unit = node.get("stringUnit")
    if isinstance(unit, dict) and isinstance(unit.get("value"), str):
        values.append(unit["value"])
    for key in ("variations", "substitutions"):
        child = node.get(key)
        if isinstance(child, dict):
            for value in child.values():
                if isinstance(value, dict):
                    for nested in value.values():
                        values.extend(string_units(nested))
    return values


def placeholder_signature(value: str) -> Counter[tuple[int, str]]:
    implicit_position = 0
    signature: Counter[tuple[int, str]] = Counter()
    for match in PRINTF_RE.finditer(value):
        if match.group(1) is not None:
            position = int(match.group(1))
        else:
            implicit_position += 1
            position = implicit_position
        signature[(position, match.group(2))] += 1
    return signature


def plural_categories(localization: Any) -> set[str] | None:
    if not isinstance(localization, dict):
        return None
    variations = localization.get("variations")
    if isinstance(variations, dict) and isinstance(variations.get("plural"), dict):
        return set(variations["plural"])
    substitutions = localization.get("substitutions")
    if isinstance(substitutions, dict):
        categories: set[str] = set()
        for substitution in substitutions.values():
            if not isinstance(substitution, dict):
                continue
            nested = substitution.get("variations", {}).get("plural")
            if isinstance(nested, dict):
                categories.update(nested)
        if categories:
            return categories
    return None


def validate_shipping_catalog(catalog: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    require(catalog.get("sourceLanguage") == "en", "sourceLanguage must be English", failures)
    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        return failures + ["catalog strings must be an object"]
    for key, entry in sorted(strings.items()):
        if not isinstance(entry, dict):
            failures.append(f"invalid catalog entry: {key}")
            continue
        localizations = entry.get("localizations", {})
        if not isinstance(localizations, dict):
            failures.append(f"missing localizations: {key}")
            continue
        unexpected = set(localizations) - {"en"}
        require(not unexpected, f"non-shipping locale in production catalog for {key}: {sorted(unexpected)}", failures)
        values = string_units(localizations.get("en"))
        require(bool(values), f"missing en localization: {key}", failures)
        for value in values:
            require(bool(value.strip()), f"empty en localization: {key}", failures)
        plural = plural_categories(localizations.get("en"))
        if plural is not None:
            require({"one", "other"} <= plural, f"English plural categories incomplete: {key}", failures)
    return failures


def validate_pseudo_fixture(shipping: dict[str, Any], fixture: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    require(fixture.get("locale") == "ar-XB", "pseudo fixture locale must be ar-XB", failures)
    require(
        fixture.get("layoutDirection") in (None, "right-to-left"),
        "pseudo fixture must use right-to-left layout direction",
        failures,
    )
    shipping_strings = shipping.get("strings", {})
    pseudo_strings = fixture.get("strings", {})
    if not isinstance(shipping_strings, dict) or not isinstance(pseudo_strings, dict):
        return failures + ["shipping and pseudo strings must be objects"]
    require(
        set(shipping_strings) == set(pseudo_strings),
        "shipping and pseudo fixture keys differ",
        failures,
    )
    for key in sorted(set(shipping_strings) & set(pseudo_strings)):
        shipping_entry = shipping_strings[key]
        english = shipping_entry.get("localizations", {}).get("en") if isinstance(shipping_entry, dict) else None
        pseudo = pseudo_strings[key]
        english_values = string_units(english)
        pseudo_values = string_units(pseudo)
        require(bool(pseudo_values), f"missing RTL pseudo localization: {key}", failures)
        for value in pseudo_values:
            require(value.startswith("\u200f⟦") and value.endswith("⟧"), f"invalid RTL pseudo decoration: {key}", failures)
        if english_values and pseudo_values:
            english_signatures = {tuple(sorted(placeholder_signature(value).items())) for value in english_values}
            pseudo_signatures = {tuple(sorted(placeholder_signature(value).items())) for value in pseudo_values}
            require(
                english_signatures == pseudo_signatures,
                f"placeholder parity mismatch for {key}: en={english_signatures}, pseudo={pseudo_signatures}",
                failures,
            )
        english_plural = plural_categories(english)
        pseudo_plural = plural_categories(pseudo)
        if english_plural is not None or pseudo_plural is not None:
            require(
                english_plural is not None and {"one", "other"} <= english_plural,
                f"English plural categories incomplete: {key}",
                failures,
            )
            require(
                pseudo_plural is not None and {"zero", "one", "two", "few", "many", "other"} <= pseudo_plural,
                f"Arabic plural categories incomplete: {key}",
                failures,
            )
    return failures


def matching_brace(source: str, opening: int) -> int:
    depth = 0
    in_string = False
    escaped = False
    for index in range(opening, len(source)):
        character = source[index]
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == '"':
            in_string = True
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return index
    return len(source)


def find_uncatalogued_computed_literals(source: str, relative_path: str) -> list[str]:
    source = strip_debug_regions(source)
    failures: list[str] = []
    declarations = sorted(
        [*VAR_STRING_DECLARATION_RE.finditer(source), *FUNC_STRING_DECLARATION_RE.finditer(source)],
        key=lambda match: match.start(),
    )
    for declaration in declarations:
        name = declaration.group(1)
        if TECHNICAL_NAME_RE.search(name) or not USER_VISIBLE_NAME_RE.search(name):
            continue
        opening = source.find("{", declaration.start())
        block = source[opening + 1:matching_brace(source, opening)]
        localized_ranges: list[tuple[int, int]] = []
        for match in re.finditer(r"(?:String|LocalizedStringResource)\s*\(\s*localized\s*:\s*", block):
            opening_call = block.find("(", match.start())
            depth = 0
            end = len(block)
            in_string = False
            escaped = False
            for index in range(opening_call, len(block)):
                character = block[index]
                if in_string:
                    if escaped:
                        escaped = False
                    elif character == "\\":
                        escaped = True
                    elif character == '"':
                        in_string = False
                    continue
                if character == '"':
                    in_string = True
                elif character == "(":
                    depth += 1
                elif character == ")":
                    depth -= 1
                    if depth == 0:
                        end = index + 1
                        break
            localized_ranges.append((match.start(), end))
        for literal in SWIFT_LITERAL_RE.finditer(block):
            value = literal.group(1)
            if not value or any(start <= literal.start(1) < end for start, end in localized_ranges):
                continue
            if re.fullmatch(r"[a-z0-9_.:/+-]+", value):
                continue
            line = source.count("\n", 0, opening + 1 + literal.start()) + 1
            failures.append(
                f"uncatalogued computed user-visible literal: {relative_path}:{line}: {value}"
            )
    return failures


def validate_source_coverage(root: Path, catalog: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    strings = catalog.get("strings", {})
    catalog_keys = {normalize_key(key) for key in strings} if isinstance(strings, dict) else set()
    source_root = root / "Sources"
    for path in sorted(source_root.rglob("*.swift")):
        source = path.read_text(encoding="utf-8")
        relative = str(path.relative_to(root))
        for key in sorted(extract_localizable_keys(source) - catalog_keys):
            failures.append(f"uncatalogued production-visible key: {relative}: {key}")
        failures.extend(find_uncatalogued_computed_literals(source, relative))
    return failures


def main() -> int:
    failures: list[str] = []
    catalog_path = ROOT / "Resources/Localizable.xcstrings"
    pseudo_path = ROOT / "UITests/Fixtures/Localizable.ar-XB.json"
    try:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        pseudo_fixture = json.loads(pseudo_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"invalid localization resource: {error}", file=sys.stderr)
        return 1

    failures.extend(validate_shipping_catalog(catalog))
    failures.extend(validate_pseudo_fixture(catalog, pseudo_fixture))
    failures.extend(validate_source_coverage(ROOT, catalog))

    for screen in ("TimerScreen.swift", "TasksScreen.swift", "ServicePatternScreen.swift", "HistoryScreen.swift"):
        require(
            ".primaryRouteAccountToolbar(model: model)" in read(f"Sources/Views/{screen}"),
            f"mobile primary route lacks Account toolbar: {screen}", failures,
        )

    modern_tabs = read("Sources/Views/ModernTabs.swift")
    legacy_tabs = read("Sources/Views/LegacyTabs.swift")
    for tabs, name in ((modern_tabs, "ModernTabs"), (legacy_tabs, "LegacyTabs")):
        require(tabs.count('"Timer"') == 1, f"{name} Timer route mismatch", failures)
        require(tabs.count('"Tasks"') == 1, f"{name} Tasks route mismatch", failures)
        require(tabs.count('"Pattern"') == 1, f"{name} Pattern route mismatch", failures)
        require(tabs.count('"Arrivals"') == 1, f"{name} Arrivals route mismatch", failures)
        require('"Network"' not in tabs, f"{name} must not add Network as a fifth mobile tab", failures)

    main_container = read("Sources/Views/MainContainer.swift")
    require('Label("Network"' in main_container, "macOS Network primary destination missing", failures)
    require('Button("Settings"' in main_container, "macOS Settings action missing", failures)
    require('.accessibilityValue("Pattern")' in main_container, "macOS Settings must name Pattern", failures)

    pattern = read("Sources/Views/ServicePatternCard.swift")
    task_picker = read("Sources/Views/TimerTaskPicker.swift")
    permission = read("Sources/Views/PermissionIntroductionView.swift")
    account = read("Sources/Views/AccountView.swift")
    require('Label("Applies to next timer"' in pattern, "active pattern edits lack next-timer disclosure", failures)
    require('Picker("Next focus task"' in task_picker, "active task picker lacks next-focus semantics", failures)
    require('Text("Active timer task")' in task_picker, "active task assignment is not separately announced", failures)
    guarantee = "subject to the operating system's delivery policy"
    require(guarantee in permission, "pre-permission completion guarantee disclosure missing", failures)
    require(guarantee in account, "persistent completion guarantee disclosure missing", failures)
    require("https://pomodoro-everywhere.github.io/pomodorough-server/privacy/" in account,
            "public privacy policy link missing", failures)

    pbx = read("Pomodorough.xcodeproj/project.pbxproj")
    require("Localizable.xcstrings" in pbx, "localization catalog is not in the generated project", failures)
    require("Localizable.ar-XB.json" in pbx, "RTL pseudo fixture is not in the UI test target", failures)
    require("ar.lproj" not in pbx, "production project must not contain ar.lproj", failures)

    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(
        f"interface contract ok ({len(catalog.get('strings', {}))} English shipping keys; "
        "non-shipping RTL pseudo fixture)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
