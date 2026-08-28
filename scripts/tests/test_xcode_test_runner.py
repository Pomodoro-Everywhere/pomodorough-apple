from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest import mock

from scripts import run_xcode_tests


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "scripts" / "run_xcode_tests.py"
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


class XcodeTestRunnerTests(unittest.TestCase):
    def test_successful_child_fails_closed_when_log_write_fails(self) -> None:
        process = mock.Mock(stdout=iter(["** TEST EXECUTE SUCCEEDED **\n"]), returncode=0)
        process.poll.return_value = 0
        bad_log = mock.MagicMock()
        bad_log.__enter__.return_value.write.side_effect = OSError(28, "No space left")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = argparse.Namespace(
                log_path=root / "xcodebuild.log",
                diagnostics_dir=root / "diagnostics",
                command=["fake-xcodebuild"],
                idle_timeout=1,
                wall_timeout=5,
            )
            with mock.patch.object(Path, "open", return_value=bad_log), mock.patch.object(
                run_xcode_tests.subprocess,
                "Popen",
                return_value=process,
            ):
                result = run_xcode_tests.run(args)

        self.assertEqual(result, run_xcode_tests.EVIDENCE_FAILURE)

    def test_process_exit_during_timeout_signaling_is_harmless(self) -> None:
        process = mock.Mock(pid=1234)
        process.poll.return_value = None
        with mock.patch.object(
            run_xcode_tests.os,
            "killpg",
            side_effect=ProcessLookupError,
        ):
            run_xcode_tests.terminate_process_group(process)

    def test_descendants_are_terminated_after_xcodebuild_leader_exits(self) -> None:
        process = mock.Mock(pid=1234)
        with mock.patch.object(
            run_xcode_tests,
            "signal_process_group",
            return_value=True,
        ) as send, mock.patch.object(
            run_xcode_tests,
            "wait_for_process_group_exit",
            side_effect=[False, True],
        ), mock.patch.object(
            run_xcode_tests,
            "descendant_pids",
            return_value=set(),
        ):
            run_xcode_tests.terminate_process_group(process)

        sent_signals = [call.args[1] for call in send.call_args_list]
        self.assertIn(run_xcode_tests.signal.SIGINT, sent_signals)
        self.assertIn(run_xcode_tests.signal.SIGTERM, sent_signals)

    def test_escaped_diagnostic_descendant_is_terminated_by_pid(self) -> None:
        process = mock.Mock(pid=1234)
        with mock.patch.object(
            run_xcode_tests,
            "descendant_pids",
            return_value={2222},
        ), mock.patch.object(
            run_xcode_tests,
            "signal_process_group",
            return_value=False,
        ), mock.patch.object(
            run_xcode_tests,
            "signal_pid",
            return_value=True,
        ) as send, mock.patch.object(
            run_xcode_tests,
            "wait_for_pids_exit",
            side_effect=[False, True],
        ):
            run_xcode_tests.terminate_process_group(process)

        send.assert_any_call(2222, run_xcode_tests.signal.SIGTERM)

    def test_escaped_descendant_is_gone_after_real_timeout(self) -> None:
        result, log = self.run_fake_xcode(
            """
            import subprocess
            import sys
            import time
            child = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(30)"],
                start_new_session=True,
            )
            print(f"ESCAPED_PID={child.pid}", flush=True)
            time.sleep(30)
            """
        )
        match = re.search(r"ESCAPED_PID=(\d+)", log)
        self.assertIsNotNone(match)
        assert match is not None
        escaped_pid = int(match.group(1))
        try:
            status = subprocess.CompletedProcess([], 0, "", "")
            for _ in range(20):
                status = subprocess.run(
                    ["ps", "-p", str(escaped_pid), "-o", "pid="],
                    capture_output=True,
                    check=False,
                    text=True,
                )
                if not status.stdout.strip():
                    break
                time.sleep(0.05)
            self.assertFalse(status.stdout.strip())
            self.assertEqual(result.returncode, 125)
        finally:
            try:
                os.kill(escaped_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def run_fake_xcode(self, source: str) -> tuple[subprocess.CompletedProcess[str], str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child = root / "fake_xcode.py"
            log = root / "xcodebuild.log"
            diagnostics = root / "diagnostics"
            child.write_text(textwrap.dedent(source), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(RUNNER),
                    "--idle-timeout",
                    "1",
                    "--wall-timeout",
                    "5",
                    "--log-path",
                    str(log),
                    "--diagnostics-dir",
                    str(diagnostics),
                    "--completion-marker",
                    "Test Suite 'PomodoroughUITests.xctest' passed",
                    "--",
                    sys.executable,
                    str(child),
                ],
                capture_output=True,
                check=False,
                text=True,
                timeout=10,
            )
            return result, log.read_text(encoding="utf-8") if log.exists() else ""

    def test_classifies_timeout_after_complete_test_summary_as_finalization(self) -> None:
        result, log = self.run_fake_xcode(
            """
            import time
            print("Test Suite 'PomodoroughUITests.xctest' passed", flush=True)
            print("Test Suite 'All tests' passed", flush=True)
            print("Executed 5 tests, with 0 failures", flush=True)
            time.sleep(30)
            """
        )
        self.assertEqual(result.returncode, 124)
        self.assertIn("classification=post-test-finalization-timeout", result.stderr)
        self.assertIn("Test Suite 'All tests' passed", log)

    def test_classifies_timeout_before_complete_summary_as_test_execution(self) -> None:
        result, _ = self.run_fake_xcode(
            """
            import time
            print("Test Case 'example' started", flush=True)
            time.sleep(30)
            """
        )
        self.assertEqual(result.returncode, 125)
        self.assertIn("classification=test-execution-timeout", result.stderr)

    def test_unit_summary_does_not_hide_stalled_ui_execution(self) -> None:
        result, _ = self.run_fake_xcode(
            """
            import time
            print("✔ Test run with 420 tests in 18 suites passed after 20 seconds.", flush=True)
            print("Test Case '-[PomodoroughUITests example]' started", flush=True)
            time.sleep(30)
            """
        )
        self.assertEqual(result.returncode, 125)
        self.assertIn("classification=test-execution-timeout", result.stderr)

    def test_zero_test_xctest_shell_does_not_count_as_scheme_completion(self) -> None:
        result, _ = self.run_fake_xcode(
            """
            import time
            print("Test Suite 'All tests' passed", flush=True)
            print("Executed 0 tests, with 0 failures", flush=True)
            print("◇ Test run started.", flush=True)
            time.sleep(30)
            """
        )
        self.assertEqual(result.returncode, 125)
        self.assertIn("classification=test-execution-timeout", result.stderr)

    def test_preserves_child_test_failure_exit_code(self) -> None:
        result, log = self.run_fake_xcode(
            """
            print("** TEST FAILED **", flush=True)
            raise SystemExit(65)
            """
        )
        self.assertEqual(result.returncode, 65)
        self.assertIn("** TEST FAILED **", log)
        self.assertNotIn("classification=", result.stderr)

    def test_successful_child_exits_zero(self) -> None:
        result, log = self.run_fake_xcode(
            """
            print("** TEST EXECUTE SUCCEEDED **", flush=True)
            """
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("** TEST EXECUTE SUCCEEDED **", log)


class XcodeWorkflowTests(unittest.TestCase):
    def test_ios_tests_are_split_bounded_and_retained(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("build-for-testing", workflow)
        self.assertIn("scripts/run_xcode_tests.py", workflow)
        self.assertIn("test-without-building", workflow)
        self.assertIn("--completion-marker \"Test Suite 'PomodoroughUITests.xctest' passed\"", workflow)
        self.assertIn("-resultBundlePath \"$IOS_RESULT_BUNDLE\"", workflow)
        self.assertIn('test -d "$IOS_RESULT_BUNDLE"', workflow)
        self.assertIn("if: ${{ always() }}", workflow)
        self.assertIn("actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02", workflow)
        self.assertIn("if-no-files-found: error", workflow)


if __name__ == "__main__":
    unittest.main()
