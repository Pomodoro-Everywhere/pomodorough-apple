from __future__ import annotations

import argparse
import ctypes
import io
import os
from pathlib import Path
import re
import select
import signal
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
import uuid
from typing import Callable
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


def direct_job(root: Path, marker: str | None = None) -> run_xcode_tests.DirectJob:
    process = mock.Mock(spec=subprocess.Popen)
    process.poll.return_value = None
    return run_xcode_tests.DirectJob(
        root,
        root / "stdout.log",
        root / "stderr.log",
        process,
        run_xcode_tests.ProcessIdentity(123, (456, 789)),
        run_xcode_tests.DirectChannel(-1, b"test-key"),
        marker=marker,
    )


def authenticated_direct_spawn(
    job: run_xcode_tests.DirectJob,
) -> Callable[..., run_xcode_tests.DirectJob]:
    def spawn(*_arguments: object, **options: object) -> run_xcode_tests.DirectJob:
        callback = options.get("authenticated")
        if not callable(callback):
            raise AssertionError("missing direct authentication callback")
        callback()
        return job

    return spawn


def lifecycle_test_deadline() -> float:
    return (
        time.monotonic()
        + run_xcode_tests.LAUNCHCTL_AUTHENTICATION_SECONDS
        + run_xcode_tests.LIFECYCLE_BOOTSTRAP_SECONDS
        + run_xcode_tests.LAUNCHCTL_PROCESS_CLEANUP_SECONDS
        + run_xcode_tests.CONTAINMENT_HANDSHAKE_SECONDS
        + run_xcode_tests.LIFECYCLE_CLEANUP_SECONDS
    )


def launchctl_test_deadline(command_window: float = 1.0) -> float:
    return (
        time.monotonic()
        + command_window
        + run_xcode_tests.LAUNCHCTL_PROCESS_CLEANUP_SECONDS
    )


def explicit_atomic_temporary(path: Path, token: str = "0123456789abcdef") -> Path:
    return path.with_suffix(f".{token}.tmp")


def invoke_atomic_writer(
    target: Path, temporary: Path | None, content: bytes = b"acknowledgement"
) -> tuple[int, str]:
    stdin = mock.Mock()
    stdin.buffer.read.return_value = content
    stderr = io.StringIO()
    arguments = [run_xcode_tests.ATOMIC_WRITER_ARGUMENT, str(target)]
    if temporary is not None:
        arguments.append(str(temporary))
    with mock.patch.object(
        run_xcode_tests.sys, "stdin", stdin
    ), mock.patch.object(run_xcode_tests.sys, "stderr", stderr):
        result = run_xcode_tests.run_atomic_writer(arguments)
    return result, stderr.getvalue()


def late_atomic_commit_popen(
    release: threading.Event,
    finished: threading.Event,
    commit_errors: list[OSError],
    threads: list[threading.Thread],
) -> Callable[..., subprocess.Popen[bytes]]:
    def spawn(command: list[str], **options: object) -> subprocess.Popen[bytes]:
        inherited = options["pass_fds"]  # type: ignore[assignment]
        descriptor = os.dup(inherited[0])
        directory_descriptor = os.dup(inherited[1])
        started = threading.Event()
        process = mock.Mock()
        process.args = command
        process.pid = 4321
        process.returncode = None
        process.poll.return_value = None
        process.wait.side_effect = subprocess.TimeoutExpired(command, 0.01)
        process.stdin.close.side_effect = OSError("forced stdin close failure")
        process.stderr.close.side_effect = OSError("forced stderr close failure")

        def communicate(content: bytes, timeout: float) -> tuple[bytes, bytes]:
            def finish() -> None:
                try:
                    os.write(descriptor, content)
                    started.set()
                    release.wait(2)
                    os.fsync(descriptor)
                    os.stat(
                        Path(command[-3]).name,
                        dir_fd=directory_descriptor,
                        follow_symlinks=False,
                    )
                except OSError as error:
                    commit_errors.append(error)
                finally:
                    os.close(descriptor)
                    os.close(directory_descriptor)
                    finished.set()

            thread = threading.Thread(target=finish)
            threads.append(thread)
            thread.start()
            started.wait(1)
            raise subprocess.TimeoutExpired(command, timeout)

        process.communicate.side_effect = communicate
        return process

    return spawn


def replace_atomic_entry(path: Path, attacker: Path, replacement: str) -> None:
    if path.exists() or path.is_symlink():
        path.unlink()
    if replacement == "symlink":
        path.symlink_to(attacker)
    elif replacement == "hardlink":
        os.link(attacker, path)
    else:
        staged = path.with_name(f"{path.name}.{replacement}")
        staged.write_bytes(replacement.encode())
        if replacement == "rename":
            os.rename(staged, path)
        else:
            path.write_bytes(staged.read_bytes())
            staged.unlink()


def atomic_race_rename(
    raced_path: Path, attacker: Path, replacement: str
) -> Callable[[run_xcode_tests.AtomicWrite, str, str, int], None]:
    original = run_xcode_tests.rename_atomic_entries
    pending = True

    def rename(
        write: run_xcode_tests.AtomicWrite,
        source: str,
        destination: str,
        flags: int,
    ) -> None:
        nonlocal pending
        if pending:
            pending = False
            replace_atomic_entry(raced_path, attacker, replacement)
        original(write, source, destination, flags)

    return rename


def assert_atomic_race_outcome(
    test: unittest.TestCase,
    target: Path,
    temporary: Path,
    attacker: Path,
    raced_entry: str,
    replacement: str,
    had_destination: bool,
) -> None:
    test.assertEqual(attacker.read_bytes(), b"attacker")
    if raced_entry == "temporary":
        test.assertEqual(target.exists(), had_destination)
        if had_destination:
            test.assertEqual(target.read_bytes(), b"original")
        test.assertTrue(temporary.exists() or temporary.is_symlink())
        return
    test.assertFalse(temporary.exists() or temporary.is_symlink())
    if replacement == "symlink":
        test.assertEqual(target.readlink(), attacker)
    else:
        expected = b"attacker" if replacement == "hardlink" else replacement.encode()
        test.assertEqual(target.read_bytes(), expected)


def replace_atomic_directory(
    parent: Path, moved: Path, attacker_parent: Path, replacement: str
) -> None:
    parent.rename(moved)
    if replacement == "symlink":
        parent.symlink_to(attacker_parent, target_is_directory=True)
    else:
        parent.mkdir()
    (parent / "acknowledgement.json").write_bytes(b"attacker")


def atomic_directory_race(
    parent: Path,
    moved: Path,
    attacker_parent: Path,
    replacement: str,
    phase: str,
) -> Callable[[run_xcode_tests.AtomicWrite, str, str, int], None]:
    original = run_xcode_tests.rename_atomic_entries
    pending = True

    def rename(
        write: run_xcode_tests.AtomicWrite,
        source: str,
        destination: str,
        flags: int,
    ) -> None:
        nonlocal pending
        race = pending
        pending = False
        if race and phase == "during":
            replace_atomic_directory(parent, moved, attacker_parent, replacement)
        original(write, source, destination, flags)
        if race and phase == "after":
            replace_atomic_directory(parent, moved, attacker_parent, replacement)

    return rename


def assert_atomic_directory_race(
    test: unittest.TestCase, phase: str, replacement: str, original: bytes | None
) -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        parent = root / "owned"
        parent.mkdir()
        moved = root / "moved"
        attacker_parent = root / "attacker"
        attacker_parent.mkdir()
        target = parent / "acknowledgement.json"
        if original is not None:
            target.write_bytes(original)
        write = run_xcode_tests.open_atomic_write(target)
        primary: BaseException | None = None
        try:
            run_xcode_tests.write_atomic_descriptor(write.descriptor, b"replacement")
            if phase == "before":
                replace_atomic_directory(parent, moved, attacker_parent, replacement)
                run_xcode_tests.commit_atomic_write(write)
            else:
                rename = atomic_directory_race(
                    parent, moved, attacker_parent, replacement, phase
                )
                with mock.patch.object(
                    run_xcode_tests, "rename_atomic_entries", side_effect=rename
                ):
                    run_xcode_tests.commit_atomic_write(write)
        except BaseException as error:
            primary = error
        finally:
            run_xcode_tests.close_atomic_write(write, primary)
        test.assertIsInstance(primary, OSError)
        test.assertEqual((parent / target.name).read_bytes(), b"attacker")
        test.assertEqual((moved / target.name).exists(), original is not None)
        if original is not None:
            test.assertEqual((moved / target.name).read_bytes(), original)
        test.assertEqual(list(moved.glob("acknowledgement.*.tmp")), [])


def assert_displaced_temp_replacement_rejected(
    test: unittest.TestCase, replacement: str
) -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        target = root / "acknowledgement.json"
        target.write_bytes(b"original")
        temporary = explicit_atomic_temporary(target)
        attacker = root / "attacker.json"
        attacker.write_bytes(b"attacker")
        original_rename = run_xcode_tests.rename_atomic_entries
        pending = True

        def replace_after_rename(
            write: run_xcode_tests.AtomicWrite,
            source: str,
            destination: str,
            flags: int,
        ) -> None:
            nonlocal pending
            original_rename(write, source, destination, flags)
            if pending:
                pending = False
                replace_atomic_entry(temporary, attacker, replacement)

        with mock.patch.object(
            run_xcode_tests,
            "rename_atomic_entries",
            side_effect=replace_after_rename,
        ), test.assertRaisesRegex(OSError, "rollback identity changed"):
            run_xcode_tests.write_atomic_bytes(target, b"replacement", temporary)
        test.assertEqual(target.read_bytes(), b"replacement")
        test.assertNotEqual(target.stat().st_ino, attacker.stat().st_ino)
        test.assertTrue(temporary.exists() or temporary.is_symlink())


def assert_rollback_substitution_rejected(
    test: unittest.TestCase, raced_entry: str
) -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        target = root / "acknowledgement.json"
        target.write_bytes(b"original")
        temporary = explicit_atomic_temporary(target)
        attacker = root / "attacker.json"
        attacker.write_bytes(b"attacker")
        original_rename = run_xcode_tests.rename_atomic_entries
        original_fsync = os.fsync
        rename_calls = 0
        directory_syncs = 0

        def substitute_before_rollback(*arguments: object) -> None:
            nonlocal rename_calls
            rename_calls += 1
            if rename_calls == 2:
                raced = target if raced_entry == "destination" else temporary
                replace_atomic_entry(raced, attacker, "hardlink")
            original_rename(*arguments)  # type: ignore[arg-type]

        def fail_commit_sync(descriptor: int) -> None:
            nonlocal directory_syncs
            if stat.S_ISDIR(os.fstat(descriptor).st_mode):
                directory_syncs += 1
                if directory_syncs == 1:
                    raise OSError("forced commit fsync failure")
            original_fsync(descriptor)

        with mock.patch.object(
            run_xcode_tests,
            "rename_atomic_entries",
            side_effect=substitute_before_rollback,
        ), mock.patch.object(
            run_xcode_tests.os, "fsync", side_effect=fail_commit_sync
        ), test.assertRaisesRegex(OSError, "rollback failed.*identity changed"):
            run_xcode_tests.write_atomic_bytes(target, b"replacement", temporary)
        if raced_entry == "destination":
            test.assertEqual(temporary.read_bytes(), b"original")
        else:
            test.assertEqual(target.read_bytes(), b"replacement")


def directory_sync_control_environment(
    root: Path, actions: tuple[str, ...]
) -> dict[str, str]:
    control = root / "directory-sync-control"
    marker = root / "directory-sync-hung-pid"
    (root / "sitecustomize.py").write_text(
        textwrap.dedent(
            """
            import errno
            import os
            from pathlib import Path
            import sys
            import time

            if "--directory-sync" in sys.argv:
                real_fsync = os.fsync
                def controlled_fsync(descriptor):
                    control = Path(os.environ["POMODOROUGH_SYNC_CONTROL"])
                    count = int(control.read_text()) if control.exists() else 0
                    control.write_text(str(count + 1))
                    actions = os.environ["POMODOROUGH_SYNC_ACTIONS"].split(",")
                    action = actions[count] if count < len(actions) else "ok"
                    if action == "error":
                        raise OSError(errno.EIO, "forced directory sync failure")
                    if action == "hang":
                        Path(os.environ["POMODOROUGH_SYNC_MARKER"]).write_text(
                            str(os.getpid())
                        )
                        time.sleep(30)
                    real_fsync(descriptor)
                os.fsync = controlled_fsync
            """
        ),
        encoding="utf-8",
    )
    return {
        "PYTHONPATH": str(root),
        "POMODOROUGH_SYNC_ACTIONS": ",".join(actions),
        "POMODOROUGH_SYNC_CONTROL": str(control),
        "POMODOROUGH_SYNC_MARKER": str(marker),
    }


def assert_hung_sync_reaped(test: unittest.TestCase, root: Path) -> None:
    process_id = int((root / "directory-sync-hung-pid").read_text())
    with test.assertRaises(ProcessLookupError):
        os.kill(process_id, 0)


HOSTED_ATTEMPT_WALL_TIMEOUT = (
    run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS
    + run_xcode_tests.TIMEOUT_EVIDENCE_SECONDS
    + run_xcode_tests.LAUNCHCTL_AUTHENTICATION_SECONDS
    + run_xcode_tests.LIFECYCLE_BOOTSTRAP_SECONDS
    + run_xcode_tests.LAUNCHCTL_PROCESS_CLEANUP_SECONDS
    + run_xcode_tests.CONTAINMENT_HANDSHAKE_SECONDS
)


def simulated_launchctl_delay(
    delay: float,
) -> subprocess.CompletedProcess[str]:
    clock = [0.0]
    job = direct_job(Path("/tmp/ap13-launchctl-bootstrap"))

    def spawn(*_arguments: object, **options: object) -> run_xcode_tests.DirectJob:
        callback = options.get("authenticated")
        if not callable(callback):
            raise AssertionError("missing direct authentication callback")
        clock[0] = run_xcode_tests.LAUNCHCTL_AUTHENTICATION_SECONDS
        callback()
        return job

    def complete(
        _job: run_xcode_tests.DirectJob,
        timeout: float,
        _deadline: float,
        _cleanup_reserve: float,
    ) -> run_xcode_tests.DirectCompletion:
        clock[0] += min(delay, timeout)
        returncode = 0 if delay <= timeout + 1e-9 else None
        return run_xcode_tests.DirectCompletion(returncode, "", "", None)

    total_deadline = (
        run_xcode_tests.LAUNCHCTL_AUTHENTICATION_SECONDS
        + run_xcode_tests.LIFECYCLE_BOOTSTRAP_SECONDS
        + run_xcode_tests.LAUNCHCTL_PROCESS_CLEANUP_SECONDS
    )
    with mock.patch.object(
        run_xcode_tests.time, "monotonic", side_effect=lambda: clock[0]
    ), mock.patch.object(
        run_xcode_tests, "spawn_direct_job", side_effect=spawn
    ), mock.patch.object(
        run_xcode_tests, "complete_direct_job", side_effect=complete
    ):
        return run_xcode_tests.launchctl_run(
            [], total_deadline, run_xcode_tests.LIFECYCLE_BOOTSTRAP_SECONDS
        )


def direct_frame(
    key: bytes, sequence: int, payload: dict[str, object]
) -> bytes:
    authenticated = run_xcode_tests.direct_message_bytes(sequence, payload)
    message = {
        "mac": run_xcode_tests.hmac.new(
            key, authenticated, run_xcode_tests.hashlib.sha256
        ).hexdigest(),
        "payload": payload,
        "sequence": sequence,
    }
    return run_xcode_tests.json.dumps(
        message, separators=(",", ":"), sort_keys=True
    ).encode() + b"\n"


def apply_authenticated_direct_payload(
    channel: run_xcode_tests.DirectChannel,
    payload: dict[str, object],
    deadline: float | None = None,
) -> None:
    frame = direct_frame(channel.key, channel.sequence + 1, payload)
    run_xcode_tests.apply_direct_message(
        channel, frame.removesuffix(b"\n"), deadline
    )


def darwin_direct_identity(
    pid: int, start_abstime: int, pid_version: int
) -> run_xcode_tests.ProcessIdentity:
    audit_token = [0] * 8
    audit_token[5], audit_token[7] = pid, pid_version
    return run_xcode_tests.ProcessIdentity(pid, (start_abstime, 0), tuple(audit_token))


def darwin_unique_info(
    unique_id: int, pid_version: int
) -> run_xcode_tests.ProcUniqueIdentifierInfo:
    info = run_xcode_tests.ProcUniqueIdentifierInfo()
    info.p_uniqueid = unique_id
    info.p_idversion = pid_version
    return info


def spawn_execing_socket_peer(
    socket_path: Path, gate_descriptor: int
) -> subprocess.Popen[bytes]:
    exec_source = "import os,sys,time;os.write(int(sys.argv[1]),b'x');time.sleep(30)"
    child_source = textwrap.dedent(
        """
        import os
        import socket
        import sys

        peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        peer.connect(sys.argv[1])
        peer.set_inheritable(True)
        os.read(int(sys.argv[2]), 1)
        os.execv(sys.executable, [sys.executable, "-c", sys.argv[3], str(peer.fileno())])
        """
    )
    return subprocess.Popen(
        [sys.executable, "-c", child_source, str(socket_path), str(gate_descriptor), exec_source],
        pass_fds=(gate_descriptor,),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def spawn_reporting_execing_socket_peer(
    socket_path: Path, report_descriptor: int
) -> subprocess.Popen[bytes]:
    exec_source = "import os,sys,time;os.write(int(sys.argv[1]),b'x');time.sleep(30)"
    child_source = textwrap.dedent(
        """
        import os
        import socket
        import sys
        import time

        sys.path.insert(0, sys.argv[1])
        from scripts import run_xcode_tests as runner

        peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        peer.connect(sys.argv[2])
        peer.set_inheritable(True)
        deadline = time.monotonic() + 5
        identity = None
        while identity is None and time.monotonic() < deadline:
            identity = runner.direct_process_identity(os.getpid())
        if identity is None:
            raise SystemExit(125)
        report = runner.json.dumps(runner.identity_payload(identity)).encode()
        os.write(int(sys.argv[3]), report)
        os.set_inheritable(int(sys.argv[3]), False)
        os.execv(sys.executable, [sys.executable, "-c", sys.argv[4], str(peer.fileno())])
        """
    )
    return subprocess.Popen(
        [
            sys.executable,
            "-c",
            child_source,
            str(ROOT),
            str(socket_path),
            str(report_descriptor),
            exec_source,
        ],
        pass_fds=(report_descriptor,),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def read_reported_wrapper_identity(
    descriptor: int, deadline: float
) -> run_xcode_tests.ProcessIdentity:
    content = bytearray()
    while time.monotonic() < deadline:
        ready, _, _ = select.select([descriptor], [], [], 0.1)
        if not ready:
            continue
        chunk = os.read(descriptor, 4096)
        if not chunk:
            break
        content.extend(chunk)
    payload = run_xcode_tests.json.loads(content)
    return run_xcode_tests.process_identity_from_payload(payload, "wrapper stress")


def await_execed_wrapper_identity(
    process: subprocess.Popen[bytes],
    reported: run_xcode_tests.ProcessIdentity,
    deadline: float,
) -> run_xcode_tests.ProcessIdentity:
    while time.monotonic() < deadline:
        current = run_xcode_tests.direct_process_identity(process.pid)
        if current is not None and current.audit_token != reported.audit_token:
            if run_xcode_tests.peer_identity_covers_exec_report(reported, current):
                return current
        time.sleep(run_xcode_tests.bounded_wait(deadline, 0.01))
    raise AssertionError("wrapper exec identity unavailable")


def exercise_real_wrapper_exec_convergence() -> tuple[
    run_xcode_tests.ProcessIdentity,
    run_xcode_tests.ProcessIdentity,
    run_xcode_tests.ProcessIdentity,
]:
    with tempfile.TemporaryDirectory() as directory:
        socket_path = Path(directory) / "wrapper.sock"
        listener = run_xcode_tests.open_direct_listener(socket_path)
        report_read, report_write = os.pipe()
        process = spawn_reporting_execing_socket_peer(socket_path, report_write)
        os.close(report_write)
        channel = run_xcode_tests.DirectChannel(-1, b"key")
        try:
            deadline = time.monotonic() + 5
            reported = read_reported_wrapper_identity(report_read, deadline)
            current = await_execed_wrapper_identity(process, reported, deadline)
            channel.wrapper = reported
            channel.wrapper_listener = listener.detach()
            channel.wrapper_socket_path = socket_path
            channel.peer_identity_required = True
            with mock.patch.object(run_xcode_tests, "pump_direct_channel"):
                accepted = run_xcode_tests.await_direct_identity(
                    channel, process, deadline
                )
            ready, _, _ = select.select([channel.wrapper_peer], [], [], 1)
            if ready != [channel.wrapper_peer] or os.read(channel.wrapper_peer, 1) != b"x":
                raise AssertionError("exec wrapper peer unavailable")
            return reported, current, accepted
        finally:
            listener.close()
            os.close(report_read)
            for descriptor in (channel.wrapper_listener, channel.wrapper_peer):
                if descriptor >= 0:
                    os.close(descriptor)
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)


def darwin_descendant_fixture() -> tuple[
    run_xcode_tests.ProcessIdentity,
    list[int],
    dict[int, run_xcode_tests.DarwinDirectAncestry],
    set[run_xcode_tests.ProcessIdentity],
]:
    root = darwin_direct_identity(900, 90_000, 77)
    process_ids = [root.pid]
    records = {
        root.pid: run_xcode_tests.DarwinDirectAncestry(root, 1, 0, 0)
    }
    expected: set[run_xcode_tests.ProcessIdentity] = set()

    def add_identity(pid: int, unique_id: int, parent_unique_id: int) -> None:
        identity = darwin_direct_identity(pid, pid * 10, pid + 1_000_000)
        process_ids.append(pid)
        records[pid] = run_xcode_tests.DarwinDirectAncestry(
            identity, unique_id, parent_unique_id, 0
        )
        expected.add(identity)

    parent_unique_id = records[root.pid].unique_id
    for level in range(40):
        for branch in range(3):
            leaf_id = 10_000 + level * 3 + branch
            add_identity(20_000 + leaf_id, leaf_id, parent_unique_id)
        chain_id = level + 2
        add_identity(1_000 + level, chain_id, parent_unique_id)
        parent_unique_id = chain_id
    return root, process_ids, records, expected


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
            args.wall_deadline = lifecycle_test_deadline()
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
            args.wall_deadline = lifecycle_test_deadline()
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
            args.wall_deadline = lifecycle_test_deadline()
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
                args.wall_deadline = lifecycle_test_deadline()
                pid_path = root / "grandchild.pid"
                grandchild = "import time; time.sleep(30)"
                intermediary = (
                    "import pathlib,subprocess,sys; "
                    f"child=subprocess.Popen([sys.executable,'-c',{grandchild!r}],"
                    "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True); "
                    "pathlib.Path(sys.argv[1]).write_text(str(child.pid))"
                )
                source = (
                    "import subprocess,sys; "
                    f"middle=subprocess.Popen([sys.executable,'-c',{intermediary!r},{str(pid_path)!r}],"
                    "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); "
                    "middle.wait(timeout=2); "
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

    @unittest.skipUnless(sys.platform.startswith("linux"), "requires Linux subreaper")
    def test_direct_cleanup_reaps_descendant_forked_during_sigterm(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pid_path = root / "termination-child.pid"
            source = """
                import os, pathlib, signal, subprocess, sys, time
                signal.signal(signal.SIGINT, signal.SIG_IGN)
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
            child_pid = self.terminate_ready_direct_job(command, pid_path)
        try:
            self.assertTrue(self.wait_until_process_exits(child_pid))
        finally:
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_direct_pipe_failure_closes_earlier_pipe_and_removes_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "spawn"
            acquired: list[int] = []
            failure = OSError("key pipe failed")
            real_pipe = os.pipe

            def create_root(**_options: object) -> str:
                root.mkdir()
                return str(root)

            def fail_after_first_pipe() -> tuple[int, int]:
                if acquired:
                    raise failure
                descriptors = real_pipe()
                acquired.extend(descriptors)
                return descriptors

            with mock.patch.object(
                run_xcode_tests.tempfile, "mkdtemp", side_effect=create_root
            ), mock.patch.object(
                run_xcode_tests.os, "pipe", side_effect=fail_after_first_pipe
            ), mock.patch.object(
                run_xcode_tests, "LIBPROC", None
            ):
                with self.assertRaisesRegex(OSError, "key pipe failed") as raised:
                    run_xcode_tests.spawn_direct_job(["target"], None)
            self.assertIs(raised.exception, failure)
            self.assertFalse(root.exists())
            for descriptor in acquired:
                with self.assertRaises(OSError):
                    os.fstat(descriptor)

    def test_direct_setup_preserves_primary_when_abort_cleanup_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "spawn"
            acquired: list[int] = []
            real_pipe = os.pipe
            process = mock.Mock(spec=subprocess.Popen)
            primary = run_xcode_tests.SimulatorLifecycleError("identity failed")
            cleanup = run_xcode_tests.SimulatorLifecycleError("abort timed out")

            def create_root(**_options: object) -> str:
                root.mkdir()
                return str(root)

            def capture_pipe() -> tuple[int, int]:
                descriptors = real_pipe()
                acquired.extend(descriptors)
                return descriptors

            with mock.patch.object(
                run_xcode_tests.tempfile, "mkdtemp", side_effect=create_root
            ), mock.patch.object(
                run_xcode_tests.os, "pipe", side_effect=capture_pipe
            ), mock.patch.object(
                run_xcode_tests.os, "write", side_effect=lambda _fd, content: len(content)
            ), mock.patch.object(
                run_xcode_tests.subprocess, "Popen", return_value=process
            ), mock.patch.object(
                run_xcode_tests, "await_direct_identity", side_effect=primary
            ), mock.patch.object(
                run_xcode_tests, "LIBPROC", None
            ), mock.patch.object(
                run_xcode_tests, "abort_direct_spawn", side_effect=cleanup
            ) as abort:
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError,
                    "identity failed; direct setup cleanup error: abort timed out",
                ) as raised:
                    run_xcode_tests.spawn_direct_job(["target"], None)
            self.assertIs(raised.exception, primary)
            abort.assert_called_once_with(process, None)
            self.assertFalse(root.exists())
            for descriptor in acquired:
                with self.assertRaises(OSError):
                    os.fstat(descriptor)

    def test_abort_direct_spawn_zero_budget_uses_bounded_reap(self) -> None:
        process = mock.Mock(spec=subprocess.Popen)
        process.poll.return_value = None
        process.wait.return_value = -signal.SIGKILL
        with mock.patch.object(run_xcode_tests.threading, "Thread") as thread:
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "direct wrapper setup cleanup deadline expired",
            ):
                run_xcode_tests.abort_direct_spawn(process, time.monotonic() - 1)
        process.kill.assert_called_once_with()
        process.wait.assert_called_once()
        timeout = process.wait.call_args.kwargs["timeout"]
        self.assertGreater(timeout, 0)
        self.assertLessEqual(timeout, run_xcode_tests.DIRECT_WRAPPER_REAP_SECONDS)
        thread.assert_not_called()

    def test_reap_direct_wrapper_zero_budget_uses_bounded_reap(self) -> None:
        job = direct_job(Path("/tmp/unused-direct-job"))
        job.process.wait.return_value = 0
        with mock.patch.object(run_xcode_tests.threading, "Thread") as thread:
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "direct wrapper reap deadline expired",
            ):
                run_xcode_tests.reap_direct_wrapper(job, time.monotonic() - 1)
        job.process.wait.assert_called_once()
        timeout = job.process.wait.call_args.kwargs["timeout"]
        self.assertGreater(timeout, 0)
        self.assertLessEqual(timeout, run_xcode_tests.DIRECT_WRAPPER_REAP_SECONDS)
        thread.assert_not_called()

    def test_direct_cleanup_reserves_wrapper_reap_budget(self) -> None:
        job = direct_job(Path("/tmp/unused-direct-job"))
        with mock.patch.object(
            run_xcode_tests, "cleanup_deadline", return_value=10.0
        ), mock.patch.object(
            run_xcode_tests, "drain_direct_job"
        ) as drain, mock.patch.object(
            run_xcode_tests, "force_direct_wrapper_exit"
        ) as force, mock.patch.object(
            run_xcode_tests, "reap_direct_wrapper"
        ) as reap, mock.patch.object(run_xcode_tests, "close_direct_channel"):
            run_xcode_tests.cleanup_direct_job(job, None, False)
        observation_by = 10.0 - run_xcode_tests.DIRECT_WRAPPER_REAP_SECONDS
        self.assertEqual(drain.call_args.args[:2], (job, observation_by))
        force.assert_called_once_with(job, 10.0)
        reap.assert_called_once_with(job, 10.0)

    def test_darwin_direct_spawn_enters_direct_protocol(self) -> None:
        failure = OSError("root unavailable")
        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests.tempfile, "mkdtemp", side_effect=failure
        ) as create_root:
            with self.assertRaisesRegex(OSError, "root unavailable") as raised:
                run_xcode_tests.spawn_direct_job(["target"], None)
        self.assertIs(raised.exception, failure)
        create_root.assert_called_once_with(prefix="pomodorough-xcode-lifecycle-")

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

    def test_direct_channel_frame_flood_is_bounded_without_losing_status(self) -> None:
        read_descriptor, write_descriptor = os.pipe()
        os.set_blocking(read_descriptor, False)
        channel = run_xcode_tests.DirectChannel(read_descriptor, b"authenticated")
        identities = [
            run_xcode_tests.ProcessIdentity(pid, (pid, 1))
            for pid in range(100, 228)
        ]
        payloads = [
            {"event": "wrapper", "identity": run_xcode_tests.identity_payload(identities[0])},
            {"event": "target", "identity": run_xcode_tests.identity_payload(identities[1])},
            *(
                {"event": "descendant", "identity": run_xcode_tests.identity_payload(identity)}
                for identity in identities[2:]
            ),
            {"event": "status", "returncode": 0},
        ]
        channel.buffer = b"".join(
            direct_frame(channel.key, sequence, payload)
            for sequence, payload in enumerate(payloads, 1)
        )
        try:
            run_xcode_tests.pump_direct_channel(channel, time.monotonic() + 1)
            self.assertIsNone(channel.returncode)
            self.assertEqual(channel.sequence, run_xcode_tests.DIRECT_CHANNEL_WORK_PER_PUMP)
            run_xcode_tests.pump_direct_channel(channel, time.monotonic() + 1)
            self.assertEqual(channel.returncode, 0)
        finally:
            os.close(write_descriptor)
            run_xcode_tests.close_direct_channel(channel)

    def test_darwin_monitor_reports_exec_identity_before_reaping_status(self) -> None:
        wrapper = darwin_direct_identity(800, 8, 7000000)
        pre_exec = darwin_direct_identity(900, 10, 7100837)
        post_exec = darwin_direct_identity(900, 10, 7100840)
        process = mock.Mock(spec=subprocess.Popen)
        process.pid = post_exec.pid
        trace: list[str] = []
        process.poll.side_effect = lambda: trace.append("poll") or 7

        def record_event(
            _reporter: run_xcode_tests.DirectReporter, payload: dict[str, object]
        ) -> None:
            trace.append(str(payload["event"]))

        reporter = run_xcode_tests.DirectReporter(91, b"key")
        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests,
            "stable_darwin_peer_identity",
            return_value=post_exec,
        ), mock.patch.object(
            run_xcode_tests, "observe_direct_descendants", side_effect=set
        ), mock.patch.object(
            run_xcode_tests, "report_direct_event", side_effect=record_event
        ), mock.patch.object(
            run_xcode_tests,
            "darwin_direct_target_state",
            side_effect=[(signal.SIGTRAP, False), (None, True)],
        ), mock.patch.object(
            run_xcode_tests,
            "continue_direct_target",
            side_effect=lambda _pid, _signal: trace.append("continue"),
        ) as resume, mock.patch.object(
            run_xcode_tests, "reap_direct_orphans"
        ), mock.patch.object(
            run_xcode_tests.time,
            "sleep",
            side_effect=[None, RuntimeError("stop monitor")],
        ):
            with self.assertRaisesRegex(RuntimeError, "stop monitor"):
                run_xcode_tests.monitor_direct_command(
                    process, wrapper, reporter, pre_exec, None, 92
                )
        self.assertEqual(trace, ["target-exec", "continue", "poll", "status"])
        resume.assert_called_once_with(process.pid, 0)

    def test_darwin_monitor_reports_marked_descendant_before_status(self) -> None:
        wrapper = darwin_direct_identity(800, 8, 7000000)
        target = darwin_direct_identity(900, 10, 7100840)
        descendant = darwin_direct_identity(901, 11, 7100841)
        process = mock.Mock(spec=subprocess.Popen)
        process.pid = target.pid
        trace: list[str] = []
        process.poll.side_effect = lambda: trace.append("poll") or 0

        def record_event(
            _reporter: run_xcode_tests.DirectReporter, payload: dict[str, object]
        ) -> None:
            trace.append(str(payload["event"]))

        reporter = run_xcode_tests.DirectReporter(91, b"key")
        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests,
            "observe_darwin_target_state",
            return_value=(target, True, True),
        ), mock.patch.object(
            run_xcode_tests, "observe_direct_descendants", side_effect=set
        ), mock.patch.object(
            run_xcode_tests,
            "inspect_marked_darwin_processes",
            return_value={descendant},
        ) as inspect, mock.patch.object(
            run_xcode_tests, "report_direct_event", side_effect=record_event
        ), mock.patch.object(
            run_xcode_tests, "reap_direct_orphans"
        ), mock.patch.object(
            run_xcode_tests.time, "sleep", side_effect=RuntimeError("stop monitor")
        ):
            with self.assertRaisesRegex(RuntimeError, "stop monitor"):
                run_xcode_tests.monitor_direct_command(
                    process, wrapper, reporter, target, "marker", 92
                )
        self.assertEqual(trace, ["descendant", "poll", "status"])
        self.assertGreater(inspect.call_args.args[1], 0)

    def test_darwin_monitor_reports_partial_marker_census_before_timeout(self) -> None:
        wrapper = darwin_direct_identity(800, 8, 7000000)
        target = darwin_direct_identity(900, 10, 7100840)
        descendant = darwin_direct_identity(901, 11, 7100841)
        process = mock.Mock(spec=subprocess.Popen)
        process.pid = target.pid
        trace: list[str] = []

        def partial_census(
            _marker: str,
            _deadline: float,
            observed: set[run_xcode_tests.ProcessIdentity],
        ) -> set[run_xcode_tests.ProcessIdentity]:
            observed.add(descendant)
            raise run_xcode_tests.OperationDeadlineExpired("marker census expired")

        reporter = run_xcode_tests.DirectReporter(91, b"key")
        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests,
            "observe_darwin_target_state",
            return_value=(target, True, True),
        ), mock.patch.object(
            run_xcode_tests, "observe_direct_descendants", side_effect=set
        ), mock.patch.object(
            run_xcode_tests, "inspect_marked_darwin_processes", side_effect=partial_census
        ), mock.patch.object(
            run_xcode_tests,
            "report_direct_event",
            side_effect=lambda _reporter, payload: trace.append(str(payload["event"])),
        ):
            with self.assertRaisesRegex(
                run_xcode_tests.OperationDeadlineExpired, "marker census expired"
            ):
                run_xcode_tests.monitor_direct_command(
                    process, wrapper, reporter, target, "marker", 92
                )
        self.assertEqual(trace, ["descendant"])
        process.poll.assert_not_called()

    def test_darwin_monitor_rejects_exited_target_when_identity_disappears(self) -> None:
        wrapper = darwin_direct_identity(800, 8, 7000000)
        pre_exec = darwin_direct_identity(900, 10, 7100837)
        process = mock.Mock(spec=subprocess.Popen)
        process.pid = pre_exec.pid
        reporter = run_xcode_tests.DirectReporter(91, b"key")
        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests, "stable_darwin_peer_identity", return_value=None
        ) as identity, mock.patch.object(
            run_xcode_tests, "observe_direct_descendants"
        ) as observe, mock.patch.object(
            run_xcode_tests, "report_direct_event"
        ) as report, mock.patch.object(
            run_xcode_tests, "darwin_direct_target_state", return_value=(None, True)
        ), mock.patch.object(
            run_xcode_tests, "continue_direct_target"
        ) as resume, mock.patch.object(
            run_xcode_tests, "reap_direct_orphans"
        ) as reap:
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "exited direct target identity unavailable",
            ):
                run_xcode_tests.monitor_direct_command(
                    process, wrapper, reporter, pre_exec, None, 92
                )
        identity.assert_called_once_with(92, process.pid)
        process.poll.assert_not_called()
        observe.assert_not_called()
        report.assert_not_called()
        resume.assert_not_called()
        reap.assert_not_called()

    def test_authenticated_darwin_status_requires_exec_transition(self) -> None:
        wrapper = darwin_direct_identity(800, 8, 7000000)
        pre_exec = darwin_direct_identity(900, 10, 7100837)
        channel = run_xcode_tests.DirectChannel(-1, b"authenticated")
        for event, identity in (("wrapper", wrapper), ("target", pre_exec)):
            apply_authenticated_direct_payload(
                channel,
                {"event": event, "identity": run_xcode_tests.identity_payload(identity)},
            )
        with self.assertRaisesRegex(
            run_xcode_tests.SimulatorLifecycleError,
            "status precedes target exec identity",
        ):
            apply_authenticated_direct_payload(
                channel, {"event": "status", "returncode": 0}
            )
        self.assertEqual(channel.sequence, 2)
        self.assertIsNone(channel.returncode)

    def test_authenticated_exec_transition_rejects_malformed_versions(self) -> None:
        wrapper = darwin_direct_identity(800, 8, 7000000)
        pre_exec = darwin_direct_identity(900, 10, 7100837)
        malformed_token = list(pre_exec.audit_token or ())
        malformed_token[5] = 901
        cases = {
            "duplicate": pre_exec,
            "reordered": darwin_direct_identity(900, 10, 7100836),
            "malformed": run_xcode_tests.ProcessIdentity(
                900, (10, 0), tuple(malformed_token)
            ),
        }
        for name, candidate in cases.items():
            with self.subTest(name=name):
                channel = run_xcode_tests.DirectChannel(-1, b"authenticated")
                for event, identity in (("wrapper", wrapper), ("target", pre_exec)):
                    apply_authenticated_direct_payload(
                        channel,
                        {"event": event, "identity": run_xcode_tests.identity_payload(identity)},
                    )
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError,
                    "invalid direct target exec identity",
                ):
                    apply_authenticated_direct_payload(
                        channel,
                        {"event": "target-exec", "identity": run_xcode_tests.identity_payload(candidate)},
                    )
                self.assertEqual(channel.sequence, 2)
                self.assertEqual(channel.target, pre_exec)

    def test_hosted_exec_reports_accept_authenticated_later_peer_generation(
        self,
    ) -> None:
        wrapper = darwin_direct_identity(800, 8, 7000000)
        pre_exec = darwin_direct_identity(900, 10, 7100837)
        latest = darwin_direct_identity(900, 10, 7100867)
        channel = run_xcode_tests.DirectChannel(
            -1,
            b"authenticated",
            wrapper=wrapper,
            target=pre_exec,
            target_peer=91,
            peer_identity_required=True,
        )
        with mock.patch.object(
            run_xcode_tests,
            "stable_darwin_peer_identity",
            return_value=latest,
        ) as inspect_peer:
            for version in range(7100838, 7100868):
                apply_authenticated_direct_payload(
                    channel,
                    {
                        "event": "target-exec",
                        "identity": run_xcode_tests.identity_payload(
                            darwin_direct_identity(900, 10, version)
                        ),
                    },
                )
        self.assertEqual(channel.target, latest)
        self.assertTrue(channel.target_exec_observed)
        self.assertEqual(inspect_peer.call_count, 30)
        self.assertEqual(len(channel.target_identities), 31)

    def test_hosted_exec_report_waits_for_parent_peer_generation(self) -> None:
        wrapper = darwin_direct_identity(800, 8, 7000000)
        before_exec = darwin_direct_identity(900, 10, 7100837)
        reported = darwin_direct_identity(900, 10, 7100838)
        channel = run_xcode_tests.DirectChannel(
            -1,
            b"authenticated",
            wrapper=wrapper,
            target=before_exec,
            target_peer=91,
            peer_identity_required=True,
        )
        with mock.patch.object(
            run_xcode_tests,
            "stable_darwin_peer_identity",
            side_effect=[before_exec, None, reported],
        ) as inspect_peer:
            apply_authenticated_direct_payload(
                channel,
                {
                    "event": "target-exec",
                    "identity": run_xcode_tests.identity_payload(reported),
                },
                time.monotonic() + 1,
            )
        self.assertEqual(channel.target, reported)
        self.assertEqual(inspect_peer.call_count, 3)

    def test_target_exec_peer_rejects_reuse_regression_and_substitution(
        self,
    ) -> None:
        reported = darwin_direct_identity(900, 10, 7100838)
        substituted_token = list(
            darwin_direct_identity(900, 10, 7100839).audit_token or ()
        )
        substituted_token[5] = 901
        rejected = (
            darwin_direct_identity(900, 10, 7100837),
            darwin_direct_identity(900, 11, 7100839),
            run_xcode_tests.ProcessIdentity(900, (10, 0), tuple(substituted_token)),
            run_xcode_tests.ProcessIdentity(900, (10, 0), None),
            None,
        )
        for current in rejected:
            with self.subTest(current=current):
                channel = run_xcode_tests.DirectChannel(
                    -1,
                    b"authenticated",
                    wrapper=darwin_direct_identity(800, 8, 7000000),
                    target=darwin_direct_identity(900, 10, 7100837),
                    target_peer=91,
                    peer_identity_required=True,
                )
                with mock.patch.object(
                    run_xcode_tests,
                    "stable_darwin_peer_identity",
                    return_value=current,
                ) as inspect_peer, self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError,
                    "forged direct target exec identity",
                ):
                    apply_authenticated_direct_payload(
                        channel,
                        {
                            "event": "target-exec",
                            "identity": run_xcode_tests.identity_payload(reported),
                        },
                        time.monotonic() + 0.1,
                    )
                self.assertGreaterEqual(inspect_peer.call_count, 1)
                self.assertEqual(channel.sequence, 0)
                self.assertEqual(
                    channel.target,
                    darwin_direct_identity(900, 10, 7100837),
                )

    def test_target_exec_peer_accepts_same_process_credential_change(self) -> None:
        before_exec = darwin_direct_identity(900, 10, 7100837)
        reported = darwin_direct_identity(900, 10, 7100838)
        current_token = list(darwin_direct_identity(900, 10, 7100839).audit_token or ())
        current_token[1] = 501
        current = run_xcode_tests.ProcessIdentity(900, (10, 0), tuple(current_token))
        channel = run_xcode_tests.DirectChannel(
            -1,
            b"authenticated",
            wrapper=darwin_direct_identity(800, 8, 7000000),
            target=before_exec,
            target_peer=91,
            peer_identity_required=True,
        )
        with mock.patch.object(
            run_xcode_tests, "stable_darwin_peer_identity", return_value=current
        ):
            apply_authenticated_direct_payload(
                channel,
                {
                    "event": "target-exec",
                    "identity": run_xcode_tests.identity_payload(reported),
                },
            )
        self.assertEqual(channel.target, reported)

    def test_target_exec_peer_accepts_authenticated_report_after_peer_exit(self) -> None:
        parent, target = socket.socketpair()
        try:
            before_exec = darwin_direct_identity(900, 10, 7100837)
            reported = darwin_direct_identity(900, 10, 7100838)
            channel = run_xcode_tests.DirectChannel(
                -1,
                b"authenticated",
                wrapper=darwin_direct_identity(800, 8, 7000000),
                target=before_exec,
                target_peer=parent.fileno(),
                peer_identity_required=True,
            )
            target.close()
            with mock.patch.object(
                run_xcode_tests, "stable_darwin_peer_identity", return_value=None
            ):
                apply_authenticated_direct_payload(
                    channel,
                    {
                        "event": "target-exec",
                        "identity": run_xcode_tests.identity_payload(reported),
                    },
                )
            self.assertEqual(channel.target, reported)
        finally:
            parent.close()
            target.close()

    def test_direct_target_exec_event_rejects_identity_change(self) -> None:
        wrapper = darwin_direct_identity(800, 8, 7000000)
        pre_exec = darwin_direct_identity(900, 10, 7100837)
        replacement = darwin_direct_identity(900, 11, 7100840)
        channel = run_xcode_tests.DirectChannel(
            -1, b"key", wrapper=wrapper, target=pre_exec
        )
        payload = {
            "event": "target-exec",
            "identity": run_xcode_tests.identity_payload(replacement),
        }
        with self.assertRaisesRegex(
            run_xcode_tests.SimulatorLifecycleError,
            "invalid direct target exec identity",
        ):
            run_xcode_tests.apply_direct_payload(channel, payload)
        self.assertIs(channel.target, pre_exec)

    def test_direct_channel_closes_descriptor_on_eof_and_invalid_frames(self) -> None:
        cases = [("eof", b"", None), ("malformed", b"{bad}\n", "invalid"), ("truncated", b"{bad", "truncated")]
        for name, content, expected in cases:
            with self.subTest(name=name):
                read_descriptor, write_descriptor = os.pipe()
                os.set_blocking(read_descriptor, False)
                channel = run_xcode_tests.DirectChannel(read_descriptor, b"key")
                os.write(write_descriptor, content)
                os.close(write_descriptor)
                if expected is None:
                    run_xcode_tests.pump_direct_channel(channel, time.monotonic() + 1)
                else:
                    with self.assertRaisesRegex(
                        run_xcode_tests.SimulatorLifecycleError, expected
                    ):
                        run_xcode_tests.pump_direct_channel(
                            channel, time.monotonic() + 1
                        )
                self.assertTrue(channel.closed)
                self.assertEqual(channel.descriptor, -1)
                with self.assertRaises(OSError):
                    os.fstat(read_descriptor)

    def test_malformed_channel_error_survives_descriptor_close_failure(self) -> None:
        channel = run_xcode_tests.DirectChannel(91, b"key", buffer=b"frame\n")
        primary = run_xcode_tests.SimulatorLifecycleError("invalid direct channel message")
        close_error = OSError("descriptor busy")
        with mock.patch.object(
            run_xcode_tests, "apply_direct_message", side_effect=primary
        ), mock.patch.object(
            run_xcode_tests.os, "close", side_effect=close_error
        ) as close:
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "invalid direct channel message; direct channel cleanup error: "
                "descriptor close failed: descriptor busy",
            ) as raised:
                run_xcode_tests.pump_direct_channel(channel, time.monotonic() + 1)
        self.assertIs(raised.exception, primary)
        self.assertTrue(channel.closed)
        self.assertEqual(channel.descriptor, -1)
        close.assert_called_once_with(91)

    def test_direct_channel_deadline_prevents_further_authenticated_work(self) -> None:
        read_descriptor, write_descriptor = os.pipe()
        os.set_blocking(read_descriptor, False)
        channel = run_xcode_tests.DirectChannel(read_descriptor, b"key")
        channel.buffer = direct_frame(
            channel.key,
            1,
            {"event": "wrapper", "identity": run_xcode_tests.identity_payload(
                run_xcode_tests.ProcessIdentity(123, (1, 2))
            )},
        )
        try:
            run_xcode_tests.pump_direct_channel(channel, time.monotonic() - 1)
            self.assertEqual(channel.sequence, 0)
            self.assertNotEqual(channel.buffer, b"")
        finally:
            os.close(write_descriptor)
            run_xcode_tests.close_direct_channel(channel)

    def test_direct_channel_deadline_expiry_stops_buffered_frame_loop(self) -> None:
        read_descriptor, write_descriptor = os.pipe()
        os.set_blocking(read_descriptor, False)
        channel = run_xcode_tests.DirectChannel(
            read_descriptor,
            b"key",
            wrapper=run_xcode_tests.ProcessIdentity(1, (1, 1)),
            target=run_xcode_tests.ProcessIdentity(2, (2, 2)),
        )
        frames = b"".join(
            direct_frame(
                channel.key,
                sequence,
                {"event": "descendant", "identity": run_xcode_tests.identity_payload(
                    run_xcode_tests.ProcessIdentity(sequence + 2, (sequence + 2, 3))
                )},
            )
            for sequence in range(1, run_xcode_tests.DIRECT_CHANNEL_WORK_PER_PUMP + 1)
        )
        channel.buffer = frames
        try:
            with mock.patch.object(
                run_xcode_tests.time, "monotonic", side_effect=[9.0, 10.0]
            ):
                run_xcode_tests.pump_direct_channel(channel, 10.0)
            self.assertEqual(channel.sequence, 0)
            self.assertEqual(channel.buffer, frames)
        finally:
            os.close(write_descriptor)
            run_xcode_tests.close_direct_channel(channel)

    def test_linux_direct_signal_uses_pidfd_before_identity_recheck(self) -> None:
        identity = run_xcode_tests.ProcessIdentity(2222, (10, 20))
        events: list[str] = []
        with mock.patch.object(run_xcode_tests, "LIBPROC", None), mock.patch.object(
            run_xcode_tests.os, "pidfd_open", create=True,
            side_effect=lambda *_args: events.append("open") or 91,
        ), mock.patch.object(
            run_xcode_tests, "current_direct_identity",
            side_effect=lambda *_args: events.append("inspect") or identity,
        ), mock.patch.object(
            run_xcode_tests.signal, "pidfd_send_signal", create=True,
            side_effect=lambda *_args: events.append("signal"),
        ), mock.patch.object(
            run_xcode_tests.os, "close", side_effect=lambda *_args: events.append("close")
        ):
            self.assertTrue(
                run_xcode_tests.signal_direct_identity(
                    identity, signal.SIGTERM, time.monotonic() + 1
                )
            )
        self.assertEqual(events, ["open", "inspect", "signal", "close"])

    def test_linux_direct_signal_rejects_reused_pid_after_pidfd_open(self) -> None:
        identity = run_xcode_tests.ProcessIdentity(2222, (10, 20))
        with mock.patch.object(run_xcode_tests, "LIBPROC", None), mock.patch.object(
            run_xcode_tests.os, "pidfd_open", create=True, return_value=91
        ), mock.patch.object(
            run_xcode_tests, "current_direct_identity", return_value=None
        ), mock.patch.object(
            run_xcode_tests.signal, "pidfd_send_signal", create=True
        ) as send, mock.patch.object(run_xcode_tests.os, "close") as close:
            self.assertFalse(
                run_xcode_tests.signal_direct_identity(
                    identity, signal.SIGTERM, time.monotonic() + 1
                )
            )
        send.assert_not_called()
        close.assert_called_once_with(91)

    def test_darwin_direct_signal_uses_retained_token_after_census_deadline(self) -> None:
        identity = darwin_direct_identity(2222, 10, 41)
        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests, "signal_audit_token", return_value=True
        ) as send, mock.patch.object(
            run_xcode_tests, "current_direct_identity"
        ) as inspect:
            self.assertTrue(
                run_xcode_tests.signal_direct_identity(
                    identity, signal.SIGKILL, time.monotonic() - 1
                )
            )
        send.assert_called_once_with(identity.audit_token, signal.SIGKILL)
        inspect.assert_not_called()

    def test_direct_child_snapshot_rejects_reused_unrelated_pid(self) -> None:
        parent = run_xcode_tests.ProcessIdentity(1111, (10, 20))
        replacement = run_xcode_tests.ProcessIdentity(2222, (30, 40))

        def current_identity(pid: int) -> run_xcode_tests.ProcessIdentity:
            return parent if pid == parent.pid else replacement

        with mock.patch.object(
            run_xcode_tests, "direct_process_identity", side_effect=current_identity
        ), mock.patch.object(
            run_xcode_tests, "direct_child_process_ids", return_value=[replacement.pid]
        ), mock.patch.object(
            run_xcode_tests, "direct_child_identity", return_value=None
        ):
            children = run_xcode_tests.observed_direct_children(parent)
        self.assertEqual(children, set())

    def test_direct_child_identity_rejects_pid_reuse_during_binding(self) -> None:
        parent = run_xcode_tests.ProcessIdentity(1111, (10, 20))
        departed = run_xcode_tests.ProcessIdentity(2222, (30, 40))
        replacement = run_xcode_tests.ProcessIdentity(2222, (50, 60))
        with mock.patch.object(run_xcode_tests, "LIBPROC", None), mock.patch.object(
            run_xcode_tests,
            "direct_process_record",
            side_effect=[
                (departed, parent.pid),
                (replacement, parent.pid),
            ],
        ):
            identity = run_xcode_tests.direct_child_identity(parent, departed.pid)
        self.assertIsNone(identity)

    def test_darwin_child_identity_rejects_public_identity_churn(self) -> None:
        parent = darwin_direct_identity(1111, 10, 20)
        departed = darwin_direct_identity(2222, 30, 40)
        replacement = darwin_direct_identity(2222, 50, 60)
        with mock.patch.object(
            run_xcode_tests,
            "direct_process_identity",
            side_effect=[parent, departed, replacement, parent],
        ), mock.patch.object(
            run_xcode_tests,
            "direct_child_process_ids",
            side_effect=[[departed.pid], [departed.pid]],
        ):
            identity = run_xcode_tests.darwin_direct_child_identity(
                parent, departed.pid
            )
        self.assertIsNone(identity)

    def test_darwin_child_identity_accepts_stable_public_identity(self) -> None:
        parent = darwin_direct_identity(1111, 10, 20)
        child = darwin_direct_identity(2222, 30, 40)
        with mock.patch.object(
            run_xcode_tests,
            "direct_process_identity",
            side_effect=[parent, child, child, parent],
        ), mock.patch.object(
            run_xcode_tests,
            "direct_child_process_ids",
            side_effect=[[child.pid], [child.pid]],
        ):
            identity = run_xcode_tests.darwin_direct_child_identity(parent, child.pid)
        self.assertEqual(identity, child)

    def test_darwin_child_identity_rejects_parent_exec_churn(self) -> None:
        parent = darwin_direct_identity(1111, 10, 20)
        exec_parent = darwin_direct_identity(1111, 10, 21)
        child = darwin_direct_identity(2222, 30, 40)
        with mock.patch.object(
            run_xcode_tests,
            "direct_process_identity",
            side_effect=[parent, child, child, exec_parent],
        ), mock.patch.object(
            run_xcode_tests,
            "direct_child_process_ids",
            side_effect=[[child.pid], [child.pid]],
        ):
            identity = run_xcode_tests.darwin_direct_child_identity(parent, child.pid)
        self.assertIsNone(identity)

    def test_direct_wrapper_identity_retries_transient_lookup_failures(self) -> None:
        identity = run_xcode_tests.ProcessIdentity(2222, (30, 40))
        with mock.patch.object(
            run_xcode_tests,
            "direct_wrapper_process_identity",
            side_effect=[None, None, identity],
        ) as inspect, mock.patch.object(run_xcode_tests.time, "sleep") as sleep:
            result = run_xcode_tests.await_direct_process_identity(
                identity.pid, time.monotonic() + 1
            )
        self.assertEqual(result, identity)
        self.assertEqual(inspect.call_count, 3)
        self.assertEqual(sleep.call_count, 2)

    def test_direct_wrapper_identity_lookup_has_hard_deadline(self) -> None:
        entered = threading.Event()
        release = threading.Event()
        finished = threading.Event()

        def stalled_identity(_pid: int) -> None:
            entered.set()
            release.wait(1)
            finished.set()
            raise RuntimeError("released stalled identity lookup")

        try:
            with mock.patch.object(
                run_xcode_tests,
                "direct_wrapper_process_identity",
                side_effect=stalled_identity,
            ):
                with self.assertRaisesRegex(
                    run_xcode_tests.OperationDeadlineExpired,
                    "direct wrapper identity deadline expired",
                ):
                    run_xcode_tests.await_direct_process_identity(
                        2222, time.monotonic() + 0.02
                    )
            self.assertTrue(entered.is_set())
        finally:
            release.set()
            self.assertTrue(finished.wait(1))

    def test_direct_wrapper_identity_exhaustion_fails_closed(self) -> None:
        def immediate(operation: Callable[[], object], *_args: object) -> object:
            return operation()

        with mock.patch.object(
            run_xcode_tests, "direct_wrapper_process_identity", return_value=None
        ), mock.patch.object(
            run_xcode_tests.time, "monotonic", side_effect=[0.0, 0.0, 1.0]
        ), mock.patch.object(
            run_xcode_tests.time, "sleep"
        ), mock.patch.object(
            run_xcode_tests, "deadline_call", side_effect=immediate
        ):
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "direct wrapper identity unavailable",
            ):
                run_xcode_tests.await_direct_process_identity(2222, 1.0)

    def test_direct_child_authenticates_identity_setup_failure(self) -> None:
        failure = run_xcode_tests.OperationDeadlineExpired(
            "direct wrapper identity deadline expired"
        )
        with mock.patch.object(
            run_xcode_tests, "read_direct_key", return_value=b"k" * 32
        ), mock.patch.object(
            run_xcode_tests, "connect_direct_peer", return_value=94
        ), mock.patch.object(run_xcode_tests.os, "close"), mock.patch.object(
            run_xcode_tests, "configure_direct_subreaper"
        ) as configure, mock.patch.object(
            run_xcode_tests, "await_direct_process_identity", side_effect=failure
        ), mock.patch.object(
            run_xcode_tests, "report_direct_event"
        ) as report, mock.patch.object(
            run_xcode_tests.signal, "pause", side_effect=RuntimeError("stop child")
        ), mock.patch.object(run_xcode_tests, "spawn_gated_direct_target") as spawn:
            with self.assertRaisesRegex(RuntimeError, "stop child"):
                run_xcode_tests.direct_child(
                    91, 92, 93, "wrapper", "parent-target", "wrapper-target", ["target"]
                )
        configure.assert_called_once_with()
        reporter, payload = report.call_args.args
        self.assertEqual((reporter.descriptor, reporter.key), (91, b"k" * 32))
        self.assertEqual(
            payload,
            {"event": "error", "message": "direct wrapper identity deadline expired"},
        )
        spawn.assert_not_called()

    def test_stable_darwin_process_info_rejects_uniqueid_churn(self) -> None:
        first = run_xcode_tests.ProcUniqueIdentifierInfo()
        first.p_uniqueid = 10
        first.p_idversion = 20
        second = run_xcode_tests.ProcUniqueIdentifierInfo()
        second.p_uniqueid = 11
        second.p_idversion = 20
        library = mock.Mock()

        def read_bsd_info(
            pid: int, _flavor: int, _arg: int, pointer: object, _size: int
        ) -> int:
            pointer._obj.pbi_pid = pid  # type: ignore[attr-defined]
            return ctypes.sizeof(run_xcode_tests.ProcBSDInfo)

        library.proc_pidinfo.side_effect = read_bsd_info
        with mock.patch.object(run_xcode_tests, "LIBPROC", library), mock.patch.object(
            run_xcode_tests,
            "unique_identifier_info",
            side_effect=[first, second],
        ):
            record = run_xcode_tests.stable_darwin_process_info(2222)
        self.assertIsNone(record)

    def test_darwin_direct_identity_uses_only_public_process_apis(self) -> None:
        token = darwin_direct_identity(2222, 10, 20).audit_token
        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests,
            "darwin_process_audit_token",
            side_effect=[token, token],
        ), mock.patch.object(
            run_xcode_tests,
            "darwin_process_start_abstime",
            side_effect=[10, 10],
        ), mock.patch.object(
            run_xcode_tests, "unique_identifier_info"
        ) as unique, mock.patch.object(
            run_xcode_tests, "direct_process_record"
        ) as record:
            identity = run_xcode_tests.direct_process_identity(2222)
        self.assertEqual(identity, darwin_direct_identity(2222, 10, 20))
        record.assert_not_called()
        unique.assert_not_called()

    def test_darwin_start_identity_uses_public_rusage_v0(self) -> None:
        library = mock.Mock()

        def read_rusage(pid: int, flavor: int, pointer: object) -> int:
            self.assertEqual((pid, flavor), (2222, run_xcode_tests.RUSAGE_INFO_V0))
            pointer._obj.ri_proc_start_abstime = 123  # type: ignore[attr-defined]
            return 0

        library.proc_pid_rusage.side_effect = read_rusage
        with mock.patch.object(run_xcode_tests, "LIBPROC", library):
            observed = run_xcode_tests.darwin_process_start_abstime(2222)
        self.assertEqual(observed, 123)

    def test_darwin_start_identity_rejects_failed_or_zero_rusage(self) -> None:
        library = mock.Mock()
        with mock.patch.object(run_xcode_tests, "LIBPROC", library):
            library.proc_pid_rusage.return_value = 1
            self.assertIsNone(run_xcode_tests.darwin_process_start_abstime(2222))
            library.proc_pid_rusage.return_value = 0
            self.assertIsNone(run_xcode_tests.darwin_process_start_abstime(2222))

    def test_darwin_task_audit_token_uses_public_task_info(self) -> None:
        library = mock.Mock()

        def read_token(
            task: int, flavor: int, values: object, count: object
        ) -> int:
            self.assertEqual((task, flavor), (99, run_xcode_tests.TASK_AUDIT_TOKEN))
            observed_count = count._obj.value  # type: ignore[attr-defined]
            self.assertEqual(observed_count, run_xcode_tests.TASK_AUDIT_TOKEN_COUNT)
            token = ctypes.cast(
                values, ctypes.POINTER(run_xcode_tests.AuditToken)
            ).contents
            token.values[5], token.values[7] = 2222, 20
            return 0

        library.task_info.side_effect = read_token
        with mock.patch.object(run_xcode_tests, "LIBSYSTEM", library):
            observed = run_xcode_tests.darwin_task_audit_token(99, 2222)
        self.assertEqual(observed, darwin_direct_identity(2222, 10, 20).audit_token)

    def test_darwin_self_identity_survives_peer_token_unavailability(self) -> None:
        expected = darwin_direct_identity(os.getpid(), 8, 20).audit_token
        library = mock.Mock()
        library.mach_task_self.return_value = 99
        with mock.patch.object(
            run_xcode_tests, "LIBSYSTEM", library
        ), mock.patch.object(
            run_xcode_tests,
            "darwin_task_audit_token",
            return_value=expected,
        ) as task_token, mock.patch.object(
            run_xcode_tests.socket,
            "socketpair",
            side_effect=OSError("direct wrapper identity unavailable"),
        ) as socketpair:
            observed = run_xcode_tests.darwin_process_audit_token(os.getpid())
        self.assertEqual(observed, expected)
        task_token.assert_called_once_with(99, os.getpid())
        socketpair.assert_not_called()

    def test_darwin_self_identity_falls_back_to_socketpair_peer_token(self) -> None:
        expected = darwin_direct_identity(os.getpid(), 8, 20).audit_token
        local, peer = mock.Mock(), mock.Mock()
        local.fileno.return_value = 91
        library = mock.Mock()
        library.mach_task_self.return_value = 99
        with mock.patch.object(
            run_xcode_tests, "LIBSYSTEM", library
        ), mock.patch.object(
            run_xcode_tests, "darwin_task_audit_token", return_value=None
        ), mock.patch.object(
            run_xcode_tests.socket, "socketpair", return_value=(local, peer)
        ) as socketpair, mock.patch.object(
            run_xcode_tests, "darwin_peer_audit_token", return_value=expected
        ) as peer_token:
            observed = run_xcode_tests.darwin_process_audit_token(os.getpid())
        self.assertEqual(observed, expected)
        socketpair.assert_called_once_with(socket.AF_UNIX, socket.SOCK_STREAM)
        peer_token.assert_called_once_with(91, os.getpid())
        local.close.assert_called_once_with()
        peer.close.assert_called_once_with()

    def test_darwin_self_identity_rejects_failed_socketpair_fallback(self) -> None:
        cases = (
            (None, None),
            (OSError("query failed"), None),
            (None, OSError("close failed")),
        )
        for query_result, close_error in cases:
            local, peer = mock.Mock(), mock.Mock()
            local.fileno.return_value = 91
            local.close.side_effect = close_error
            peer_effect = query_result if isinstance(query_result, OSError) else None
            with self.subTest(
                query_result=query_result, close_error=close_error
            ), mock.patch.object(
                run_xcode_tests, "darwin_task_audit_token", return_value=None
            ), mock.patch.object(
                run_xcode_tests.socket, "socketpair", return_value=(local, peer)
            ), mock.patch.object(
                run_xcode_tests,
                "darwin_peer_audit_token",
                side_effect=peer_effect,
                return_value=query_result,
            ):
                observed = run_xcode_tests.darwin_self_audit_token(os.getpid())
            self.assertIsNone(observed)
            local.close.assert_called_once_with()
            peer.close.assert_called_once_with()

    def test_darwin_self_identity_rejects_socketpair_creation_failure(self) -> None:
        with mock.patch.object(
            run_xcode_tests, "darwin_task_audit_token", return_value=None
        ), mock.patch.object(
            run_xcode_tests.socket,
            "socketpair",
            side_effect=OSError("socketpair unavailable"),
        ):
            observed = run_xcode_tests.darwin_self_audit_token(os.getpid())
        self.assertIsNone(observed)

    @unittest.skipUnless(sys.platform == "darwin", "requires Darwin process identity")
    def test_darwin_wrapper_identity_survives_task_token_unavailability(self) -> None:
        with mock.patch.object(
            run_xcode_tests,
            "darwin_process_audit_token",
            side_effect=AssertionError("private token lookup used"),
        ) as private_token:
            identity = run_xcode_tests.direct_wrapper_process_identity(os.getpid())
        self.assertIsNotNone(identity)
        assert identity is not None
        self.assertEqual(identity.pid, os.getpid())
        self.assertIsNotNone(identity.audit_token)
        assert identity.audit_token is not None
        self.assertEqual(identity.audit_token[5], os.getpid())
        self.assertGreater(identity.audit_token[7], 0)
        private_token.assert_not_called()

    def test_darwin_task_audit_token_rejects_malformed_identity(self) -> None:
        cases = ((2223, 20, 8, 0), (2222, 0, 8, 0), (2222, 20, 7, 0), (2222, 20, 8, 5))
        for observed_pid, version, count, result in cases:
            library = mock.Mock()

            def read_token(_task: int, _flavor: int, values: object, size: object) -> int:
                token = ctypes.cast(
                    values, ctypes.POINTER(run_xcode_tests.AuditToken)
                ).contents
                token.values[5], token.values[7] = observed_pid, version
                size._obj.value = count  # type: ignore[attr-defined]
                return result

            library.task_info.side_effect = read_token
            with self.subTest(case=(observed_pid, version, count, result)), mock.patch.object(
                run_xcode_tests, "LIBSYSTEM", library
            ):
                self.assertIsNone(run_xcode_tests.darwin_task_audit_token(99, 2222))

    def test_stable_darwin_identity_rejects_process_or_exec_churn(self) -> None:
        original_token = darwin_direct_identity(2222, 10, 20).audit_token
        exec_token = darwin_direct_identity(2222, 10, 21).audit_token
        cases = (
            ("PID reuse", [10, 11], [original_token, original_token]),
            ("exec", [10, 10], [original_token, exec_token]),
        )
        for name, starts, tokens in cases:
            with self.subTest(name=name), mock.patch.object(
                run_xcode_tests,
                "darwin_process_start_abstime",
                side_effect=starts,
            ), mock.patch.object(
                run_xcode_tests, "darwin_process_audit_token", side_effect=tokens
            ):
                identity = run_xcode_tests.stable_darwin_process_identity(2222)
            self.assertIsNone(identity)

    def test_darwin_wrapper_identity_accepts_stable_birth_token_sample(self) -> None:
        expected = darwin_direct_identity(2222, 10, 20)
        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests,
            "darwin_process_start_abstime",
            side_effect=[10, 10],
        ), mock.patch.object(
            run_xcode_tests,
            "unique_identifier_info",
            side_effect=[darwin_unique_info(30, 20), darwin_unique_info(30, 20)],
        ), mock.patch.object(
            run_xcode_tests, "darwin_process_audit_token"
        ) as private_token:
            identity = run_xcode_tests.direct_wrapper_process_identity(2222)
        self.assertEqual(identity, expected)
        private_token.assert_not_called()

    def test_darwin_wrapper_identity_rejects_birth_or_token_substitution(self) -> None:
        stable = darwin_unique_info(30, 20)
        cases = (
            ("start churn", [10, 11], [stable, stable]),
            ("unique ID churn", [10, 10], [stable, darwin_unique_info(31, 20)]),
            ("version churn", [10, 10], [stable, darwin_unique_info(30, 21)]),
            ("zero unique ID", [10, 10], [darwin_unique_info(0, 20)] * 2),
            ("zero version", [10, 10], [darwin_unique_info(30, 0)] * 2),
            ("missing sample", [10, 10], [stable, None]),
        )
        for name, starts, identifiers in cases:
            with self.subTest(name=name), mock.patch.object(
                run_xcode_tests, "LIBPROC", object()
            ), mock.patch.object(
                run_xcode_tests,
                "darwin_process_start_abstime",
                side_effect=starts,
            ), mock.patch.object(
                run_xcode_tests, "unique_identifier_info", side_effect=identifiers
            ):
                identity = run_xcode_tests.direct_wrapper_process_identity(2222)
            self.assertIsNone(identity)

    def test_stable_darwin_peer_identity_accepts_one_exec_transition(self) -> None:
        before_exec = darwin_direct_identity(2222, 10, 20)
        after_exec = darwin_direct_identity(2222, 10, 21)
        with mock.patch.object(
            run_xcode_tests,
            "darwin_process_start_abstime",
            side_effect=[10] * 6,
        ), mock.patch.object(
            run_xcode_tests,
            "darwin_peer_audit_token",
            side_effect=[before_exec.audit_token, after_exec.audit_token, after_exec.audit_token],
        ) as token:
            identity = run_xcode_tests.stable_darwin_peer_identity(91, 2222)
        self.assertEqual(identity, after_exec)
        self.assertEqual(token.call_count, 3)

    def test_stable_darwin_peer_identity_rejects_reuse_or_substitution(self) -> None:
        token = darwin_direct_identity(2222, 10, 20).audit_token
        cases = (
            ("PID reuse", [10, 10, 11, 11], [token, token]),
            ("peer substitution", [10, 10, 10, 10], [token, None]),
        )
        for name, starts, tokens in cases:
            with self.subTest(name=name), mock.patch.object(
                run_xcode_tests,
                "darwin_process_start_abstime",
                side_effect=starts,
            ), mock.patch.object(
                run_xcode_tests, "darwin_peer_audit_token", side_effect=tokens
            ):
                identity = run_xcode_tests.stable_darwin_peer_identity(91, 2222)
            self.assertIsNone(identity)

    def test_wrapper_peer_identity_waits_for_reported_exec_generation(self) -> None:
        before_report = darwin_direct_identity(2222, 10, 19)
        reported = darwin_direct_identity(2222, 10, 20)
        after_report = darwin_direct_identity(2222, 10, 21)
        with mock.patch.object(
            run_xcode_tests,
            "stable_darwin_peer_identity",
            side_effect=[before_report, after_report],
        ) as inspect, mock.patch.object(run_xcode_tests.time, "sleep"):
            current = run_xcode_tests.await_peer_identity_covering_wrapper_report(
                91, reported, time.monotonic() + 1
            )
        self.assertEqual(current, after_report)
        self.assertEqual(inspect.call_count, 2)

    def test_wrapper_peer_identity_does_not_accept_peer_eof(self) -> None:
        reported = darwin_direct_identity(2222, 10, 20)
        with mock.patch.object(
            run_xcode_tests,
            "stable_darwin_peer_identity",
            return_value=None,
        ), mock.patch.object(
            run_xcode_tests, "direct_peer_closed", return_value=True
        ) as closed:
            current = run_xcode_tests.await_peer_identity_covering_wrapper_report(
                91, reported, time.monotonic() + 0.02
            )
        self.assertIsNone(current)
        closed.assert_not_called()

    def test_wrapper_peer_identity_reserves_completion_after_slow_sample(self) -> None:
        reported = darwin_direct_identity(2222, 10, 20)

        def slow_missing_identity(*_arguments: object) -> None:
            time.sleep(0.03)

        with mock.patch.object(
            run_xcode_tests,
            "stable_darwin_peer_identity",
            side_effect=slow_missing_identity,
        ) as inspect, mock.patch.object(
            run_xcode_tests, "direct_peer_closed", return_value=True
        ) as closed:
            current = run_xcode_tests.await_peer_identity_covering_wrapper_report(
                91, reported, time.monotonic() + 0.05
            )
        self.assertIsNone(current)
        self.assertEqual(inspect.call_count, 1)
        closed.assert_not_called()

    def test_wrapper_peer_identity_bounds_stalled_sample(self) -> None:
        reported = darwin_direct_identity(2222, 10, 20)
        release = threading.Event()
        finished = threading.Event()

        def stalled_identity(*_arguments: object) -> None:
            release.wait(1)
            finished.set()

        try:
            with mock.patch.object(
                run_xcode_tests,
                "stable_darwin_peer_identity",
                side_effect=stalled_identity,
            ) as inspect, mock.patch.object(
                run_xcode_tests, "direct_peer_closed", return_value=True
            ) as closed:
                current = run_xcode_tests.await_peer_identity_covering_wrapper_report(
                    91, reported, time.monotonic() + 0.1
                )
            self.assertIsNone(current)
            self.assertEqual(inspect.call_count, 1)
            closed.assert_not_called()
        finally:
            release.set()
        self.assertTrue(finished.wait(1))

    def test_stable_darwin_peer_identity_rejects_missing_descriptor(self) -> None:
        with self.assertRaisesRegex(
            run_xcode_tests.SimulatorLifecycleError,
            "direct peer descriptor unavailable",
        ):
            run_xcode_tests.stable_darwin_peer_identity(-1, 2222)

    def test_darwin_process_audit_token_rejects_port_cleanup_failure(self) -> None:
        token = darwin_direct_identity(2222, 10, 20).audit_token
        library = mock.Mock()
        library.mach_task_self.return_value = 7

        def name_task(_self: int, _pid: int, pointer: object) -> int:
            pointer._obj.value = 99  # type: ignore[attr-defined]
            return 0

        library.task_name_for_pid.side_effect = name_task
        library.mach_port_deallocate.return_value = 5
        with mock.patch.object(run_xcode_tests, "LIBSYSTEM", library), mock.patch.object(
            run_xcode_tests, "darwin_task_audit_token", return_value=token
        ):
            observed = run_xcode_tests.darwin_process_audit_token(2222)
        self.assertIsNone(observed)
        library.mach_port_deallocate.assert_called_once_with(7, 99)

    def test_darwin_process_audit_token_cleans_up_after_query_error(self) -> None:
        library = mock.Mock()
        library.mach_task_self.return_value = 7

        def name_task(_self: int, _pid: int, pointer: object) -> int:
            pointer._obj.value = 99  # type: ignore[attr-defined]
            return 0

        library.task_name_for_pid.side_effect = name_task
        library.mach_port_deallocate.return_value = 0
        with mock.patch.object(run_xcode_tests, "LIBSYSTEM", library), mock.patch.object(
            run_xcode_tests, "darwin_task_audit_token", side_effect=RuntimeError("query")
        ):
            with self.assertRaisesRegex(RuntimeError, "query"):
                run_xcode_tests.darwin_process_audit_token(2222)
        library.mach_port_deallocate.assert_called_once_with(7, 99)

    def test_darwin_ancestry_rejects_stale_private_exec_version(self) -> None:
        info = run_xcode_tests.ProcUniqueIdentifierInfo()
        info.p_uniqueid = 77
        info.p_idversion = 20
        current = darwin_direct_identity(2222, 10, 21)
        with mock.patch.object(
            run_xcode_tests, "unique_identifier_info", return_value=info
        ), mock.patch.object(
            run_xcode_tests, "stable_darwin_process_identity", return_value=current
        ):
            record = run_xcode_tests.stable_darwin_direct_ancestry(2222)
        self.assertIsNone(record)

    def test_darwin_ancestry_rejects_private_pid_reuse(self) -> None:
        first = run_xcode_tests.ProcUniqueIdentifierInfo()
        first.p_uniqueid, first.p_idversion = 77, 20
        second = run_xcode_tests.ProcUniqueIdentifierInfo()
        second.p_uniqueid, second.p_idversion = 78, 20
        current = darwin_direct_identity(2222, 10, 20)
        with mock.patch.object(
            run_xcode_tests, "unique_identifier_info", side_effect=[first, second]
        ), mock.patch.object(
            run_xcode_tests, "stable_darwin_process_identity", return_value=current
        ):
            record = run_xcode_tests.stable_darwin_direct_ancestry(2222)
        self.assertIsNone(record)

    def test_darwin_target_identity_uses_owned_process_not_private_record(self) -> None:
        wrapper = darwin_direct_identity(1111, 10, 20)
        target = darwin_direct_identity(2222, 30, 40)
        process = mock.Mock(spec=subprocess.Popen)
        process.pid = target.pid
        process.poll.return_value = None
        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests,
            "direct_process_identity",
            side_effect=[wrapper, wrapper],
        ), mock.patch.object(
            run_xcode_tests, "stable_darwin_peer_identity", return_value=target
        ), mock.patch.object(run_xcode_tests, "direct_process_record") as private:
            observed = run_xcode_tests.direct_target_identity(process, wrapper, 91)
        self.assertEqual(observed, target)
        private.assert_not_called()

    def test_darwin_target_identity_accepts_wrapper_exec_convergence(self) -> None:
        wrapper = darwin_direct_identity(1111, 10, 20)
        converged = darwin_direct_identity(1111, 10, 21)
        target = darwin_direct_identity(2222, 30, 40)
        process = mock.Mock(spec=subprocess.Popen)
        process.pid = target.pid
        process.poll.return_value = None
        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests,
            "direct_process_identity",
            side_effect=[converged, converged],
        ), mock.patch.object(
            run_xcode_tests, "stable_darwin_peer_identity", return_value=target
        ):
            observed = run_xcode_tests.direct_target_identity(process, wrapper, 91)
        self.assertEqual(observed, target)

    def test_darwin_target_identity_rejects_wrapper_birth_substitution(self) -> None:
        wrapper = darwin_direct_identity(1111, 10, 20)
        replacement = darwin_direct_identity(1111, 11, 21)
        target = darwin_direct_identity(2222, 30, 40)
        process = mock.Mock(spec=subprocess.Popen)
        process.pid = target.pid
        process.poll.return_value = None
        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests, "direct_process_identity", return_value=replacement
        ), mock.patch.object(
            run_xcode_tests, "stable_darwin_peer_identity", return_value=target
        ) as peer:
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "direct wrapper identity changed",
            ):
                run_xcode_tests.direct_target_identity(process, wrapper, 91)
        peer.assert_not_called()

    def test_darwin_target_identity_rejects_exec_during_binding(self) -> None:
        wrapper = darwin_direct_identity(1111, 10, 20)
        before_exec = darwin_direct_identity(2222, 30, 40)
        after_exec = darwin_direct_identity(2222, 30, 41)
        process = mock.Mock(spec=subprocess.Popen)
        process.pid = before_exec.pid
        process.poll.return_value = None
        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests,
            "direct_process_identity",
            return_value=wrapper,
        ), mock.patch.object(
            run_xcode_tests, "stable_darwin_peer_identity", return_value=None
        ):
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "direct target ancestry unavailable",
            ):
                run_xcode_tests.direct_target_identity(process, wrapper, 91)

    def test_darwin_direct_signal_rechecks_connected_peer(self) -> None:
        identity = darwin_direct_identity(2222, 30, 40)
        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests, "signal_audit_token", side_effect=[False, True]
        ) as send, mock.patch.object(
            run_xcode_tests, "bounded_peer_process_identity", return_value=identity
        ) as inspect, mock.patch.object(
            run_xcode_tests, "bounded_process_identity"
        ) as task_identity:
            self.assertTrue(
                run_xcode_tests.signal_direct_identity(
                    identity, signal.SIGTERM, time.monotonic() + 1, 91
                )
            )
        inspect.assert_called_once()
        task_identity.assert_not_called()
        self.assertEqual(send.call_count, 2)

    def test_darwin_peer_binding_accepts_same_process_exec_transition(self) -> None:
        before_exec = darwin_direct_identity(2222, 30, 40)
        after_exec = darwin_direct_identity(2222, 30, 41)
        with mock.patch.object(
            run_xcode_tests, "accept_direct_peer", return_value=92
        ), mock.patch.object(
            run_xcode_tests,
            "stable_darwin_peer_identity",
            side_effect=[None, after_exec],
        ) as inspect, mock.patch.object(
            run_xcode_tests, "direct_peer_closed", return_value=False
        ), mock.patch.object(
            run_xcode_tests.time, "sleep"
        ) as sleep, mock.patch.object(run_xcode_tests.os, "close") as close:
            descriptor = run_xcode_tests.bind_direct_peer_identity(
                91, Path("target.sock"), before_exec, time.monotonic() + 1
            )
        self.assertEqual(descriptor, 92)
        close.assert_called_once_with(91)
        self.assertEqual(inspect.call_count, 2)
        sleep.assert_called_once()

    def test_darwin_peer_binding_rejects_stable_wrong_process(self) -> None:
        reported = darwin_direct_identity(2222, 30, 40)
        replacement = darwin_direct_identity(2222, 31, 40)
        with mock.patch.object(
            run_xcode_tests, "accept_direct_peer", return_value=92
        ), mock.patch.object(
            run_xcode_tests, "stable_darwin_peer_identity", return_value=replacement
        ) as inspect, mock.patch.object(
            run_xcode_tests.time, "sleep"
        ) as sleep, mock.patch.object(run_xcode_tests.os, "close") as close:
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "forged direct peer identity",
            ):
                run_xcode_tests.bind_direct_peer_identity(
                    91, Path("target.sock"), reported, time.monotonic() + 1
                )
        inspect.assert_called_once_with(92, reported.pid)
        sleep.assert_not_called()
        self.assertEqual(close.call_args_list, [mock.call(92)])

    def test_darwin_peer_binding_closes_real_peer_after_identity_timeout(self) -> None:
        identity = darwin_direct_identity(2222, 30, 40)
        entered = threading.Event()
        release = threading.Event()
        accepted: list[int] = []

        def stalled_identity(descriptor: int, _pid: int) -> None:
            accepted.append(descriptor)
            entered.set()
            release.wait(1)

        with tempfile.TemporaryDirectory() as directory:
            socket_path = Path(directory) / "peer.sock"
            listener = run_xcode_tests.open_direct_listener(socket_path)
            peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            peer.connect(str(socket_path))
            try:
                with mock.patch.object(
                    run_xcode_tests,
                    "stable_darwin_peer_identity",
                    side_effect=stalled_identity,
                ):
                    with self.assertRaisesRegex(
                        run_xcode_tests.OperationDeadlineExpired,
                        "direct process identity deadline expired",
                    ):
                        run_xcode_tests.bind_direct_peer_identity(
                            listener.fileno(),
                            socket_path,
                            identity,
                            time.monotonic() + 0.02,
                        )
                self.assertTrue(entered.is_set())
                with self.assertRaises(OSError):
                    os.fstat(accepted[0])
            finally:
                release.set()
                peer.close()
                listener.close()

    @unittest.skipUnless(
        sys.platform == "darwin" and run_xcode_tests.LIBPROC is not None,
        "requires Darwin peer audit tokens",
    )
    def test_darwin_peer_identity_tracks_real_socket_across_exec(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            socket_path = Path(directory) / "peer.sock"
            listener = run_xcode_tests.open_direct_listener(socket_path)
            gate_read, gate_write = os.pipe()
            process = spawn_execing_socket_peer(socket_path, gate_read)
            os.close(gate_read)
            peer_descriptor = -1
            try:
                deadline = time.monotonic() + 5
                peer_descriptor = run_xcode_tests.accept_direct_peer(
                    listener.fileno(), deadline
                )
                listener.close()
                self.assertIsNone(
                    run_xcode_tests.stable_darwin_peer_identity(
                        peer_descriptor, os.getpid()
                    )
                )
                before_exec = run_xcode_tests.bounded_peer_process_identity(
                    peer_descriptor, process.pid, deadline
                )
                self.assertIsNotNone(before_exec)
                os.write(gate_write, b"1")
                os.close(gate_write)
                gate_write = -1
                ready, _, _ = select.select(
                    [peer_descriptor], [], [], run_xcode_tests.bounded_wait(deadline, 5)
                )
                self.assertEqual(ready, [peer_descriptor])
                self.assertEqual(os.read(peer_descriptor, 1), b"x")
                after_exec = run_xcode_tests.bounded_peer_process_identity(
                    peer_descriptor, process.pid, deadline
                )
                self.assertIsNotNone(after_exec)
                self.assertTrue(run_xcode_tests.same_direct_process(before_exec, after_exec))
                self.assertNotEqual(before_exec.audit_token, after_exec.audit_token)
            finally:
                listener.close()
                if peer_descriptor >= 0:
                    os.close(peer_descriptor)
                if gate_write >= 0:
                    os.close(gate_write)
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)

    @unittest.skipUnless(
        sys.platform == "darwin" and run_xcode_tests.LIBPROC is not None,
        "requires Darwin peer audit tokens",
    )
    def test_darwin_direct_protocol_accepts_rapid_exec_generations(self) -> None:
        source = (
            "import os,sys; source=sys.argv[1]; remaining=int(sys.argv[2]); "
            "os.execv(sys.executable,[sys.executable,'-c',source,source,"
            "str(remaining-1)]) if remaining else print('DONE')"
        )
        command = [sys.executable, "-c", source, source, "40"]
        deadline = time.monotonic() + 15
        outcome = run_xcode_tests.direct_lifecycle_process(command, 10, deadline)
        self.assertEqual(outcome.returncode, 0)
        self.assertEqual(outcome.stdout, "DONE\n")

    @unittest.skipUnless(
        sys.platform == "darwin" and run_xcode_tests.LIBPROC is not None,
        "requires Darwin peer audit tokens",
    )
    def test_darwin_short_lived_launchctl_helpers_converge_repeatedly(self) -> None:
        with mock.patch.object(run_xcode_tests, "LAUNCHCTL", sys.executable):
            for iteration in range(40):
                with self.subTest(iteration=iteration):
                    result = run_xcode_tests.launchctl_run(
                        ["-c", "raise SystemExit(7)"], launchctl_test_deadline(4), 2
                    )
                    self.assertEqual(result.returncode, 7)

    @unittest.skipUnless(
        sys.platform == "darwin" and run_xcode_tests.LIBPROC is not None,
        "requires Darwin peer audit tokens",
    )
    def test_darwin_wrapper_handshake_converges_after_real_exec_stress(self) -> None:
        for iteration in range(40):
            with self.subTest(iteration=iteration):
                reported, current, accepted = exercise_real_wrapper_exec_convergence()
                self.assertTrue(run_xcode_tests.same_direct_process(reported, current))
                self.assertNotEqual(reported.audit_token, current.audit_token)
                self.assertTrue(
                    run_xcode_tests.peer_identity_covers_exec_report(reported, accepted)
                )

    def test_wrapper_handshake_accepts_same_process_exec_generation(self) -> None:
        reported = darwin_direct_identity(2222, 10, 20)
        current = darwin_direct_identity(2222, 10, 21)
        channel = run_xcode_tests.DirectChannel(
            -1,
            b"key",
            wrapper=reported,
            wrapper_listener=91,
            wrapper_socket_path=Path("wrapper.sock"),
            peer_identity_required=True,
        )
        process = mock.Mock(spec=subprocess.Popen)
        process.pid = reported.pid
        with mock.patch.object(
            run_xcode_tests, "pump_direct_channel"
        ), mock.patch.object(
            run_xcode_tests, "bind_direct_peer_identity", return_value=92
        ) as bind, mock.patch.object(
            run_xcode_tests,
            "await_peer_identity_covering_wrapper_report",
            return_value=current,
        ) as converge:
            observed = run_xcode_tests.await_direct_identity(channel, process, None)
        self.assertEqual(observed, current)
        self.assertEqual(channel.wrapper, current)
        self.assertEqual(channel.wrapper_peer, 92)
        bind.assert_called_once()
        converge.assert_called_once()

    def test_wrapper_handshake_rejects_process_birth_substitution(self) -> None:
        reported = darwin_direct_identity(2222, 10, 20)
        replacement = darwin_direct_identity(2222, 11, 21)
        channel = run_xcode_tests.DirectChannel(
            -1,
            b"key",
            wrapper=reported,
            wrapper_listener=91,
            wrapper_socket_path=Path("wrapper.sock"),
            peer_identity_required=True,
        )
        process = mock.Mock(spec=subprocess.Popen)
        process.pid = reported.pid
        with mock.patch.object(run_xcode_tests, "pump_direct_channel"), mock.patch.object(
            run_xcode_tests, "bind_direct_peer_identity", return_value=92
        ), mock.patch.object(
            run_xcode_tests,
            "await_peer_identity_covering_wrapper_report",
            return_value=replacement,
        ):
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "forged direct wrapper identity",
            ):
                run_xcode_tests.await_direct_identity(channel, process, None)

    def test_launchd_containment_rejects_identity_or_coalition_churn(self) -> None:
        original = run_xcode_tests.ProcessIdentity(2222, (10, 20))
        replacement = run_xcode_tests.ProcessIdentity(2222, (11, 20))
        cases = (
            ("identity", original, replacement, 77, 77),
            ("coalition", original, original, 77, 99),
        )
        for name, first, second, first_coalition, second_coalition in cases:
            with self.subTest(name=name), mock.patch.object(
                run_xcode_tests, "process_identity", side_effect=[first, second]
            ) as identities, mock.patch.object(
                run_xcode_tests,
                "resource_coalition_id",
                side_effect=[first_coalition, 88, second_coalition],
            ) as coalitions:
                result = run_xcode_tests.inspect_launchd_service_containment(2222)
            self.assertIsNone(result)
            self.assertEqual(identities.call_args_list, [mock.call(2222), mock.call(2222)])
            self.assertEqual(
                coalitions.call_args_list,
                [mock.call(2222), mock.call(os.getpid()), mock.call(2222)],
            )

    def test_bounded_child_census_rejects_reused_unrelated_pid(self) -> None:
        parent = run_xcode_tests.ProcessIdentity(1111, (10, 20))
        replacement = run_xcode_tests.ProcessIdentity(2222, (30, 40))

        def bounded_identity(
            pid: int, _deadline: float
        ) -> run_xcode_tests.ProcessIdentity:
            return parent if pid == parent.pid else replacement

        with mock.patch.object(run_xcode_tests, "LIBPROC", None), mock.patch.object(
            run_xcode_tests, "bounded_process_identity", side_effect=bounded_identity
        ), mock.patch.object(
            run_xcode_tests, "direct_child_process_ids", return_value=[replacement.pid]
        ), mock.patch.object(
            run_xcode_tests,
            "direct_process_record",
            return_value=(replacement, 9999),
        ):
            children = run_xcode_tests.bounded_direct_children(
                parent, time.monotonic() + 1
            )
        self.assertEqual(children, set())

    def test_pidfd_close_failure_attaches_to_primary_identity_error(self) -> None:
        identity = run_xcode_tests.ProcessIdentity(2222, (10, 20))
        primary = run_xcode_tests.SimulatorLifecycleError("identity inspection failed")
        with mock.patch.object(run_xcode_tests, "LIBPROC", None), mock.patch.object(
            run_xcode_tests.os, "pidfd_open", create=True, return_value=91
        ), mock.patch.object(
            run_xcode_tests, "current_direct_identity", side_effect=primary
        ), mock.patch.object(
            run_xcode_tests.signal, "pidfd_send_signal", create=True
        ) as send, mock.patch.object(
            run_xcode_tests.os, "close", side_effect=OSError("descriptor busy")
        ) as close:
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "identity inspection failed; Linux identity cleanup error: "
                "pidfd close failed: descriptor busy",
            ) as raised:
                run_xcode_tests.signal_direct_identity(
                    identity, signal.SIGTERM, time.monotonic() + 1
                )
        self.assertIs(raised.exception, primary)
        send.assert_not_called()
        close.assert_called_once_with(91)

    def test_pidfd_close_failure_fails_closed_after_successful_signal(self) -> None:
        identity = run_xcode_tests.ProcessIdentity(2222, (10, 20))
        close_error = OSError("descriptor busy")
        with mock.patch.object(run_xcode_tests, "LIBPROC", None), mock.patch.object(
            run_xcode_tests.os, "pidfd_open", create=True, return_value=91
        ), mock.patch.object(
            run_xcode_tests, "current_direct_identity", return_value=identity
        ), mock.patch.object(
            run_xcode_tests.signal, "pidfd_send_signal", create=True
        ) as send, mock.patch.object(
            run_xcode_tests.os, "close", side_effect=close_error
        ):
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "Linux identity handle cleanup failed: descriptor busy",
            ) as raised:
                run_xcode_tests.signal_direct_identity(
                    identity, signal.SIGTERM, time.monotonic() + 1
                )
        self.assertIs(raised.exception.__cause__, close_error)
        send.assert_called_once_with(91, signal.SIGTERM, None, 0)

    def test_direct_darwin_pid_census_has_hard_deadline(self) -> None:
        entered = threading.Event()
        release = threading.Event()

        def stalled_census(*_args: object) -> list[int]:
            entered.set()
            release.wait(1)
            return []

        deadline = time.monotonic() + 0.02
        try:
            with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
                run_xcode_tests, "all_process_ids", side_effect=stalled_census
            ):
                with self.assertRaisesRegex(
                    run_xcode_tests.OperationDeadlineExpired,
                    "Darwin process census deadline expired",
                ):
                    run_xcode_tests.inspect_darwin_direct_descendants(set(), deadline)
            self.assertTrue(entered.is_set())
        finally:
            release.set()

    def test_direct_darwin_marker_census_has_hard_deadline(self) -> None:
        entered = threading.Event()
        release = threading.Event()

        def stalled_census(*_args: object) -> list[int]:
            entered.set()
            release.wait(1)
            return []

        deadline = time.monotonic() + 0.02
        try:
            with mock.patch.object(
                run_xcode_tests, "all_process_ids", side_effect=stalled_census
            ):
                with self.assertRaisesRegex(
                    run_xcode_tests.OperationDeadlineExpired,
                    "direct Darwin marker census deadline expired",
                ):
                    run_xcode_tests.inspect_marked_darwin_processes("marker", deadline)
            self.assertTrue(entered.is_set())
        finally:
            release.set()

    def test_darwin_marker_census_retains_hit_before_later_stall(self) -> None:
        descendant = darwin_direct_identity(901, 11, 7100841)
        observed: set[run_xcode_tests.ProcessIdentity] = set()
        entered = threading.Event()
        release = threading.Event()

        def inspect(pid: int, _marker: bytes) -> run_xcode_tests.ProcessIdentity | None:
            if pid == descendant.pid:
                return descendant
            entered.set()
            release.wait(1)
            return None

        deadline = time.monotonic() + 0.02
        try:
            with mock.patch.object(
                run_xcode_tests, "all_process_ids", return_value=[descendant.pid, 902]
            ), mock.patch.object(
                run_xcode_tests, "marked_darwin_process_identity", side_effect=inspect
            ):
                with self.assertRaisesRegex(
                    run_xcode_tests.OperationDeadlineExpired,
                    "direct Darwin marker census deadline expired",
                ):
                    run_xcode_tests.inspect_marked_darwin_processes(
                        "marker", deadline, observed
                    )
            self.assertTrue(entered.is_set())
            self.assertEqual(observed, {descendant})
        finally:
            release.set()

    def test_partial_marker_cleanup_census_retains_and_signals_hit(self) -> None:
        job = direct_job(Path("/tmp/partial-marker-cleanup"), "marker")
        descendant = darwin_direct_identity(901, 11, 7100841)
        errors: list[str] = []
        clock = [0.0]

        def partial_census(
            marker: str,
            deadline: float,
            observed: set[run_xcode_tests.ProcessIdentity],
        ) -> set[run_xcode_tests.ProcessIdentity]:
            self.assertEqual((marker, deadline), ("marker", 1.0))
            observed.add(descendant)
            raise run_xcode_tests.OperationDeadlineExpired("marker census expired")

        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests, "bounded_direct_children", return_value=set()
        ), mock.patch.object(
            run_xcode_tests, "inspect_marked_darwin_processes", side_effect=partial_census
        ), mock.patch.object(
            run_xcode_tests, "signal_direct_identity", return_value=True
        ) as send, mock.patch.object(
            run_xcode_tests.time, "monotonic", side_effect=lambda: clock[0]
        ), mock.patch.object(
            run_xcode_tests.time,
            "sleep",
            side_effect=lambda _duration: clock.__setitem__(0, 1.0),
        ):
            run_xcode_tests.drain_direct_job(job, 1.0, errors)
        self.assertIn(descendant, job.channel.descendants)
        send.assert_called_once_with(descendant, signal.SIGKILL, 1.0)
        self.assertEqual(
            errors, ["marker census expired", "direct process cleanup incomplete"]
        )

    def test_darwin_environment_marker_requires_exact_entry(self) -> None:
        integer_size = ctypes.sizeof(ctypes.c_int)
        arguments = (
            (2).to_bytes(integer_size, sys.byteorder, signed=True)
            + b"/bin/tool\0\0tool\0argument\0A=1\0"
            + b"POMODOROUGH_DIRECT_JOB=marker\0"
            + b"LOOK=POMODOROUGH_DIRECT_JOB=marker\0\0"
        )
        entries = run_xcode_tests.darwin_environment_entries(arguments)
        self.assertEqual(
            entries,
            {
                b"A=1",
                b"POMODOROUGH_DIRECT_JOB=marker",
                b"LOOK=POMODOROUGH_DIRECT_JOB=marker",
            },
        )
        self.assertNotIn(b"POMODOROUGH_DIRECT_JOB=missing", entries or set())

    def test_darwin_marker_requires_stable_process_identity(self) -> None:
        identity = darwin_direct_identity(900, 10, 7100840)
        marker = b"POMODOROUGH_DIRECT_JOB=marker"
        arguments = (
            (1).to_bytes(ctypes.sizeof(ctypes.c_int), sys.byteorder, signed=True)
            + b"/bin/tool\0\0tool\0"
            + marker
            + b"\0\0"
        )
        with mock.patch.object(
            run_xcode_tests, "direct_process_identity", side_effect=[identity, identity]
        ), mock.patch.object(
            run_xcode_tests, "darwin_process_arguments", return_value=arguments
        ):
            observed = run_xcode_tests.marked_darwin_process_identity(900, marker)
        self.assertEqual(observed, identity)

    def test_darwin_marker_accepts_same_process_after_exec(self) -> None:
        before_exec = darwin_direct_identity(900, 10, 7100837)
        after_exec = darwin_direct_identity(900, 10, 7100840)
        marker = b"POMODOROUGH_DIRECT_JOB=marker"
        arguments = (
            (1).to_bytes(ctypes.sizeof(ctypes.c_int), sys.byteorder, signed=True)
            + b"/bin/tool\0\0tool\0"
            + marker
            + b"\0\0"
        )
        with mock.patch.object(
            run_xcode_tests,
            "direct_process_identity",
            side_effect=[before_exec, after_exec],
        ), mock.patch.object(
            run_xcode_tests, "darwin_process_arguments", return_value=arguments
        ):
            observed = run_xcode_tests.marked_darwin_process_identity(900, marker)
        self.assertEqual(observed, after_exec)

    def test_darwin_marker_rejects_process_identity_churn(self) -> None:
        original = darwin_direct_identity(900, 10, 7100840)
        replacement = darwin_direct_identity(900, 11, 7100841)
        marker = b"POMODOROUGH_DIRECT_JOB=marker"
        arguments = (
            (1).to_bytes(ctypes.sizeof(ctypes.c_int), sys.byteorder, signed=True)
            + b"/bin/tool\0\0tool\0"
            + marker
            + b"\0\0"
        )
        with mock.patch.object(
            run_xcode_tests,
            "direct_process_identity",
            side_effect=[original, replacement],
        ), mock.patch.object(
            run_xcode_tests, "darwin_process_arguments", return_value=arguments
        ):
            observed = run_xcode_tests.marked_darwin_process_identity(900, marker)
        self.assertIsNone(observed)

    def test_darwin_marker_rejects_environment_value_lookalike(self) -> None:
        identity = darwin_direct_identity(900, 10, 7100840)
        marker = b"POMODOROUGH_DIRECT_JOB=marker"
        arguments = (
            (1).to_bytes(ctypes.sizeof(ctypes.c_int), sys.byteorder, signed=True)
            + b"/bin/tool\0\0tool\0"
            + b"LOOK=POMODOROUGH_DIRECT_JOB=marker\0\0"
        )
        with mock.patch.object(
            run_xcode_tests, "direct_process_identity", return_value=identity
        ) as inspect, mock.patch.object(
            run_xcode_tests, "darwin_process_arguments", return_value=arguments
        ):
            observed = run_xcode_tests.marked_darwin_process_identity(900, marker)
        self.assertIsNone(observed)
        inspect.assert_called_once_with(900)

    def test_direct_darwin_identity_lookup_has_hard_deadline(self) -> None:
        entered = threading.Event()
        release = threading.Event()

        def stalled_identity(_pid: int) -> object:
            entered.set()
            release.wait(1)
            return None

        deadline = time.monotonic() + 0.02
        try:
            with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
                run_xcode_tests, "all_process_ids", return_value=[42]
            ), mock.patch.object(
                run_xcode_tests,
                "stable_darwin_direct_ancestry",
                side_effect=stalled_identity,
            ):
                with self.assertRaisesRegex(
                    run_xcode_tests.OperationDeadlineExpired,
                    "direct Darwin process census deadline expired",
                ):
                    run_xcode_tests.inspect_darwin_direct_descendants(set(), deadline)
            self.assertTrue(entered.is_set())
        finally:
            release.set()

    def test_direct_darwin_census_uses_single_deadline_worker(self) -> None:
        process_ids = list(range(1, 501))

        def bounded(
            operation: Callable[[], object], _deadline: float, _message: str
        ) -> object:
            return operation()

        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests, "all_process_ids", return_value=process_ids
        ), mock.patch.object(
            run_xcode_tests, "stable_darwin_direct_ancestry", return_value=None
        ) as inspect, mock.patch.object(
            run_xcode_tests, "deadline_call", side_effect=bounded
        ) as deadline_call, mock.patch.object(
            run_xcode_tests.time, "monotonic", return_value=0.0
        ):
            descendants = run_xcode_tests.inspect_darwin_direct_descendants(set(), 1.0)
        self.assertEqual(descendants, set())
        self.assertEqual(inspect.call_count, len(process_ids))
        deadline_call.assert_called_once()

    def test_direct_darwin_descendant_closure_is_complete_with_budget(self) -> None:
        root, process_ids, records, expected = darwin_descendant_fixture()
        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests, "all_process_ids", return_value=process_ids
        ), mock.patch.object(
            run_xcode_tests,
            "stable_darwin_direct_ancestry",
            side_effect=lambda pid: records[pid],
        ), mock.patch.object(run_xcode_tests.time, "monotonic", return_value=0.0):
            descendants = run_xcode_tests.inspect_darwin_direct_descendants(
                {root}, 1.0
            )
        self.assertEqual(descendants, expected)

    def test_direct_darwin_descendant_closure_keeps_reparented_chain(self) -> None:
        def process_info(
            unique_id: int, id_version: int, original_parent_version: int
        ) -> run_xcode_tests.ProcUniqueIdentifierInfo:
            info = run_xcode_tests.ProcUniqueIdentifierInfo()
            info.p_uniqueid = unique_id
            info.p_puniqueid = 1
            info.p_idversion = id_version
            info.p_orig_ppidversion = original_parent_version
            return info

        root_token = [0] * 8
        root_token[5], root_token[7] = 900, 77
        root = run_xcode_tests.ProcessIdentity(900, (10, 0), tuple(root_token))
        infos = {
            901: process_info(11, 88, 77),
            902: process_info(12, 99, 88),
            903: process_info(13, 111, 66),
        }
        records = {
            pid: run_xcode_tests.DarwinDirectAncestry(
                darwin_direct_identity(pid, pid * 10, info.p_idversion),
                info.p_uniqueid,
                info.p_puniqueid,
                info.p_orig_ppidversion,
            )
            for pid, info in infos.items()
        }
        expected = {records[pid].identity for pid in (901, 902)}
        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests, "all_process_ids", return_value=list(infos)
        ), mock.patch.object(
            run_xcode_tests,
            "stable_darwin_direct_ancestry",
            side_effect=lambda pid: records[pid],
        ), mock.patch.object(run_xcode_tests.time, "monotonic", return_value=0.0):
            descendants = run_xcode_tests.inspect_darwin_direct_descendants(
                {root}, 1.0
            )
        self.assertEqual(descendants, expected)

    def test_hosted_direct_census_uses_post_exec_target_version(self) -> None:
        wrapper = darwin_direct_identity(800, 8, 7000000)
        pre_exec = darwin_direct_identity(900, 10, 7100837)
        post_exec = darwin_direct_identity(900, 10, 7100840)
        child_info = run_xcode_tests.ProcUniqueIdentifierInfo()
        child_info.p_uniqueid = 11
        child_info.p_puniqueid = 1
        child_info.p_idversion = 88
        child_info.p_orig_ppidversion = 7100840
        hosted_info = run_xcode_tests.ProcUniqueIdentifierInfo()
        hosted_info.p_uniqueid = 12
        hosted_info.p_puniqueid = 1
        hosted_info.p_idversion = 99
        hosted_info.p_orig_ppidversion = 88
        infos = {901: child_info, 902: hosted_info}
        channel = run_xcode_tests.DirectChannel(-1, b"key")
        for event, identity in (
            ("wrapper", wrapper),
            ("target", pre_exec),
            ("target-exec", post_exec),
        ):
            apply_authenticated_direct_payload(
                channel,
                {"event": event, "identity": run_xcode_tests.identity_payload(identity)},
            )
        job = run_xcode_tests.DirectJob(
            Path("/tmp/hosted-direct"), Path("/dev/null"), Path("/dev/null"),
            mock.Mock(spec=subprocess.Popen), wrapper, channel,
        )
        records = {
            pid: run_xcode_tests.DarwinDirectAncestry(
                darwin_direct_identity(pid, pid * 10, info.p_idversion),
                info.p_uniqueid,
                info.p_puniqueid,
                info.p_orig_ppidversion,
            )
            for pid, info in infos.items()
        }
        expected = {record.identity for record in records.values()}
        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests, "all_process_ids", return_value=list(infos)
        ), mock.patch.object(
            run_xcode_tests,
            "stable_darwin_direct_ancestry",
            side_effect=lambda pid: records[pid],
        ), mock.patch.object(
            run_xcode_tests, "bounded_direct_children", return_value=set()
        ), mock.patch.object(run_xcode_tests.time, "monotonic", return_value=0.0):
            self.assertEqual(
                run_xcode_tests.inspect_darwin_direct_descendants({pre_exec}, 1.0),
                set(),
            )
            descendants = run_xcode_tests.direct_descendant_census(job, 1.0)
        self.assertEqual(channel.target_identities, {pre_exec, post_exec})
        self.assertEqual(descendants, expected)

    def test_direct_darwin_descendant_closure_stops_on_expiring_clock(self) -> None:
        root, process_ids, records, _expected = darwin_descendant_fixture()
        clock_calls = 0

        def expiring_clock() -> float:
            nonlocal clock_calls
            clock_calls += 1
            return 1.0 if clock_calls >= 20 else 0.0

        with mock.patch.object(run_xcode_tests, "LIBPROC", object()), mock.patch.object(
            run_xcode_tests, "all_process_ids", return_value=process_ids
        ), mock.patch.object(
            run_xcode_tests,
            "stable_darwin_direct_ancestry",
            side_effect=lambda pid: records[pid],
        ), mock.patch.object(run_xcode_tests.time, "monotonic", expiring_clock):
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "direct Darwin process census deadline expired",
            ):
                run_xcode_tests.inspect_darwin_direct_descendants({root}, 1.0)
        self.assertEqual(clock_calls, 20)

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
            output = self.completed_contained_output(
                [sys.executable, "-c", source, escaped]
            )
            self.assertIn("SUBMIT_RC=1", output)
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

    def test_acknowledgement_fsync_timeout_fails_closed_without_overlap(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "fsync-entered"
            (root / "sitecustomize.py").write_text(
                textwrap.dedent(
                    """
                    import os
                    import sys
                    import time
                    if "--atomic-writer" in sys.argv:
                        def delayed_fsync(_descriptor):
                            open(os.environ["POMODOROUGH_FSYNC_MARKER"], "w").close()
                            time.sleep(30)
                        os.fsync = delayed_fsync
                    """
                ),
                encoding="utf-8",
            )
            job = launchd_job(root)
            deadline = time.monotonic() + 1.0
            original_popen = subprocess.Popen
            writers: list[subprocess.Popen[bytes]] = []

            def capture_writer(*arguments: object, **options: object) -> object:
                writer = original_popen(*arguments, **options)
                writers.append(writer)
                return writer

            environment = {
                "PYTHONPATH": str(root),
                "POMODOROUGH_FSYNC_MARKER": str(marker),
            }
            with mock.patch.dict(os.environ, environment), mock.patch.object(
                run_xcode_tests.subprocess, "Popen", side_effect=capture_writer
            ), self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError, "write deadline expired"
            ):
                run_xcode_tests.write_containment_acknowledgement(
                    job, "token", 77, deadline
                )
            finished = time.monotonic()
            self.assertTrue(marker.exists())
            self.assertFalse(job.acknowledgement_path.exists())
            self.assertEqual(list(root.glob("acknowledgement.*.tmp")), [])
        self.assertEqual(len(writers), 1)
        self.assertIsNotNone(writers[0].poll())
        self.assertLess(finished, deadline + 0.25)

    def test_atomic_stream_failures_remove_temporary_file(self) -> None:
        for operation in ("write", "flush"):
            with self.subTest(
                operation=operation
            ), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                target = root / "acknowledgement.json"
                temporary = explicit_atomic_temporary(target)
                real_fdopen = os.fdopen

                def failing_fdopen(descriptor: int, mode: str) -> mock.MagicMock:
                    real_stream = real_fdopen(descriptor, mode)
                    stream = mock.MagicMock(wraps=real_stream)
                    getattr(stream, operation).side_effect = OSError(
                        f"forced {operation} failure"
                    )
                    return stream

                with mock.patch.object(
                    run_xcode_tests.os, "fdopen", side_effect=failing_fdopen
                ), self.assertRaisesRegex(OSError, f"forced {operation} failure"):
                    run_xcode_tests.write_atomic_bytes(
                        target, b"acknowledgement", temporary
                    )
                self.assertEqual(list(root.iterdir()), [])

    def test_direct_atomic_writer_fsync_failure_removes_temporary_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "acknowledgement.json"
            target.write_bytes(b"original")
            temporary = explicit_atomic_temporary(target)
            with mock.patch.object(
                run_xcode_tests.os,
                "fsync",
                side_effect=OSError("forced fsync failure"),
            ):
                result, _ = invoke_atomic_writer(target, temporary)
            self.assertEqual(result, run_xcode_tests.PRETEST_INFRASTRUCTURE_FAILURE)
            self.assertEqual(target.read_bytes(), b"original")
            self.assertFalse(temporary.exists())

    def test_direct_atomic_writer_rejects_unowned_temporary_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "acknowledgement.json"
            target.write_bytes(b"original")
            valid_name = explicit_atomic_temporary(target).name
            paths = (
                target,
                root / "other" / valid_name,
                target.with_suffix(".0123456789abcdeg.tmp"),
                root / "nested" / ".." / valid_name,
            )
            for temporary in paths:
                with self.subTest(temporary=temporary):
                    result, stderr = invoke_atomic_writer(target, temporary)
                    self.assertEqual(
                        result, run_xcode_tests.PRETEST_INFRASTRUCTURE_FAILURE
                    )
                    self.assertIn("invalid atomic temporary path", stderr)
                    self.assertEqual(target.read_bytes(), b"original")

    def test_direct_atomic_writer_rejects_symlink_equivalent_temporary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "acknowledgement.json"
            target.write_bytes(b"original")
            temporary = explicit_atomic_temporary(target)
            temporary.symlink_to(target)
            result, stderr = invoke_atomic_writer(target, temporary)
            self.assertEqual(result, run_xcode_tests.PRETEST_INFRASTRUCTURE_FAILURE)
            self.assertIn("atomic temporary path already exists", stderr)
            self.assertEqual(target.read_bytes(), b"original")
            self.assertTrue(temporary.is_symlink())

    def test_direct_atomic_writer_rejects_destination_symlink_to_temp(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "acknowledgement.json"
            temporary = explicit_atomic_temporary(target)
            target.symlink_to(temporary)
            result, stderr = invoke_atomic_writer(target, temporary)
            self.assertEqual(result, run_xcode_tests.PRETEST_INFRASTRUCTURE_FAILURE)
            self.assertIn("atomic destination is not a regular file", stderr)
            self.assertEqual(target.readlink(), temporary)
            self.assertFalse(temporary.exists())

    def test_real_atomic_writer_rejects_unrelated_destination_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            unrelated = root / "unrelated.json"
            unrelated.write_bytes(b"unrelated")
            target = root / "acknowledgement.json"
            target.symlink_to(unrelated)
            temporary = explicit_atomic_temporary(target)
            result = subprocess.run(
                [sys.executable, RUNNER, "--atomic-writer", target, temporary],
                input=b"replacement",
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, run_xcode_tests.PRETEST_INFRASTRUCTURE_FAILURE)
            self.assertIn(b"atomic destination is not a regular file", result.stderr)
            self.assertEqual(target.readlink(), unrelated)
            self.assertEqual(unrelated.read_bytes(), b"unrelated")
            self.assertFalse(temporary.exists())

    def test_direct_atomic_writer_rejects_non_regular_destination(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "acknowledgement.json"
            target.mkdir()
            temporary = explicit_atomic_temporary(target)
            result, stderr = invoke_atomic_writer(target, temporary)
            self.assertEqual(result, run_xcode_tests.PRETEST_INFRASTRUCTURE_FAILURE)
            self.assertIn("atomic destination is not a regular file", stderr)
            self.assertTrue(target.is_dir())
            self.assertFalse(temporary.exists())

    def test_direct_atomic_writer_only_prepares_valid_temporary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "acknowledgement.json"
            target.write_bytes(b"original")
            temporary = explicit_atomic_temporary(target)
            result, stderr = invoke_atomic_writer(target, temporary)
            self.assertEqual(result, 0)
            self.assertEqual(stderr, "")
            self.assertEqual(target.read_bytes(), b"original")
            self.assertFalse(temporary.exists())

    def test_real_direct_atomic_writer_prepares_without_committing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "acknowledgement.json"
            target.write_bytes(b"original")
            temporary = explicit_atomic_temporary(target)
            result = subprocess.run(
                [sys.executable, RUNNER, "--atomic-writer", target, temporary],
                input=b"replacement",
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(target.read_bytes(), b"original")
            self.assertFalse(temporary.exists())

    def test_atomic_commit_replaces_absent_and_existing_destination(self) -> None:
        for original in (None, b"original"):
            with self.subTest(original=original), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                target = root / "acknowledgement.json"
                if original is not None:
                    target.write_bytes(original)
                run_xcode_tests.write_atomic_bytes(target, b"replacement")
                self.assertEqual(target.read_bytes(), b"replacement")
                self.assertEqual(list(root.glob("acknowledgement.*.tmp")), [])

    def test_atomic_commit_rejects_requested_directory_replacement(self) -> None:
        for phase in ("before", "during", "after"):
            for replacement in ("directory", "symlink"):
                for original in (None, b"original"):
                    with self.subTest(
                        phase=phase, replacement=replacement, original=original
                    ):
                        assert_atomic_directory_race(
                            self, phase, replacement, original
                        )

    def test_atomic_directory_fsync_failure_restores_destination(self) -> None:
        original_fsync = os.fsync

        def fail_directory_sync(descriptor: int) -> None:
            if stat.S_ISDIR(os.fstat(descriptor).st_mode):
                raise OSError("forced directory fsync failure")
            original_fsync(descriptor)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "acknowledgement.json"
            target.write_bytes(b"original")
            with mock.patch.object(
                run_xcode_tests.os, "fsync", side_effect=fail_directory_sync
            ), self.assertRaisesRegex(OSError, "forced directory fsync failure"):
                run_xcode_tests.write_atomic_bytes(target, b"replacement")
            self.assertEqual(target.read_bytes(), b"original")
            self.assertEqual(list(root.glob("acknowledgement.*.tmp")), [])

    def test_atomic_commit_rejects_final_entry_substitutions(self) -> None:
        replacements = ("symlink", "regular", "hardlink", "rename")
        for raced_entry in ("temporary", "destination"):
            for had_destination in (False, True):
                for replacement in replacements:
                    with self.subTest(
                        entry=raced_entry,
                        existing=had_destination,
                        replacement=replacement,
                    ), tempfile.TemporaryDirectory() as directory:
                        root = Path(directory)
                        target = root / "acknowledgement.json"
                        if had_destination:
                            target.write_bytes(b"original")
                        temporary = explicit_atomic_temporary(target)
                        attacker = root / "attacker.json"
                        attacker.write_bytes(b"attacker")
                        raced_path = temporary if raced_entry == "temporary" else target
                        rename = atomic_race_rename(raced_path, attacker, replacement)
                        with mock.patch.object(
                            run_xcode_tests, "rename_atomic_entries", side_effect=rename
                        ), self.assertRaises(OSError):
                            run_xcode_tests.write_atomic_bytes(
                                target, b"replacement", temporary
                            )
                        assert_atomic_race_outcome(
                            self, target, temporary, attacker,
                            raced_entry, replacement, had_destination,
                        )

    def test_atomic_rollback_rejects_displaced_entry_replacement(self) -> None:
        for replacement in ("symlink", "regular", "hardlink", "rename"):
            with self.subTest(replacement=replacement):
                assert_displaced_temp_replacement_rejected(self, replacement)

    def test_atomic_rollback_rejects_last_boundary_substitutions(self) -> None:
        for raced_entry in ("destination", "temporary"):
            with self.subTest(entry=raced_entry):
                assert_rollback_substitution_rejected(self, raced_entry)

    def test_atomic_namespace_mutations_are_synced_in_order(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "acknowledgement.json"
            target.write_bytes(b"original")
            events: list[str] = []
            original_fsync = os.fsync
            original_rename = run_xcode_tests.rename_atomic_entries
            original_unlink = os.unlink

            def record_sync(descriptor: int) -> None:
                kind = "directory-sync" if stat.S_ISDIR(os.fstat(descriptor).st_mode) else "file-sync"
                events.append(kind)
                original_fsync(descriptor)

            def record_rename(*arguments: object) -> None:
                events.append("rename")
                original_rename(*arguments)  # type: ignore[arg-type]

            def record_unlink(*arguments: object, **options: object) -> None:
                events.append("unlink")
                original_unlink(*arguments, **options)  # type: ignore[arg-type]

            with mock.patch.object(
                run_xcode_tests.os, "fsync", side_effect=record_sync
            ), mock.patch.object(
                run_xcode_tests, "rename_atomic_entries", side_effect=record_rename
            ), mock.patch.object(
                run_xcode_tests.os, "unlink", side_effect=record_unlink
            ):
                run_xcode_tests.write_atomic_bytes(target, b"replacement")
            self.assertEqual(
                events,
                ["file-sync", "rename", "directory-sync", "unlink", "directory-sync"],
            )

    def test_atomic_rollback_namespace_mutations_are_synced_in_order(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "acknowledgement.json"
            target.write_bytes(b"original")
            events: list[str] = []
            original_fsync = os.fsync
            original_rename = run_xcode_tests.rename_atomic_entries
            original_unlink = os.unlink
            directory_syncs = 0

            def record_sync(descriptor: int) -> None:
                nonlocal directory_syncs
                is_directory = stat.S_ISDIR(os.fstat(descriptor).st_mode)
                events.append("directory-sync" if is_directory else "file-sync")
                if is_directory:
                    directory_syncs += 1
                    if directory_syncs == 1:
                        raise OSError("forced commit sync failure")
                original_fsync(descriptor)

            def record_rename(*arguments: object) -> None:
                events.append("rename")
                original_rename(*arguments)  # type: ignore[arg-type]

            def record_unlink(*arguments: object, **options: object) -> None:
                events.append("unlink")
                original_unlink(*arguments, **options)  # type: ignore[arg-type]

            with mock.patch.object(
                run_xcode_tests.os, "fsync", side_effect=record_sync
            ), mock.patch.object(
                run_xcode_tests, "rename_atomic_entries", side_effect=record_rename
            ), mock.patch.object(
                run_xcode_tests.os, "unlink", side_effect=record_unlink
            ), self.assertRaisesRegex(OSError, "forced commit sync failure"):
                run_xcode_tests.write_atomic_bytes(target, b"replacement")
            self.assertEqual(target.read_bytes(), b"original")
            self.assertEqual(
                events,
                [
                    "file-sync", "rename", "directory-sync", "rename",
                    "directory-sync", "unlink", "directory-sync",
                ],
            )

    def test_atomic_cleanup_sync_failure_rejects_committed_success(self) -> None:
        original_fsync = os.fsync
        directory_syncs = 0

        def fail_cleanup_sync(descriptor: int) -> None:
            nonlocal directory_syncs
            if stat.S_ISDIR(os.fstat(descriptor).st_mode):
                directory_syncs += 1
                if directory_syncs == 2:
                    raise OSError("forced cleanup sync failure")
            original_fsync(descriptor)

        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "acknowledgement.json"
            target.write_bytes(b"original")
            with mock.patch.object(
                run_xcode_tests.os, "fsync", side_effect=fail_cleanup_sync
            ), self.assertRaisesRegex(OSError, "forced cleanup sync failure"):
                run_xcode_tests.write_atomic_bytes(target, b"replacement")
            self.assertEqual(target.read_bytes(), b"replacement")
            self.assertEqual(list(Path(directory).glob("*.tmp")), [])

    def test_atomic_cleanup_sync_failure_preserves_commit_error(self) -> None:
        original_fsync = os.fsync
        primary = OSError("forced commit sync failure")
        directory_syncs = 0

        def fail_namespace_syncs(descriptor: int) -> None:
            nonlocal directory_syncs
            if stat.S_ISDIR(os.fstat(descriptor).st_mode):
                directory_syncs += 1
                if directory_syncs == 1:
                    raise primary
                if directory_syncs == 3:
                    raise OSError("forced cleanup sync failure")
            original_fsync(descriptor)

        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "acknowledgement.json"
            target.write_bytes(b"original")
            with mock.patch.object(
                run_xcode_tests.os, "fsync", side_effect=fail_namespace_syncs
            ), self.assertRaises(OSError) as raised:
                run_xcode_tests.write_atomic_bytes(target, b"replacement")
            self.assertIs(raised.exception, primary)
            self.assertIn("forced cleanup sync failure", str(primary))
            self.assertEqual(target.read_bytes(), b"original")
            self.assertEqual(list(Path(directory).glob("*.tmp")), [])

    def test_atomic_writer_rejects_intermediate_symlink_alias(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            actual = root / "actual"
            actual.mkdir()
            alias = root / "alias"
            alias.symlink_to(actual, target_is_directory=True)
            target = alias / "acknowledgement.json"
            temporary = explicit_atomic_temporary(target)
            result = subprocess.run(
                [sys.executable, RUNNER, "--atomic-writer", target, temporary],
                input=b"replacement",
                capture_output=True,
                check=False,
            )
            self.assertEqual(
                result.returncode, run_xcode_tests.PRETEST_INFRASTRUCTURE_FAILURE
            )
            self.assertRegex(
                result.stderr, rb"(Not a directory|Too many levels of symbolic links)"
            )
            self.assertEqual(list(actual.iterdir()), [])

    def test_inherited_atomic_writer_close_failure_preserves_write_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "acknowledgement.json"
            temporary = explicit_atomic_temporary(target)
            write = run_xcode_tests.open_atomic_write(target, temporary)
            descriptor = os.dup(write.descriptor)
            directory_descriptor = os.dup(write.directory_descriptor)
            primary = OSError("primary write failure")
            original_close = os.close

            def fail_inherited_close(candidate: int) -> None:
                if candidate in {descriptor, directory_descriptor}:
                    raise OSError("forced inherited close failure")
                original_close(candidate)

            try:
                with mock.patch.object(
                    run_xcode_tests, "write_atomic_descriptor", side_effect=primary
                ), mock.patch.object(
                    run_xcode_tests.os,
                    "close",
                    side_effect=fail_inherited_close,
                ), self.assertRaises(OSError) as raised:
                    run_xcode_tests.write_inherited_atomic_temporary(
                        target, temporary, descriptor, directory_descriptor, b"payload"
                    )
                self.assertIs(raised.exception, primary)
                self.assertIn("primary write failure", str(primary))
                self.assertIn("forced inherited close failure", str(primary))
            finally:
                original_close(descriptor)
                original_close(directory_descriptor)
                run_xcode_tests.close_atomic_write(write, None)

    def test_atomic_replace_failure_removes_temporary_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "acknowledgement.json"
            with mock.patch.object(
                run_xcode_tests,
                "rename_atomic_entries",
                side_effect=OSError("forced replace failure"),
            ), self.assertRaisesRegex(OSError, "forced replace failure"):
                run_xcode_tests.write_atomic_bytes(target, b"acknowledgement")
            self.assertEqual(list(root.iterdir()), [])

    def test_atomic_cleanup_failure_does_not_mask_primary_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "acknowledgement.json"
            target.write_bytes(b"original")
            with mock.patch.object(
                run_xcode_tests.os,
                "fsync",
                side_effect=OSError("primary fsync failure"),
            ), mock.patch.object(
                run_xcode_tests.os,
                "unlink",
                side_effect=OSError("cleanup unlink failure"),
            ), self.assertRaisesRegex(
                OSError,
                "primary fsync failure; atomic temporary cleanup failed: "
                "cleanup unlink failure",
            ):
                run_xcode_tests.write_atomic_bytes(target, b"acknowledgement")
            self.assertEqual(target.read_bytes(), b"original")
            self.assertEqual(len(list(Path(directory).glob("*.tmp"))), 1)

    def test_atomic_cleanup_failure_surfaces_without_primary_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "acknowledgement.json"
            target.write_bytes(b"original")
            temporary = explicit_atomic_temporary(target)
            cleanup = OSError("cleanup unlink failure")
            with mock.patch.object(
                run_xcode_tests, "commit_atomic_write"
            ), mock.patch.object(
                run_xcode_tests.os, "unlink", side_effect=cleanup
            ), self.assertRaisesRegex(OSError, "cleanup unlink failure") as raised:
                run_xcode_tests.write_atomic_bytes(
                    target, b"acknowledgement", temporary
                )
            self.assertIs(raised.exception, cleanup)
            self.assertEqual(target.read_bytes(), b"original")
            self.assertTrue(temporary.exists())

    def test_bounded_atomic_timeout_preserves_primary_and_removes_temp(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "acknowledgement.json"
            target.write_bytes(b"original")
            temporary = explicit_atomic_temporary(target)
            process = mock.Mock(spec=subprocess.Popen)
            process.args = ["atomic-writer"]
            process.communicate.side_effect = subprocess.TimeoutExpired([], 1)
            process.stdin = mock.Mock()
            process.stderr = mock.Mock()
            cleanup = OSError("containment acknowledgement writer could not be terminated")
            with mock.patch.object(
                run_xcode_tests, "atomic_temporary_path", return_value=temporary
            ), mock.patch.object(
                run_xcode_tests.subprocess, "Popen", return_value=process
            ), mock.patch.object(
                run_xcode_tests, "terminate_bounded_writer", side_effect=cleanup
            ), self.assertRaisesRegex(
                OSError,
                "containment acknowledgement write deadline expired; containment "
                "acknowledgement writer cleanup failed: containment acknowledgement "
                "writer could not be terminated",
            ) as raised:
                run_xcode_tests.write_bytes_bounded(
                    target,
                    b"acknowledgement",
                    time.monotonic() + 1,
                    run_xcode_tests.ATOMIC_WRITER_ARGUMENT,
                    "containment acknowledgement",
                )
            self.assertIsInstance(raised.exception.__cause__, subprocess.TimeoutExpired)
            self.assertEqual(target.read_bytes(), b"original")
            self.assertFalse(temporary.exists())

    def test_bounded_atomic_timeout_blocks_late_child_commit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "acknowledgement.json"
            target.write_bytes(b"original")
            temporary = explicit_atomic_temporary(target)
            release = threading.Event()
            finished = threading.Event()
            commit_errors: list[OSError] = []
            threads: list[threading.Thread] = []
            spawn = late_atomic_commit_popen(release, finished, commit_errors, threads)
            with mock.patch.object(
                run_xcode_tests, "atomic_temporary_path", return_value=temporary
            ), mock.patch.object(
                run_xcode_tests.subprocess, "Popen", side_effect=spawn
            ), mock.patch.object(
                run_xcode_tests.os, "killpg", side_effect=OSError("forced kill failure")
            ), self.assertRaises(OSError) as raised:
                run_xcode_tests.write_bytes_bounded(
                    target,
                    b"replacement",
                    time.monotonic() + 0.2,
                    run_xcode_tests.ATOMIC_WRITER_ARGUMENT,
                    "containment acknowledgement",
                )
            message = str(raised.exception)
            self.assertIn("write deadline expired", message)
            self.assertIn("forced kill failure", message)
            self.assertIn("could not be terminated", message)
            self.assertIn("forced stdin close failure", message)
            self.assertIn("forced stderr close failure", message)
            self.assertIsInstance(raised.exception.__cause__, subprocess.TimeoutExpired)
            release.set()
            self.assertTrue(finished.wait(1))
            threads[0].join(1)
            self.assertIsInstance(commit_errors[0], FileNotFoundError)
            self.assertEqual(target.read_bytes(), b"original")
            self.assertFalse(temporary.exists())

    def test_bounded_atomic_rejects_temporary_substitution(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "acknowledgement.json"
            target.write_bytes(b"original")
            attacker = root / "attacker.json"
            attacker.write_bytes(b"attacker")
            temporary = explicit_atomic_temporary(target)
            process = mock.Mock(spec=subprocess.Popen)
            process.returncode = 0

            def substitute(*_arguments: object) -> bytes:
                temporary.unlink()
                temporary.symlink_to(attacker)
                return b""

            with mock.patch.object(
                run_xcode_tests, "atomic_temporary_path", return_value=temporary
            ), mock.patch.object(
                run_xcode_tests.subprocess, "Popen", return_value=process
            ), mock.patch.object(
                run_xcode_tests, "communicate_bounded_writer", side_effect=substitute
            ), self.assertRaisesRegex(OSError, "untrusted atomic temporary file"):
                run_xcode_tests.write_bytes_bounded(
                    target,
                    b"replacement",
                    time.monotonic() + 1,
                    run_xcode_tests.ATOMIC_WRITER_ARGUMENT,
                    "containment acknowledgement",
                )
            self.assertEqual(target.read_bytes(), b"original")
            self.assertEqual(attacker.read_bytes(), b"attacker")
            self.assertTrue(temporary.is_symlink())

    def test_bounded_atomic_parent_replace_failure_removes_temp(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "acknowledgement.json"
            target.write_bytes(b"original")
            with mock.patch.object(
                run_xcode_tests,
                "rename_atomic_entries",
                side_effect=OSError("forced parent replace failure"),
            ), self.assertRaisesRegex(OSError, "forced parent replace failure"):
                run_xcode_tests.write_bytes_bounded(
                    target,
                    b"replacement",
                    time.monotonic() + 1,
                    run_xcode_tests.ATOMIC_WRITER_ARGUMENT,
                    "containment acknowledgement",
                )
            self.assertEqual(target.read_bytes(), b"original")
            self.assertEqual(list(root.glob("acknowledgement.*.tmp")), [])

    def test_bounded_atomic_directory_sync_completes_before_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "acknowledgement.json"
            target.write_bytes(b"original")
            environment = directory_sync_control_environment(root, ("ok", "ok"))
            with mock.patch.dict(os.environ, environment):
                run_xcode_tests.write_bytes_bounded(
                    target,
                    b"replacement",
                    time.monotonic() + 1,
                    run_xcode_tests.ATOMIC_WRITER_ARGUMENT,
                    "containment acknowledgement",
                )
            self.assertEqual(target.read_bytes(), b"replacement")
            self.assertEqual((root / "directory-sync-control").read_text(), "2")
            self.assertEqual(list(root.glob("acknowledgement.*.tmp")), [])

    def test_bounded_atomic_commit_sync_hang_obeys_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "acknowledgement.json"
            target.write_bytes(b"original")
            environment = directory_sync_control_environment(root, ("hang",))
            deadline = time.monotonic() + 0.75
            with mock.patch.dict(os.environ, environment), self.assertRaisesRegex(
                OSError, "directory synchronization write deadline expired"
            ):
                run_xcode_tests.write_bytes_bounded(
                    target,
                    b"replacement",
                    deadline,
                    run_xcode_tests.ATOMIC_WRITER_ARGUMENT,
                    "containment acknowledgement",
                )
            self.assertLess(time.monotonic(), deadline + 0.25)
            self.assertEqual(target.read_bytes(), b"original")
            self.assertEqual(list(root.glob("acknowledgement.*.tmp")), [])
            assert_hung_sync_reaped(self, root)

    def test_bounded_atomic_cleanup_sync_hang_rejects_success(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "acknowledgement.json"
            target.write_bytes(b"original")
            environment = directory_sync_control_environment(root, ("ok", "hang"))
            deadline = time.monotonic() + 0.75
            with mock.patch.dict(os.environ, environment), self.assertRaisesRegex(
                OSError, "cleanup write deadline expired"
            ):
                run_xcode_tests.write_bytes_bounded(
                    target,
                    b"replacement",
                    deadline,
                    run_xcode_tests.ATOMIC_WRITER_ARGUMENT,
                    "containment acknowledgement",
                )
            self.assertLess(time.monotonic(), deadline + 0.25)
            self.assertEqual(target.read_bytes(), b"replacement")
            self.assertEqual(list(root.glob("acknowledgement.*.tmp")), [])
            assert_hung_sync_reaped(self, root)

    def test_bounded_atomic_rollback_sync_hang_preserves_primary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "acknowledgement.json"
            target.write_bytes(b"original")
            environment = directory_sync_control_environment(root, ("error", "hang"))
            deadline = time.monotonic() + 0.75
            with mock.patch.dict(os.environ, environment), self.assertRaises(
                OSError
            ) as raised:
                run_xcode_tests.write_bytes_bounded(
                    target,
                    b"replacement",
                    deadline,
                    run_xcode_tests.ATOMIC_WRITER_ARGUMENT,
                    "containment acknowledgement",
                )
            self.assertLess(time.monotonic(), deadline + 0.25)
            self.assertIn("forced directory sync failure", str(raised.exception))
            self.assertIn("rollback failed", str(raised.exception))
            self.assertIn("deadline expired", str(raised.exception))
            self.assertEqual(target.read_bytes(), b"original")
            self.assertEqual(list(root.glob("acknowledgement.*.tmp")), [])
            assert_hung_sync_reaped(self, root)

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

    def test_launchd_domain_failure_does_not_create_job_root(self) -> None:
        failure = run_xcode_tests.SimulatorLifecycleError("domain unavailable")
        with mock.patch.object(
            run_xcode_tests, "launchd_domain", side_effect=failure
        ), mock.patch.object(run_xcode_tests.tempfile, "mkdtemp") as create_root:
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError, "domain unavailable"
            ) as raised:
                run_xcode_tests.create_launchd_job()
        self.assertIs(raised.exception, failure)
        create_root.assert_not_called()

    def test_launchctl_returned_command_reaps_lingering_descendant(self) -> None:
        source = (
            "import subprocess,sys; "
            "child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],"
            "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True); "
            "print(child.pid,flush=True)"
        )
        with mock.patch.object(run_xcode_tests, "LAUNCHCTL", sys.executable):
            result = run_xcode_tests.launchctl_run(
                ["-c", source], launchctl_test_deadline(4), 2
            )
        child_pid = int(result.stdout.strip())
        try:
            self.assertTrue(self.wait_until_process_exits(child_pid))
        finally:
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_launchctl_reaps_reparented_late_descendant(self) -> None:
        grandchild = "import time;time.sleep(30)"
        intermediary = (
            "import subprocess,sys; "
            f"child=subprocess.Popen([sys.executable,'-c',{grandchild!r}],"
            "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True); "
            "print(child.pid,flush=True)"
        )
        source = (
            "import subprocess,sys; "
            f"middle=subprocess.run([sys.executable,'-c',{intermediary!r}],"
            "capture_output=True,text=True,check=True); print(middle.stdout,flush=True)"
        )
        with mock.patch.object(run_xcode_tests, "LAUNCHCTL", sys.executable):
            result = run_xcode_tests.launchctl_run(
                ["-c", source], launchctl_test_deadline(4), 2
            )
        child_pid = int(result.stdout.strip())
        try:
            self.assertTrue(self.wait_until_process_exits(child_pid))
        finally:
            try:
                os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_launchctl_total_deadline_includes_nested_cleanup(self) -> None:
        authenticate_by, command_seconds, cleanup_by = (
            run_xcode_tests.launchctl_deadlines(10.0, 26.0, 10.0, None)
        )
        self.assertEqual(authenticate_by, 14.0)
        self.assertEqual(command_seconds, 10.0)
        self.assertEqual(cleanup_by, 26.0)
        self.assertEqual(
            cleanup_by - authenticate_by - command_seconds,
            run_xcode_tests.LAUNCHCTL_PROCESS_CLEANUP_SECONDS,
        )

    def test_lifecycle_bootstrap_accepts_delays_through_ten_seconds(self) -> None:
        for delay in (2.01, 10.0):
            with self.subTest(delay=delay):
                result = simulated_launchctl_delay(delay)
                self.assertEqual(result.returncode, 0)

    def test_lifecycle_bootstrap_rejects_delay_over_ten_seconds(self) -> None:
        with self.assertRaisesRegex(
            run_xcode_tests.SimulatorLifecycleError, "launchctl timed out"
        ):
            simulated_launchctl_delay(10.01)

    def test_timeout_evidence_probe_cannot_enter_cleanup_reserve(self) -> None:
        clock = [18.0]
        wall_deadline = 33.75
        with mock.patch.object(
            run_xcode_tests.time, "monotonic", side_effect=lambda: clock[0]
        ), mock.patch.object(run_xcode_tests, "launchctl_result") as launch:
            evidence_deadline = run_xcode_tests.process_evidence_deadline(
                wall_deadline
            )
            evidence = run_xcode_tests.launchd_job_evidence(
                launchd_job(Path("/tmp/ap13-evidence")), evidence_deadline
            )
        self.assertEqual(evidence_deadline - clock[0], 0.25)
        self.assertEqual(
            wall_deadline - evidence_deadline,
            run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS,
        )
        self.assertIn("launchd containment deadline expired", evidence)
        launch.assert_not_called()

    def test_launchctl_timeout_reaps_real_authenticated_process_tree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target_path, child_path = root / "target.pid", root / "child.pid"
            grandchild = "import time;time.sleep(30)"
            intermediary = (
                "import pathlib,subprocess,sys; "
                f"child=subprocess.Popen([sys.executable,'-c',{grandchild!r}],"
                "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True); "
                "pathlib.Path(sys.argv[1]).write_text(str(child.pid))"
            )
            source = (
                "import os,pathlib,subprocess,sys,time; "
                "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); "
                f"subprocess.run([sys.executable,'-c',{intermediary!r},sys.argv[2]],check=True); "
                "time.sleep(30)"
            )
            jobs: list[run_xcode_tests.DirectJob] = []
            spawn_direct_job = run_xcode_tests.spawn_direct_job

            def capture_job(*args: object, **kwargs: object) -> object:
                job = spawn_direct_job(*args, **kwargs)
                jobs.append(job)
                return job

            started = time.monotonic()
            finish_by = started + 1
            cleanup_by = finish_by + run_xcode_tests.LAUNCHCTL_PROCESS_CLEANUP_SECONDS
            with mock.patch.object(run_xcode_tests, "LAUNCHCTL", sys.executable), mock.patch.object(
                run_xcode_tests, "spawn_direct_job", side_effect=capture_job
            ):
                with self.assertRaises(run_xcode_tests.SimulatorLifecycleError) as raised:
                    run_xcode_tests.launchctl_run(
                        ["-c", source, str(target_path), str(child_path)],
                        finish_by, 1, cleanup_by,
                    )
            elapsed = time.monotonic() - started
            pids = [jobs[0].identity.pid, int(target_path.read_text()), int(child_path.read_text())]
        self.assertEqual(str(raised.exception), "launchctl timed out")
        self.assertIsInstance(raised.exception.__cause__, subprocess.TimeoutExpired)
        self.assertGreater(
            run_xcode_tests.LAUNCHCTL_PROCESS_CLEANUP_SECONDS,
            jobs[0].wrapper_reap_seconds,
        )
        self.assertLess(
            elapsed,
            1.25 + run_xcode_tests.LAUNCHCTL_PROCESS_CLEANUP_SECONDS,
        )
        self.assertTrue(all(self.wait_until_process_exits(pid) for pid in pids))

    def test_launchctl_near_deadline_return_reaps_late_descendant(self) -> None:
        source = (
            "import subprocess,sys,time; time.sleep(0.35); "
            "child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],"
            "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True); "
            "print(child.pid,flush=True)"
        )
        jobs: list[run_xcode_tests.DirectJob] = []
        spawn_direct_job = run_xcode_tests.spawn_direct_job

        def capture_job(*args: object, **kwargs: object) -> object:
            job = spawn_direct_job(*args, **kwargs)
            jobs.append(job)
            return job

        started = time.monotonic()
        command_by = (
            started + run_xcode_tests.LAUNCHCTL_AUTHENTICATION_SECONDS + 0.8
        )
        cleanup_by = command_by + run_xcode_tests.LAUNCHCTL_PROCESS_CLEANUP_SECONDS
        with mock.patch.object(run_xcode_tests, "LAUNCHCTL", sys.executable), mock.patch.object(
            run_xcode_tests, "spawn_direct_job", side_effect=capture_job
        ):
            result = run_xcode_tests.launchctl_run(
                ["-c", source], command_by, 0.8, cleanup_by
            )
        child_pid = int(result.stdout.strip())
        target_pid = jobs[0].channel.target.pid if jobs[0].channel.target else -1
        self.assertLess(time.monotonic() - started, 1.4)
        self.assertTrue(all(self.wait_until_process_exits(pid) for pid in (
            jobs[0].identity.pid, target_pid, child_pid,
        )))

    def test_launchctl_retry_bounds_timeout_and_reap_to_one_deadline(self) -> None:
        timeout = subprocess.TimeoutExpired(
            ["launchctl"], run_xcode_tests.LAUNCHCTL_RETRY_SECONDS
        )
        failure = run_xcode_tests.SimulatorLifecycleError("launchctl timed out")
        failure.__cause__ = timeout
        clock = [10.0]

        def launchctl(*arguments: object) -> subprocess.CompletedProcess[str]:
            clock[0] = 13.0
            raise failure

        with mock.patch.object(
            run_xcode_tests.time, "monotonic", side_effect=lambda: clock[0]
        ), mock.patch.object(run_xcode_tests, "launchctl_run", side_effect=launchctl) as run:
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError, "launchctl timed out"
            ):
                run_xcode_tests.launchctl_retry(["print", "service"], 13.0)
        run.assert_called_once_with(
            ["print", "service"],
            11.0,
            run_xcode_tests.LAUNCHCTL_RETRY_SECONDS,
            13.0,
        )

    def test_launchctl_retry_requires_authenticated_cleanup_budget(self) -> None:
        deadline = 10.0 + run_xcode_tests.LAUNCHCTL_PROCESS_CLEANUP_SECONDS
        with mock.patch.object(
            run_xcode_tests.time, "monotonic", return_value=10.0
        ), mock.patch.object(run_xcode_tests, "launchctl_run") as launch:
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "launchd containment deadline expired",
            ):
                run_xcode_tests.launchctl_retry(["print", "service"], deadline)
        launch.assert_not_called()

    def test_launchctl_timeout_cleanup_failure_takes_precedence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            job = direct_job(Path(directory) / "job")
            job.root.mkdir()
            job.stdout_path.write_text("partial", encoding="utf-8")
            job.stderr_path.write_text("", encoding="utf-8")
            cleanup_error = run_xcode_tests.SimulatorLifecycleError(
                "direct process cleanup incomplete"
            )
            with mock.patch.object(
                run_xcode_tests,
                "spawn_direct_job",
                side_effect=authenticated_direct_spawn(job),
            ), mock.patch.object(
                run_xcode_tests, "wait_for_direct_status", return_value=None
            ), mock.patch.object(
                run_xcode_tests, "cleanup_direct_job", side_effect=cleanup_error
            ):
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError,
                    "launchctl timeout cleanup failed: direct process cleanup incomplete",
                ) as raised:
                    run_xcode_tests.launchctl_run([], launchctl_test_deadline(), 0.2)
        self.assertIsInstance(
            raised.exception.__cause__, run_xcode_tests.SimulatorLifecycleError
        )

    def test_launchctl_success_requires_complete_direct_cleanup(self) -> None:
        job = direct_job(Path("/tmp/ap12-launchctl-success"))
        completion = run_xcode_tests.DirectCompletion(
            0, "service stopped", "", "direct process cleanup incomplete"
        )
        with mock.patch.object(
            run_xcode_tests,
            "spawn_direct_job",
            side_effect=authenticated_direct_spawn(job),
        ), mock.patch.object(
            run_xcode_tests, "complete_direct_job", return_value=completion
        ):
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError,
                "launchctl process cleanup failed: direct process cleanup incomplete",
            ):
                run_xcode_tests.launchctl_run([], launchctl_test_deadline(), 0.2)

    def test_launchctl_failure_cleanup_evidence_blocks_absence_match(self) -> None:
        job = direct_job(Path("/tmp/ap12-launchctl-failure"))
        completion = run_xcode_tests.DirectCompletion(
            113,
            "",
            "Could not find service\n",
            "direct process cleanup incomplete",
        )
        with mock.patch.object(
            run_xcode_tests,
            "spawn_direct_job",
            side_effect=authenticated_direct_spawn(job),
        ), mock.patch.object(
            run_xcode_tests, "complete_direct_job", return_value=completion
        ):
            result = run_xcode_tests.launchctl_run([], launchctl_test_deadline(), 0.2)
        self.assertEqual(result.returncode, 113)
        self.assertIn("launchctl process cleanup failed", result.stderr)
        self.assertFalse(run_xcode_tests.bootout_result_is_absent(result))

    def test_launchctl_preserves_authenticated_target_exec_generations(self) -> None:
        wrapper = darwin_direct_identity(800, 8, 7000000)
        before_exec = darwin_direct_identity(900, 10, 7100837)
        after_exec = darwin_direct_identity(900, 10, 7100840)
        channel = run_xcode_tests.DirectChannel(-1, b"key")
        for event, identity in (
            ("wrapper", wrapper),
            ("target", before_exec),
            ("target-exec", after_exec),
        ):
            apply_authenticated_direct_payload(
                channel,
                {"event": event, "identity": run_xcode_tests.identity_payload(identity)},
            )
        job = run_xcode_tests.DirectJob(
            Path("/tmp/ap12-launchctl"), Path("/dev/null"), Path("/dev/null"),
            mock.Mock(spec=subprocess.Popen), wrapper, channel,
        )

        def complete(candidate: run_xcode_tests.DirectJob, *_: object) -> object:
            self.assertEqual(candidate.channel.target_identities, {before_exec, after_exec})
            return run_xcode_tests.DirectCompletion(0, "", "", None)

        with mock.patch.object(
            run_xcode_tests,
            "spawn_direct_job",
            side_effect=authenticated_direct_spawn(job),
        ), mock.patch.object(
            run_xcode_tests, "complete_direct_job", side_effect=complete
        ):
            result = run_xcode_tests.launchctl_run([], launchctl_test_deadline(), 0.2)
        self.assertEqual(result.returncode, 0)

    def test_launchctl_accepts_slow_authentication_before_command_budget(self) -> None:
        job = direct_job(Path("/tmp/ap12-launchctl-authentication"))
        clock = [10.0]

        def spawn(*_arguments: object, **options: object) -> run_xcode_tests.DirectJob:
            clock[0] = 12.25
            callback = options["authenticated"]
            assert callable(callback)
            callback()
            return job

        completion = run_xcode_tests.DirectCompletion(0, "", "", None)
        with mock.patch.object(
            run_xcode_tests.time, "monotonic", side_effect=lambda: clock[0]
        ), mock.patch.object(
            run_xcode_tests, "spawn_direct_job", side_effect=spawn
        ), mock.patch.object(
            run_xcode_tests, "complete_direct_job", return_value=completion
        ) as complete:
            run_xcode_tests.launchctl_run([], 15.0, 1.0, 17.0)
        complete.assert_called_once_with(job, 1.0, 15.25, 2.0)

    def test_bootout_reserves_full_direct_authentication_after_drain(self) -> None:
        job = direct_job(Path("/tmp/ap12-bootout-authentication"))
        clock = [10.0]
        authentication_windows: list[float] = []

        def spawn(*arguments: object, **options: object) -> object:
            deadline, cleanup_reserve = arguments[1:3]
            assert isinstance(deadline, float)
            assert isinstance(cleanup_reserve, float)
            authenticate_by = deadline - cleanup_reserve
            authentication_windows.append(authenticate_by - clock[0])
            clock[0] = authenticate_by
            callback = options.get("authenticated")
            assert callable(callback)
            callback()
            return job

        completion = run_xcode_tests.DirectCompletion(0, "", "", None)
        bootout_by = clock[0] + run_xcode_tests.CONTAINMENT_BOOTOUT_RESERVE_SECONDS
        cleanup_by = bootout_by + run_xcode_tests.LAUNCHCTL_PROCESS_CLEANUP_SECONDS
        with mock.patch.object(
            run_xcode_tests.time, "monotonic", side_effect=lambda: clock[0]
        ), mock.patch.object(
            run_xcode_tests, "spawn_direct_job", side_effect=spawn
        ), mock.patch.object(
            run_xcode_tests, "complete_direct_job", return_value=completion
        ) as complete:
            run_xcode_tests.bootout_job(launchd_job(job.root), bootout_by, cleanup_by)
        self.assertEqual(authentication_windows, [4.0])
        complete.assert_called_once_with(job, 1.5, cleanup_by, 2.0)

    def test_absence_reserves_full_direct_authentication_after_bootout(self) -> None:
        job = direct_job(Path("/tmp/ap12-absence-authentication"))
        clock = [10.0]
        authentication_windows: list[float] = []

        def spawn(*arguments: object, **options: object) -> object:
            deadline, cleanup_reserve = arguments[1:3]
            assert isinstance(deadline, float)
            assert isinstance(cleanup_reserve, float)
            authenticate_by = deadline - cleanup_reserve
            authentication_windows.append(authenticate_by - clock[0])
            clock[0] = authenticate_by
            callback = options.get("authenticated")
            assert callable(callback)
            callback()
            return job

        completion = run_xcode_tests.DirectCompletion(
            113, "", "Could not find service\n", None
        )
        confirmation_by = clock[0] + run_xcode_tests.CONTAINMENT_ABSENCE_RESERVE_SECONDS
        with mock.patch.object(
            run_xcode_tests.time, "monotonic", side_effect=lambda: clock[0]
        ), mock.patch.object(
            run_xcode_tests, "spawn_direct_job", side_effect=spawn
        ), mock.patch.object(
            run_xcode_tests, "complete_direct_job", return_value=completion
        ) as complete:
            run_xcode_tests.confirm_job_absent(
                launchd_job(job.root), confirmation_by
            )
        self.assertEqual(authentication_windows, [4.0])
        complete.assert_called_once_with(job, 1.0, confirmation_by, 2.0)

    def test_launchctl_fails_closed_on_direct_identity_setup_error(self) -> None:
        failure = run_xcode_tests.SimulatorLifecycleError(
            "forged direct wrapper identity"
        )
        with mock.patch.object(
            run_xcode_tests, "spawn_direct_job", side_effect=failure
        ), mock.patch.object(run_xcode_tests, "complete_direct_job") as complete:
            with self.assertRaises(run_xcode_tests.SimulatorLifecycleError) as raised:
                run_xcode_tests.launchctl_run([], launchctl_test_deadline(), 0.2)
        self.assertIs(raised.exception, failure)
        complete.assert_not_called()

    def test_darwin_timeout_survives_coalition_cleanup_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = simulator_args(root)
            args.diagnostics_dir.mkdir()
            job = launchd_job(root / "job")
            job.root.mkdir()
            job.stderr_path.write_text("command stalled\n", encoding="utf-8")
            cleanup_error = run_xcode_tests.SimulatorLifecycleError(
                "coalition cleanup incomplete"
            )
            with mock.patch.object(
                run_xcode_tests.sys, "platform", "darwin"
            ), mock.patch.object(
                run_xcode_tests, "spawn_contained_job", return_value=job
            ), mock.patch.object(
                run_xcode_tests, "wait_for_job_status", return_value=None
            ), mock.patch.object(
                run_xcode_tests, "lifecycle_cleanup_error", side_effect=cleanup_error
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
        self.assertIn("coalition cleanup error: coalition cleanup incomplete", evidence)
        cleanup.assert_called_once_with(job, None, True)
        self.assertFalse(job.root.exists())

    def test_darwin_command_nonzero_wins_over_coalition_cleanup_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = simulator_args(root)
            args.diagnostics_dir.mkdir()
            job = launchd_job(root / "job")
            job.root.mkdir()
            job.stderr_path.write_text("target failed\n", encoding="utf-8")
            cleanup_error = run_xcode_tests.SimulatorLifecycleError(
                "coalition cleanup incomplete"
            )
            with mock.patch.object(
                run_xcode_tests.sys, "platform", "darwin"
            ), mock.patch.object(
                run_xcode_tests, "spawn_contained_job", return_value=job
            ), mock.patch.object(
                run_xcode_tests, "wait_for_job_status", return_value=7
            ), mock.patch.object(
                run_xcode_tests, "lifecycle_cleanup_error", side_effect=cleanup_error
            ) as cleanup:
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError, "probe exited 7"
                ):
                    run_xcode_tests.lifecycle_command(args, "probe", ["target"])
            evidence = (args.diagnostics_dir / "simulator-lifecycle.log").read_text()
        self.assertIn("coalition cleanup error: coalition cleanup incomplete", evidence)
        cleanup.assert_called_once_with(job, None, False)
        self.assertFalse(job.root.exists())

    def test_successful_lifecycle_fails_closed_on_cleanup_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            job = direct_job(Path(directory) / "job")
            job.root.mkdir()
            cleanup_error = run_xcode_tests.SimulatorLifecycleError(
                "direct process cleanup incomplete"
            )
            with mock.patch.object(
                run_xcode_tests, "spawn_direct_job", return_value=job
            ), mock.patch.object(
                run_xcode_tests, "wait_for_direct_status", return_value=0
            ), mock.patch.object(
                run_xcode_tests, "cleanup_direct_job", side_effect=cleanup_error
            ) as cleanup:
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError, "cleanup incomplete"
                ):
                    run_xcode_tests.direct_lifecycle_process(["target"], 1, None)
        cleanup.assert_called_once_with(job, None, False)
        self.assertFalse(job.root.exists())

    def test_successful_lifecycle_fails_closed_on_root_removal_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            job = direct_job(Path(directory) / "job")
            job.root.mkdir()
            with mock.patch.object(
                run_xcode_tests, "spawn_direct_job", return_value=job
            ), mock.patch.object(
                run_xcode_tests, "wait_for_direct_status", return_value=0
            ), mock.patch.object(
                run_xcode_tests, "cleanup_direct_job"
            ) as cleanup, mock.patch.object(
                run_xcode_tests.shutil, "rmtree", side_effect=OSError("root busy")
            ) as remove:
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError,
                    "job root removal failed: root busy",
                ):
                    run_xcode_tests.direct_lifecycle_process(["target"], 1, None)
        cleanup.assert_called_once_with(job, None, False)
        remove.assert_called_once_with(job.root)

    def test_direct_status_failure_preserves_primary_and_cleanup_errors(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            job = direct_job(Path(directory) / "job")
            job.root.mkdir()
            primary = run_xcode_tests.SimulatorLifecycleError(
                "invalid direct channel message"
            )
            cleanup_error = run_xcode_tests.SimulatorLifecycleError(
                "direct process cleanup incomplete"
            )
            with mock.patch.object(
                run_xcode_tests, "spawn_direct_job", return_value=job
            ), mock.patch.object(
                run_xcode_tests, "wait_for_direct_status", side_effect=primary
            ), mock.patch.object(
                run_xcode_tests, "cleanup_direct_job", side_effect=cleanup_error
            ) as cleanup:
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError,
                    "invalid direct channel message; direct cleanup error: "
                    "direct process cleanup incomplete",
                ) as raised:
                    run_xcode_tests.direct_lifecycle_process(["target"], 1, None)
        self.assertIs(raised.exception, primary)
        cleanup.assert_called_once_with(job, None, True)
        self.assertFalse(job.root.exists())

    def test_darwin_lifecycle_selects_launchd_coalition(self) -> None:
        expected = run_xcode_tests.LifecycleOutcome(["target"], 0, "contained\n", "")
        with mock.patch.object(
            run_xcode_tests.sys, "platform", "darwin"
        ), mock.patch.object(
            run_xcode_tests, "contained_lifecycle_process", return_value=expected
        ) as contained, mock.patch.object(
            run_xcode_tests, "direct_lifecycle_process"
        ) as direct:
            result = run_xcode_tests.lifecycle_process(["target"], 1, None)
        self.assertIs(result, expected)
        contained.assert_called_once_with(["target"], 1, None)
        direct.assert_not_called()

    def test_darwin_lifecycle_fails_closed_on_coalition_cleanup_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory) / "job")
            job.root.mkdir()
            failure = run_xcode_tests.SimulatorLifecycleError("coalition drain failed")
            with mock.patch.object(
                run_xcode_tests, "spawn_contained_job", return_value=job
            ) as contained, mock.patch.object(
                run_xcode_tests, "wait_for_job_status", return_value=0
            ), mock.patch.object(
                run_xcode_tests, "lifecycle_cleanup_error", side_effect=failure
            ) as cleanup:
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError, "coalition drain failed"
                ):
                    run_xcode_tests.contained_lifecycle_process(["target"], 1, None)
        contained.assert_called_once_with(
            ["target"],
            False,
            None,
            bootstrap_maximum=run_xcode_tests.LIFECYCLE_BOOTSTRAP_SECONDS,
            cleanup_reserve=run_xcode_tests.LIFECYCLE_CLEANUP_SECONDS,
        )
        cleanup.assert_called_once_with(job, None, False)
        self.assertFalse(job.root.exists())

    def test_darwin_prelaunch_containment_failure_has_no_direct_fallback(self) -> None:
        failure = run_xcode_tests.SimulatorLifecycleError("bootstrap failed")
        with mock.patch.object(run_xcode_tests.sys, "platform", "darwin"), mock.patch.object(
            run_xcode_tests, "contained_lifecycle_process", side_effect=failure
        ) as contained, mock.patch.object(
            run_xcode_tests, "direct_lifecycle_process"
        ) as direct:
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError, "bootstrap failed"
            ) as raised:
                run_xcode_tests.lifecycle_process(["target"], 1, None)
        self.assertIs(raised.exception, failure)
        contained.assert_called_once_with(["target"], 1, None)
        direct.assert_not_called()

    def test_darwin_preflight_fails_closed_on_launchctl_failures(self) -> None:
        failures = (
            "launchctl timed out",
            "launchctl timeout cleanup failed: launchctl process identity unavailable",
            "launchd bootstrap exited 5: permission denied",
        )
        for detail in failures:
            with self.subTest(detail=detail), tempfile.TemporaryDirectory() as directory:
                args = simulator_args(Path(directory))
                args.diagnostics_dir.mkdir()
                failure = run_xcode_tests.SimulatorLifecycleError(detail)
                with mock.patch.object(
                    run_xcode_tests.sys, "platform", "darwin"
                ), mock.patch.object(
                    run_xcode_tests,
                    "contained_lifecycle_process",
                    side_effect=failure,
                ) as launchd, mock.patch.object(
                    run_xcode_tests, "direct_lifecycle_process"
                ) as direct:
                    with self.assertRaises(run_xcode_tests.SimulatorLifecycleError) as raised:
                        run_xcode_tests.lifecycle_command(
                            args, "hosted-preflight", ["target"]
                        )
            self.assertIs(raised.exception, failure)
            launchd.assert_called_once_with(["target"], 120, None)
            direct.assert_not_called()
            self.assertFalse((args.diagnostics_dir / "simulator-lifecycle.log").exists())

    def test_successful_lifecycle_requires_launchd_absence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory) / "job")
            job.root.mkdir()
            job.stdout_path.write_text("contained\n", encoding="utf-8")
            cleanup_error = "bootout failed: permission denied"
            with mock.patch.object(
                run_xcode_tests, "spawn_contained_job", return_value=job
            ), mock.patch.object(
                run_xcode_tests, "wait_for_job_status", return_value=0
            ), mock.patch.object(
                run_xcode_tests, "lifecycle_cleanup_error", return_value=cleanup_error
            ) as cleanup:
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError,
                    "bootout failed: permission denied",
                ):
                    run_xcode_tests.contained_lifecycle_process(["target"], 1, None)
        cleanup.assert_called_once_with(job, None, False)
        self.assertFalse(job.root.exists())

    def containment_cleanup_operations(
        self,
    ) -> tuple[
        tuple[str, Callable[[run_xcode_tests.LaunchdJob], object]], ...
    ]:
        return (
            (
                "lifecycle",
                lambda job: run_xcode_tests.lifecycle_cleanup_error(job, None, False),
            ),
            (
                "contained",
                lambda job: run_xcode_tests.cleanup_contained_job(job, None, False),
            ),
            (
                "handshake",
                lambda job: run_xcode_tests.abort_containment_handshake(
                    job, 77, None
                ),
            ),
        )

    def cleanup_operation_result(
        self,
        operation: Callable[[run_xcode_tests.LaunchdJob], object],
        job: run_xcode_tests.LaunchdJob,
    ) -> str | None:
        try:
            result = operation(job)
        except run_xcode_tests.SimulatorLifecycleError as error:
            return str(error)
        return result if isinstance(result, str) else None

    def hosted_cleanup_deadlines(
        self, sidecar: str | None, caller_deadline: float | None = None
    ) -> tuple[list[float], dict[str, object]]:
        clock = [10.0]
        signal_deadlines: list[float] = []
        deadlines: dict[str, object] = {}

        def signal_members(
            _coalition_id: int, _requested: signal.Signals, deadline: float
        ) -> None:
            signal_deadlines.append(deadline)
            clock[0] += 0.2
            if clock[0] >= deadline:
                raise run_xcode_tests.SimulatorLifecycleError(
                    "Darwin coalition census deadline expired"
                )

        def capture(name: str) -> object:
            def operation(
                _value: object,
                deadline: float,
                process_cleanup_deadline: float | None = None,
            ) -> None:
                deadlines[name] = deadline
                if name == "bootout" and process_cleanup_deadline is not None:
                    deadlines["bootout_cleanup"] = process_cleanup_deadline

            return operation

        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            if sidecar is not None:
                job.coalition_path.write_text(sidecar, encoding="utf-8")
            with mock.patch.object(
                run_xcode_tests.time, "monotonic", side_effect=lambda: clock[0]
            ), mock.patch.object(
                run_xcode_tests, "signal_coalition_members", side_effect=signal_members
            ), mock.patch.object(
                run_xcode_tests, "pause_before_cleanup"
            ), mock.patch.object(
                run_xcode_tests, "drain_coalition", side_effect=capture("drain")
            ), mock.patch.object(
                run_xcode_tests, "bootout_job", side_effect=capture("bootout")
            ), mock.patch.object(
                run_xcode_tests, "confirm_job_absent", side_effect=capture("confirm")
            ):
                run_xcode_tests.cleanup_contained_job(job, caller_deadline, False)
        return signal_deadlines, deadlines

    def test_hosted_cleanup_paths_receive_bounded_census_budget(self) -> None:
        caller_deadline = 10.0 + run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS
        cases = {
            "descendant": ('{"resource_coalition_id":77}', caller_deadline),
            "sidecar-missing-0": (None, caller_deadline),
            "sidecar-missing-4": (None, caller_deadline),
            "sidecar-corrupt-0": ("not-json", caller_deadline),
            "sidecar-corrupt-3": ("not-json", caller_deadline),
            "sidecar-corrupt-4": ("not-json", caller_deadline),
            "sidecar-forged-1": ('{"resource_coalition_id":999}', caller_deadline),
            "sidecar-forged-2": ('{"resource_coalition_id":999}', caller_deadline),
            "successful-target": ('{"resource_coalition_id":77}', caller_deadline),
        }
        for name, (sidecar, caller_deadline) in cases.items():
            with self.subTest(path=name):
                with mock.patch.object(
                    run_xcode_tests,
                    "CONTAINED_JOB_CLEANUP_SECONDS",
                    run_xcode_tests.CLEANUP_RESERVE_SECONDS,
                ), self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError,
                    "Darwin coalition census deadline expired",
                ):
                    self.hosted_cleanup_deadlines(sidecar, caller_deadline)
                signal_deadlines, deadlines = self.hosted_cleanup_deadlines(
                    sidecar, caller_deadline
                )
                expected = run_xcode_tests.containment_cleanup_deadlines(
                    caller_deadline
                )
                self.assertTrue(signal_deadlines)
                self.assertTrue(
                    all(deadline == expected.signal_by for deadline in signal_deadlines)
                )
                self.assertEqual(deadlines["drain"], expected.drain_by)
                self.assertEqual(deadlines["bootout"], expected.bootout_by)
                self.assertEqual(
                    deadlines["bootout_cleanup"], expected.bootout_cleanup_by
                )
                self.assertEqual(deadlines["confirm"], expected.confirmation_by)

    def test_contained_cleanup_budget_obeys_caller_deadline(self) -> None:
        caller_deadline = 10.0 + run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS
        signal_deadlines, deadlines = self.hosted_cleanup_deadlines(
            '{"resource_coalition_id":77}', caller_deadline
        )
        expected = run_xcode_tests.containment_cleanup_deadlines(caller_deadline)
        self.assertTrue(signal_deadlines)
        self.assertTrue(
            all(deadline == expected.signal_by for deadline in signal_deadlines)
        )
        self.assertEqual(deadlines["drain"], expected.drain_by)
        self.assertEqual(deadlines["bootout"], expected.bootout_by)
        self.assertEqual(deadlines["bootout_cleanup"], expected.bootout_cleanup_by)
        self.assertEqual(deadlines["confirm"], caller_deadline)

    def expired_drain_finalization(
        self,
        operation: Callable[[run_xcode_tests.LaunchdJob], object],
        bootout_times_out: bool,
    ) -> tuple[str | None, dict[str, float], mock.Mock]:
        clock = [10.0]
        budgets: dict[str, float] = {}
        direct_job = mock.Mock()

        def drain(_coalition_id: int, deadline: float) -> None:
            clock[0] = deadline + 0.000001
            raise run_xcode_tests.SimulatorLifecycleError("descendants remained")

        def complete(
            _job: object,
            timeout: float,
            _deadline: float,
            cleanup_reserve: float,
        ) -> run_xcode_tests.DirectCompletion:
            budgets["bootout"] = timeout
            clock[0] += timeout
            if bootout_times_out:
                budgets["termination"] = cleanup_reserve
                clock[0] += cleanup_reserve
                return run_xcode_tests.DirectCompletion(None, "", "", None)
            return run_xcode_tests.DirectCompletion(0, "", "", None)

        def confirm_absence(
            arguments: list[str], deadline: float
        ) -> subprocess.CompletedProcess[str]:
            budgets["absence"] = deadline - clock[0]
            return subprocess.CompletedProcess(arguments, 113, "", "Could not find service")

        def spawn(*arguments: object, **options: object) -> object:
            deadline = arguments[1]
            cleanup_reserve = arguments[2]
            if not isinstance(deadline, float) or not isinstance(cleanup_reserve, float):
                raise AssertionError("invalid direct wrapper deadline")
            clock[0] = max(clock[0], deadline - cleanup_reserve)
            callback = options.get("authenticated")
            if not callable(callback):
                raise AssertionError("missing direct authentication callback")
            callback()
            return direct_job

        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            with mock.patch.object(
                run_xcode_tests.time, "monotonic", side_effect=lambda: clock[0]
            ), mock.patch.object(
                run_xcode_tests, "cleanup_coalition_id", return_value=77
            ), mock.patch.object(
                run_xcode_tests, "signal_coalition_members"
            ), mock.patch.object(
                run_xcode_tests, "pause_before_cleanup"
            ), mock.patch.object(
                run_xcode_tests, "drain_coalition", side_effect=drain
            ), mock.patch.object(
                run_xcode_tests, "spawn_direct_job", side_effect=spawn
            ) as launch, mock.patch.object(
                run_xcode_tests, "complete_direct_job", side_effect=complete
            ), mock.patch.object(
                run_xcode_tests, "launchctl_retry", side_effect=confirm_absence
            ):
                result = self.cleanup_operation_result(operation, job)
        return result, budgets, launch

    def assert_expired_drain_preserves_finalization(
        self,
        operation: Callable[[run_xcode_tests.LaunchdJob], object],
        bootout_times_out: bool,
    ) -> None:
        result, budgets, launch = self.expired_drain_finalization(
            operation, bootout_times_out
        )
        expected = "coalition drain failed: descendants remained"
        if bootout_times_out:
            expected += "; bootout failed: launchctl timed out"
        self.assertEqual(result, expected)
        self.assertGreater(budgets["bootout"], 0)
        self.assertLessEqual(
            budgets["bootout"], run_xcode_tests.CONTAINMENT_BOOTOUT_RESERVE_SECONDS
        )
        if bootout_times_out:
            self.assertAlmostEqual(
                budgets["termination"],
                run_xcode_tests.CONTAINMENT_BOOTOUT_CLEANUP_RESERVE_SECONDS,
            )
            self.assertAlmostEqual(
                budgets["absence"],
                run_xcode_tests.CONTAINMENT_ABSENCE_RESERVE_SECONDS,
            )
        else:
            self.assertNotIn("absence", budgets)
        launch.assert_called_once()
        self.assertEqual(launch.call_args.args[0][1], "bootout")

    def test_lifecycle_cleanup_drains_live_coalition_before_bootout(self) -> None:
        events: list[str] = []
        coalition_live = True

        def bootout(*_args: object) -> None:
            events.append("bootout")
            if coalition_live:
                raise run_xcode_tests.SimulatorLifecycleError("launchctl timed out")

        def drain(*_args: object) -> None:
            nonlocal coalition_live
            events.append("drain")
            coalition_live = False

        def confirm_absence(*_args: object) -> None:
            events.append("confirm")
            self.assertFalse(coalition_live)

        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            with mock.patch.object(
                run_xcode_tests, "cleanup_coalition_id", return_value=77
            ), mock.patch.object(run_xcode_tests, "signal_coalition_members"), mock.patch.object(
                run_xcode_tests,
                "drain_coalition",
                side_effect=drain,
            ), mock.patch.object(
                run_xcode_tests, "bootout_job", side_effect=bootout
            ), mock.patch.object(
                run_xcode_tests, "confirm_job_absent", side_effect=confirm_absence
            ):
                cleanup_error = run_xcode_tests.lifecycle_cleanup_error(job, None, False)
        self.assertIsNone(cleanup_error)
        self.assertEqual(events, ["drain", "bootout", "confirm"])

    def test_cleanup_paths_report_all_finalization_errors(self) -> None:
        events: list[str] = []
        bootout_failure = run_xcode_tests.SimulatorLifecycleError(
            "bootout permission denied"
        )
        drain_failure = run_xcode_tests.SimulatorLifecycleError("descendants remained")
        absence_failure = run_xcode_tests.SimulatorLifecycleError(
            "absence permission denied"
        )

        def fail_bootout(*_args: object) -> None:
            events.append("bootout")
            raise bootout_failure

        def fail_absence(*_args: object) -> None:
            events.append("confirm")
            raise absence_failure

        def fail_drain(*_args: object) -> None:
            events.append("drain")
            raise drain_failure

        for name, operation in self.containment_cleanup_operations():
            events.clear()
            with self.subTest(path=name), tempfile.TemporaryDirectory() as directory:
                job = launchd_job(Path(directory))
                with mock.patch.object(
                    run_xcode_tests, "cleanup_coalition_id", return_value=77
                ), mock.patch.object(
                    run_xcode_tests, "signal_coalition_members"
                ), mock.patch.object(
                    run_xcode_tests, "pause_before_cleanup"
                ), mock.patch.object(
                    run_xcode_tests, "drain_coalition", side_effect=fail_drain
                ), mock.patch.object(
                    run_xcode_tests, "bootout_job", side_effect=fail_bootout
                ), mock.patch.object(
                    run_xcode_tests, "confirm_job_absent", side_effect=fail_absence
                ):
                    cleanup_error = self.cleanup_operation_result(operation, job)
            self.assertEqual(
                cleanup_error,
                "coalition drain failed: descendants remained; "
                "bootout failed: bootout permission denied; "
                "absence confirmation failed: absence permission denied",
            )
            self.assertEqual(events, ["drain", "bootout", "confirm"])

    def test_missing_coalition_still_aggregates_finalization_failures(self) -> None:
        events: list[str] = []

        def fail(phase: str, detail: str) -> Callable[..., None]:
            def operation(*_args: object) -> None:
                events.append(phase)
                raise run_xcode_tests.SimulatorLifecycleError(detail)

            return operation

        for name, operation in self.containment_cleanup_operations()[:2]:
            events.clear()
            with self.subTest(path=name), tempfile.TemporaryDirectory() as directory:
                job = launchd_job(Path(directory), None)
                with mock.patch.object(
                    run_xcode_tests, "bootout_job", side_effect=fail("bootout", "denied")
                ), mock.patch.object(
                    run_xcode_tests,
                    "confirm_job_absent",
                    side_effect=fail("confirm", "still loaded"),
                ), mock.patch.object(run_xcode_tests, "drain_coalition") as drain:
                    cleanup_error = self.cleanup_operation_result(operation, job)
            self.assertEqual(
                cleanup_error,
                "contained coalition identity unavailable; containment finalization "
                "failed: bootout failed: denied; absence confirmation failed: still loaded",
            )
            self.assertEqual(events, ["bootout", "confirm"])
            drain.assert_not_called()

    def test_cleanup_attempts_unload_and_absence_after_drain_failure(self) -> None:
        events: list[str] = []
        drain_failure = run_xcode_tests.SimulatorLifecycleError("descendants remained")

        def capture(name: str, failure: Exception | None = None) -> object:
            def operation(*_args: object) -> None:
                events.append(name)
                if failure is not None:
                    raise failure

            return operation

        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            with mock.patch.object(
                run_xcode_tests, "cleanup_coalition_id", return_value=77
            ), mock.patch.object(run_xcode_tests, "signal_coalition_members"), mock.patch.object(
                run_xcode_tests, "pause_before_cleanup"
            ), mock.patch.object(
                run_xcode_tests,
                "drain_coalition",
                side_effect=capture("drain", drain_failure),
            ), mock.patch.object(
                run_xcode_tests, "bootout_job", side_effect=capture("bootout")
            ), mock.patch.object(
                run_xcode_tests,
                "confirm_job_absent",
                side_effect=capture("confirm"),
            ):
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError,
                    "coalition drain failed: descendants remained",
                ):
                    run_xcode_tests.cleanup_contained_job(job, None, False)
        self.assertEqual(events, ["drain", "bootout", "confirm"])

    def test_handshake_abort_drains_known_coalition_before_bootout(self) -> None:
        events: list[str] = []
        coalition_live = True

        def drain(*_args: object) -> None:
            nonlocal coalition_live
            events.append("drain")
            coalition_live = False

        def bootout(*_args: object) -> None:
            events.append("bootout")
            self.assertFalse(coalition_live)

        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            with mock.patch.object(
                run_xcode_tests, "drain_coalition", side_effect=drain
            ), mock.patch.object(
                run_xcode_tests, "bootout_job", side_effect=bootout
            ), mock.patch.object(
                run_xcode_tests,
                "confirm_job_absent",
                side_effect=lambda *_args: events.append("confirm"),
            ):
                run_xcode_tests.abort_containment_handshake(job, 77, None)
        self.assertEqual(events, ["drain", "bootout", "confirm"])

    def test_drain_epsilon_preserves_finalization_across_cleanup_paths(self) -> None:
        for name, operation in self.containment_cleanup_operations():
            with self.subTest(path=name):
                self.assert_expired_drain_preserves_finalization(operation, False)

    def test_bootout_timeout_preserves_confirmation_across_cleanup_paths(self) -> None:
        for name, operation in self.containment_cleanup_operations():
            with self.subTest(path=name):
                self.assert_expired_drain_preserves_finalization(operation, True)

    def test_signal_exhaustion_preserves_finalization_across_cleanup_paths(self) -> None:
        for name, operation in self.containment_cleanup_operations():
            clock = [10.0]
            events: list[str] = []
            first_signal: list[str] = []

            def signal_members(
                _coalition_id: int, requested: signal.Signals, deadline: float
            ) -> None:
                events.append(requested.name)
                if first_signal:
                    return
                first_signal.append(requested.name)
                clock[0] = deadline + 0.000001
                raise run_xcode_tests.SimulatorLifecycleError("signal budget exhausted")

            def fail(phase: str, detail: str) -> Callable[..., None]:
                def operation(*_args: object) -> None:
                    events.append(phase)
                    raise run_xcode_tests.SimulatorLifecycleError(detail)

                return operation

            def drain(_coalition_id: int, deadline: float) -> None:
                events.append("drain")
                if name == "handshake":
                    signal_members(77, signal.SIGKILL, deadline)
                raise run_xcode_tests.SimulatorLifecycleError("descendants remained")

            with self.subTest(path=name), tempfile.TemporaryDirectory() as directory:
                job = launchd_job(Path(directory))
                with mock.patch.object(
                    run_xcode_tests.time, "monotonic", side_effect=lambda: clock[0]
                ), mock.patch.object(
                    run_xcode_tests, "cleanup_coalition_id", return_value=77
                ), mock.patch.object(
                    run_xcode_tests, "signal_coalition_members", side_effect=signal_members
                ), mock.patch.object(
                    run_xcode_tests, "pause_before_cleanup"
                ), mock.patch.object(
                    run_xcode_tests,
                    "drain_coalition",
                    side_effect=drain,
                ), mock.patch.object(
                    run_xcode_tests,
                    "bootout_job",
                    side_effect=fail("bootout", "bootout denied"),
                ), mock.patch.object(
                    run_xcode_tests,
                    "confirm_job_absent",
                    side_effect=fail("confirm", "absence denied"),
                ):
                    cleanup_error = self.cleanup_operation_result(operation, job)
            detail = cleanup_error or ""
            if name == "handshake":
                self.assertIn("coalition drain failed: signal budget exhausted", detail)
            else:
                self.assertIn(
                    f"{first_signal[0]} signal failed: signal budget exhausted", detail
                )
                self.assertIn("coalition drain failed: descendants remained", detail)
            self.assertIn("bootout failed: bootout denied", detail)
            self.assertIn("absence confirmation failed: absence denied", detail)
            self.assertEqual(events[-2:], ["bootout", "confirm"])

    def test_lifecycle_cleanup_reserves_absence_confirmation_budget(self) -> None:
        deadlines: dict[str, object] = {}
        signal_deadlines: list[float] = []

        def capture(name: str) -> object:
            def operation(
                _value: object,
                deadline: float,
                process_cleanup_deadline: float | None = None,
            ) -> None:
                value: object = deadline
                if name == "bootout" and process_cleanup_deadline is not None:
                    value = (deadline, process_cleanup_deadline)
                deadlines[name] = value

            return operation

        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            with mock.patch.object(
                run_xcode_tests.time, "monotonic", return_value=10.0
            ), mock.patch.object(
                run_xcode_tests, "cleanup_coalition_id", return_value=77
            ) as coalition, mock.patch.object(
                run_xcode_tests,
                "signal_coalition_members",
                side_effect=lambda _coalition, _signal, deadline: signal_deadlines.append(
                    deadline
                ),
            ), mock.patch.object(
                run_xcode_tests, "pause_before_cleanup"
            ), mock.patch.object(
                run_xcode_tests, "bootout_job", side_effect=capture("bootout")
            ), mock.patch.object(
                run_xcode_tests, "drain_coalition", side_effect=capture("drain")
            ), mock.patch.object(
                run_xcode_tests, "confirm_job_absent", side_effect=capture("confirm")
            ):
                self.assertIsNone(
                    run_xcode_tests.lifecycle_cleanup_error(job, None, False)
                )
        cleanup_by = 10.0 + run_xcode_tests.LIFECYCLE_CLEANUP_SECONDS
        teardown_by = cleanup_by - run_xcode_tests.CLEANUP_RESERVE_SECONDS
        cleanup_deadlines = run_xcode_tests.containment_cleanup_deadlines(
            cleanup_by, teardown_by
        )
        coalition.assert_called_once()
        coalition_deadlines = coalition.call_args.args[1]
        self.assertEqual(coalition.call_args.args[0], job)
        self.assertEqual(coalition_deadlines, cleanup_deadlines)
        self.assertEqual(
            deadlines,
            {
                "bootout": (
                    cleanup_by
                    - run_xcode_tests.CONTAINMENT_ABSENCE_RESERVE_SECONDS
                    - run_xcode_tests.CONTAINMENT_BOOTOUT_CLEANUP_RESERVE_SECONDS,
                    cleanup_by
                    - run_xcode_tests.CONTAINMENT_ABSENCE_RESERVE_SECONDS,
                ),
                "drain": cleanup_by
                - run_xcode_tests.CONTAINMENT_ABSENCE_RESERVE_SECONDS
                - run_xcode_tests.CONTAINMENT_BOOTOUT_CLEANUP_RESERVE_SECONDS
                - run_xcode_tests.CONTAINMENT_BOOTOUT_RESERVE_SECONDS,
                "confirm": cleanup_by,
            },
        )
        self.assertTrue(signal_deadlines)
        self.assertTrue(
            all(deadline == cleanup_deadlines.signal_by for deadline in signal_deadlines)
        )

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
        self.assertEqual(launchctl.call_args.args[2], 2.0)
        abort.assert_called_once_with(
            job, None, deadline, run_xcode_tests.CLEANUP_RESERVE_SECONDS
        )

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
                    run_xcode_tests.spawn_contained_job(
                        ["target"],
                        False,
                        deadline,
                        run_xcode_tests.LIFECYCLE_BOOTSTRAP_SECONDS,
                    )
        setup_deadline = deadline - run_xcode_tests.CLEANUP_RESERVE_SECONDS
        self.assertEqual(launchctl.call_args.args[1], setup_deadline)
        self.assertEqual(
            launchctl.call_args.args[2], run_xcode_tests.LIFECYCLE_BOOTSTRAP_SECONDS
        )
        handshake.assert_called_once_with(job, setup_deadline)
        abort.assert_called_once_with(
            job, None, deadline, run_xcode_tests.CLEANUP_RESERVE_SECONDS
        )

    def test_launchd_setup_preserves_primary_and_all_cleanup_failures(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory) / "job")
            job.root.mkdir()
            deadline = time.monotonic() + 1
            primary = run_xcode_tests.SimulatorLifecycleError("bootstrap failed")
            abort_error = run_xcode_tests.SimulatorLifecycleError("abort failed")
            with mock.patch.object(
                run_xcode_tests, "create_launchd_job", return_value=job
            ), mock.patch.object(
                run_xcode_tests, "launchd_domain", return_value=f"gui/{os.getuid()}"
            ), mock.patch.object(
                run_xcode_tests, "launchctl_run", side_effect=primary
            ), mock.patch.object(
                run_xcode_tests, "abort_containment_handshake", side_effect=abort_error
            ) as abort, mock.patch.object(
                run_xcode_tests.shutil, "rmtree", side_effect=OSError("root busy")
            ) as remove:
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError,
                    "bootstrap failed; launchd setup cleanup error: containment abort "
                    "failed: abort failed; setup root removal failed: root busy",
                ) as raised:
                    run_xcode_tests.spawn_contained_job(["target"], False, deadline)
        self.assertIs(raised.exception, primary)
        abort.assert_called_once_with(
            job, None, deadline, run_xcode_tests.CLEANUP_RESERVE_SECONDS
        )
        remove.assert_called_once_with(job.root)

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
            execution_budget = 4.0
            args.wall_deadline = (
                90.0
                + run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS
                + execution_budget
            )
            job = launchd_job(root / "job")
            job.root.mkdir()
            with mock.patch.object(
                run_xcode_tests,
                "remaining_wall_budget",
                return_value=(
                    run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS
                    + execution_budget
                ),
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
        self.assertLessEqual(
            evidence_deadline,
            args.wall_deadline - run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS,
        )
        cleanup.assert_called_once_with(job, args.wall_deadline, True)
        final_output.assert_not_called()

    def test_attempt_cleanup_failure_preserves_exit_without_duplicate_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = simulator_args(root)
            args.wall_deadline = (
                time.monotonic()
                + run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS
                + 4
            )
            job = launchd_job(root / "job")
            job.root.mkdir()
            cleanup_error = run_xcode_tests.SimulatorLifecycleError(
                "launchctl timed out"
            )
            with mock.patch.object(
                run_xcode_tests, "spawn_contained_job", return_value=job
            ), mock.patch.object(
                run_xcode_tests, "observe_attempt", return_value=(65, "failed", None)
            ), mock.patch.object(
                run_xcode_tests, "cleanup_contained_job", side_effect=cleanup_error
            ) as cleanup:
                outcome = run_xcode_tests.run_attempt(
                    args, args.command, io.StringIO(), 1, 0.0, []
                )
        self.assertEqual(outcome.returncode, 65)
        self.assertEqual(outcome.cleanup_error, "launchctl timed out")
        self.assertIn("containment cleanup error = launchctl timed out", outcome.process_evidence)
        cleanup.assert_called_once_with(job, args.wall_deadline, False)
        self.assertFalse(job.root.exists())

    def test_attempt_status_error_survives_failed_containment_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = simulator_args(root)
            args.wall_deadline = (
                time.monotonic()
                + run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS
                + 4
            )
            job = launchd_job(root / "job")
            job.root.mkdir()
            primary = run_xcode_tests.SimulatorLifecycleError("invalid xcodebuild status")
            cleanup_error = run_xcode_tests.SimulatorLifecycleError("containment stuck")
            with mock.patch.object(
                run_xcode_tests, "spawn_contained_job", return_value=job
            ), mock.patch.object(
                run_xcode_tests, "observe_attempt", side_effect=primary
            ), mock.patch.object(
                run_xcode_tests, "cleanup_contained_job", side_effect=cleanup_error
            ) as cleanup:
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError,
                    "invalid xcodebuild status; xcodebuild cleanup error: containment "
                    "cleanup failed: containment stuck",
                ) as raised:
                    run_xcode_tests.run_attempt(
                        args, args.command, io.StringIO(), 1, 0.0, []
                    )
        self.assertIs(raised.exception, primary)
        cleanup.assert_called_once_with(job, args.wall_deadline, True)
        self.assertFalse(job.root.exists())

    def test_run_attempt_keeps_xcodebuild_launchd_contained(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            args = simulator_args(Path(directory))
            args.wall_deadline = (
                time.monotonic()
                + run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS
                + 4
            )
            job = launchd_job(Path(directory) / "job")
            job.root.mkdir()
            with mock.patch.object(
                run_xcode_tests, "spawn_contained_job", return_value=job
            ) as contained, mock.patch.object(
                run_xcode_tests, "spawn_direct_job"
            ) as direct, mock.patch.object(
                run_xcode_tests, "observe_attempt", return_value=(0, "passed", None)
            ), mock.patch.object(run_xcode_tests, "cleanup_contained_job"):
                outcome = run_xcode_tests.run_attempt(
                    args, args.command, io.StringIO(), 1, 0.0, []
                )
        self.assertEqual(outcome.returncode, 0)
        contained.assert_called_once_with(
            args.command,
            True,
            args.wall_deadline - run_xcode_tests.TIMEOUT_EVIDENCE_SECONDS,
            bootstrap_maximum=run_xcode_tests.LIFECYCLE_BOOTSTRAP_SECONDS,
            cleanup_reserve=run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS,
        )
        direct.assert_not_called()

    def test_delayed_setup_cannot_cross_cutoff_or_consume_reserves(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            clock = [0.0]
            wall_deadline = HOSTED_ATTEMPT_WALL_TIMEOUT
            launch_deadline = wall_deadline - 0.25
            setup_cutoff = launch_deadline - 15.5
            started = subprocess.CompletedProcess([], 0, "", "")
            def delayed_acknowledgement(
                _job: run_xcode_tests.LaunchdJob,
                _token: str,
                _coalition_id: int,
                deadline: float | None,
            ) -> None:
                assert deadline is not None
                self.assertEqual(deadline, setup_cutoff)
                clock[0] = deadline + 0.01
            with mock.patch.object(
                run_xcode_tests, "create_launchd_job", return_value=job
            ), mock.patch.object(
                run_xcode_tests, "launchd_domain", return_value=f"gui/{os.getuid()}"
            ), mock.patch.object(
                run_xcode_tests, "launchctl_run", return_value=started
            ), mock.patch.object(
                run_xcode_tests,
                "await_containment_handshake",
                return_value=({}, 77, mock.sentinel.wrapper),
            ), mock.patch.object(
                run_xcode_tests, "validate_containment_sidecar"
            ), mock.patch.object(
                run_xcode_tests,
                "write_containment_acknowledgement",
                side_effect=delayed_acknowledgement,
            ), mock.patch.object(
                run_xcode_tests.time, "monotonic", side_effect=lambda: clock[0]
            ), mock.patch.object(
                run_xcode_tests, "abort_containment_handshake"
            ) as abort:
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError,
                    "containment setup deadline expired",
                ):
                    run_xcode_tests.spawn_contained_job(
                        ["target"], False, launch_deadline, 10.0, 15.5
                    )
        self.assertEqual(launch_deadline - setup_cutoff, 15.5)
        self.assertEqual(wall_deadline - launch_deadline, 0.25)
        abort.assert_called_once_with(
            job, 77, launch_deadline, 15.5
        )

    def test_runner_fails_closed_only_for_successful_cleanup_error(self) -> None:
        for expected in (0, 7, 65, 124, 125):
            with self.subTest(returncode=expected), tempfile.TemporaryDirectory() as directory:
                args = simulator_args(Path(directory))
                args.command = ["fake-xcodebuild"]
                args.simulator_name = None
                outcome = run_xcode_tests.AttemptOutcome(
                    expected, "target output", None, "", "launchctl timed out"
                )
                stderr = io.StringIO()
                with mock.patch.object(
                    run_xcode_tests, "run_attempt", return_value=outcome
                ) as attempt, mock.patch.object(run_xcode_tests.sys, "stderr", stderr):
                    actual = run_xcode_tests.run(args)
            required = (
                run_xcode_tests.PRETEST_INFRASTRUCTURE_FAILURE
                if expected == 0
                else expected
            )
            self.assertEqual(actual, required)
            self.assertIn("classification=containment-cleanup-failure", stderr.getvalue())
            attempt.assert_called_once()

    def test_timeout_classification_survives_cleanup_failure(self) -> None:
        completed = (
            "Test Suite 'PomodoroughUITests.xctest' passed\n"
            "Test Suite 'All tests' passed\n"
            " Executed 1 tests, with 0 failures\n"
        )
        for output, expected in (
            (completed, run_xcode_tests.POST_TEST_TIMEOUT),
            ("Test Case 'example' started\n", run_xcode_tests.TEST_EXECUTION_TIMEOUT),
        ):
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                args = simulator_args(Path(directory))
                args.command = ["fake-xcodebuild"]
                args.simulator_name = None
                outcome = run_xcode_tests.AttemptOutcome(
                    -signal.SIGKILL,
                    output,
                    "wall-timeout=1800s",
                    run_xcode_tests.cleanup_process_evidence(
                        "process evidence\n", "launchctl timed out"
                    ),
                    "launchctl timed out",
                )
                original_popen = subprocess.Popen

                def delayed_writer(
                    *arguments: object, **options: object
                ) -> subprocess.Popen[bytes]:
                    time.sleep(0.3)
                    return original_popen(*arguments, **options)

                stderr = io.StringIO()
                with mock.patch.object(
                    run_xcode_tests, "run_attempt", return_value=outcome
                ), mock.patch.object(
                    run_xcode_tests.subprocess, "Popen", side_effect=delayed_writer
                ), mock.patch.object(run_xcode_tests.sys, "stderr", stderr):
                    actual = run_xcode_tests.run(args)
                evidence = {
                    path.name: path.read_text(encoding="utf-8")
                    for path in args.diagnostics_dir.glob("*timeout.txt")
                }
            self.assertEqual(actual, expected)
            self.assert_timeout_cleanup_failure_evidence(evidence, stderr)

    def assert_timeout_cleanup_failure_evidence(
        self, evidence: dict[str, str], stderr: io.StringIO
    ) -> None:
        self.assertEqual(set(evidence), {"attempt-1-timeout.txt", "timeout.txt"})
        self.assertTrue(
            all(
                "containment cleanup error = launchctl timed out" in value
                for value in evidence.values()
            )
        )
        self.assertIn("classification=containment-cleanup-failure", stderr.getvalue())

    def test_linux_lifecycle_commands_avoid_launchd(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            args = simulator_args(Path(directory))
            args.diagnostics_dir.mkdir()
            self.assert_linux_direct_lifecycle_sequence_avoids_launchd(args)

    def assert_linux_direct_lifecycle_sequence_avoids_launchd(
        self, args: argparse.Namespace
    ) -> None:
        args.wall_deadline = time.monotonic() + 5
        unavailable = run_xcode_tests.SimulatorLifecycleError("launchctl timed out")
        with mock.patch.object(
            run_xcode_tests.sys, "platform", "linux"
        ), mock.patch.object(
            run_xcode_tests, "launchctl_run", side_effect=unavailable
        ) as launchctl, mock.patch.object(
            run_xcode_tests, "spawn_contained_job", side_effect=unavailable
        ) as contained:
            listed = run_xcode_tests.lifecycle_command(
                args, "list-simulators", [sys.executable, "-c", "print('listed')"]
            )
            booted = run_xcode_tests.lifecycle_command(
                args, "boot-simulator", [sys.executable, "-c", "print('booted')"]
            )
            with self.assertRaisesRegex(
                run_xcode_tests.SimulatorLifecycleError, "generic-launchctl exited 7"
            ):
                run_xcode_tests.lifecycle_command(
                    args,
                    "generic-launchctl",
                    [
                        sys.executable,
                        "-c",
                        "import sys; print('permission denied', file=sys.stderr); sys.exit(7)",
                    ],
                )
        self.assertEqual(listed.stdout, "listed\n")
        self.assertEqual(booted.stdout, "booted\n")
        launchctl.assert_not_called()
        contained.assert_not_called()

    def successful_command_child_pid(self, source: str) -> int:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = simulator_args(root)
            args.diagnostics_dir.mkdir()
            args.wall_deadline = lifecycle_test_deadline()
            result = run_xcode_tests.lifecycle_command(
                args, "successful-command", [sys.executable, "-c", source]
            )
        match = re.search(r"CHILD_PID=(\d+)", result.stdout)
        self.assertIsNotNone(match)
        assert match is not None
        return int(match.group(1))

    def completed_contained_output(self, command: list[str]) -> str:
        deadline = (
            time.monotonic()
            + run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS
            + 4
        )
        job = run_xcode_tests.spawn_contained_job(
            command,
            False,
            deadline,
            cleanup_reserve=run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS,
        )
        cleaned = False
        try:
            returncode = run_xcode_tests.wait_for_job_status(job, 2, deadline)
            self.assertEqual(returncode, 0, run_xcode_tests.job_output(job.stderr_path))
            output = run_xcode_tests.job_output(job.stdout_path)
            run_xcode_tests.cleanup_contained_job(job, deadline, False)
            cleaned = True
            return output
        finally:
            if not cleaned:
                try:
                    run_xcode_tests.cleanup_contained_job(job, deadline, True)
                except run_xcode_tests.SimulatorLifecycleError:
                    pass
            shutil.rmtree(job.root, ignore_errors=True)

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
        deadline = (
            time.monotonic()
            + run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS
            + 4
        )
        job = run_xcode_tests.spawn_contained_job(
            command,
            False,
            deadline,
            cleanup_reserve=run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS,
        )
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

    def terminate_ready_direct_job(self, command: list[str], pid_path: Path) -> int:
        deadline = time.monotonic() + 4
        job = run_xcode_tests.spawn_direct_job(command, deadline)
        cleaned = False
        try:
            self.assertTrue(self.wait_until_file_contains(job.stdout_path, "READY"))
            run_xcode_tests.cleanup_direct_job(job, deadline, True)
            cleaned = True
            return int(pid_path.read_text(encoding="utf-8"))
        finally:
            if not cleaned:
                try:
                    run_xcode_tests.cleanup_direct_job(job, deadline, True)
                except run_xcode_tests.SimulatorLifecycleError:
                    pass
            shutil.rmtree(job.root, ignore_errors=True)

    def cleanup_after_sidecar_tamper(self, replacement: str | None) -> int:
        deadline = (
            time.monotonic()
            + run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS
            + 6
        )
        source = (
            "import subprocess,sys,time; "
            "child=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)'],"
            "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True); "
            "print(f'CHILD_PID={child.pid}',flush=True); time.sleep(30)"
        )
        job = run_xcode_tests.spawn_contained_job(
            [sys.executable, "-c", source],
            False,
            deadline,
            cleanup_reserve=run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS,
        )
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
                wall_timeout=run_xcode_tests.CONTAINED_JOB_CLEANUP_SECONDS + 4,
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

    def test_bootout_accepts_macos_idempotent_absence(self) -> None:
        result = subprocess.CompletedProcess(
            [], 3, "", "Boot-out failed: 3: No such process\n"
        )
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            with mock.patch.object(
                run_xcode_tests, "launchctl_run", return_value=result
            ):
                warning = run_xcode_tests.bootout_job(job, None)
        self.assertIsNone(warning)

    def test_bootout_absence_recognition_is_exact(self) -> None:
        cases = (
            ("no newline", "", "No such process", True),
            ("single newline", "", "No such process\n", True),
            ("bootout prefix", "", "Boot-out failed: 3: No such process", True),
            (
                "bootout prefix newline",
                "",
                "Boot-out failed: 3: No such process\n",
                True,
            ),
            ("stdout only", "No such process", "", False),
            ("extra stdout", "permission denied", "No such process", False),
            ("mixed stderr", "", "No such process; permission denied", False),
            (
                "bootout prefix mixed",
                "",
                "Boot-out failed: 3: No such process; permission denied",
                False,
            ),
            ("extra stderr line", "", "No such process\npermission denied", False),
            ("wrong case", "", "no such process", False),
            ("leading newline", "", "\nNo such process", False),
            ("double newline", "", "No such process\n\n", False),
        )
        for name, stdout, stderr, expected in cases:
            with self.subTest(name=name):
                result = subprocess.CompletedProcess([], 3, stdout, stderr)
                self.assertIs(
                    run_xcode_tests.bootout_result_is_absent(result), expected
                )

    def test_service_absence_rejects_bootout_only_diagnostic(self) -> None:
        result = subprocess.CompletedProcess(
            [], 3, "", "Boot-out failed: 3: No such process\n"
        )
        self.assertFalse(run_xcode_tests.service_is_absent(result))

    def test_bootout_uses_bootstrap_domain_and_plist(self) -> None:
        result = subprocess.CompletedProcess([], 0, "", "")
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            with mock.patch.object(
                run_xcode_tests, "launchctl_run", return_value=result
            ) as launchctl:
                run_xcode_tests.bootout_job(job, None)
        launchctl.assert_called_once_with(
            [
                "bootout",
                f"gui/{os.getuid()}",
                str(job.root / "job.plist"),
            ],
            None,
            1.5,
            None,
        )

    def test_bootout_removes_inactive_definition_before_absence_proof(self) -> None:
        loaded = True

        def launchctl(
            arguments: list[str], *_args: object
        ) -> subprocess.CompletedProcess[str]:
            nonlocal loaded
            if arguments[0] == "bootout":
                self.assertEqual(arguments[1], f"gui/{os.getuid()}")
                self.assertTrue(arguments[2].endswith("/job.plist"))
                loaded = False
                return subprocess.CompletedProcess(arguments, 0, "", "")
            self.assertEqual(arguments, ["print", job.service])
            self.assertFalse(loaded)
            return subprocess.CompletedProcess(
                arguments, 113, "", "Could not find service\n"
            )

        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            with mock.patch.object(
                run_xcode_tests, "launchctl_run", side_effect=launchctl
            ), mock.patch.object(
                run_xcode_tests, "launchctl_retry", side_effect=launchctl
            ):
                run_xcode_tests.bootout_job(job, None)
                run_xcode_tests.confirm_job_absent(job, time.monotonic() + 1)
        self.assertFalse(loaded)

    def test_bootout_status_113_absence_recognition_is_exact(self) -> None:
        contextual = (
            'Bad request.\nCould not find service "com.pomodorough.xcode-tests.unit" '
            "in domain for user gui: 501"
        )
        cases = (
            ("no newline", "", "Could not find service", True),
            ("single newline", "", "Could not find service\n", True),
            ("contextual", "", contextual, True),
            ("contextual newline", "", f"{contextual}\n", True),
            ("stdout only", "Could not find service", "", False),
            ("extra stdout", "permission denied", "Could not find service", False),
            ("suffix", "", "Could not find service: permission denied", False),
            ("prefix", "", "permission denied: Could not find service", False),
            ("mixed stderr", "", "Could not find service\npermission denied", False),
            ("wrong case", "", "could not find service", False),
            ("leading newline", "", "\nCould not find service", False),
            ("double newline", "", "Could not find service\n\n", False),
            ("context suffix", "", f"{contextual}: permission denied", False),
            ("context prefix", "", f"permission denied\n{contextual}", False),
            ("context mixed", "", f"{contextual}\npermission denied", False),
            ("context case", "", contextual.replace("Could", "could"), False),
            ("context double newline", "", f"{contextual}\n\n", False),
            ("empty", "", "", False),
        )
        for name, stdout, stderr, expected in cases:
            with self.subTest(name=name):
                result = subprocess.CompletedProcess([], 113, stdout, stderr)
                self.assertIs(
                    run_xcode_tests.bootout_result_is_absent(result), expected
                )

    def test_bootout_fails_closed_for_mixed_exit_three_error(self) -> None:
        result = subprocess.CompletedProcess(
            [], 3, "", "No such process; permission denied"
        )
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            with mock.patch.object(
                run_xcode_tests, "launchctl_run", return_value=result
            ):
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError, "permission denied"
                ):
                    run_xcode_tests.bootout_job(job, None)

    def test_lifecycle_cleanup_accepts_macos_idempotent_absence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            with mock.patch.object(
                run_xcode_tests, "cleanup_coalition_id", return_value=77
            ), mock.patch.object(run_xcode_tests, "signal_coalition_members"), mock.patch.object(
                run_xcode_tests, "drain_coalition"
            ), mock.patch.object(
                run_xcode_tests, "bootout_job", return_value=None
            ), mock.patch.object(
                run_xcode_tests, "confirm_job_absent"
            ) as confirm:
                cleanup_error = run_xcode_tests.lifecycle_cleanup_error(job, None, False)
        self.assertIsNone(cleanup_error)
        confirm.assert_called_once_with(job, mock.ANY, True)

    def test_confirm_absence_accepts_exact_missing_service_result(self) -> None:
        result = subprocess.CompletedProcess([], 113, "", "Could not find service")
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            with mock.patch.object(
                run_xcode_tests, "launchctl_retry", return_value=result
            ) as launchctl:
                run_xcode_tests.confirm_job_absent(job, time.monotonic() + 1)
        launchctl.assert_called_once_with(
            ["print", job.service], mock.ANY
        )

    def test_confirm_absence_rejects_mixed_absence_diagnostic(self) -> None:
        result = subprocess.CompletedProcess(
            [], 113, "", "Could not find service\npermission denied"
        )
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            with mock.patch.object(
                run_xcode_tests, "launchctl_retry", return_value=result
            ):
                with self.assertRaisesRegex(
                    run_xcode_tests.SimulatorLifecycleError,
                    "disappearance check exited 113",
                ):
                    run_xcode_tests.confirm_job_absent(job, time.monotonic() + 1)

    def test_successful_bootout_skips_redundant_print_probe(self) -> None:
        errors: list[str] = []
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            deadlines = run_xcode_tests.containment_cleanup_deadlines(
                time.monotonic() + 1
            )
            with mock.patch.object(
                run_xcode_tests, "bootout_job", return_value=None
            ) as bootout, mock.patch.object(
                run_xcode_tests, "launchctl_retry"
            ) as launchctl:
                run_xcode_tests.record_containment_finalization(
                    errors, job, None, deadlines
                )
        self.assertEqual(errors, [])
        bootout.assert_called_once()
        launchctl.assert_not_called()

    def test_failed_bootout_keeps_exact_absence_fallback(self) -> None:
        failure = run_xcode_tests.SimulatorLifecycleError("permission denied")
        absent = subprocess.CompletedProcess([], 113, "", "Could not find service")
        errors: list[str] = []
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            deadlines = run_xcode_tests.containment_cleanup_deadlines(
                time.monotonic() + 1
            )
            with mock.patch.object(
                run_xcode_tests, "bootout_job", side_effect=failure
            ), mock.patch.object(
                run_xcode_tests, "launchctl_retry", return_value=absent
            ) as launchctl:
                run_xcode_tests.record_containment_finalization(
                    errors, job, None, deadlines
                )
        self.assertEqual(errors, ["bootout failed: permission denied"])
        launchctl.assert_called_once_with(["print", job.service], mock.ANY)

    def test_confirm_absence_preserves_launchctl_timeout(self) -> None:
        failure = run_xcode_tests.SimulatorLifecycleError("launchctl timed out")
        with tempfile.TemporaryDirectory() as directory:
            job = launchd_job(Path(directory))
            with mock.patch.object(
                run_xcode_tests, "launchctl_retry", side_effect=failure
            ):
                with self.assertRaises(run_xcode_tests.SimulatorLifecycleError) as raised:
                    run_xcode_tests.confirm_job_absent(job, time.monotonic() + 1)
        self.assertIs(raised.exception, failure)

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
                    run_xcode_tests.confirm_job_absent(
                        job,
                        time.monotonic()
                        + run_xcode_tests.LAUNCHCTL_PROCESS_CLEANUP_SECONDS
                        + 0.05,
                    )

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
        self,
        source: str,
        idle_timeout: float = 1,
        wall_timeout: float = HOSTED_ATTEMPT_WALL_TIMEOUT,
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
        wall_timeout = HOSTED_ATTEMPT_WALL_TIMEOUT
        started = time.monotonic()
        result, _, evidence = self.run_fake_xcode(
            """
            import time
            time.sleep(30)
            """,
            idle_timeout=30,
            wall_timeout=wall_timeout,
        )
        elapsed = time.monotonic() - started
        expected = {"attempt-1-timeout.txt", "timeout.txt"}
        self.assertEqual(result.returncode, run_xcode_tests.TEST_EXECUTION_TIMEOUT)
        self.assertIn("classification=test-execution-timeout", result.stderr)
        self.assertEqual(set(evidence), expected)
        for content in evidence.values():
            self.assertIn("classification=test-execution-timeout", content)
            self.assertIn(f"wall-timeout={wall_timeout}s", content)
        self.assertLess(elapsed, wall_timeout + 2)

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
        self.assertLess(elapsed, run_xcode_tests.EVIDENCE_WRITE_SECONDS + 0.75)

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
