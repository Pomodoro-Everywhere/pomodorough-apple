from __future__ import annotations

import argparse
import ctypes
import io
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
import uuid
from unittest import mock

from scripts import run_xcode_tests


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "scripts" / "run_xcode_tests.py"
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


def simulator_args(root: Path) -> argparse.Namespace:
    return argparse.Namespace(
        log_path=root / "xcodebuild.log",
        diagnostics_dir=root / "diagnostics",
        command=[
            "xcodebuild",
            "-destination",
            "platform=iOS Simulator,name=iPhone 17",
            "test-without-building",
        ],
        idle_timeout=300,
        wall_timeout=1800,
        completion_marker="Test Suite 'PomodoroughUITests.xctest' passed",
        simulator_name="iPhone 17",
        simulator_timeout=120,
        result_bundle_path=root / "Pomodorough-iOS.xcresult",
    )


def launchd_job(
    root: Path, coalition_id: int | None = 77
) -> run_xcode_tests.LaunchdJob:
    label = "com.pomodorough.xcode-tests.unit"
    return run_xcode_tests.LaunchdJob(
        label,
        f"gui/{os.getuid()}/{label}",
        root,
        root / "stdout.log",
        root / "stderr.log",
        root / "status.json",
        root / "identity.json",
        root / "coalition.json",
        root / "acknowledgement.json",
        coalition_id,
    )


def launchd_service_pid(label: str) -> int | None:
    result = subprocess.run(
        ["/bin/launchctl", "print", f"gui/{os.getuid()}/{label}"],
        capture_output=True,
        check=False,
        text=True,
    )
    match = re.search(r"^\s*pid = (\d+)$", result.stdout, re.MULTILINE)
    return int(match.group(1)) if match else None


def launchd_service_identity(
    label: str, expected_executable: str
) -> run_xcode_tests.ProcessIdentity | None:
    pid = launchd_service_pid(label)
    if pid is None:
        return None
    identity = run_xcode_tests.process_identity(pid)
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "comm="],
        capture_output=True,
        check=False,
        text=True,
    )
    if identity is None or result.returncode or result.stdout.strip() != expected_executable:
        return None
    if launchd_service_pid(label) != pid:
        return None
    return identity if run_xcode_tests.process_identity(pid) == identity else None


def wait_for_launchd_service_identity(
    label: str, expected_executable: str
) -> run_xcode_tests.ProcessIdentity:
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        identity = launchd_service_identity(label, expected_executable)
        if identity is not None:
            return identity
        time.sleep(min(0.01, max(0, deadline - time.monotonic())))
    raise AssertionError(
        f"launchd service did not stabilize as {expected_executable}: {label}"
    )


def remove_test_launchd_service(
    label: str, identity: run_xcode_tests.ProcessIdentity | None
) -> None:
    subprocess.run(
        ["/bin/launchctl", "remove", label],
        capture_output=True,
        check=False,
        text=True,
    )
    if identity is None:
        return
    deadline = time.monotonic() + 2
    while run_xcode_tests.identity_is_live(identity) and time.monotonic() < deadline:
        time.sleep(0.01)
    if run_xcode_tests.process_identity(identity.pid) == identity:
        run_xcode_tests.signal_identity(identity, signal.SIGKILL)


class XcodeTestRunnerTests(unittest.TestCase):
    def test_available_simulator_prefers_booted_and_binds_exact_udid(self) -> None:
        inventory = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                    {"name": "iPhone 17", "udid": "SHUTDOWN", "state": "Shutdown", "isAvailable": True},
                    {"name": "iPhone 17", "udid": "BOOTED", "state": "Booted", "isAvailable": True},
                ]
            }
        }
        args = argparse.Namespace(
            simulator_destination=run_xcode_tests.parse_simulator_destination(
                "platform=iOS Simulator,name=iPhone 17"
            )
        )
        result = subprocess.CompletedProcess([], 0, run_xcode_tests.json.dumps(inventory), "")
        with mock.patch.object(run_xcode_tests, "lifecycle_command", return_value=result):
            udid, state = run_xcode_tests.available_simulator(args)
        command = run_xcode_tests.bind_simulator_destination(
            ["xcodebuild", "-destination", "platform=iOS Simulator,name=iPhone 17"], udid
        )
        self.assertEqual((udid, state), ("BOOTED", "Booted"))
        self.assertEqual(command[-1], "platform=iOS Simulator,id=BOOTED")

    def test_exact_id_and_os_destination_is_preserved(self) -> None:
        destination = "platform=iOS Simulator,id=EXACT,OS=18.5"
        inventory = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                    {"name": "iPhone 16", "udid": "EXACT", "state": "Shutdown", "isAvailable": True}
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                    {"name": "iPhone 17", "udid": "WRONG", "state": "Booted", "isAvailable": True}
                ],
            }
        }
        args = argparse.Namespace(
            simulator_destination=run_xcode_tests.parse_simulator_destination(destination)
        )
        result = subprocess.CompletedProcess([], 0, run_xcode_tests.json.dumps(inventory), "")
        with mock.patch.object(run_xcode_tests, "lifecycle_command", return_value=result):
            selected = run_xcode_tests.available_simulator(args)
        command = ["xcodebuild", "-destination", destination]
        self.assertEqual(selected, ("EXACT", "Shutdown"))
        self.assertEqual(run_xcode_tests.bind_simulator_destination(command, "EXACT"), command)

    def test_os_constraint_ignores_booted_device_from_wrong_runtime(self) -> None:
        inventory = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                    {"name": "iPhone 17", "udid": "MATCH", "state": "Shutdown", "isAvailable": True}
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                    {"name": "iPhone 17", "udid": "WRONG", "state": "Booted", "isAvailable": True}
                ],
            }
        }
        destination = "platform=iOS Simulator,name=iPhone 17,OS=18.5"
        args = argparse.Namespace(
            simulator_destination=run_xcode_tests.parse_simulator_destination(destination)
        )
        result = subprocess.CompletedProcess([], 0, run_xcode_tests.json.dumps(inventory), "")
        with mock.patch.object(run_xcode_tests, "lifecycle_command", return_value=result):
            self.assertEqual(run_xcode_tests.available_simulator(args), ("MATCH", "Shutdown"))

    def test_missing_os_selects_latest_runtime_before_booted_preference(self) -> None:
        inventory = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                    {"name": "iPhone 17", "udid": "OLD", "state": "Booted", "isAvailable": True}
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                    {"name": "iPhone 17", "udid": "LATEST", "state": "Shutdown", "isAvailable": True}
                ],
            }
        }
        destination = "platform=iOS Simulator,name=iPhone 17"
        args = argparse.Namespace(
            simulator_destination=run_xcode_tests.parse_simulator_destination(destination)
        )
        result = subprocess.CompletedProcess([], 0, run_xcode_tests.json.dumps(inventory), "")
        with mock.patch.object(run_xcode_tests, "lifecycle_command", return_value=result):
            selected = run_xcode_tests.available_simulator(args)
        command = ["xcodebuild", "-destination", destination]
        self.assertEqual(selected, ("LATEST", "Shutdown"))
        self.assertEqual(
            run_xcode_tests.bind_simulator_destination(command, "LATEST")[-1],
            "platform=iOS Simulator,id=LATEST",
        )

    def test_exact_id_is_rejected_when_latest_runtime_conflicts(self) -> None:
        inventory = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                    {"name": "iPhone 17", "udid": "OLD", "state": "Booted", "isAvailable": True}
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                    {"name": "iPhone 17", "udid": "NEW", "state": "Shutdown", "isAvailable": True}
                ],
            }
        }
        destination = "platform=iOS Simulator,name=iPhone 17,id=OLD,OS=latest"
        args = argparse.Namespace(
            simulator_destination=run_xcode_tests.parse_simulator_destination(destination)
        )
        result = subprocess.CompletedProcess([], 0, run_xcode_tests.json.dumps(inventory), "")
        with mock.patch.object(run_xcode_tests, "lifecycle_command", return_value=result):
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError, "no available simulator"
            ):
                run_xcode_tests.available_simulator(args)

    def test_arch_constraint_is_preserved_when_binding_exact_simulator(self) -> None:
        args = argparse.Namespace(
            command=[
                "xcodebuild",
                "-destination",
                "platform=iOS Simulator,name=iPhone 17,arch=arm64",
            ],
            simulator_name=None,
            result_bundle_path=Path("/tmp/result.xcresult"),
        )
        run_xcode_tests.configure_simulator(args)
        self.assertEqual(args.simulator_destination.architecture, "arm64")
        self.assertEqual(
            run_xcode_tests.bind_simulator_destination(args.command, "EXACT")[-1],
            "platform=iOS Simulator,id=EXACT,arch=arm64",
        )

    def test_incompatible_simulator_architecture_fails_closed(self) -> None:
        destination = "platform=iOS Simulator,name=iPhone 17,arch=ppc64"
        with self.assertRaisesRegex(
            run_xcode_tests.SimulatorLifecycleError, "unsupported.*architecture"
        ):
            run_xcode_tests.parse_simulator_destination(destination)

    def test_unknown_simulator_constraint_fails_closed(self) -> None:
        destination = "platform=iOS Simulator,name=iPhone 17,custom=value"
        with self.assertRaisesRegex(
            run_xcode_tests.SimulatorLifecycleError, "unsupported.*custom"
        ):
            run_xcode_tests.parse_simulator_destination(destination)

    def test_simulator_configuration_comes_from_existing_xcode_command(self) -> None:
        args = argparse.Namespace(
            command=[
                "xcodebuild",
                "-destination",
                "platform=iOS Simulator,name=iPhone 17",
                "-resultBundlePath",
                "/tmp/result.xcresult",
            ],
            simulator_name=None,
            result_bundle_path=None,
        )
        run_xcode_tests.configure_simulator(args)
        self.assertEqual(args.simulator_name, "iPhone 17")
        self.assertEqual(args.result_bundle_path, Path("/tmp/result.xcresult"))

    def test_lifecycle_timeout_fails_closed_with_diagnostics(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = simulator_args(root)
            args.diagnostics_dir.mkdir()
            timeout = subprocess.TimeoutExpired(["xcrun", "simctl"], 120, output="partial")
            with mock.patch.object(run_xcode_tests, "lifecycle_process", side_effect=timeout):
                with self.assertRaises(run_xcode_tests.SimulatorLifecycleError):
                    run_xcode_tests.lifecycle_command(args, "health", ["xcrun", "simctl"])
            evidence = (args.diagnostics_dir / "simulator-lifecycle.log").read_text()
        self.assertIn("## health", evidence)
        self.assertIn("returncode=None", evidence)
        self.assertIn("partial", evidence)

    def test_lifecycle_timeout_terminates_real_descendant(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = simulator_args(root)
            args.diagnostics_dir.mkdir()
            args.wall_deadline = time.monotonic() + 4
            source = (
                "import subprocess,sys,time; "
                "child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],"
                "start_new_session=True); "
                "print(f'CHILD_PID={child.pid}',flush=True); time.sleep(30)"
            )
            with self.assertRaises(run_xcode_tests.SimulatorLifecycleError):
                run_xcode_tests.lifecycle_command(
                    args, "leaking-command", [sys.executable, "-c", source], timeout=0.2
                )
            evidence = (args.diagnostics_dir / "simulator-lifecycle.log").read_text()
        match = re.search(r"CHILD_PID=(\d+)", evidence)
        self.assertIsNotNone(match)
        assert match is not None
        child_pid = int(match.group(1))
        try:
            self.assertTrue(self.wait_until_process_exits(child_pid))
        finally:
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_lifecycle_nonzero_exit_terminates_detached_descendant(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = simulator_args(root)
            args.diagnostics_dir.mkdir()
            args.wall_deadline = time.monotonic() + 4
            source = (
                "import subprocess,sys,time; "
                "child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],"
                "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True); "
                "print(f'CHILD_PID={child.pid}',flush=True); time.sleep(0.05); raise SystemExit(7)"
            )
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError, "exited 7"
            ):
                run_xcode_tests.lifecycle_command(
                    args, "failing-command", [sys.executable, "-c", source]
                )
            evidence = (args.diagnostics_dir / "simulator-lifecycle.log").read_text()
        match = re.search(r"CHILD_PID=(\d+)", evidence)
        self.assertIsNotNone(match)
        assert match is not None
        child_pid = int(match.group(1))
        try:
            self.assertTrue(self.wait_until_process_exits(child_pid))
        finally:
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_lifecycle_success_terminates_detached_descendant(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = simulator_args(root)
            args.diagnostics_dir.mkdir()
            args.wall_deadline = time.monotonic() + 4
            source = (
                "import subprocess,sys; "
                "child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],"
                "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True); "
                "print(f'CHILD_PID={child.pid}',flush=True)"
            )
            try:
                result = run_xcode_tests.lifecycle_command(
                    args, "successful-command", [sys.executable, "-c", source]
                )
            except run_xcode_tests.SimulatorLifecycleError:
                print((args.diagnostics_dir / "simulator-lifecycle.log").read_text())
                raise
            child_pid = int(result.stdout.removeprefix("CHILD_PID=").strip())
        try:
            self.assertTrue(self.wait_until_process_exits(child_pid))
        finally:
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_successful_parent_cannot_escape_by_stripping_marker(self) -> None:
        source = (
            "import os,subprocess,sys; "
            "code=\"import os,time; "
            "os.environ.pop('POMODOROUGH_PROCESS_CONTAINMENT',None); "
            "os.environ.clear(); time.sleep(30)\"; "
            "child=subprocess.Popen([sys.executable,'-c',code],"
            "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True); "
            "print(f'CHILD_PID={child.pid}',flush=True)"
        )
        for iteration in range(20):
            with self.subTest(iteration=iteration):
                child_pid = self.successful_command_child_pid(source)
                self.assertTrue(self.wait_until_process_exits(child_pid))

    def test_target_sidecar_tampering_cannot_hide_detached_child(self) -> None:
        operations = {
            "missing": None,
            "corrupt": "{corrupt",
            "forged": '{"resource_coalition_id":1}',
        }
        for name, replacement in operations.items():
            for iteration in range(5):
                with self.subTest(name=name, iteration=iteration):
                    child_pid = self.cleanup_after_sidecar_tamper(replacement)
                    self.assertTrue(self.wait_until_process_exits(child_pid))

    def test_late_short_lived_intermediary_descendant_is_cleaned(self) -> None:
        for iteration in range(30):
            with self.subTest(iteration=iteration), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                args = simulator_args(root)
                args.diagnostics_dir.mkdir()
                args.wall_deadline = time.monotonic() + 6
                pid_path = root / "grandchild.pid"
                grandchild = "import time; time.sleep(30)"
                intermediary = (
                    "import pathlib,subprocess,sys; "
                    f"child=subprocess.Popen([sys.executable,'-c',{grandchild!r}],"
                    "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True); "
                    "pathlib.Path(sys.argv[1]).write_text(str(child.pid))"
                )
                source = (
                    "import pathlib,subprocess,sys,time; time.sleep(0.3); "
                    f"middle=subprocess.Popen([sys.executable,'-c',{intermediary!r},{str(pid_path)!r}],"
                    "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); "
                    "time.sleep(0.003); middle.wait(timeout=2); "
                    "raise SystemExit(7)"
                )
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError, "exited 7"
                ):
                    run_xcode_tests.lifecycle_command(
                        args, "late-intermediary", [sys.executable, "-c", source, str(pid_path)]
                    )
                self.assertTrue(pid_path.exists())
                grandchild_pid = int(pid_path.read_text(encoding="utf-8"))
                try:
                    self.assertTrue(self.wait_until_process_exits(grandchild_pid))
                finally:
                    try:
                        os.kill(grandchild_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_descendant_forked_during_sigterm_is_cleaned(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pid_path = root / "termination-child.pid"
            source = """
                import os
                import pathlib
                import signal
                import subprocess
                import sys
                import time

                signal.signal(signal.SIGINT, signal.SIG_IGN)
                if hasattr(signal, "SIGINFO"):
                    signal.signal(signal.SIGINFO, signal.SIG_IGN)

                def terminate(*_):
                    child = subprocess.Popen(
                        [sys.executable, "-c", "import time; time.sleep(30)"],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        start_new_session=True,
                    )
                    pathlib.Path(sys.argv[1]).write_text(str(child.pid))
                    os._exit(7)

                signal.signal(signal.SIGTERM, terminate)
                print("READY", flush=True)
                time.sleep(30)
            """
            command = [sys.executable, "-c", textwrap.dedent(source), str(pid_path)]
            child_pid = self.terminate_ready_contained_job(command, pid_path)
        try:
            self.assertTrue(self.wait_until_process_exits(child_pid))
        finally:
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_launchd_cleanup_has_no_fixed_process_count_cap(self) -> None:
        size_queries = iter([1024, 1500])
        capacities = []

        def list_all_pids(buffer: object, size: int) -> int:
            if buffer is None:
                return next(size_queries)
            capacity = size // ctypes.sizeof(ctypes.c_int)
            capacities.append(capacity)
            count = min(capacity, 1500)
            for index in range(count):
                buffer[index] = index + 1  # type: ignore[index]
            return count

        library = mock.Mock()
        library.proc_listallpids.side_effect = list_all_pids
        with mock.patch.object(run_xcode_tests, "LIBPROC", library):
            process_ids = run_xcode_tests.all_process_ids(time.monotonic() + 1)
        self.assertEqual(capacities, [1024, 2048])
        self.assertEqual(process_ids, list(range(1, 1501)))

    def test_coalition_census_hard_deadline_bounds_all_pid_lookups(self) -> None:
        entered = threading.Event()
        release = threading.Event()

        def stalled_census(_coalition_id: int, _deadline: float) -> list[object]:
            entered.set()
            release.wait(1)
            return []

        started = time.monotonic()
        try:
            with mock.patch.object(
                run_xcode_tests,
                "inspect_coalition_members",
                side_effect=stalled_census,
            ):
                with self.assertRaisesRegex(
                    run_xcode_tests.OperationDeadlineExpired,
                    "census deadline expired",
                ):
                    run_xcode_tests.coalition_members(77, started + 0.02)
            self.assertTrue(entered.is_set())
            self.assertLess(time.monotonic() - started, 0.2)
        finally:
            release.set()

    def test_coalition_member_lookup_hard_deadline_precedes_signal(self) -> None:
        identity = run_xcode_tests.ProcessIdentity(2222, (10, 20))
        entered = threading.Event()
        release = threading.Event()

        def stalled_lookup(_pid: int, _coalition_id: int) -> None:
            entered.set()
            release.wait(1)

        started = time.monotonic()
        try:
            with mock.patch.object(
                run_xcode_tests, "coalition_members", return_value=[identity]
            ), mock.patch.object(
                run_xcode_tests,
                "inspect_coalition_member",
                side_effect=stalled_lookup,
            ), mock.patch.object(run_xcode_tests, "signal_identity") as send:
                with self.assertRaisesRegex(
                    run_xcode_tests.OperationDeadlineExpired,
                    "member lookup deadline expired",
                ):
                    run_xcode_tests.signal_coalition_members(
                        77, signal.SIGTERM, started + 0.02
                    )
            self.assertTrue(entered.is_set())
            self.assertLess(time.monotonic() - started, 0.2)
            send.assert_not_called()
        finally:
            release.set()

    def test_expired_coalition_census_fails_before_lookup(self) -> None:
        with mock.patch.object(
            run_xcode_tests, "inspect_coalition_members"
        ) as inspect:
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError, "census deadline expired"
            ):
                run_xcode_tests.coalition_members(77, time.monotonic() - 1)
        inspect.assert_not_called()

    def test_launchd_cleanup_fails_closed_without_darwin_coalitions(self) -> None:
        with mock.patch.object(run_xcode_tests, "LIBPROC", None):
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "Darwin coalition inspection is unavailable",
            ):
                run_xcode_tests.resource_coalition_id(os.getpid())

    def test_identity_bound_signal_has_no_pid_reuse_kill_gap(self) -> None:
        token = (0, 0, 0, 0, 0, 2222, 0, 41)
        original = run_xcode_tests.ProcessIdentity(2222, (10, 20), token)
        with mock.patch.object(
            run_xcode_tests, "signal_audit_token", return_value=False
        ) as atomic_send, mock.patch.object(
            run_xcode_tests, "process_identity"
        ) as inspect, mock.patch.object(run_xcode_tests, "signal_pid") as raw_send:
            self.assertFalse(run_xcode_tests.signal_identity(original, signal.SIGTERM))
        atomic_send.assert_called_once_with(token, signal.SIGTERM)
        inspect.assert_not_called()
        raw_send.assert_not_called()

    def test_coalition_signal_does_not_target_reused_pid(self) -> None:
        original = run_xcode_tests.ProcessIdentity(2222, (10, 20), (0, 0, 0, 0, 0, 2222, 0, 41))
        replacement = run_xcode_tests.ProcessIdentity(2222, (10, 21), (0, 0, 0, 0, 0, 2222, 0, 42))
        with mock.patch.object(
            run_xcode_tests, "coalition_members", return_value=[original]
        ), mock.patch.object(
            run_xcode_tests, "signal_audit_token", return_value=False
        ) as atomic_send, mock.patch.object(
            run_xcode_tests, "coalition_member_identity", return_value=replacement
        ), mock.patch.object(run_xcode_tests, "signal_pid") as raw_send:
            run_xcode_tests.signal_coalition_members(77, signal.SIGTERM, time.monotonic() + 1)
        atomic_send.assert_not_called()
        raw_send.assert_not_called()

    def test_coalition_signal_rechecks_identity_after_failed_atomic_signal(self) -> None:
        identity = run_xcode_tests.ProcessIdentity(2222, (10, 20))
        with mock.patch.object(
            run_xcode_tests, "coalition_members", return_value=[identity]
        ), mock.patch.object(
            run_xcode_tests,
            "coalition_member_identity",
            side_effect=[identity, identity],
        ) as inspect, mock.patch.object(
            run_xcode_tests, "signal_identity", return_value=False
        ):
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "identity-bound coalition signal failed",
            ):
                run_xcode_tests.signal_coalition_members(
                    77, signal.SIGTERM, time.monotonic() + 1
                )
        self.assertEqual(inspect.call_count, 2)

    def test_cleanup_uses_retained_coalition_after_sidecar_corruption(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            job.coalition_path.write_text("{corrupt", encoding="utf-8")
            with mock.patch.object(
                run_xcode_tests, "resource_coalition_id", return_value=999
            ), mock.patch.object(
                run_xcode_tests, "signal_coalition_members"
            ) as send, mock.patch.object(
                run_xcode_tests, "bootout_job"
            ) as bootout, mock.patch.object(
                run_xcode_tests, "drain_coalition"
            ) as drain, mock.patch.object(
                run_xcode_tests, "confirm_job_absent"
            ) as absent:
                run_xcode_tests.cleanup_contained_job(job, None, False)
        self.assertTrue(send.call_args_list)
        self.assertTrue(all(call.args[0] == 77 for call in send.call_args_list))
        bootout.assert_called_once()
        drain.assert_called_once_with(77, mock.ANY)
        absent.assert_called_once()

    def wrapper_ack_result(
        self, acknowledgement: object | None
    ) -> tuple[int, mock.Mock, object]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            acknowledgement_path = root / "acknowledgement.json"
            if isinstance(acknowledgement, str):
                acknowledgement_path.write_text(acknowledgement, encoding="utf-8")
            elif acknowledgement is not None:
                run_xcode_tests.write_atomic_json(acknowledgement_path, acknowledgement)
            wrapper = run_xcode_tests.ProcessIdentity(2222, (10, 20), None)
            with mock.patch.object(
                run_xcode_tests, "CONTAINMENT_HANDSHAKE_SECONDS", 0.005
            ), mock.patch.object(
                run_xcode_tests, "process_identity", return_value=wrapper
            ), mock.patch.object(
                run_xcode_tests, "resource_coalition_id", return_value=77
            ), mock.patch.object(run_xcode_tests.subprocess, "Popen") as launch:
                result = run_xcode_tests.contained_child(
                    root / "status.json",
                    root / "identity.json",
                    root / "coalition.json",
                    acknowledgement_path,
                    "expected-token",
                    False,
                    ["target"],
                )
            status = run_xcode_tests.read_json(root / "status.json")
        return result, launch, status

    def test_missing_acknowledgement_never_starts_target(self) -> None:
        result, launch, status = self.wrapper_ack_result(None)
        self.assertEqual(result, run_xcode_tests.PRETEST_INFRASTRUCTURE_FAILURE)
        launch.assert_not_called()
        self.assertIn("acknowledgement unavailable", str(status))

    def test_corrupt_acknowledgement_never_starts_target(self) -> None:
        result, launch, status = self.wrapper_ack_result("{corrupt")
        self.assertEqual(result, run_xcode_tests.PRETEST_INFRASTRUCTURE_FAILURE)
        launch.assert_not_called()
        self.assertIn("invalid containment acknowledgement", str(status))

    def test_forged_acknowledgement_never_starts_target(self) -> None:
        acknowledgement = {"token": "forged", "resource_coalition_id": 77}
        result, launch, status = self.wrapper_ack_result(acknowledgement)
        self.assertEqual(result, run_xcode_tests.PRETEST_INFRASTRUCTURE_FAILURE)
        launch.assert_not_called()
        self.assertIn("forged containment acknowledgement", str(status))

    def test_sandbox_failure_never_starts_target(self) -> None:
        acknowledgement = {"token": "expected-token", "resource_coalition_id": 77}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run_xcode_tests.write_atomic_json(root / "acknowledgement.json", acknowledgement)
            wrapper = run_xcode_tests.ProcessIdentity(2222, (10, 20), None)
            with mock.patch.object(
                run_xcode_tests, "process_identity", return_value=wrapper
            ), mock.patch.object(
                run_xcode_tests, "resource_coalition_id", return_value=77
            ), mock.patch.object(
                run_xcode_tests,
                "deny_launchd_job_creation",
                side_effect=run_xcode_tests.SimulatorLifecycleError("sandbox rejected"),
            ), mock.patch.object(run_xcode_tests.subprocess, "Popen") as launch:
                result = run_xcode_tests.contained_child(
                    root / "status.json",
                    root / "identity.json",
                    root / "coalition.json",
                    root / "acknowledgement.json",
                    "expected-token",
                    False,
                    ["target"],
                )
            status = run_xcode_tests.read_json(root / "status.json")
        self.assertEqual(result, run_xcode_tests.PRETEST_INFRASTRUCTURE_FAILURE)
        launch.assert_not_called()
        self.assertIn("sandbox rejected", str(status))

    @unittest.skipUnless(sys.platform == "darwin", "requires Darwin launchd")
    def test_target_cannot_submit_launchd_escape_or_touch_concurrent_job(self) -> None:
        escaped = f"com.pomodorough.ap6.escape.{uuid.uuid4().hex}"
        concurrent = f"com.pomodorough.ap6.concurrent.{uuid.uuid4().hex}"
        source = (
            "import subprocess,sys; "
            "result=subprocess.run(['/bin/launchctl','submit','-l',sys.argv[1],"
            "'--','/bin/sleep','60'],capture_output=True,text=True); "
            "print(f'SUBMIT_RC={result.returncode}',flush=True)"
        )
        concurrent_identity = None
        try:
            started = subprocess.run(
                ["/bin/launchctl", "submit", "-l", concurrent, "--", "/bin/sleep", "60"],
                capture_output=True,
                check=False,
                text=True,
            )
            self.assertEqual(started.returncode, 0, started.stderr)
            concurrent_identity = wait_for_launchd_service_identity(concurrent, "/bin/sleep")
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                args = simulator_args(root)
                args.diagnostics_dir.mkdir()
                args.wall_deadline = time.monotonic() + 5
                result = run_xcode_tests.lifecycle_command(
                    args, "launchd-escape", [sys.executable, "-c", source, escaped]
                )
            self.assertIn("SUBMIT_RC=1", result.stdout)
            self.assertIsNone(launchd_service_pid(escaped))
            self.assertEqual(
                run_xcode_tests.process_identity(concurrent_identity.pid),
                concurrent_identity,
            )
        finally:
            remove_test_launchd_service(escaped, None)
            remove_test_launchd_service(concurrent, concurrent_identity)

    def test_missing_coalition_sidecar_fails_before_acknowledgement(self) -> None:
        wrapper = run_xcode_tests.ProcessIdentity(2222, (10, 20), None)
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "contained coalition identity unavailable",
            ):
                run_xcode_tests.wait_for_containment_sidecar(
                    job, time.monotonic() + 0.005
                )
        self.assertFalse(job.acknowledgement_path.exists())

    def test_corrupt_coalition_sidecar_fails_before_acknowledgement(self) -> None:
        wrapper = run_xcode_tests.ProcessIdentity(2222, (10, 20), None)
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            job.coalition_path.write_text("{corrupt", encoding="utf-8")
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "invalid containment sidecar coalition.json",
            ):
                run_xcode_tests.wait_for_containment_sidecar(
                    job, time.monotonic() + 1
                )
        self.assertFalse(job.acknowledgement_path.exists())

    def test_forged_coalition_sidecar_fails_before_acknowledgement(self) -> None:
        wrapper = run_xcode_tests.ProcessIdentity(2222, (10, 20), None)
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            run_xcode_tests.write_atomic_json(
                job.coalition_path,
                {
                    "resource_coalition_id": 88,
                    "wrapper": run_xcode_tests.identity_payload(wrapper),
                },
            )
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "forged contained coalition identity",
            ):
                payload = run_xcode_tests.read_json(job.coalition_path)
                run_xcode_tests.validate_containment_sidecar(job, wrapper, payload)
        self.assertFalse(job.acknowledgement_path.exists())

    def test_job_root_signal_uses_persisted_audit_identity(self) -> None:
        token = (0, 0, 0, 0, 0, 2222, 0, 41)
        original = run_xcode_tests.ProcessIdentity(2222, (10, 20), token)
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            run_xcode_tests.write_atomic_json(
                job.identity_path, run_xcode_tests.identity_payload(original)
            )
            with mock.patch.object(
                run_xcode_tests, "signal_audit_token", return_value=True
            ) as send, mock.patch.object(run_xcode_tests, "process_identity") as inspect:
                self.assertTrue(run_xcode_tests.signal_job_root(job, signal.SIGTERM))
        send.assert_called_once_with(token, signal.SIGTERM)
        inspect.assert_not_called()

    def test_lifecycle_commands_share_one_absolute_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = simulator_args(root)
            args.diagnostics_dir.mkdir()
            args.wall_deadline = time.monotonic() + 0.8
            started = time.monotonic()
            with self.assertRaises(run_xcode_tests.SimulatorLifecycleError):
                run_xcode_tests.lifecycle_command(
                    args,
                    "consume-budget",
                    [sys.executable, "-c", "import time; time.sleep(30)"],
                    timeout=30,
                )
            with mock.patch.object(run_xcode_tests.subprocess, "Popen") as launch:
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError, "wall timeout exhausted"
                ):
                    run_xcode_tests.lifecycle_command(
                        args, "after-budget", [sys.executable, "-c", "pass"]
                    )
            elapsed = time.monotonic() - started
        launch.assert_not_called()
        self.assertLess(elapsed, 1.0)

    def test_cleanup_deadline_caps_global_and_standalone_cleanup(self) -> None:
        with mock.patch.object(run_xcode_tests.time, "monotonic", return_value=10.0):
            standalone = run_xcode_tests.cleanup_deadline(None)
            distant = run_xcode_tests.cleanup_deadline(100.0)
            urgent = run_xcode_tests.cleanup_deadline(10.25)
        self.assertEqual(standalone, 10.0 + run_xcode_tests.CLEANUP_RESERVE_SECONDS)
        self.assertEqual(distant, 10.0 + run_xcode_tests.CLEANUP_RESERVE_SECONDS)
        self.assertEqual(urgent, 10.25)

    def test_launchctl_timeout_kills_and_reaps_identity_bound_process(self) -> None:
        token = (0, 0, 0, 0, 0, 2222, 0, 41)
        identity = run_xcode_tests.ProcessIdentity(2222, (10, 41), token)
        process = mock.Mock(pid=2222)
        process.poll.return_value = None
        timeout = subprocess.TimeoutExpired(["launchctl"], 0.1)
        process.wait.side_effect = [timeout, -signal.SIGKILL]
        with mock.patch.object(
            run_xcode_tests.subprocess, "Popen", return_value=process
        ), mock.patch.object(
            run_xcode_tests, "process_identity", return_value=identity
        ), mock.patch.object(
            run_xcode_tests, "signal_identity", return_value=True
        ) as send:
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError, "launchctl timed out"
            ) as raised:
                run_xcode_tests.launchctl_run([], time.monotonic() + 1, 0.2)
        self.assertIs(raised.exception.__cause__, timeout)
        send.assert_called_once_with(identity, signal.SIGKILL)
        self.assertEqual(process.wait.call_count, 2)

    def test_launchctl_timeout_requires_process_identity_before_signal(self) -> None:
        process = mock.Mock(pid=2222)
        process.poll.return_value = None
        process.wait.side_effect = subprocess.TimeoutExpired(["launchctl"], 0.1)
        with mock.patch.object(
            run_xcode_tests.subprocess, "Popen", return_value=process
        ), mock.patch.object(
            run_xcode_tests, "process_identity", return_value=None
        ), mock.patch.object(run_xcode_tests, "signal_identity") as send:
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError, "identity unavailable"
            ):
                run_xcode_tests.launchctl_run([], time.monotonic() + 1, 0.2)
        send.assert_not_called()
        process.wait.assert_called_once()

    def test_launchctl_timeout_reaps_real_safe_process(self) -> None:
        source = (
            "import os,sys,time\n"
            "with open(sys.argv[1],'w') as stream:\n"
            " stream.write(str(os.getpid()))\n"
            " stream.flush()\n"
            " os.fsync(stream.fileno())\n"
            "time.sleep(30)\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "stalled_launchctl.py"
            pid_path = root / "pid"
            script.write_text(source, encoding="utf-8")
            started = time.monotonic()
            with mock.patch.object(run_xcode_tests, "LAUNCHCTL", sys.executable):
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError, "launchctl timed out"
                ):
                    run_xcode_tests.launchctl_run(
                        [str(script), str(pid_path)], started + 1, 0.5
                    )
            elapsed = time.monotonic() - started
            pid = int(pid_path.read_text(encoding="utf-8"))
        self.assertLess(elapsed, 1.0)
        self.assertIsNone(run_xcode_tests.process_identity(pid))

    def test_command_timeout_survives_failed_cleanup_without_retry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = simulator_args(root)
            args.diagnostics_dir.mkdir()
            job = launchd_job(root / "job")
            job.root.mkdir()
            job.stderr_path.write_text("command stalled\n", encoding="utf-8")
            cleanup_error = run_xcode_tests.SimulatorLifecycleError(
                "launchctl timed out"
            )
            with mock.patch.object(
                run_xcode_tests, "spawn_contained_job", return_value=job
            ), mock.patch.object(
                run_xcode_tests, "wait_for_job_status", return_value=None
            ), mock.patch.object(
                run_xcode_tests,
                "cleanup_contained_job",
                side_effect=cleanup_error,
            ) as cleanup:
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError,
                    "wait-for-simulator-boot timed out after 120s",
                ) as raised:
                    run_xcode_tests.lifecycle_command(
                        args, "wait-for-simulator-boot", ["stalled"]
                    )
            evidence = (args.diagnostics_dir / "simulator-lifecycle.log").read_text()
        self.assertIsInstance(raised.exception.__cause__, subprocess.TimeoutExpired)
        self.assertIn("containment cleanup error: launchctl timed out", evidence)
        cleanup.assert_called_once_with(job, None, True)
        self.assertFalse(job.root.exists())

    def test_bootstrap_timeout_always_aborts_possible_job(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            deadline = time.monotonic() + 1
            timeout = run_xcode_tests.SimulatorLifecycleError("launchctl timed out")
            with mock.patch.object(
                run_xcode_tests, "create_launchd_job", return_value=job
            ), mock.patch.object(
                run_xcode_tests, "launchd_domain", return_value=f"gui/{os.getuid()}"
            ), mock.patch.object(
                run_xcode_tests, "launchctl_run", side_effect=timeout
            ) as launchctl, mock.patch.object(
                run_xcode_tests, "abort_containment_handshake"
            ) as abort:
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError, "launchctl timed out"
                ):
                    run_xcode_tests.spawn_contained_job(["target"], False, deadline)
        bootstrap_deadline = launchctl.call_args.args[1]
        self.assertEqual(
            bootstrap_deadline,
            deadline - run_xcode_tests.CLEANUP_RESERVE_SECONDS,
        )
        abort.assert_called_once_with(job, None, deadline)

    def test_handshake_deadline_leaves_abort_reserve(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            deadline = 11.0
            started = subprocess.CompletedProcess([], 0, "", "")
            unavailable = run_xcode_tests.SimulatorLifecycleError("sidecar unavailable")
            with mock.patch.object(
                run_xcode_tests, "create_launchd_job", return_value=job
            ), mock.patch.object(
                run_xcode_tests, "launchd_domain", return_value=f"gui/{os.getuid()}"
            ), mock.patch.object(
                run_xcode_tests, "launchctl_run", return_value=started
            ) as launchctl, mock.patch.object(
                run_xcode_tests.time, "monotonic", return_value=10.0
            ), mock.patch.object(
                run_xcode_tests,
                "wait_for_containment_sidecar",
                side_effect=unavailable,
            ) as handshake, mock.patch.object(
                run_xcode_tests, "abort_containment_handshake"
            ) as abort:
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError, "sidecar unavailable"
                ):
                    run_xcode_tests.spawn_contained_job(["target"], False, deadline)
        setup_deadline = deadline - run_xcode_tests.CLEANUP_RESERVE_SECONDS
        self.assertEqual(launchctl.call_args.args[1], setup_deadline)
        handshake.assert_called_once_with(job, setup_deadline)
        abort.assert_called_once_with(job, None, deadline)

    def test_attempt_observation_reserves_evidence_and_cleanup_time(self) -> None:
        args = argparse.Namespace(wall_deadline=100.0, wall_timeout=100, idle_timeout=300)
        job = launchd_job(Path("/tmp/unused-job"))
        with mock.patch.object(
            run_xcode_tests, "read_job_bytes", return_value=(b"", 0)
        ) as read, mock.patch.object(
            run_xcode_tests, "job_status", return_value=None
        ) as status, mock.patch.object(
            run_xcode_tests.time, "monotonic", side_effect=[0.0, 99.25]
        ), mock.patch.object(run_xcode_tests.time, "sleep"):
            result = run_xcode_tests.observe_attempt(job, args, 0.0, io.StringIO(), [])
        self.assertEqual(result, (None, "", "wall-timeout=100s"))
        read.assert_not_called()
        status.assert_not_called()

    def test_attempt_observation_stops_when_status_read_hits_deadline(self) -> None:
        args = argparse.Namespace(wall_deadline=100.0, wall_timeout=100, idle_timeout=300)
        job = launchd_job(Path("/tmp/unused-job"))
        with mock.patch.object(
            run_xcode_tests, "read_job_bytes"
        ) as read, mock.patch.object(
            run_xcode_tests,
            "job_status",
            side_effect=run_xcode_tests.OperationDeadlineExpired("status stalled"),
        ), mock.patch.object(
            run_xcode_tests.time, "monotonic", return_value=0.0
        ):
            result = run_xcode_tests.observe_attempt(job, args, 0.0, io.StringIO(), [])
        self.assertEqual(result, (None, "", "wall-timeout=100s"))
        read.assert_not_called()

    def test_attempt_output_read_is_chunk_bounded(self) -> None:
        payload = b"x" * (run_xcode_tests.ATTEMPT_OUTPUT_CHUNK_BYTES + 1)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "stdout.log"
            path.write_bytes(payload)
            first, offset = run_xcode_tests.read_job_bytes(path, 0)
            second, final_offset = run_xcode_tests.read_job_bytes(path, offset)
        self.assertEqual(len(first), run_xcode_tests.ATTEMPT_OUTPUT_CHUNK_BYTES)
        self.assertEqual(second, b"x")
        self.assertEqual(final_offset, len(payload))

    def test_attempt_output_read_has_hard_deadline(self) -> None:
        entered = threading.Event()
        release = threading.Event()

        def stalled_read(_path: Path, _offset: int) -> tuple[bytes, int]:
            entered.set()
            release.wait(1)
            return b"late", 4

        started = time.monotonic()
        try:
            with mock.patch.object(
                run_xcode_tests, "read_job_bytes_now", side_effect=stalled_read
            ):
                with self.assertRaisesRegex(
                    run_xcode_tests.OperationDeadlineExpired,
                    "output read deadline expired",
                ):
                    run_xcode_tests.read_job_bytes(
                        Path("/tmp/unused-output"), 0, started + 0.02
                    )
            self.assertTrue(entered.is_set())
            self.assertLess(time.monotonic() - started, 0.2)
        finally:
            release.set()

    def test_completed_attempt_drains_all_bounded_output_chunks(self) -> None:
        prefix = b"x" * run_xcode_tests.ATTEMPT_OUTPUT_CHUNK_BYTES
        args = argparse.Namespace(wall_deadline=100.0, wall_timeout=100, idle_timeout=300)
        job = launchd_job(Path("/tmp/unused-job"))
        log = io.StringIO()
        stdout = io.StringIO()
        with mock.patch.object(
            run_xcode_tests, "read_job_bytes", side_effect=[(prefix, len(prefix)), (b"tail", len(prefix) + 4)]
        ) as read, mock.patch.object(
            run_xcode_tests, "job_status", return_value=0
        ), mock.patch.object(
            run_xcode_tests.time, "monotonic", return_value=0.0
        ), mock.patch.object(
            run_xcode_tests.time, "sleep"
        ), mock.patch.object(run_xcode_tests.sys, "stdout", stdout):
            result = run_xcode_tests.observe_attempt(job, args, 0.0, log, [])
        expected = prefix.decode() + "tail"
        self.assertEqual(result, (0, expected, None))
        self.assertEqual(log.getvalue(), expected)
        self.assertEqual(stdout.getvalue(), expected)
        self.assertEqual(read.call_count, 2)

    def test_attempt_output_stops_before_expired_writes(self) -> None:
        log = mock.Mock()
        stdout = mock.Mock()
        with mock.patch.object(
            run_xcode_tests.time, "monotonic", side_effect=[99.0, 99.25]
        ), mock.patch.object(run_xcode_tests.sys, "stdout", stdout):
            published = run_xcode_tests.publish_attempt_output(
                "late output", log, [], 99.25
            )
        self.assertFalse(published)
        log.write.assert_not_called()
        stdout.write.assert_not_called()
        stdout.flush.assert_not_called()

    def test_attempt_output_write_has_hard_deadline(self) -> None:
        entered = threading.Event()
        release = threading.Event()
        log = mock.Mock()
        stdout = mock.Mock()

        def stalled_write(_content: str) -> None:
            entered.set()
            release.wait(1)

        log.write.side_effect = stalled_write
        started = time.monotonic()
        try:
            with mock.patch.object(run_xcode_tests.sys, "stdout", stdout):
                published = run_xcode_tests.publish_attempt_output(
                    "blocked output", log, [], started + 0.02
                )
            self.assertFalse(published)
            self.assertTrue(entered.is_set())
            self.assertLess(time.monotonic() - started, 0.2)
            stdout.write.assert_not_called()
        finally:
            release.set()

    def test_attempt_stdout_write_has_hard_deadline(self) -> None:
        entered = threading.Event()
        release = threading.Event()
        stdout = mock.Mock()

        def stalled_write(_content: str) -> None:
            entered.set()
            release.wait(1)

        stdout.write.side_effect = stalled_write
        started = time.monotonic()
        try:
            with mock.patch.object(run_xcode_tests.sys, "stdout", stdout):
                published = run_xcode_tests.publish_attempt_output(
                    "blocked output", io.StringIO(), [], started + 0.02
                )
            self.assertFalse(published)
            self.assertTrue(entered.is_set())
            self.assertLess(time.monotonic() - started, 0.2)
            stdout.flush.assert_not_called()
        finally:
            release.set()

    def test_process_evidence_deadline_precedes_cleanup_reserve(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = simulator_args(root)
            args.wall_deadline = 100.0
            job = launchd_job(root / "job")
            job.root.mkdir()
            with mock.patch.object(
                run_xcode_tests, "remaining_wall_budget", return_value=10
            ), mock.patch.object(
                run_xcode_tests, "spawn_contained_job", return_value=job
            ), mock.patch.object(
                run_xcode_tests, "observe_attempt", return_value=(None, "", "idle-timeout=300s")
            ), mock.patch.object(
                run_xcode_tests.time, "monotonic", return_value=90.0
            ), mock.patch.object(
                run_xcode_tests, "launchd_job_evidence", return_value="evidence"
            ) as evidence, mock.patch.object(
                run_xcode_tests, "cleanup_contained_job"
            ) as cleanup, mock.patch.object(run_xcode_tests, "job_output") as final_output:
                run_xcode_tests.run_attempt(args, args.command, io.StringIO(), 1, 0.0, [])
        evidence_deadline = evidence.call_args.args[1]
        self.assertEqual(evidence_deadline, 90.25)
        self.assertLessEqual(evidence_deadline, 99.5)
        cleanup.assert_called_once_with(job, 100.0, True)
        final_output.assert_not_called()

    def successful_command_child_pid(self, source: str) -> int:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = simulator_args(root)
            args.diagnostics_dir.mkdir()
            args.wall_deadline = time.monotonic() + 4
            result = run_xcode_tests.lifecycle_command(
                args, "successful-command", [sys.executable, "-c", source]
            )
        match = re.search(r"CHILD_PID=(\d+)", result.stdout)
        self.assertIsNotNone(match)
        assert match is not None
        return int(match.group(1))

    def wait_until_process_exits(self, pid: int) -> bool:
        for _ in range(40):
            status = subprocess.run(
                ["ps", "-p", str(pid), "-o", "pid="],
                capture_output=True,
                check=False,
                text=True,
            )
            if not status.stdout.strip():
                return True
            time.sleep(0.05)
        return False

    def terminate_ready_contained_job(self, command: list[str], pid_path: Path) -> int:
        deadline = time.monotonic() + 4
        job = run_xcode_tests.spawn_contained_job(command, False, deadline)
        cleaned = False
        try:
            self.assertTrue(self.wait_until_file_contains(job.stdout_path, "READY"))
            run_xcode_tests.cleanup_contained_job(job, deadline, True)
            cleaned = True
            return int(pid_path.read_text(encoding="utf-8"))
        finally:
            if not cleaned:
                try:
                    run_xcode_tests.cleanup_contained_job(job, deadline, True)
                except run_xcode_tests.SimulatorLifecycleError:
                    pass
            shutil.rmtree(job.root, ignore_errors=True)

    def cleanup_after_sidecar_tamper(self, replacement: str | None) -> int:
        deadline = time.monotonic() + 6
        source = (
            "import subprocess,sys,time; "
            "child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],"
            "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True); "
            "print(f'CHILD_PID={child.pid}',flush=True); time.sleep(30)"
        )
        job = run_xcode_tests.spawn_contained_job([sys.executable, "-c", source], False, deadline)
        cleaned = False
        try:
            self.assertTrue(self.wait_until_file_contains(job.stdout_path, "CHILD_PID="))
            match = re.search(r"CHILD_PID=(\d+)", run_xcode_tests.job_output(job.stdout_path))
            self.assertIsNotNone(match)
            assert match is not None
            if replacement is None:
                job.coalition_path.unlink()
            else:
                job.coalition_path.write_text(replacement, encoding="utf-8")
            run_xcode_tests.cleanup_contained_job(job, deadline, True)
            cleaned = True
            return int(match.group(1))
        finally:
            if not cleaned:
                try:
                    run_xcode_tests.cleanup_contained_job(job, deadline, True)
                except run_xcode_tests.SimulatorLifecycleError:
                    pass
            shutil.rmtree(job.root, ignore_errors=True)

    def wait_until_file_contains(self, path: Path, expected: str) -> bool:
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                if expected in path.read_text(encoding="utf-8"):
                    return True
            except FileNotFoundError:
                pass
            time.sleep(0.01)
        return False

    def test_preflight_boots_and_checks_simulator_services(self) -> None:
        args = argparse.Namespace(simulator_timeout=120)
        with mock.patch.object(run_xcode_tests, "lifecycle_command") as command:
            run_xcode_tests.boot_and_check_simulator(args, "DEVICE", "Shutdown")
        labels = [call.args[1] for call in command.call_args_list]
        self.assertEqual(
            labels,
            [
                "boot-simulator",
                "wait-for-simulator-boot",
                "check-simulator-springboard",
                "check-simulator-services",
            ],
        )

    def test_preflight_recovers_when_simulator_inventory_stalls(self) -> None:
        args = argparse.Namespace(simulator_timeout=120)
        stalled = run_xcode_tests.SimulatorLifecycleError("inventory stalled")
        with mock.patch.object(
            run_xcode_tests, "available_simulator", side_effect=stalled
        ), mock.patch.object(
            run_xcode_tests, "recover_simulator", return_value="RECOVERED"
        ) as recover:
            result = run_xcode_tests.prepare_simulator(args)
        self.assertEqual(result, ("RECOVERED", True))
        recover.assert_called_once_with(args, None, "preflight")

    def test_diagnostic_timeout_does_not_block_remaining_capture(self) -> None:
        args = argparse.Namespace(simulator_timeout=120)
        with mock.patch.object(
            run_xcode_tests,
            "lifecycle_command",
            side_effect=[run_xcode_tests.SimulatorLifecycleError("stalled"), None],
        ) as command, mock.patch.object(
            run_xcode_tests, "capture_host_process_diagnostic"
        ) as host_processes:
            run_xcode_tests.capture_simulator_diagnostics(args, "DEVICE", "failure")
        self.assertEqual(command.call_count, 2)
        self.assertTrue(all(call.kwargs["timeout"] == 20 for call in command.call_args_list))
        self.assertTrue(all(call.args[2][0] != "ps" for call in command.call_args_list))
        host_processes.assert_called_once_with(args, "failure-host-processes")

    def test_host_process_diagnostic_uses_libproc_without_sandboxed_ps(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = simulator_args(root)
            args.diagnostics_dir.mkdir()
            with mock.patch.object(
                run_xcode_tests,
                "host_process_census",
                return_value='{"pid": 22, "path": "/usr/bin/example"}\n',
            ) as census, mock.patch.object(
                run_xcode_tests.subprocess, "Popen"
            ) as launch:
                run_xcode_tests.capture_host_process_diagnostic(args, "host-processes")
            evidence = (args.diagnostics_dir / "simulator-lifecycle.log").read_text()
        census.assert_called_once()
        launch.assert_not_called()
        self.assertIn("command=['libproc', 'stable-process-census']", evidence)
        self.assertIn('"pid": 22', evidence)
        self.assertNotIn("command=['ps'", evidence)

    def test_recovery_restarts_service_after_shutdown_timeout(self) -> None:
        args = argparse.Namespace(simulator_timeout=120)
        stalled = run_xcode_tests.SimulatorLifecycleError("shutdown stalled")
        restarted = subprocess.CompletedProcess([], 0, "", "")
        with mock.patch.object(
            run_xcode_tests, "capture_simulator_diagnostics"
        ), mock.patch.object(
            run_xcode_tests, "lifecycle_command", side_effect=[stalled, restarted]
        ) as command, mock.patch.object(
            run_xcode_tests.time, "sleep"
        ), mock.patch.object(
            run_xcode_tests, "available_simulator", return_value=("NEW", "Shutdown")
        ), mock.patch.object(
            run_xcode_tests, "boot_and_check_simulator"
        ):
            recovered = run_xcode_tests.recover_simulator(args, "OLD", "attempt-1")
        self.assertEqual(recovered, "NEW")
        self.assertEqual(command.call_args_list[0].args[1], "shutdown-simulator")
        self.assertEqual(
            command.call_args_list[1].args[1], "restart-core-simulator-service"
        )

    def test_launch_failure_recovers_once_and_preserves_first_result(self) -> None:
        failure = run_xcode_tests.AttemptOutcome(
            -signal.SIGINT,
            "Failed to launch app with identifier\nNSMachErrorDomain Code=-308\n",
            "idle-timeout=300s",
            "xcodebuild process evidence",
        )
        success = run_xcode_tests.AttemptOutcome(0, "** TEST EXECUTE SUCCEEDED **\n", None, "")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = simulator_args(root)
            args.result_bundle_path.mkdir()
            with mock.patch.object(
                run_xcode_tests, "prepare_simulator", return_value=("OLD", False)
            ), mock.patch.object(
                run_xcode_tests, "run_attempt", side_effect=[failure, success]
            ) as attempts, mock.patch.object(
                run_xcode_tests, "recover_simulator", return_value="NEW"
            ) as recover:
                result = run_xcode_tests.run(args)
            preserved = args.diagnostics_dir / "attempt-1.xcresult"
            result_preserved = preserved.exists()
            timeout_evidence = (args.diagnostics_dir / "attempt-1-timeout.txt").read_text()
        self.assertEqual(result, 0)
        recover.assert_called_once_with(args, "OLD", "attempt-1")
        self.assertIn("id=OLD", attempts.call_args_list[0].args[1][2])
        self.assertIn("id=NEW", attempts.call_args_list[1].args[1][2])
        self.assertTrue(result_preserved)
        self.assertIn("classification=pre-test-launch-infrastructure-timeout", timeout_evidence)
        self.assertIn("xcodebuild process evidence", timeout_evidence)

    def test_test_failure_after_execution_starts_is_never_retried(self) -> None:
        failure = run_xcode_tests.AttemptOutcome(
            65,
            "Test Case '-[PomodoroughTests example]' started\n"
            "Failed to launch app with identifier\n** TEST FAILED **\n",
            None,
            "",
        )
        with tempfile.TemporaryDirectory() as directory:
            args = simulator_args(Path(directory))
            with mock.patch.object(
                run_xcode_tests, "prepare_simulator", return_value=("DEVICE", False)
            ), mock.patch.object(
                run_xcode_tests, "run_attempt", return_value=failure
            ) as attempts, mock.patch.object(run_xcode_tests, "recover_simulator") as recover:
                result = run_xcode_tests.run(args)
        self.assertEqual(result, 65)
        self.assertEqual(attempts.call_count, 1)
        recover.assert_not_called()

    def test_second_launch_failure_stops_after_single_recovery(self) -> None:
        failure = run_xcode_tests.AttemptOutcome(
            65, "Failed to launch test runner: (ipc/mig) server died\n", None, ""
        )
        with tempfile.TemporaryDirectory() as directory:
            args = simulator_args(Path(directory))
            with mock.patch.object(
                run_xcode_tests, "prepare_simulator", return_value=("OLD", False)
            ), mock.patch.object(
                run_xcode_tests, "run_attempt", side_effect=[failure, failure]
            ) as attempts, mock.patch.object(
                run_xcode_tests, "recover_simulator", return_value="NEW"
            ) as recover:
                result = run_xcode_tests.run(args)
        self.assertEqual(result, run_xcode_tests.PRETEST_INFRASTRUCTURE_FAILURE)
        self.assertEqual(attempts.call_count, 2)
        self.assertEqual(recover.call_count, 1)

    def test_preflight_recovery_consumes_only_recovery_budget(self) -> None:
        failure = run_xcode_tests.AttemptOutcome(
            65, "Lost connection to testmanagerd\n", None, ""
        )
        with tempfile.TemporaryDirectory() as directory:
            args = simulator_args(Path(directory))
            with mock.patch.object(
                run_xcode_tests, "prepare_simulator", return_value=("RECOVERED", True)
            ), mock.patch.object(
                run_xcode_tests, "run_attempt", return_value=failure
            ) as attempts, mock.patch.object(run_xcode_tests, "recover_simulator") as recover:
                result = run_xcode_tests.run(args)
        self.assertEqual(result, run_xcode_tests.PRETEST_INFRASTRUCTURE_FAILURE)
        self.assertEqual(attempts.call_count, 1)
        recover.assert_not_called()

    def test_successful_child_fails_closed_when_log_write_fails(self) -> None:
        bad_log = mock.MagicMock()
        bad_log.__enter__.return_value.write.side_effect = OSError(28, "No space left")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            job = launchd_job(root / "job")
            job.root.mkdir()
            args = argparse.Namespace(
                log_path=root / "xcodebuild.log",
                diagnostics_dir=root / "diagnostics",
                command=["fake-xcodebuild"],
                idle_timeout=1,
                wall_timeout=5,
            )
            with mock.patch.object(Path, "open", return_value=bad_log), mock.patch.object(
                run_xcode_tests, "spawn_contained_job", return_value=job
            ), mock.patch.object(
                run_xcode_tests,
                "observe_attempt",
                return_value=(0, "** TEST EXECUTE SUCCEEDED **\n", None),
            ), mock.patch.object(
                run_xcode_tests, "cleanup_contained_job"
            ), mock.patch.object(
                run_xcode_tests, "job_output", return_value="** TEST EXECUTE SUCCEEDED **\n"
            ):
                result = run_xcode_tests.run(args)

        self.assertEqual(result, run_xcode_tests.EVIDENCE_FAILURE)

    def test_process_exit_during_atomic_signaling_is_harmless(self) -> None:
        token = (0, 0, 0, 0, 0, 2222, 0, 41)
        identity = run_xcode_tests.ProcessIdentity(2222, (10, 20), token)
        with mock.patch.object(
            run_xcode_tests, "signal_audit_token", return_value=False
        ):
            self.assertFalse(run_xcode_tests.signal_identity(identity, signal.SIGKILL))

    def test_launchd_cleanup_fails_closed_for_unknown_bootout_error(self) -> None:
        result = subprocess.CompletedProcess([], 7, "", "permission denied")
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            with mock.patch.object(
                run_xcode_tests, "launchctl_run", return_value=result
            ):
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError, "bootout exited 7"
                ):
                    run_xcode_tests.bootout_job(job, None)

    def test_launchd_cleanup_fails_when_service_never_disappears(self) -> None:
        result = subprocess.CompletedProcess([], 0, "state = running", "")
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            with mock.patch.object(
                run_xcode_tests, "launchctl_run", return_value=result
            ):
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError, "cleanup incomplete"
                ):
                    run_xcode_tests.confirm_job_absent(job, time.monotonic() + 0.01)

    def test_escaped_descendant_is_gone_after_real_timeout(self) -> None:
        result, log, _ = self.run_fake_xcode(
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

    def test_escaped_descendant_is_gone_after_main_process_failure(self) -> None:
        result, log, _ = self.run_fake_xcode(
            """
            import subprocess
            import sys
            child = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(30)"],
                start_new_session=True,
            )
            print(f"ESCAPED_PID={child.pid}", flush=True)
            raise SystemExit(65)
            """
        )
        match = re.search(r"ESCAPED_PID=(\d+)", log)
        self.assertIsNotNone(match)
        assert match is not None
        escaped_pid = int(match.group(1))
        try:
            self.assertTrue(self.wait_until_process_exits(escaped_pid))
            self.assertEqual(result.returncode, 65)
        finally:
            try:
                os.kill(escaped_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def run_fake_xcode(
        self, source: str, idle_timeout: float = 1, wall_timeout: float = 5
    ) -> tuple[subprocess.CompletedProcess[str], str, dict[str, str]]:
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
                    str(idle_timeout),
                    "--wall-timeout",
                    str(wall_timeout),
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
                timeout=wall_timeout + 5,
            )
            log_content = log.read_text(encoding="utf-8") if log.exists() else ""
            evidence = {
                path.name: path.read_text(encoding="utf-8")
                for path in diagnostics.glob("*.txt")
            }
            return result, log_content, evidence

    def test_classifies_timeout_after_complete_test_summary_as_finalization(self) -> None:
        result, log, _ = self.run_fake_xcode(
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
        result, _, _ = self.run_fake_xcode(
            """
            import time
            print("Test Case 'example' started", flush=True)
            time.sleep(30)
            """
        )
        self.assertEqual(result.returncode, 125)
        self.assertIn("classification=test-execution-timeout", result.stderr)

    def test_wall_timeout_writes_both_timeout_evidence_files(self) -> None:
        started = time.monotonic()
        result, _, evidence = self.run_fake_xcode(
            """
            import time
            time.sleep(30)
            """,
            idle_timeout=30,
            wall_timeout=3,
        )
        elapsed = time.monotonic() - started
        expected = {"attempt-1-timeout.txt", "timeout.txt"}
        self.assertEqual(result.returncode, run_xcode_tests.TEST_EXECUTION_TIMEOUT)
        self.assertIn("classification=test-execution-timeout", result.stderr)
        self.assertEqual(set(evidence), expected)
        for content in evidence.values():
            self.assertIn("classification=test-execution-timeout", content)
            self.assertIn("wall-timeout=3s", content)
        self.assertLess(elapsed, 5)

    def test_timeout_evidence_write_is_bounded_and_reaps_writer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = simulator_args(root)
            args.diagnostics_dir.mkdir()
            blocked = args.diagnostics_dir / "attempt-1-timeout.txt"
            os.mkfifo(blocked)
            args.wall_deadline = time.monotonic() + 1
            started = time.monotonic()
            original_popen = subprocess.Popen
            writers: list[subprocess.Popen[bytes]] = []

            def capture_writer(*arguments: object, **options: object) -> subprocess.Popen[bytes]:
                writer = original_popen(*arguments, **options)
                writers.append(writer)
                return writer

            with mock.patch.object(
                run_xcode_tests.subprocess, "Popen", side_effect=capture_writer
            ), self.assertRaisesRegex(OSError, "write deadline expired"):
                run_xcode_tests.write_timeout_evidence(
                    args, 1, "test-execution-timeout", "wall-timeout=1s", started, ""
                )
            elapsed = time.monotonic() - started
            aggregate_written = (args.diagnostics_dir / "timeout.txt").is_file()
        self.assertEqual(len(writers), 2)
        self.assertTrue(all(writer.poll() is not None for writer in writers))
        self.assertTrue(aggregate_written)
        self.assertLess(elapsed, 0.75)

    def test_setup_directory_failure_is_classified_as_evidence_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            args = simulator_args(Path(directory))
            stderr = io.StringIO()
            failure = OSError("disk full")
            with mock.patch.object(Path, "mkdir", side_effect=failure), mock.patch(
                "sys.stderr", stderr
            ):
                result = run_xcode_tests.run(args)
        self.assertEqual(result, run_xcode_tests.EVIDENCE_FAILURE)
        self.assertIn("classification=evidence-write-failure; disk full", stderr.getvalue())

    def test_unit_summary_does_not_hide_stalled_ui_execution(self) -> None:
        result, _, _ = self.run_fake_xcode(
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
        result, _, _ = self.run_fake_xcode(
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
        result, log, _ = self.run_fake_xcode(
            """
            print("** TEST FAILED **", flush=True)
            raise SystemExit(65)
            """
        )
        self.assertEqual(result.returncode, 65)
        self.assertIn("** TEST FAILED **", log)
        self.assertNotIn("classification=", result.stderr)

    def test_successful_child_exits_zero(self) -> None:
        result, log, _ = self.run_fake_xcode(
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
