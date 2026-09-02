#!/usr/bin/env python3
"""Run xcodebuild with bounded execution and reviewable timeout evidence."""

from __future__ import annotations

import argparse
import codecs
import ctypes
from dataclasses import dataclass, replace
import json
from pathlib import Path
import os
import plistlib
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from typing import Callable, TextIO, TypeVar, cast


FINAL_TEST_MARKERS = (
    re.compile(
        r"Test Suite 'All tests' passed[^\n]*\n\s*Executed [1-9][0-9]* tests, with 0 failures"
    ),
)
POST_TEST_TIMEOUT = 124
TEST_EXECUTION_TIMEOUT = 125
EVIDENCE_FAILURE = 126
PRETEST_INFRASTRUCTURE_FAILURE = 127
TEST_START_MARKERS = (
    re.compile(r"Test Suite '[^']+' started"),
    re.compile(r"Test Case '[^']+' started"),
    re.compile(r"◇ Test run started\."),
)
LAUNCH_INFRASTRUCTURE_MARKERS = (
    "Failed to launch app with identifier",
    "Failed to launch test runner",
    "NSMachErrorDomain Code=-308",
    "(ipc/mig) server died",
    "Lost connection to testmanagerd",
)
SIMULATOR_DESTINATION_KEYS = frozenset({"platform", "name", "id", "OS", "arch"})
SIMULATOR_ARCHITECTURES = frozenset({"arm64", "x86_64"})
CLEANUP_RESERVE_SECONDS = 0.5
TIMEOUT_EVIDENCE_SECONDS = 0.25
EVIDENCE_WRITE_SECONDS = 0.25
EVIDENCE_WRITER_CLEANUP_SECONDS = 0.05
DESCENDANT_POLL_SECONDS = 0.001
DESCENDANT_QUIESCENCE_SECONDS = 0.02
ATTEMPT_OUTPUT_CHUNK_BYTES = 64 * 1024
CONTAINMENT_HANDSHAKE_SECONDS = 2.0
CONTAINED_CHILD_ARGUMENT = "--contained-child"
EVIDENCE_WRITER_ARGUMENT = "--evidence-writer"
LAUNCHCTL = "/bin/launchctl"
LAUNCHD_EXIT_TIMEOUT_SECONDS = 1
LAUNCHD_DELEGATION_SANDBOX = b"(version 1)(allow default)(deny job-creation)"
PROC_PIDTBSDINFO = 3
PROC_PIDUNIQIDENTIFIERINFO = 17
PROC_PIDCOALITIONINFO = 20
COALITION_TYPE_RESOURCE = 0
LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib") if sys.platform == "darwin" else None
LIBSANDBOX = (
    ctypes.CDLL("/usr/lib/libsandbox.1.dylib") if sys.platform == "darwin" else None
)


class ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_ids", ctypes.c_uint32 * 7),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


class AuditToken(ctypes.Structure):
    _fields_ = [("values", ctypes.c_uint32 * 8)]


class ProcUniqueIdentifierInfo(ctypes.Structure):
    _fields_ = [
        ("p_uuid", ctypes.c_uint8 * 16),
        ("p_uniqueid", ctypes.c_uint64),
        ("p_puniqueid", ctypes.c_uint64),
        ("p_idversion", ctypes.c_int32),
        ("p_orig_ppidversion", ctypes.c_int32),
        ("p_reserve3", ctypes.c_uint64),
        ("p_reserve4", ctypes.c_uint64),
    ]


class ProcCoalitionInfo(ctypes.Structure):
    _fields_ = [
        ("coalition_id", ctypes.c_uint64 * 2),
        ("reserved1", ctypes.c_uint64),
        ("reserved2", ctypes.c_uint64),
        ("reserved3", ctypes.c_uint64),
    ]


if LIBPROC is not None:
    LIBPROC.proc_pidinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    LIBPROC.proc_pidinfo.restype = ctypes.c_int
    LIBPROC.proc_signal_with_audittoken.argtypes = [
        ctypes.POINTER(AuditToken),
        ctypes.c_int,
    ]
    LIBPROC.proc_signal_with_audittoken.restype = ctypes.c_int
    LIBPROC.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
    LIBPROC.proc_listallpids.restype = ctypes.c_int

if LIBSANDBOX is not None:
    LIBSANDBOX.sandbox_init.argtypes = [
        ctypes.c_char_p,
        ctypes.c_uint64,
        ctypes.POINTER(ctypes.c_char_p),
    ]
    LIBSANDBOX.sandbox_init.restype = ctypes.c_int
    LIBSANDBOX.sandbox_free_error.argtypes = [ctypes.c_char_p]
    LIBSANDBOX.sandbox_free_error.restype = None


class SimulatorLifecycleError(RuntimeError):
    pass


class OperationDeadlineExpired(SimulatorLifecycleError):
    pass


DeadlineResult = TypeVar("DeadlineResult")


@dataclass(frozen=True)
class AttemptOutcome:
    returncode: int
    output: str
    timeout_reason: str | None
    process_evidence: str


@dataclass(frozen=True)
class LaunchdJob:
    label: str
    service: str
    root: Path
    stdout_path: Path
    stderr_path: Path
    status_path: Path
    identity_path: Path
    coalition_path: Path
    acknowledgement_path: Path
    coalition_id: int | None = None


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    started_at: tuple[int, int]
    audit_token: tuple[int, ...] | None = None


@dataclass(frozen=True)
class LifecycleOutcome:
    args: list[str]
    returncode: int
    stdout: str
    stderr: str
    job: LaunchdJob


@dataclass(frozen=True)
class SimulatorDestination:
    raw: str
    name: str | None
    udid: str | None
    os_version: str | None
    architecture: str | None


@dataclass(frozen=True)
class SimulatorCandidate:
    name: str
    udid: str
    state: str
    runtime: tuple[int, ...]


def tests_completed(output: str, completion_marker: str) -> bool:
    return completion_marker in output and any(
        pattern.search(output) for pattern in FINAL_TEST_MARKERS
    )


def bounded_wait(deadline: float | None, maximum: float) -> float:
    if deadline is None:
        return maximum
    return max(0.0, min(maximum, deadline - time.monotonic()))


def reserved_deadline(deadline: float | None, reserve: float) -> float | None:
    return None if deadline is None else deadline - reserve


def deadline_call(
    operation: Callable[[], DeadlineResult],
    deadline: float | None,
    timeout_message: str,
) -> DeadlineResult:
    if deadline is None:
        return operation()
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise OperationDeadlineExpired(timeout_message)
    completed = threading.Event()
    outcome: list[tuple[bool, object]] = []

    def invoke() -> None:
        try:
            outcome.append((True, operation()))
        except BaseException as error:
            outcome.append((False, error))
        finally:
            completed.set()

    threading.Thread(target=invoke, daemon=True).start()
    if not completed.wait(remaining):
        raise OperationDeadlineExpired(timeout_message)
    succeeded, value = outcome[0]
    if succeeded:
        return cast(DeadlineResult, value)
    raise cast(BaseException, value)


def signal_pid(pid: int, requested: signal.Signals) -> bool:
    try:
        os.kill(pid, requested)
        return True
    except (PermissionError, ProcessLookupError):
        return False


def unique_identifier_info(pid: int) -> ProcUniqueIdentifierInfo | None:
    assert LIBPROC is not None
    info = ProcUniqueIdentifierInfo()
    size = LIBPROC.proc_pidinfo(
        pid,
        PROC_PIDUNIQIDENTIFIERINFO,
        0,
        ctypes.byref(info),
        ctypes.sizeof(info),
    )
    return info if size == ctypes.sizeof(info) else None


def unique_process_identity(pid: int, info: ProcUniqueIdentifierInfo) -> ProcessIdentity:
    values = [0] * 8
    values[5] = pid
    values[7] = info.p_idversion
    return ProcessIdentity(pid, (info.p_uniqueid, info.p_idversion), tuple(values))


def darwin_process_record(pid: int) -> tuple[ProcessIdentity, int] | None:
    first = unique_identifier_info(pid)
    info = ProcBSDInfo()
    size = LIBPROC.proc_pidinfo(
        pid, PROC_PIDTBSDINFO, 0, ctypes.byref(info), ctypes.sizeof(info)
    )
    second = unique_identifier_info(pid)
    if (
        first is None
        or second is None
        or first.p_idversion != second.p_idversion
        or size != ctypes.sizeof(info)
        or info.pbi_pid != pid
    ):
        return None
    identity = unique_process_identity(pid, first)
    return identity, info.pbi_ppid


def process_record(pid: int) -> tuple[ProcessIdentity, int] | None:
    if LIBPROC is not None:
        return darwin_process_record(pid)
    try:
        fields = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8").rsplit(") ", 1)[1].split()
    except (FileNotFoundError, IndexError, OSError):
        return None
    return ProcessIdentity(pid, (int(fields[19]), 0)), int(fields[1])


def process_identity(pid: int) -> ProcessIdentity | None:
    record = process_record(pid)
    return None if record is None else record[0]


def resource_coalition_id(pid: int) -> int | None:
    if LIBPROC is None:
        raise SimulatorLifecycleError("Darwin coalition inspection is unavailable")
    info = ProcCoalitionInfo()
    size = LIBPROC.proc_pidinfo(
        pid,
        PROC_PIDCOALITIONINFO,
        0,
        ctypes.byref(info),
        ctypes.sizeof(info),
    )
    if size == 0:
        return None
    if size != ctypes.sizeof(info):
        raise SimulatorLifecycleError("invalid Darwin coalition record")
    return int(info.coalition_id[COALITION_TYPE_RESOURCE])


def require_census_budget(deadline: float) -> None:
    if time.monotonic() >= deadline:
        raise SimulatorLifecycleError("Darwin coalition census deadline expired")


def all_process_ids(deadline: float) -> list[int]:
    if LIBPROC is None:
        raise SimulatorLifecycleError("Darwin process census is unavailable")
    require_census_budget(deadline)
    capacity = LIBPROC.proc_listallpids(None, 0)
    require_census_budget(deadline)
    if capacity <= 0:
        raise SimulatorLifecycleError("Darwin process census failed")
    while time.monotonic() < deadline:
        values = (ctypes.c_int * capacity)()
        count = LIBPROC.proc_listallpids(values, ctypes.sizeof(values))
        require_census_budget(deadline)
        if count < 0:
            raise SimulatorLifecycleError("Darwin process census failed")
        if count < capacity:
            return [pid for pid in values[:count] if pid > 0]
        observed = LIBPROC.proc_listallpids(None, 0)
        if observed <= 0:
            raise SimulatorLifecycleError("Darwin process census failed")
        capacity = max(capacity * 2, observed + 1)
    raise SimulatorLifecycleError("Darwin process census deadline expired")


def inspect_coalition_member(pid: int, coalition_id: int) -> ProcessIdentity | None:
    first = resource_coalition_id(pid)
    if first != coalition_id:
        return None
    first_info = unique_identifier_info(pid)
    second = resource_coalition_id(pid)
    second_info = unique_identifier_info(pid)
    third = resource_coalition_id(pid)
    if first_info is None and third is None:
        return None
    if second != coalition_id or third != coalition_id:
        return None
    if first_info is None or second_info is None:
        raise SimulatorLifecycleError("coalition member identity unavailable")
    if (
        first_info.p_uniqueid != second_info.p_uniqueid
        or first_info.p_idversion != second_info.p_idversion
    ):
        return None
    return unique_process_identity(pid, first_info)


def coalition_member_identity(
    pid: int, coalition_id: int, deadline: float | None = None
) -> ProcessIdentity | None:
    return deadline_call(
        lambda: inspect_coalition_member(pid, coalition_id),
        deadline,
        "Darwin coalition member lookup deadline expired",
    )


def inspect_coalition_members(
    coalition_id: int, deadline: float
) -> list[ProcessIdentity]:
    members = []
    for pid in all_process_ids(deadline):
        require_census_budget(deadline)
        identity = inspect_coalition_member(pid, coalition_id)
        if identity is not None:
            members.append(identity)
    return members


def coalition_members(coalition_id: int, deadline: float) -> list[ProcessIdentity]:
    require_census_budget(deadline)
    return deadline_call(
        lambda: inspect_coalition_members(coalition_id, deadline),
        deadline,
        "Darwin coalition census deadline expired",
    )


def identity_is_live(identity: ProcessIdentity) -> bool:
    return process_identity(identity.pid) == identity


def signal_audit_token(
    token_values: tuple[int, ...], requested: signal.Signals
) -> bool:
    assert LIBPROC is not None
    token = AuditToken()
    token.values[:] = token_values
    return LIBPROC.proc_signal_with_audittoken(
        ctypes.byref(token), int(requested)
    ) == 0


def signal_identity(identity: ProcessIdentity, requested: signal.Signals) -> bool:
    if LIBPROC is not None:
        return identity.audit_token is not None and signal_audit_token(
            identity.audit_token, requested
        )
    return identity_is_live(identity) and signal_pid(identity.pid, requested)


def write_atomic_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(f".{secrets.token_hex(8)}.tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def identity_payload(identity: ProcessIdentity) -> dict[str, object]:
    return {
        "pid": identity.pid,
        "started_at": list(identity.started_at),
        "audit_token": list(identity.audit_token) if identity.audit_token else None,
    }


def await_containment_acknowledgement(
    path: Path, token: str, coalition_id: int
) -> None:
    expected = {"token": token, "resource_coalition_id": coalition_id}
    deadline = time.monotonic() + CONTAINMENT_HANDSHAKE_SECONDS
    while time.monotonic() < deadline:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            time.sleep(DESCENDANT_POLL_SECONDS)
            continue
        except (OSError, json.JSONDecodeError) as error:
            raise SimulatorLifecycleError("invalid containment acknowledgement") from error
        if payload != expected:
            raise SimulatorLifecycleError("forged containment acknowledgement")
        return
    raise SimulatorLifecycleError("containment acknowledgement unavailable")


def deny_launchd_job_creation() -> None:
    if LIBSANDBOX is None:
        raise SimulatorLifecycleError("Darwin launchd delegation guard is unavailable")
    error = ctypes.c_char_p()
    result = LIBSANDBOX.sandbox_init(
        LAUNCHD_DELEGATION_SANDBOX, 0, ctypes.byref(error)
    )
    if result == 0:
        return
    detail = error.value.decode("utf-8", errors="replace") if error.value else "unknown error"
    if error.value:
        LIBSANDBOX.sandbox_free_error(error)
    raise SimulatorLifecycleError(f"launchd delegation guard failed: {detail}")


def contained_child(
    status_path: Path,
    identity_path: Path,
    coalition_path: Path,
    acknowledgement_path: Path,
    acknowledgement_token: str,
    combine_stderr: bool,
    command: list[str],
) -> int:
    try:
        wrapper_identity = process_identity(os.getpid())
        if wrapper_identity is None:
            raise SimulatorLifecycleError("contained wrapper identity unavailable")
        coalition_id = resource_coalition_id(os.getpid())
        if coalition_id is None:
            raise SimulatorLifecycleError("contained coalition identity unavailable")
        write_atomic_json(
            coalition_path,
            {
                "resource_coalition_id": coalition_id,
                "wrapper": identity_payload(wrapper_identity),
            },
        )
        await_containment_acknowledgement(
            acknowledgement_path, acknowledgement_token, coalition_id
        )
        deny_launchd_job_creation()
        process = subprocess.Popen(
            command,
            stderr=subprocess.STDOUT if combine_stderr else None,
            start_new_session=True,
        )
        identity = process_identity(process.pid)
        if identity is None:
            raise SimulatorLifecycleError("contained command identity unavailable")
        write_atomic_json(identity_path, identity_payload(identity))
        returncode = process.wait()
        write_atomic_json(status_path, {"returncode": returncode})
        return returncode
    except (OSError, SimulatorLifecycleError) as error:
        write_atomic_json(status_path, {"error": str(error)})
        return PRETEST_INFRASTRUCTURE_FAILURE


def launchd_domain() -> str:
    if sys.platform != "darwin" or not Path(LAUNCHCTL).is_file():
        raise SimulatorLifecycleError("Darwin launchd containment is unavailable")
    return f"gui/{os.getuid()}"


def launchctl_run(
    arguments: list[str], deadline: float | None, maximum: float = 2.0
) -> subprocess.CompletedProcess[str]:
    timeout = bounded_wait(deadline, maximum)
    if timeout <= 0:
        raise SimulatorLifecycleError("launchd containment deadline expired")
    try:
        return subprocess.run(
            [LAUNCHCTL, *arguments],
            capture_output=True,
            check=False,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        raise SimulatorLifecycleError("launchctl timed out") from error


def launchctl_retry(
    arguments: list[str], deadline: float, maximum: float = 0.25
) -> subprocess.CompletedProcess[str]:
    last_timeout: SimulatorLifecycleError | None = None
    while time.monotonic() < deadline:
        try:
            return launchctl_run(arguments, deadline, maximum)
        except SimulatorLifecycleError as error:
            if not isinstance(error.__cause__, subprocess.TimeoutExpired):
                raise
            last_timeout = error
    if last_timeout is not None:
        raise last_timeout
    raise SimulatorLifecycleError("launchd containment deadline expired")


def launchd_plist(
    job: LaunchdJob,
    command: list[str],
    combine_stderr: bool,
    acknowledgement_token: str,
) -> dict[str, object]:
    arguments = [
        sys.executable,
        str(Path(__file__).resolve()),
        CONTAINED_CHILD_ARGUMENT,
        str(job.status_path),
        str(job.identity_path),
        str(job.coalition_path),
        str(job.acknowledgement_path),
        acknowledgement_token,
        "1" if combine_stderr else "0",
        "--",
        *command,
    ]
    return {
        "Label": job.label,
        "ProgramArguments": arguments,
        "WorkingDirectory": os.getcwd(),
        "EnvironmentVariables": dict(os.environ),
        "RunAtLoad": True,
        "ProcessType": "Interactive",
        "ExitTimeOut": LAUNCHD_EXIT_TIMEOUT_SECONDS,
        "Umask": 0o077,
        "StandardOutPath": str(job.stdout_path),
        "StandardErrorPath": str(job.stderr_path),
    }


def create_launchd_job() -> LaunchdJob:
    root = Path(tempfile.mkdtemp(prefix="pomodorough-xcode-tests-"))
    label = f"com.pomodorough.xcode-tests.{secrets.token_hex(16)}"
    return LaunchdJob(
        label,
        f"{launchd_domain()}/{label}",
        root,
        root / "stdout.log",
        root / "stderr.log",
        root / "status.json",
        root / "identity.json",
        root / "coalition.json",
        root / "acknowledgement.json",
    )


def await_containment_handshake(
    job: LaunchdJob, setup_deadline: float | None
) -> tuple[object, int, ProcessIdentity]:
    handshake_by = time.monotonic() + CONTAINMENT_HANDSHAKE_SECONDS
    if setup_deadline is not None:
        handshake_by = min(handshake_by, setup_deadline)
    payload = wait_for_containment_sidecar(job, handshake_by)
    coalition_id, wrapper_identity = launchd_service_containment(job, handshake_by)
    return payload, coalition_id, wrapper_identity


def spawn_contained_job(
    command: list[str], combine_stderr: bool, deadline: float | None
) -> LaunchdJob:
    job = create_launchd_job()
    plist_path = job.root / "job.plist"
    acknowledgement_token = secrets.token_hex(32)
    setup_deadline = reserved_deadline(deadline, CLEANUP_RESERVE_SECONDS)
    bootstrap_attempted = False
    coalition_id: int | None = None
    try:
        with plist_path.open("wb") as stream:
            plistlib.dump(
                launchd_plist(job, command, combine_stderr, acknowledgement_token),
                stream,
            )
        bootstrap_attempted = True
        result = launchctl_run(
            ["bootstrap", launchd_domain(), str(plist_path)], setup_deadline
        )
        if result.returncode:
            raise SimulatorLifecycleError(
                f"launchd bootstrap exited {result.returncode}: {result.stderr.strip()}"
            )
        containment_payload, coalition_id, wrapper_identity = await_containment_handshake(
            job, setup_deadline
        )
        bound_job = replace(job, coalition_id=coalition_id)
        validate_containment_sidecar(
            bound_job, wrapper_identity, containment_payload
        )
        write_atomic_json(
            job.acknowledgement_path,
            {
                "token": acknowledgement_token,
                "resource_coalition_id": coalition_id,
            },
        )
        return bound_job
    except Exception as error:
        cleanup_error: SimulatorLifecycleError | None = None
        if bootstrap_attempted:
            try:
                abort_containment_handshake(job, coalition_id, deadline)
            except SimulatorLifecycleError as caught:
                cleanup_error = caught
        shutil.rmtree(job.root, ignore_errors=True)
        if cleanup_error is not None:
            raise cleanup_error from error
        raise


def read_json(path: Path) -> object | None:
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SimulatorLifecycleError(f"invalid containment sidecar {path.name}") from error


def process_identity_from_payload(payload: object, label: str) -> ProcessIdentity:
    if not isinstance(payload, dict):
        raise SimulatorLifecycleError(f"invalid {label}")
    pid, started_at, token = (
        payload.get("pid"),
        payload.get("started_at"),
        payload.get("audit_token"),
    )
    if not isinstance(pid, int) or not isinstance(started_at, list) or len(started_at) != 2:
        raise SimulatorLifecycleError(f"invalid {label}")
    if not all(isinstance(value, int) for value in started_at):
        raise SimulatorLifecycleError(f"invalid {label} start time")
    if token is not None and (
        not isinstance(token, list)
        or len(token) != 8
        or not all(isinstance(value, int) for value in token)
    ):
        raise SimulatorLifecycleError(f"invalid {label} audit token")
    return ProcessIdentity(pid, tuple(started_at), None if token is None else tuple(token))


def launchd_service_pid(job: LaunchdJob, deadline: float) -> int:
    while time.monotonic() < deadline:
        result = launchctl_retry(["print", job.service], deadline)
        if service_is_absent(result):
            raise SimulatorLifecycleError("launchd containment disappeared")
        if result.returncode:
            raise SimulatorLifecycleError(
                f"launchd containment inspection exited {result.returncode}"
            )
        matches = re.findall(r"^\s*pid = ([1-9][0-9]*)\s*$", result.stdout, re.MULTILINE)
        if len(matches) == 1:
            return int(matches[0])
        if len(matches) > 1:
            raise SimulatorLifecycleError("ambiguous launchd containment process")
        time.sleep(min(DESCENDANT_POLL_SECONDS, deadline - time.monotonic()))
    raise SimulatorLifecycleError("launchd containment process unavailable")


def launchd_service_containment(
    job: LaunchdJob, deadline: float
) -> tuple[int, ProcessIdentity]:
    pid = launchd_service_pid(job, deadline)
    identity, coalition_id, parent_coalition = deadline_call(
        lambda: (
            process_identity(pid),
            resource_coalition_id(pid),
            resource_coalition_id(os.getpid()),
        ),
        deadline,
        "launchd containment validation deadline expired",
    )
    if identity is None:
        raise SimulatorLifecycleError("unstable launchd containment identity")
    if coalition_id is None or coalition_id <= 0 or coalition_id == parent_coalition:
        raise SimulatorLifecycleError("unsafe contained coalition identity")
    return coalition_id, identity


def wait_for_containment_sidecar(job: LaunchdJob, deadline: float) -> object:
    while time.monotonic() < deadline:
        payload = read_json(job.coalition_path)
        if payload is not None:
            return payload
        status = read_json(job.status_path)
        if status is not None:
            raise SimulatorLifecycleError("contained wrapper exited before acknowledgement")
        time.sleep(min(DESCENDANT_POLL_SECONDS, deadline - time.monotonic()))
    raise SimulatorLifecycleError("contained coalition identity unavailable")


def validate_containment_sidecar(
    job: LaunchdJob, wrapper_identity: ProcessIdentity, payload: object
) -> None:
    if not isinstance(payload, dict):
        raise SimulatorLifecycleError("invalid contained coalition identity")
    coalition_id = payload.get("resource_coalition_id")
    sidecar_identity = process_identity_from_payload(
        payload.get("wrapper"), "contained wrapper identity"
    )
    if coalition_id != job.coalition_id or sidecar_identity != wrapper_identity:
        raise SimulatorLifecycleError("forged contained coalition identity")


def job_status(job: LaunchdJob, deadline: float | None = None) -> int | None:
    payload = deadline_call(
        lambda: read_json(job.status_path),
        deadline,
        "contained command status read deadline expired",
    )
    if payload is None:
        return None
    if not isinstance(payload, dict) or "error" in payload:
        detail = payload.get("error") if isinstance(payload, dict) else payload
        raise SimulatorLifecycleError(f"contained command failed to start: {detail}")
    returncode = payload.get("returncode")
    if isinstance(returncode, bool) or not isinstance(returncode, int):
        raise SimulatorLifecycleError("invalid contained command return code")
    return returncode


def job_identity(job: LaunchdJob) -> ProcessIdentity | None:
    payload = read_json(job.identity_path)
    if payload is None:
        return None
    return process_identity_from_payload(payload, "contained command identity")


def job_coalition_id(job: LaunchdJob) -> int:
    coalition_id = job.coalition_id
    if coalition_id is None:
        raise SimulatorLifecycleError("contained coalition identity unavailable")
    if coalition_id <= 0:
        raise SimulatorLifecycleError("unsafe contained coalition identity")
    return coalition_id


def signal_job_root(job: LaunchdJob, requested: signal.Signals) -> bool:
    identity = job_identity(job)
    return identity is not None and signal_identity(identity, requested)


def service_is_absent(result: subprocess.CompletedProcess[str]) -> bool:
    return result.returncode == 113 and "Could not find service" in result.stderr


def launchd_job_evidence(job: LaunchdJob, deadline: float | None) -> str:
    try:
        result = launchctl_run(["print", job.service], deadline)
    except SimulatorLifecycleError as error:
        return f"service={job.service}\nlaunchd evidence error = {error}\n"
    if service_is_absent(result):
        return f"service={job.service}\nstate=absent\n"
    if result.returncode:
        return f"service={job.service}\nlaunchctl-exit={result.returncode}\n"
    safe = re.compile(
        r"^(\s*(state|pid|active count|last exit code|last terminating signal|"
        r"resource coalition|jetsam coalition|ID|type|name|runs)\s*=|\s*[{}])"
    )
    lines = [line for line in result.stdout.splitlines() if safe.search(line)]
    try:
        coalition_id = job_coalition_id(job)
        census_deadline = deadline or time.monotonic() + CLEANUP_RESERVE_SECONDS
        lines.append(f"kernel coalition = {coalition_id}")
        lines.append(f"kernel member count = {len(coalition_members(coalition_id, census_deadline))}")
    except SimulatorLifecycleError as error:
        lines.append(f"kernel coalition evidence error = {error}")
    return f"service={job.service}\n" + "\n".join(lines) + "\n"


def pause_before_cleanup(deadline: float | None, maximum: float) -> None:
    wait = bounded_wait(deadline, maximum)
    if wait > 0:
        time.sleep(wait)


def bootout_job(job: LaunchdJob, deadline: float | None) -> None:
    result = launchctl_run(["bootout", job.service], deadline, 1.5)
    if result.returncode and not service_is_absent(result):
        raise SimulatorLifecycleError(
            f"launchd bootout exited {result.returncode}: {result.stderr.strip()}"
        )


def confirm_job_absent(job: LaunchdJob, deadline: float | None) -> None:
    cleanup_by = cleanup_deadline(deadline)
    while True:
        if time.monotonic() >= cleanup_by:
            raise SimulatorLifecycleError("launchd containment cleanup incomplete")
        try:
            result = launchctl_retry(["print", job.service], cleanup_by)
        except SimulatorLifecycleError as error:
            if time.monotonic() >= cleanup_by:
                raise SimulatorLifecycleError(
                    "launchd containment cleanup incomplete"
                ) from error
            raise
        if service_is_absent(result):
            return
        elif result.returncode:
            raise SimulatorLifecycleError(
                f"launchd disappearance check exited {result.returncode}"
            )
        wait = bounded_wait(cleanup_by, DESCENDANT_POLL_SECONDS)
        if wait <= 0:
            raise SimulatorLifecycleError("launchd containment cleanup incomplete")
        time.sleep(wait)


def signal_coalition_members(
    coalition_id: int, requested: signal.Signals, deadline: float
) -> None:
    for identity in coalition_members(coalition_id, deadline):
        require_census_budget(deadline)
        current = coalition_member_identity(identity.pid, coalition_id, deadline)
        if current != identity:
            continue
        signaled = signal_identity(identity, requested)
        require_census_budget(deadline)
        if signaled:
            continue
        current = coalition_member_identity(identity.pid, coalition_id, deadline)
        if current == identity:
            raise SimulatorLifecycleError("identity-bound coalition signal failed")


def drain_coalition(coalition_id: int, deadline: float) -> None:
    empty_since: float | None = None
    while time.monotonic() < deadline:
        members = coalition_members(coalition_id, deadline)
        now = time.monotonic()
        if members:
            empty_since = None
            signal_coalition_members(coalition_id, signal.SIGKILL, deadline)
        else:
            empty_since = empty_since or now
            if now - empty_since >= DESCENDANT_QUIESCENCE_SECONDS:
                return
        wait = bounded_wait(deadline, DESCENDANT_POLL_SECONDS)
        if wait > 0:
            time.sleep(wait)
    raise SimulatorLifecycleError("coalition cleanup incomplete")


def cleanup_deadline(deadline: float | None) -> float:
    return deadline or time.monotonic() + CLEANUP_RESERVE_SECONDS


def abort_containment_handshake(
    job: LaunchdJob, coalition_id: int | None, deadline: float | None
) -> None:
    cleanup_by = cleanup_deadline(deadline)
    bootout_job(job, cleanup_by)
    if coalition_id is not None:
        drain_coalition(coalition_id, cleanup_by)
    confirm_job_absent(job, cleanup_by)


def cleanup_coalition_id(job: LaunchdJob, deadline: float) -> int:
    try:
        return job_coalition_id(job)
    except SimulatorLifecycleError:
        bootout_job(job, deadline)
        confirm_job_absent(job, deadline)
        raise


def cleanup_contained_job(
    job: LaunchdJob, deadline: float | None, _signal_root: bool
) -> None:
    cleanup_by = cleanup_deadline(deadline)
    coalition_id = cleanup_coalition_id(job, cleanup_by)
    phases = [(signal.SIGINT, 0.05), (signal.SIGTERM, 0.1)]
    if hasattr(signal, "SIGINFO"):
        phases.insert(0, (signal.SIGINFO, 0.02))
    for requested, pause in phases:
        signal_coalition_members(coalition_id, requested, cleanup_by)
        pause_before_cleanup(cleanup_by, pause)
    bootout_job(job, cleanup_by)
    drain_coalition(coalition_id, cleanup_by)
    confirm_job_absent(job, cleanup_by)


def job_output(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""
    except UnicodeDecodeError as error:
        raise SimulatorLifecycleError(f"invalid UTF-8 command output in {path.name}") from error


def wait_for_job_status(
    job: LaunchdJob, timeout: float, wall_deadline: float | None = None
) -> int | None:
    deadline = time.monotonic() + timeout
    observation_deadline = reserved_deadline(wall_deadline, CLEANUP_RESERVE_SECONDS)
    if observation_deadline is not None:
        deadline = min(deadline, observation_deadline)
    while time.monotonic() < deadline:
        returncode = job_status(job, deadline)
        if returncode is not None:
            return returncode
        time.sleep(bounded_wait(deadline, DESCENDANT_POLL_SECONDS))
    return None


def write_timeout_evidence(
    args: argparse.Namespace,
    attempt: int,
    classification: str,
    timeout_reason: str,
    started: float,
    process_evidence: str,
) -> None:
    content = "\n".join(
        [
            f"attempt={attempt}",
            f"classification={classification}",
            timeout_reason,
            f"elapsed={time.monotonic() - started:.1f}s",
            "",
            process_evidence,
        ]
    )
    paths = (
        args.diagnostics_dir / f"attempt-{attempt}-timeout.txt",
        args.diagnostics_dir / "timeout.txt",
    )
    errors: list[OSError] = []
    for path in paths:
        try:
            write_text_bounded(path, content, evidence_write_deadline())
        except OSError as error:
            errors.append(error)
    if errors:
        raise errors[0]


def terminate_evidence_writer(
    process: subprocess.Popen[bytes], deadline: float
) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    timeout = bounded_wait(deadline, EVIDENCE_WRITER_CLEANUP_SECONDS)
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise OSError("timeout evidence writer could not be terminated") from error


def write_text_bounded(path: Path, content: str, deadline: float) -> None:
    remaining = deadline - time.monotonic()
    write_timeout = remaining - EVIDENCE_WRITER_CLEANUP_SECONDS
    if write_timeout <= 0:
        raise OSError("timeout evidence write deadline expired")
    process = subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), EVIDENCE_WRITER_ARGUMENT, str(path)],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        _, stderr = process.communicate(content.encode("utf-8"), timeout=write_timeout)
    except subprocess.TimeoutExpired as error:
        try:
            terminate_evidence_writer(process, deadline)
        finally:
            if process.stdin is not None:
                process.stdin.close()
            if process.stderr is not None:
                process.stderr.close()
        raise OSError("timeout evidence write deadline expired") from error
    if process.returncode != 0:
        message = stderr.decode("utf-8", "replace").strip()
        raise OSError(message or "timeout evidence writer failed")


def read_job_bytes_now(path: Path, offset: int) -> tuple[bytes, int]:
    try:
        with path.open("rb") as stream:
            stream.seek(offset)
            content = stream.read(ATTEMPT_OUTPUT_CHUNK_BYTES)
    except FileNotFoundError:
        return b"", offset
    return content, offset + len(content)


def read_job_bytes(
    path: Path, offset: int, deadline: float | None = None
) -> tuple[bytes, int]:
    return deadline_call(
        lambda: read_job_bytes_now(path, offset),
        deadline,
        "attempt output read deadline expired",
    )


def writer_file_descriptor(writer: Callable[[str], object]) -> int | None:
    owner = getattr(writer, "__self__", None)
    if owner is None:
        return None
    try:
        descriptor = owner.fileno()
    except (AttributeError, OSError):
        return None
    return descriptor if isinstance(descriptor, int) else None


def write_text_now(writer: Callable[[str], object], content: str) -> bool:
    descriptor = writer_file_descriptor(writer)
    if descriptor is None:
        writer(content)
        return False
    remaining = memoryview(content.encode("utf-8"))
    while remaining:
        written = os.write(descriptor, remaining)
        if written <= 0:
            raise OSError("attempt output write made no progress")
        remaining = remaining[written:]
    return True


def write_attempt_output(
    writer: Callable[[str], object], content: str, deadline: float | None
) -> tuple[bool, bool]:
    try:
        raw_write = deadline_call(
            lambda: write_text_now(writer, content),
            deadline,
            "attempt output write deadline expired",
        )
    except OperationDeadlineExpired:
        return False, False
    return True, raw_write


def publish_attempt_output(
    content: str,
    log: TextIO,
    evidence_errors: list[OSError],
    deadline: float | None = None,
) -> bool:
    if not content:
        return True
    if deadline is not None and time.monotonic() >= deadline:
        return False
    if not evidence_errors:
        try:
            written, _ = write_attempt_output(log.write, content, deadline)
            if not written:
                return False
        except OSError as error:
            evidence_errors.append(error)
    written, raw_write = write_attempt_output(sys.stdout.write, content, deadline)
    if not written:
        return False
    if raw_write:
        return True
    try:
        deadline_call(
            sys.stdout.flush, deadline, "attempt output flush deadline expired"
        )
    except OperationDeadlineExpired:
        return False
    return True


def observe_attempt(
    job: LaunchdJob,
    args: argparse.Namespace,
    run_started: float,
    log: TextIO,
    evidence_errors: list[OSError],
) -> tuple[int | None, str, str | None]:
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    raw_output = bytearray()
    offset = 0
    last_output = time.monotonic()
    wall_deadline = getattr(args, "wall_deadline", run_started + args.wall_timeout)
    stop_deadline = wall_deadline - CLEANUP_RESERVE_SECONDS - TIMEOUT_EVIDENCE_SECONDS
    returncode: int | None = None
    timeout_reason: str | None = None
    while True:
        now = time.monotonic()
        if now >= stop_deadline:
            timeout_reason = f"wall-timeout={args.wall_timeout:g}s"
            break
        try:
            returncode = job_status(job, stop_deadline)
            chunk, next_offset = read_job_bytes(
                job.stdout_path, offset, stop_deadline
            )
        except OperationDeadlineExpired:
            timeout_reason = f"wall-timeout={args.wall_timeout:g}s"
            break
        offset = next_offset
        final_chunk = returncode is not None and len(chunk) < ATTEMPT_OUTPUT_CHUNK_BYTES
        if chunk:
            raw_output.extend(chunk)
            last_output = time.monotonic()
        content = decoder.decode(chunk, final=final_chunk)
        if not publish_attempt_output(content, log, evidence_errors, stop_deadline):
            timeout_reason = f"wall-timeout={args.wall_timeout:g}s"
            break
        if final_chunk:
            break
        now = time.monotonic()
        if now >= stop_deadline:
            timeout_reason = f"wall-timeout={args.wall_timeout:g}s"
            break
        if now - last_output >= args.idle_timeout:
            timeout_reason = f"idle-timeout={args.idle_timeout:g}s"
            break
        wait = bounded_wait(stop_deadline, min(0.05, args.idle_timeout / 4))
        if wait > 0:
            time.sleep(wait)
    return returncode, raw_output.decode("utf-8", "replace"), timeout_reason


def evidence_failed(evidence_errors: list[OSError]) -> bool:
    if not evidence_errors:
        return False
    print(f"classification=evidence-write-failure; {evidence_errors[0]}", file=sys.stderr)
    return True


def remaining_wall_budget(args: argparse.Namespace) -> float | None:
    deadline = getattr(args, "wall_deadline", None)
    return None if deadline is None else deadline - time.monotonic()


def process_evidence_deadline(wall_deadline: float | None) -> float:
    evidence_deadline = time.monotonic() + TIMEOUT_EVIDENCE_SECONDS
    if wall_deadline is None:
        return evidence_deadline
    return min(evidence_deadline, wall_deadline - CLEANUP_RESERVE_SECONDS)


def evidence_write_deadline() -> float:
    return time.monotonic() + EVIDENCE_WRITE_SECONDS


def lifecycle_timeout(
    args: argparse.Namespace, label: str, requested: float | None
) -> float:
    configured = requested or getattr(args, "simulator_timeout", 120.0)
    remaining = remaining_wall_budget(args)
    available = None if remaining is None else remaining - CLEANUP_RESERVE_SECONDS
    if available is not None and available <= 0:
        raise SimulatorLifecycleError(f"wall timeout exhausted before {label}")
    return configured if available is None else min(configured, available)


def lifecycle_process(
    command: list[str], timeout: float, deadline: float | None
) -> LifecycleOutcome:
    job = spawn_contained_job(command, False, deadline)
    try:
        returncode = wait_for_job_status(job, timeout, deadline)
        cleanup_contained_job(job, deadline, returncode is None)
        stdout = job_output(job.stdout_path)
        stderr = job_output(job.stderr_path)
        if returncode is None:
            raise subprocess.TimeoutExpired(command, timeout, stdout, stderr)
        return LifecycleOutcome(command, returncode, stdout, stderr, job)
    except Exception:
        if job.root.exists():
            try:
                cleanup_contained_job(job, deadline, True)
            except SimulatorLifecycleError:
                pass
        raise
    finally:
        shutil.rmtree(job.root, ignore_errors=True)


def lifecycle_command(
    args: argparse.Namespace,
    label: str,
    command: list[str],
    check: bool = True,
    timeout: float | None = None,
) -> LifecycleOutcome:
    command_timeout = lifecycle_timeout(args, label, timeout)
    deadline = getattr(args, "wall_deadline", None)
    try:
        result = lifecycle_process(command, command_timeout, deadline)
    except subprocess.TimeoutExpired as error:
        append_lifecycle_evidence(args, label, command, None, error.stdout, error.stderr)
        raise SimulatorLifecycleError(
            f"{label} timed out after {command_timeout:g}s"
        ) from error
    append_lifecycle_evidence(
        args, label, command, result.returncode, result.stdout, result.stderr
    )
    if check and result.returncode:
        raise SimulatorLifecycleError(f"{label} exited {result.returncode}")
    return result


def diagnostic_command(
    args: argparse.Namespace, label: str, command: list[str]
) -> None:
    timeout = min(getattr(args, "simulator_timeout", 120.0), 20.0)
    try:
        lifecycle_command(args, label, command, check=False, timeout=timeout)
    except SimulatorLifecycleError as error:
        print(f"classification=simulator-diagnostic-failure; {error}", file=sys.stderr)


def sleep_with_wall_budget(
    args: argparse.Namespace, duration: float, label: str
) -> None:
    remaining = remaining_wall_budget(args)
    if remaining is not None and remaining < duration + CLEANUP_RESERVE_SECONDS:
        raise SimulatorLifecycleError(f"wall timeout exhausted before {label}")
    time.sleep(duration)


def append_lifecycle_evidence(
    args: argparse.Namespace,
    label: str,
    command: list[str],
    returncode: int | None,
    stdout: str | bytes | None,
    stderr: str | bytes | None,
) -> None:
    def display(value: str | bytes | None) -> str:
        if isinstance(value, bytes):
            return value.decode("utf-8", errors="replace")
        return value or ""

    content = (
        f"## {label}\ncommand={command!r}\nreturncode={returncode}\n"
        f"stdout:\n{display(stdout)}\nstderr:\n{display(stderr)}\n"
    )
    path = args.diagnostics_dir / "simulator-lifecycle.log"
    with path.open("a", encoding="utf-8") as evidence:
        evidence.write(content)


def normalized_version(version: tuple[int, ...]) -> tuple[int, ...]:
    values = list(version)
    while len(values) > 1 and values[-1] == 0:
        values.pop()
    return tuple(values)


def runtime_version(identifier: str) -> tuple[int, ...]:
    match = re.search(r"(?:^|\.)iOS-(\d+(?:-\d+)*)$", identifier)
    if match is None:
        raise SimulatorLifecycleError(f"unsupported simulator runtime {identifier!r}")
    return normalized_version(tuple(int(value) for value in match.group(1).split("-")))


def requested_os_version(value: str | None) -> tuple[int, ...] | None:
    if value is None or value == "latest":
        return None
    if not re.fullmatch(r"\d+(?:\.\d+)*", value):
        raise SimulatorLifecycleError(f"unsupported simulator OS constraint {value!r}")
    return normalized_version(tuple(int(component) for component in value.split(".")))


def simulator_candidates(
    devices: object, destination: SimulatorDestination
) -> list[SimulatorCandidate]:
    if not isinstance(devices, dict):
        raise SimulatorLifecycleError("malformed simulator inventory")
    candidates: list[SimulatorCandidate] = []
    for runtime_identifier, runtime_devices in devices.items():
        if not isinstance(runtime_identifier, str) or not isinstance(runtime_devices, list):
            raise SimulatorLifecycleError("malformed simulator inventory")
        if ".iOS-" not in runtime_identifier:
            continue
        runtime = runtime_version(runtime_identifier)
        for device in runtime_devices:
            if not isinstance(device, dict) or not device.get("isAvailable"):
                continue
            name = device.get("name")
            udid = device.get("udid")
            state = device.get("state")
            if not all(isinstance(value, str) for value in (name, udid, state)):
                raise SimulatorLifecycleError("malformed selected simulator")
            if destination.name is None or name == destination.name:
                candidates.append(SimulatorCandidate(name, udid, state, runtime))
    return candidates


def constrained_candidates(
    candidates: list[SimulatorCandidate], destination: SimulatorDestination
) -> list[SimulatorCandidate]:
    expected_os = requested_os_version(destination.os_version)
    if destination.os_version in (None, "latest") and candidates:
        expected_os = max(candidate.runtime for candidate in candidates)
    selected = [
        candidate
        for candidate in candidates
        if (destination.udid is None or candidate.udid == destination.udid)
        and (expected_os is None or candidate.runtime == expected_os)
    ]
    return selected


def available_simulator(args: argparse.Namespace) -> tuple[str, str]:
    result = lifecycle_command(
        args,
        "list-available-simulators",
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
    )
    try:
        devices = json.loads(result.stdout)["devices"]
    except (KeyError, TypeError, json.JSONDecodeError) as error:
        raise SimulatorLifecycleError("malformed simulator inventory") from error
    destination = args.simulator_destination
    matches = constrained_candidates(simulator_candidates(devices, destination), destination)
    if not matches:
        raise SimulatorLifecycleError(
            f"no available simulator satisfies destination {destination.raw!r}"
        )
    selected = next(
        (device for device in matches if device.state == "Booted"),
        matches[0],
    )
    return selected.udid, selected.state


def boot_and_check_simulator(
    args: argparse.Namespace, udid: str, state: str
) -> None:
    if state != "Booted":
        lifecycle_command(args, "boot-simulator", ["xcrun", "simctl", "boot", udid])
    lifecycle_command(
        args, "wait-for-simulator-boot", ["xcrun", "simctl", "bootstatus", udid, "-b"]
    )
    lifecycle_command(
        args,
        "check-simulator-springboard",
        [
            "xcrun",
            "simctl",
            "spawn",
            udid,
            "launchctl",
            "print",
            "system/com.apple.SpringBoard",
        ],
    )
    lifecycle_command(
        args, "check-simulator-services", ["xcrun", "simctl", "listapps", udid]
    )


def capture_simulator_diagnostics(
    args: argparse.Namespace, udid: str | None, label: str
) -> None:
    diagnostic_command(
        args, f"{label}-devices", ["xcrun", "simctl", "list", "devices"]
    )
    if udid is not None:
        diagnostic_command(
            args,
            f"{label}-springboard",
            [
                "xcrun",
                "simctl",
                "spawn",
                udid,
                "launchctl",
                "print",
                "system/com.apple.SpringBoard",
            ],
        )
    diagnostic_command(
        args,
        f"{label}-host-processes",
        ["ps", "-axo", "pid=,ppid=,etime=,state=,command="],
    )


def recover_simulator(args: argparse.Namespace, udid: str | None, label: str) -> str:
    capture_simulator_diagnostics(args, udid, f"{label}-before-recovery")
    if udid is not None:
        diagnostic_command(
            args,
            "shutdown-simulator",
            ["xcrun", "simctl", "shutdown", udid],
        )
    lifecycle_command(
        args,
        "restart-core-simulator-service",
        ["killall", "-9", "com.apple.CoreSimulator.CoreSimulatorService"],
        check=False,
    )
    sleep_with_wall_budget(args, 2, "CoreSimulator restart delay")
    recovered_udid, recovered_state = available_simulator(args)
    if recovered_state == "Booted":
        lifecycle_command(
            args,
            "shutdown-recovered-simulator",
            ["xcrun", "simctl", "shutdown", recovered_udid],
        )
        recovered_state = "Shutdown"
    boot_and_check_simulator(args, recovered_udid, recovered_state)
    capture_simulator_diagnostics(args, recovered_udid, f"{label}-after-recovery")
    return recovered_udid


def bind_simulator_destination(command: list[str], udid: str) -> list[str]:
    indices = [index for index, value in enumerate(command) if value == "-destination"]
    if len(indices) != 1 or indices[0] + 1 >= len(command):
        raise SimulatorLifecycleError("xcodebuild command needs one -destination value")
    destination = parse_simulator_destination(command[indices[0] + 1])
    if destination is None:
        raise SimulatorLifecycleError("xcodebuild destination is not an iOS Simulator")
    if destination.udid is not None:
        if destination.udid != udid:
            raise SimulatorLifecycleError("selected simulator violates exact id constraint")
        return command.copy()
    bound = command.copy()
    bound_destination = f"platform=iOS Simulator,id={udid}"
    if destination.architecture is not None:
        bound_destination += f",arch={destination.architecture}"
    bound[indices[0] + 1] = bound_destination
    return bound


def command_option(command: list[str], option: str) -> str | None:
    indices = [index for index, value in enumerate(command) if value == option]
    if not indices:
        return None
    if len(indices) != 1 or indices[0] + 1 >= len(command):
        raise SimulatorLifecycleError(f"xcodebuild command needs at most one {option} value")
    return command[indices[0] + 1]


def parse_simulator_destination(value: str) -> SimulatorDestination | None:
    fields: dict[str, str] = {}
    for component in value.split(","):
        key, separator, field_value = component.partition("=")
        if not separator or not key or not field_value or key in fields:
            raise SimulatorLifecycleError("malformed xcodebuild destination")
        fields[key] = field_value
    if fields.get("platform") != "iOS Simulator":
        return None
    unsupported = fields.keys() - SIMULATOR_DESTINATION_KEYS
    if unsupported:
        raise SimulatorLifecycleError(
            f"unsupported iOS Simulator constraints: {sorted(unsupported)!r}"
        )
    if not fields.get("name") and not fields.get("id"):
        raise SimulatorLifecycleError("iOS Simulator destination needs a name or id")
    requested_os_version(fields.get("OS"))
    architecture = fields.get("arch")
    if architecture is not None and architecture not in SIMULATOR_ARCHITECTURES:
        raise SimulatorLifecycleError(
            f"unsupported iOS Simulator architecture {architecture!r}"
        )
    return SimulatorDestination(
        value,
        fields.get("name"),
        fields.get("id"),
        fields.get("OS"),
        architecture,
    )


def simulator_destination_from_command(
    command: list[str], simulator_name: str | None
) -> SimulatorDestination | None:
    raw_destination = command_option(command, "-destination")
    destination = (
        parse_simulator_destination(raw_destination) if raw_destination is not None else None
    )
    if destination is None:
        if simulator_name:
            raise SimulatorLifecycleError(
                "--simulator-name needs an iOS Simulator destination"
            )
        return None
    if simulator_name and destination.name not in (None, simulator_name):
        raise SimulatorLifecycleError("--simulator-name conflicts with destination name")
    return replace(destination, name=simulator_name) if simulator_name else destination


def simulator_name_from_command(command: list[str]) -> str | None:
    destination = simulator_destination_from_command(command, None)
    return None if destination is None else destination.name


def configure_simulator(args: argparse.Namespace) -> None:
    simulator_name = getattr(args, "simulator_name", None)
    destination = simulator_destination_from_command(args.command, simulator_name)
    args.simulator_destination = destination
    args.simulator_name = destination.name if destination is not None else None
    if destination is None:
        return
    if not getattr(args, "result_bundle_path", None):
        result_path = command_option(args.command, "-resultBundlePath")
        args.result_bundle_path = Path(result_path) if result_path else None
    if args.result_bundle_path is None:
        raise SimulatorLifecycleError("simulator tests need -resultBundlePath")


def test_execution_started(output: str) -> bool:
    return any(pattern.search(output) for pattern in TEST_START_MARKERS)


def recoverable_launch_failure(outcome: AttemptOutcome) -> bool:
    if outcome.timeout_reason is None and outcome.returncode == 0:
        return False
    if test_execution_started(outcome.output):
        return False
    return any(marker in outcome.output for marker in LAUNCH_INFRASTRUCTURE_MARKERS)


def write_log_header(
    log: TextIO, attempt: int, evidence_errors: list[OSError]
) -> None:
    try:
        log.write(f"\n=== xcodebuild attempt {attempt} ===\n")
    except OSError as error:
        evidence_errors.append(error)


def run_attempt(
    args: argparse.Namespace,
    command: list[str],
    log: TextIO,
    attempt: int,
    run_started: float,
    evidence_errors: list[OSError],
) -> AttemptOutcome:
    write_log_header(log, attempt, evidence_errors)
    remaining = remaining_wall_budget(args)
    required_reserve = CLEANUP_RESERVE_SECONDS + TIMEOUT_EVIDENCE_SECONDS
    if remaining is not None and remaining <= required_reserve:
        raise SimulatorLifecycleError("wall timeout exhausted before xcodebuild")
    deadline = getattr(args, "wall_deadline", None)
    job = spawn_contained_job(command, True, deadline)
    try:
        returncode, output, timeout_reason = observe_attempt(
            job, args, run_started, log, evidence_errors
        )
        process_evidence = ""
        if timeout_reason:
            evidence_deadline = process_evidence_deadline(deadline)
            process_evidence = launchd_job_evidence(job, evidence_deadline)
        cleanup_contained_job(job, deadline, timeout_reason is not None)
        return AttemptOutcome(
            returncode if returncode is not None else -signal.SIGKILL,
            output,
            timeout_reason,
            process_evidence,
        )
    except Exception:
        if job.root.exists():
            try:
                cleanup_contained_job(job, deadline, True)
            except SimulatorLifecycleError:
                pass
        raise
    finally:
        shutil.rmtree(job.root, ignore_errors=True)


def timeout_classification(args: argparse.Namespace, outcome: AttemptOutcome) -> tuple[str, int]:
    if tests_completed(outcome.output, args.completion_marker):
        return "post-test-finalization-timeout", POST_TEST_TIMEOUT
    if recoverable_launch_failure(outcome):
        return "pre-test-launch-infrastructure-timeout", PRETEST_INFRASTRUCTURE_FAILURE
    return "test-execution-timeout", TEST_EXECUTION_TIMEOUT


def preserve_partial_result_bundle(args: argparse.Namespace, attempt: int) -> None:
    result_bundle = getattr(args, "result_bundle_path", None)
    if result_bundle is None or not result_bundle.exists():
        return
    preserved = args.diagnostics_dir / f"attempt-{attempt}.xcresult"
    if preserved.exists():
        if preserved.is_dir():
            shutil.rmtree(preserved)
        else:
            preserved.unlink()
    result_bundle.replace(preserved)


def record_timeout(
    args: argparse.Namespace,
    outcome: AttemptOutcome,
    attempt: int,
    run_started: float,
) -> int:
    classification, returncode = timeout_classification(args, outcome)
    assert outcome.timeout_reason is not None
    write_timeout_evidence(
        args,
        attempt,
        classification,
        outcome.timeout_reason,
        run_started,
        outcome.process_evidence,
    )
    print(f"classification={classification}; {outcome.timeout_reason}", file=sys.stderr)
    return returncode


def prepare_simulator(args: argparse.Namespace) -> tuple[str, bool]:
    udid: str | None = None
    try:
        udid, state = available_simulator(args)
        boot_and_check_simulator(args, udid, state)
        return udid, False
    except SimulatorLifecycleError as error:
        print(f"classification=simulator-preflight-failure; {error}", file=sys.stderr)
        return recover_simulator(args, udid, "preflight"), True


def run(args: argparse.Namespace) -> int:
    run_started = time.monotonic()
    args.wall_deadline = run_started + args.wall_timeout
    evidence_errors: list[OSError] = []
    recovery_used = False
    command = args.command
    simulator_udid: str | None = None
    try:
        args.log_path.parent.mkdir(parents=True, exist_ok=True)
        args.diagnostics_dir.mkdir(parents=True, exist_ok=True)
        configure_simulator(args)
        if args.simulator_destination is not None:
            simulator_udid, recovery_used = prepare_simulator(args)
            command = bind_simulator_destination(command, simulator_udid)
        with args.log_path.open("w", encoding="utf-8", buffering=1) as log:
            for attempt in (1, 2):
                outcome = run_attempt(
                    args, command, log, attempt, run_started, evidence_errors
                )
                timeout_code = (
                    record_timeout(args, outcome, attempt, run_started)
                    if outcome.timeout_reason
                    else None
                )
                if evidence_failed(evidence_errors):
                    return EVIDENCE_FAILURE
                if not recoverable_launch_failure(outcome):
                    return timeout_code if timeout_code is not None else outcome.returncode
                if recovery_used or simulator_udid is None:
                    return PRETEST_INFRASTRUCTURE_FAILURE
                preserve_partial_result_bundle(args, attempt)
                simulator_udid = recover_simulator(args, simulator_udid, f"attempt-{attempt}")
                command = bind_simulator_destination(args.command, simulator_udid)
                recovery_used = True
                print("classification=pre-test-launch-infrastructure-retry", file=sys.stderr)
    except OSError as error:
        print(f"classification=evidence-write-failure; {error}", file=sys.stderr)
        return EVIDENCE_FAILURE
    except SimulatorLifecycleError as error:
        print(f"classification=simulator-infrastructure-failure; {error}", file=sys.stderr)
        return PRETEST_INFRASTRUCTURE_FAILURE
    return PRETEST_INFRASTRUCTURE_FAILURE


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--idle-timeout", type=float, required=True)
    parser.add_argument("--wall-timeout", type=float, required=True)
    parser.add_argument("--log-path", type=Path, required=True)
    parser.add_argument("--diagnostics-dir", type=Path, required=True)
    parser.add_argument("--completion-marker", required=True)
    parser.add_argument("--simulator-name")
    parser.add_argument("--simulator-timeout", type=float, default=120)
    parser.add_argument("--result-bundle-path", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("a command is required after --")
    if args.idle_timeout <= 0 or args.wall_timeout <= 0 or args.simulator_timeout <= 0:
        parser.error("timeouts must be positive")
    return args


def run_contained_child(arguments: list[str]) -> int:
    if len(arguments) < 9 or arguments[7] != "--" or arguments[6] not in {"0", "1"}:
        print("invalid contained-child arguments", file=sys.stderr)
        return PRETEST_INFRASTRUCTURE_FAILURE
    return contained_child(
        Path(arguments[1]),
        Path(arguments[2]),
        Path(arguments[3]),
        Path(arguments[4]),
        arguments[5],
        arguments[6] == "1",
        arguments[8:],
    )


def run_evidence_writer(arguments: list[str]) -> int:
    if len(arguments) != 2:
        print("invalid evidence-writer arguments", file=sys.stderr)
        return EVIDENCE_FAILURE
    try:
        content = sys.stdin.buffer.read()
        with Path(arguments[1]).open("wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
    except OSError as error:
        print(error, file=sys.stderr)
        return EVIDENCE_FAILURE
    return 0


def main() -> int:
    if sys.argv[1:2] == [CONTAINED_CHILD_ARGUMENT]:
        return run_contained_child(sys.argv[1:])
    if sys.argv[1:2] == [EVIDENCE_WRITER_ARGUMENT]:
        return run_evidence_writer(sys.argv[1:])
    return run(parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
