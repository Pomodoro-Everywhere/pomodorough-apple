from __future__ import annotations

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
TARGETS = (
    "PersistedStateCompatibilityTests",
    "PersistedStateCompatibilityMacTests",
)
REQUIRED_SOURCES = (
    "Tests/PersistedStateDecouplingCompatibilityTests.swift",
    "Tests/Compatibility/LegacyPendingOperationRebase.swift",
)


def target_settings(project: str, target: str) -> str:
    targets = project.split("\ntargets:\n", 1)[1]
    match = re.search(
        rf"^  {re.escape(target)}:\n(.*?)(?=^  \S|\Z)",
        targets,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"Missing target: {target}")
    return match.group(1)


class CompatibilityTargetTests(unittest.TestCase):
    def assert_standalone_sources(self, project: str, target: str) -> None:
        settings = target_settings(project, target)
        sources = re.search(r"^    sources: \[([^\]\n]*)\]$", settings, re.MULTILINE)
        self.assertIsNotNone(sources, f"{target}: expected explicit inline source list")
        assert sources is not None
        paths = [path.strip() for path in sources.group(1).split(",")]
        self.assertCountEqual(paths, REQUIRED_SOURCES, target)
        for path in paths:
            self.assertTrue((ROOT / path).is_file(), f"{target}: missing source {path}")

    def test_ios_standalone_includes_only_required_test_sources(self) -> None:
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assert_standalone_sources(project, TARGETS[0])

    def test_macos_standalone_includes_only_required_test_sources(self) -> None:
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        self.assert_standalone_sources(project, TARGETS[1])

    def test_missing_source_in_either_target_is_rejected(self) -> None:
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        for target in TARGETS:
            self.assert_standalone_sources(project, target)
            settings = target_settings(project, target)
            for source in REQUIRED_SOURCES:
                with self.subTest(target=target, source=source):
                    remaining = [path for path in REQUIRED_SOURCES if path != source]
                    changed = re.sub(
                        r"(?m)^    sources: \[[^\]\n]*\]$",
                        f"    sources: [{', '.join(remaining)}]",
                        settings,
                    )
                    mutated = project.replace(settings, changed, 1)
                    mutated += f"\n# {source}\n"
                    self.assertNotEqual(mutated, project)
                    for other in TARGETS:
                        if other != target:
                            self.assert_standalone_sources(mutated, other)
                    with self.assertRaises(AssertionError):
                        self.assert_standalone_sources(mutated, target)


if __name__ == "__main__":
    unittest.main()
