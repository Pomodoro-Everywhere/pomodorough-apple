#!/usr/bin/env python3
"""Regenerate shipping English strings and a non-shipping RTL pseudo fixture.

Build with SWIFT_EMIT_LOC_STRINGS=YES, then pass the app target's Objects-normal
folder. ``Resources/Localizable.xcstrings`` contains production English only.
The separate ``UITests/Fixtures/Localizable.ar-XB.json`` file preserves
placeholder, plural, expansion, and RTL coverage without creating ar.lproj in
shipping applications.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

ARABIC_CATEGORIES = ("zero", "one", "two", "few", "many", "other")
COUNT_WORD_RE = re.compile(
    r"\b(minutes?|hours?|tasks?|entries?|changes?|pomodoros?|peers?|records?|queued|completed|total)\b",
    re.IGNORECASE,
)
INTEGER_PLACEHOLDER_RE = re.compile(r"%(?:(?:\d+)\$)?(?:ll|l)?[diu]")


def unit(value: str) -> dict[str, Any]:
    return {"stringUnit": {"state": "translated", "value": value}}


def pseudo(value: str) -> str:
    return f"\u200f⟦{value}⟧"


def singular(value: str) -> str:
    replacements = {
        "minutes": "minute",
        "hours": "hour",
        "tasks": "task",
        "entries": "entry",
        "changes": "change",
        "pomodoros": "pomodoro",
        "peers": "peer",
        "records": "record",
    }
    result = value
    for plural, one in replacements.items():
        result = re.sub(rf"\b{plural}\b", one, result, flags=re.IGNORECASE)
    result = re.sub(r"\bqueued change remain\b", "queued change remains", result, flags=re.IGNORECASE)
    return result


def needs_plural(value: str) -> bool:
    return len(INTEGER_PLACEHOLDER_RE.findall(value)) == 1 and COUNT_WORD_RE.search(value) is not None


def english_entry(value: str) -> dict[str, Any]:
    if not needs_plural(value):
        return {"localizations": {"en": unit(value)}}
    return {
        "localizations": {
            "en": {
                "variations": {
                    "plural": {
                        "one": unit(singular(value)),
                        "other": unit(value),
                    }
                }
            }
        }
    }


def pseudo_entry(value: str) -> dict[str, Any]:
    if not needs_plural(value):
        return unit(pseudo(value))
    one = singular(value)
    return {
        "variations": {
            "plural": {
                category: unit(pseudo(one if category == "one" else value))
                for category in ARABIC_CATEGORIES
            }
        }
    }


def build_catalog(keys: dict[str, str]) -> dict[str, Any]:
    return {
        "sourceLanguage": "en",
        "strings": {key: english_entry(value) for key, value in sorted(keys.items())},
        "version": "1.0",
    }


def build_pseudo_fixture(keys: dict[str, str]) -> dict[str, Any]:
    return {
        "locale": "ar-XB",
        "layoutDirection": "right-to-left",
        "strings": {key: pseudo_entry(value) for key, value in sorted(keys.items())},
        "version": 1,
    }


def collect_stringsdata(root: Path) -> dict[str, str]:
    keys: dict[str, str] = {}
    for path in sorted(root.rglob("*.stringsdata")):
        data = json.loads(path.read_text(encoding="utf-8"))
        source = data.get("source", "")
        if "Pomodorough" not in str(source) and "/Sources/" not in str(source):
            continue
        for item in data.get("tables", {}).get("Localizable", []):
            key = item.get("key")
            if not isinstance(key, str) or not key:
                continue
            value = item.get("value", key)
            if not isinstance(value, str):
                value = key
            prior = keys.get(key)
            if prior is not None and prior != value:
                raise ValueError(f"conflicting source values for {key!r}: {prior!r} vs {value!r}")
            keys[key] = value
    if not keys:
        raise ValueError(f"no Localizable keys found under {root}")
    return keys


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument("stringsdata_root", type=Path)
    parser.add_argument("--output", type=Path, default=root / "Resources/Localizable.xcstrings")
    parser.add_argument(
        "--pseudo-output",
        type=Path,
        default=root / "UITests/Fixtures/Localizable.ar-XB.json",
    )
    args = parser.parse_args()
    keys = collect_stringsdata(args.stringsdata_root)
    catalog = build_catalog(keys)
    pseudo_fixture = build_pseudo_fixture(keys)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.pseudo_output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    args.pseudo_output.write_text(
        json.dumps(pseudo_fixture, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        f"wrote {len(catalog['strings'])} English shipping keys to {args.output} "
        f"and RTL pseudo test keys to {args.pseudo_output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
