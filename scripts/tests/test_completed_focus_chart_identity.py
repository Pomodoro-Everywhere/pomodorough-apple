"""Headless source-wiring pins; Swift identity tests still require native execution."""
import unittest
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[2] / "Sources/Views/CompletedFocusBreakdownScreen.swift"


class CompletedFocusChartIdentityTests(unittest.TestCase):
    def test_chart_and_list_consume_the_same_entries(self):
        source = SOURCE.read_text()
        self.assertIn("let entries = CompletedFocusChartEntry.entries(for: summaries)", source)
        for caller in ("chart(entries)", "taskList(entries)", "Chart(entries)", "ForEach(entries)"):
            self.assertIn(caller, source)
        self.assertIn("var id: String { summary.id }", source)
        self.assertIn('.foregroundStyle(by: .value("Task", entry.id))', source)
        self.assertIn("domain: entries.map(\\.id)", source)
        self.assertNotIn("domain: summaries.map(\\.taskTitle)", source)

    def test_numbered_legend_uses_chart_palette_and_readable_labels(self):
        source = SOURCE.read_text()
        self.assertIn("range: entries.map(\\.color)", source)
        self.assertIn("ChartBadge(entry: entry)", source)
        self.assertIn(".background(entry.color, in: .circle)", source)
        self.assertEqual(source.count(".foregroundStyle(entry.labelColor)"), 2)
        self.assertEqual(source.count('Text("\\(entry.index + 1)")'), 2)
        self.assertIn(".chartLegend(.hidden)", source)
        self.assertIn("Text(summary.taskTitle)", source)
        self.assertIn(".accessibilityLabel(Self.accessibilityLabel(for: entry.summary))", source)
        self.assertIn(".accessibilityValue(Self.accessibilityValue(for: entry.summary))", source)

    def test_list_rows_speak_task_title_and_value(self):
        # Without the explicit label, the combined row speaks its child text
        # ("Deleted task, 1 completed, 1h 30m") instead of the task title.
        source = SOURCE.read_text()
        task_list = source[source.index("private func taskList("):source.index("private func focusMetric(")]
        row = task_list[task_list.index(".accessibilityElement(children: .combine)"):]
        self.assertIn(".accessibilityLabel(Self.accessibilityLabel(for: summary))", row)
        self.assertIn(".accessibilityValue(Self.accessibilityValue(for: summary))", row)


if __name__ == "__main__":
    unittest.main()
