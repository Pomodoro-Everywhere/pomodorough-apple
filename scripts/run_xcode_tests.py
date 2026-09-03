#!/usr/bin/env python3
"""Run xcodebuild with bounded execution and reviewable timeout evidence."""

from __future__ import annotations

import argparse
import codecs
import ctypes
from dataclasses import dataclass, field, replace
import hashlib
import hmac
import json
from pathlib import Path
import os
import plistlib
import re
import secrets
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from typing import BinaryIO, Callable, Iterable, TextIO, TypeVar, cast


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
CLEANUP_RESERVE_SECONDS = 2.0
CONTAINED_JOB_CLEANUP_SECONDS = 6.0
CONTAINMENT_DRAIN_RESERVE_SECONDS = 0.25
CONTAINMENT_BOOTOUT_RESERVE_SECONDS = 0.5
CONTAINMENT_BOOTOUT_CLEANUP_RESERVE_SECONDS = 0.5
CONTAINMENT_ABSENCE_RESERVE_SECONDS = 0.5
TIMEOUT_EVIDENCE_SECONDS = 0.25
EVIDENCE_WRITE_SECONDS = 1.0
EVIDENCE_WRITER_CLEANUP_SECONDS = 0.05
DESCENDANT_POLL_SECONDS = 0.001
DESCENDANT_QUIESCENCE_SECONDS = 0.02
ATTEMPT_OUTPUT_CHUNK_BYTES = 64 * 1024
CONTAINMENT_HANDSHAKE_SECONDS = 2.0
LIFECYCLE_BOOTSTRAP_SECONDS = 10.0
LIFECYCLE_CLEANUP_SECONDS = 6.0
DIRECT_CHANNEL_KEY_BYTES = 32
DIRECT_CHANNEL_LIMIT_BYTES = 64 * 1024
DIRECT_CHANNEL_WORK_PER_PUMP = 128
DIRECT_WRAPPER_REAP_SECONDS = 0.5
CONTAINED_CHILD_ARGUMENT = "--contained-child"
DIRECT_CHILD_ARGUMENT = "--direct-child"
DIRECT_TARGET_ARGUMENT = "--direct-target"
EVIDENCE_WRITER_ARGUMENT = "--evidence-writer"
LAUNCHCTL = "/bin/launchctl"
LAUNCHD_EXIT_TIMEOUT_SECONDS = 1
LAUNCHCTL_PROCESS_CLEANUP_SECONDS = 0.5
LAUNCHD_DELEGATION_SANDBOX = b"(version 1)(allow default)(deny job-creation)"
PROCESS_PATH_BUFFER_BYTES = 4096
PROC_PIDTBSDINFO = 3
PROC_PIDUNIQIDENTIFIERINFO = 17
PROC_PIDCOALITIONINFO = 20
COALITION_TYPE_RESOURCE = 0
PT_TRACE_ME = 0
PT_CONTINUE = 7
LIBSYSTEM = ctypes.CDLL(None, use_errno=True)
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
    LIBSYSTEM.ptrace.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    LIBSYSTEM.ptrace.restype = ctypes.c_int
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
    LIBPROC.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
    LIBPROC.proc_listchildpids.restype = ctypes.c_int
    LIBPROC.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    LIBPROC.proc_pidpath.restype = ctypes.c_int

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
    cleanup_error: str | None = None


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
class ContainmentCleanupDeadlines:
    signal_by: float
    drain_by: float
    bootout_by: float
    bootout_cleanup_by: float
    confirmation_by: float


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    started_at: tuple[int, int]
    audit_token: tuple[int, ...] | None = None


@dataclass
class DirectChannel:
    descriptor: int
    key: bytes
    target_exec_required: bool = False
    buffer: bytes = b""
    sequence: int = 0
    wrapper: ProcessIdentity | None = None
    target: ProcessIdentity | None = None
    target_exec_observed: bool = False
    target_identities: set[ProcessIdentity] = field(default_factory=set)
    descendants: set[ProcessIdentity] = field(default_factory=set)
    returncode: int | None = None
    failure: str | None = None
    closed: bool = False


@dataclass
class DirectReporter:
    descriptor: int
    key: bytes
    sequence: int = 0
    status_sent: bool = False
    failure_sent: bool = False


@dataclass(frozen=True)
class DirectJob:
    root: Path
    stdout_path: Path
    stderr_path: Path
    process: subprocess.Popen[bytes]
    identity: ProcessIdentity
    channel: DirectChannel


@dataclass
class DirectSpawnResources:
    root: Path | None = None
    descriptors: set[int] = field(default_factory=set)
    process: subprocess.Popen[bytes] | None = None


@dataclass(frozen=True)
class LifecycleOutcome:
    args: list[str]
    returncode: int
    stdout: str
    stderr: str


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


def stable_darwin_process_info(
    pid: int,
) -> tuple[ProcessIdentity, ProcBSDInfo] | None:
    first = unique_identifier_info(pid)
    info = ProcBSDInfo()
    size = LIBPROC.proc_pidinfo(
        pid, PROC_PIDTBSDINFO, 0, ctypes.byref(info), ctypes.sizeof(info)
    )
    second = unique_identifier_info(pid)
    if (
        first is None
        or second is None
        or first.p_uniqueid != second.p_uniqueid
        or first.p_idversion != second.p_idversion
        or size != ctypes.sizeof(info)
        or info.pbi_pid != pid
    ):
        return None
    identity = unique_process_identity(pid, first)
    return identity, info


def darwin_process_record(pid: int) -> tuple[ProcessIdentity, int] | None:
    record = stable_darwin_process_info(pid)
    if record is None:
        return None
    identity, info = record
    return identity, info.pbi_ppid


def darwin_process_path(pid: int) -> str:
    assert LIBPROC is not None
    buffer = ctypes.create_string_buffer(PROCESS_PATH_BUFFER_BYTES)
    size = LIBPROC.proc_pidpath(pid, buffer, len(buffer))
    if size <= 0:
        return ""
    return buffer.value.decode("utf-8", errors="replace")


def darwin_process_snapshot(pid: int) -> dict[str, object] | None:
    record = stable_darwin_process_info(pid)
    if record is None:
        return None
    identity, info = record
    path = darwin_process_path(pid)
    current = unique_identifier_info(pid)
    if current is None or (
        current.p_uniqueid,
        current.p_idversion,
    ) != identity.started_at:
        return None
    raw_name = bytes(info.pbi_name).split(b"\0", 1)[0]
    return {
        "identity": list(identity.started_at),
        "name": raw_name.decode("utf-8", errors="replace"),
        "path": path,
        "pid": pid,
        "ppid": info.pbi_ppid,
        "started_at": [info.pbi_start_tvsec, info.pbi_start_tvusec],
        "status": info.pbi_status,
    }


def host_process_census(deadline: float) -> str:
    lines = ["source=Darwin libproc stable process census"]
    for pid in all_process_ids(deadline):
        require_census_budget(deadline)
        snapshot = darwin_process_snapshot(pid)
        if snapshot is not None:
            lines.append(json.dumps(snapshot, sort_keys=True))
    return "\n".join(lines) + "\n"


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


def direct_identity(identity: ProcessIdentity) -> ProcessIdentity:
    if LIBPROC is None:
        return identity
    return replace(identity, started_at=(identity.started_at[0], 0))


def direct_process_record(pid: int) -> tuple[ProcessIdentity, int] | None:
    record = process_record(pid)
    if record is None:
        return None
    identity, parent_pid = record
    return direct_identity(identity), parent_pid


def direct_process_identity(pid: int) -> ProcessIdentity | None:
    record = direct_process_record(pid)
    return None if record is None else record[0]


def direct_identity_key(identity: ProcessIdentity) -> tuple[int, tuple[int, int]]:
    return identity.pid, identity.started_at


def same_direct_process(first: ProcessIdentity, second: ProcessIdentity) -> bool:
    return direct_identity_key(first) == direct_identity_key(second)


def direct_audit_pid_version(identity: ProcessIdentity) -> int | None:
    token = identity.audit_token
    if token is None or token[5] != identity.pid or token[7] <= 0:
        return None
    return token[7]


def validate_direct_target_transition(
    previous: ProcessIdentity, current: ProcessIdentity
) -> None:
    previous_version = direct_audit_pid_version(previous)
    current_version = direct_audit_pid_version(current)
    if (
        not same_direct_process(previous, current)
        or previous_version is None
        or current_version is None
        or current_version <= previous_version
    ):
        raise SimulatorLifecycleError("invalid direct target exec identity")


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


def require_census_budget(
    deadline: float,
    timeout_message: str = "Darwin coalition census deadline expired",
) -> None:
    if time.monotonic() >= deadline:
        raise SimulatorLifecycleError(timeout_message)


def all_process_ids(
    deadline: float,
    timeout_message: str = "Darwin coalition census deadline expired",
) -> list[int]:
    if LIBPROC is None:
        raise SimulatorLifecycleError("Darwin process census is unavailable")
    require_census_budget(deadline, timeout_message)
    capacity = LIBPROC.proc_listallpids(None, 0)
    require_census_budget(deadline, timeout_message)
    if capacity <= 0:
        raise SimulatorLifecycleError("Darwin process census failed")
    while time.monotonic() < deadline:
        values = (ctypes.c_int * capacity)()
        count = LIBPROC.proc_listallpids(values, ctypes.sizeof(values))
        require_census_budget(deadline, timeout_message)
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


def direct_child_process_ids(parent_pid: int) -> list[int]:
    if LIBPROC is None:
        records = (process_record(int(path.name)) for path in Path("/proc").glob("[0-9]*"))
        return [record[0].pid for record in records if record is not None and record[1] == parent_pid]
    capacity = 16
    while True:
        values = (ctypes.c_int * capacity)()
        count = LIBPROC.proc_listchildpids(parent_pid, values, ctypes.sizeof(values))
        if count < 0:
            raise SimulatorLifecycleError("direct child process census failed")
        if count < capacity:
            return [pid for pid in values[:count] if pid > 0]
        capacity *= 2


def direct_message_bytes(sequence: int, payload: dict[str, object]) -> bytes:
    return json.dumps(
        {"payload": payload, "sequence": sequence},
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def write_direct_message(
    descriptor: int, key: bytes, sequence: int, payload: dict[str, object]
) -> None:
    authenticated = direct_message_bytes(sequence, payload)
    message = {
        "mac": hmac.new(key, authenticated, hashlib.sha256).hexdigest(),
        "payload": payload,
        "sequence": sequence,
    }
    content = json.dumps(message, separators=(",", ":"), sort_keys=True).encode()
    os.write(descriptor, content + b"\n")


def report_direct_event(
    reporter: DirectReporter, payload: dict[str, object]
) -> None:
    event = payload.get("event")
    if reporter.failure_sent or (reporter.status_sent and event != "descendant"):
        raise SimulatorLifecycleError("direct channel event follows terminal event")
    reporter.sequence += 1
    write_direct_message(reporter.descriptor, reporter.key, reporter.sequence, payload)
    reporter.status_sent = event == "status" or reporter.status_sent
    reporter.failure_sent = event == "error" or reporter.failure_sent


def read_direct_key(descriptor: int) -> bytes:
    content = bytearray()
    while len(content) < DIRECT_CHANNEL_KEY_BYTES:
        chunk = os.read(descriptor, DIRECT_CHANNEL_KEY_BYTES - len(content))
        if not chunk:
            break
        content.extend(chunk)
    if len(content) != DIRECT_CHANNEL_KEY_BYTES:
        raise SimulatorLifecycleError("direct channel key unavailable")
    return bytes(content)


def configure_direct_subreaper() -> None:
    if not sys.platform.startswith("linux"):
        return
    library = ctypes.CDLL(None, use_errno=True)
    if library.prctl(36, 1, 0, 0, 0) != 0:
        detail = os.strerror(ctypes.get_errno())
        raise SimulatorLifecycleError(f"direct subreaper unavailable: {detail}")


def direct_child_identity(
    parent: ProcessIdentity, pid: int
) -> ProcessIdentity | None:
    first = direct_process_record(pid)
    if first is None or first[1] != parent.pid:
        return None
    second = direct_process_record(pid)
    if second is None or second[1] != parent.pid:
        return None
    return second[0] if same_direct_process(first[0], second[0]) else None


def observed_direct_children(parent: ProcessIdentity) -> set[ProcessIdentity]:
    current = direct_process_identity(parent.pid)
    if current is None or not same_direct_process(current, parent):
        return set()
    process_ids = direct_child_process_ids(parent.pid)
    current = direct_process_identity(parent.pid)
    if current is None or not same_direct_process(current, parent):
        return set()
    children = {
        identity
        for pid in process_ids
        if (identity := direct_child_identity(parent, pid)) is not None
    }
    current = direct_process_identity(parent.pid)
    return children if current is not None and same_direct_process(current, parent) else set()


def direct_target_identity(
    process: subprocess.Popen[bytes], wrapper: ProcessIdentity
) -> ProcessIdentity:
    current = direct_process_identity(wrapper.pid)
    if current is None or not same_direct_process(current, wrapper):
        raise SimulatorLifecycleError("direct wrapper identity changed")
    record = direct_process_record(process.pid)
    if record is None or record[1] != wrapper.pid:
        raise SimulatorLifecycleError("direct target ancestry unavailable")
    identity = record[0]
    current = direct_process_identity(wrapper.pid)
    if current is None or not same_direct_process(current, wrapper):
        raise SimulatorLifecycleError("direct wrapper identity changed")
    return identity


def observe_direct_descendants(
    identities: set[ProcessIdentity],
) -> set[ProcessIdentity]:
    observed = set(identities)
    pending = list(identities)
    while pending:
        parent = pending.pop()
        for identity in observed_direct_children(parent):
            if identity not in observed:
                observed.add(identity)
                pending.append(identity)
    return observed


def reap_direct_orphans(target_pid: int) -> None:
    if not sys.platform.startswith("linux"):
        return
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if pid <= 0:
            return
        if pid == target_pid:
            raise SimulatorLifecycleError("direct target reaped outside Popen")


def spawn_gated_direct_target(
    command: list[str], wrapper: ProcessIdentity, reporter: DirectReporter
) -> tuple[subprocess.Popen[bytes], ProcessIdentity]:
    gate_read, gate_write = os.pipe()
    arguments = [
        sys.executable,
        str(Path(__file__).resolve()),
        DIRECT_TARGET_ARGUMENT,
        str(gate_read),
        "--",
        *command,
    ]
    try:
        process = subprocess.Popen(arguments, pass_fds=(gate_read,), start_new_session=True)
        os.close(gate_read)
        gate_read = -1
        identity = direct_target_identity(process, wrapper)
        report_direct_event(
            reporter, {"event": "target", "identity": identity_payload(identity)}
        )
        os.write(gate_write, b"1")
        return process, identity
    finally:
        for descriptor in (gate_read, gate_write):
            if descriptor >= 0:
                os.close(descriptor)


def refresh_direct_target_identity(
    process: subprocess.Popen[bytes],
    reporter: DirectReporter,
    previous: ProcessIdentity,
    unavailable_message: str,
) -> ProcessIdentity:
    current = direct_process_identity(process.pid)
    if current is None:
        raise SimulatorLifecycleError(unavailable_message)
    if not same_direct_process(current, previous):
        raise SimulatorLifecycleError("direct target identity changed")
    if current == previous:
        return previous
    validate_direct_target_transition(previous, current)
    report_direct_event(
        reporter, {"event": "target-exec", "identity": identity_payload(current)}
    )
    return current


def trace_direct_target_execs() -> None:
    if LIBPROC is None:
        return
    ctypes.set_errno(0)
    if LIBSYSTEM.ptrace(PT_TRACE_ME, 0, None, 0) != 0:
        detail = os.strerror(ctypes.get_errno())
        raise SimulatorLifecycleError(f"direct target exec tracing unavailable: {detail}")


def continue_direct_target(pid: int, requested: int) -> None:
    ctypes.set_errno(0)
    address = ctypes.c_void_p(1)
    if LIBSYSTEM.ptrace(PT_CONTINUE, pid, address, requested) != 0:
        detail = os.strerror(ctypes.get_errno())
        raise SimulatorLifecycleError(f"direct target tracing continuation failed: {detail}")


def darwin_direct_target_state(
    process: subprocess.Popen[bytes],
) -> tuple[int | None, bool]:
    flags = os.WSTOPPED | os.WEXITED | os.WNOHANG | os.WNOWAIT
    event = os.waitid(os.P_PID, process.pid, flags)
    if event is None:
        return None, False
    terminal_codes = (os.CLD_EXITED, os.CLD_KILLED, os.CLD_DUMPED)
    if event.si_code in terminal_codes:
        return None, True
    if event.si_code not in (os.CLD_STOPPED, os.CLD_TRAPPED):
        raise SimulatorLifecycleError("invalid direct target tracing state")
    waited_pid, status = os.waitpid(process.pid, os.WUNTRACED | os.WNOHANG)
    if waited_pid != process.pid or not os.WIFSTOPPED(status):
        raise SimulatorLifecycleError("direct target tracing stop unavailable")
    return os.WSTOPSIG(status), False


def observe_darwin_target_state(
    process: subprocess.Popen[bytes],
    reporter: DirectReporter,
    identity: ProcessIdentity,
    exec_observed: bool,
) -> tuple[ProcessIdentity, bool, bool]:
    stopped_signal, target_exited = darwin_direct_target_state(process)
    if target_exited and not exec_observed:
        previous = identity
        identity = refresh_direct_target_identity(
            process, reporter, identity, "exited direct target identity unavailable"
        )
        exec_observed = identity != previous
    if target_exited:
        if not exec_observed:
            raise SimulatorLifecycleError("direct target exec identity unavailable")
        return identity, True, exec_observed
    if stopped_signal is None:
        return identity, False, exec_observed
    previous = identity
    identity = refresh_direct_target_identity(
        process, reporter, identity, "stopped direct target identity unavailable"
    )
    transitioned = identity != previous
    continue_direct_target(process.pid, 0 if transitioned else stopped_signal)
    return identity, False, exec_observed or transitioned


def monitor_direct_command(
    process: subprocess.Popen[bytes],
    wrapper: ProcessIdentity,
    reporter: DirectReporter,
    identity: ProcessIdentity,
) -> None:
    observed = {wrapper, identity}
    target_exec_observed = False
    status_sent = False
    while True:
        target_exited = False
        if LIBPROC is not None and not status_sent:
            previous = identity
            identity, target_exited, target_exec_observed = observe_darwin_target_state(
                process, reporter, identity, target_exec_observed
            )
            if identity != previous:
                observed.add(identity)
        updated = observe_direct_descendants(observed)
        for descendant in sorted(updated - observed, key=lambda item: item.pid):
            report_direct_event(
                reporter,
                {"event": "descendant", "identity": identity_payload(descendant)},
            )
        observed = updated
        if status_sent:
            returncode = None
        elif LIBPROC is None:
            returncode = process.poll()
        elif target_exited:
            returncode = process.poll()
            if returncode is None:
                raise SimulatorLifecycleError("direct target status unavailable")
        else:
            returncode = None
        if returncode is not None and not status_sent:
            report_direct_event(
                reporter, {"event": "status", "returncode": returncode}
            )
            status_sent = True
        if status_sent:
            reap_direct_orphans(process.pid)
        time.sleep(DESCENDANT_POLL_SECONDS)


def direct_child(
    event_descriptor: int,
    key_descriptor: int,
    acknowledgement_descriptor: int,
    command: list[str],
) -> int:
    key = b""
    reporter: DirectReporter | None = None
    try:
        key = read_direct_key(key_descriptor)
        os.close(key_descriptor)
        configure_direct_subreaper()
        identity = direct_process_identity(os.getpid())
        if identity is None:
            raise SimulatorLifecycleError("direct wrapper identity unavailable")
        reporter = DirectReporter(event_descriptor, key)
        report_direct_event(
            reporter,
            {"event": "wrapper", "identity": identity_payload(identity)},
        )
        ready, _, _ = select.select(
            [acknowledgement_descriptor], [], [], CONTAINMENT_HANDSHAKE_SECONDS
        )
        if not ready or os.read(acknowledgement_descriptor, 1) != b"1":
            raise SimulatorLifecycleError("direct wrapper acknowledgement unavailable")
        os.close(acknowledgement_descriptor)
        process, target_identity = spawn_gated_direct_target(command, identity, reporter)
        for requested in (signal.SIGINT, signal.SIGTERM):
            signal.signal(requested, signal.SIG_IGN)
        if hasattr(signal, "SIGINFO"):
            signal.signal(signal.SIGINFO, signal.SIG_IGN)
        monitor_direct_command(process, identity, reporter, target_identity)
    except (OSError, SimulatorLifecycleError) as error:
        if reporter is not None and not reporter.status_sent and not reporter.failure_sent:
            try:
                report_direct_event(
                    reporter, {"event": "error", "message": str(error)}
                )
            except OSError:
                return PRETEST_INFRASTRUCTURE_FAILURE
        while True:
            signal.pause()


def direct_target(gate_descriptor: int, command: list[str]) -> int:
    try:
        ready, _, _ = select.select(
            [gate_descriptor], [], [], CONTAINMENT_HANDSHAKE_SECONDS
        )
        if not ready or os.read(gate_descriptor, 1) != b"1":
            raise SimulatorLifecycleError("direct target acknowledgement unavailable")
        os.close(gate_descriptor)
        trace_direct_target_execs()
        os.execvp(command[0], command)
    except (OSError, SimulatorLifecycleError) as error:
        print(error, file=sys.stderr)
        return PRETEST_INFRASTRUCTURE_FAILURE


def abort_direct_spawn(process: subprocess.Popen[bytes], deadline: float | None) -> None:
    if process.poll() is None:
        try:
            process.kill()
        except ProcessLookupError:
            pass
    cleanup_by = cleanup_deadline(deadline)
    reap_process_with_grace(
        process,
        cleanup_by,
        DIRECT_WRAPPER_REAP_SECONDS,
        "direct wrapper setup cleanup deadline expired",
        "direct wrapper setup cleanup timed out",
    )


def reap_process_with_grace(
    process: subprocess.Popen[bytes],
    deadline: float,
    maximum: float,
    expired_message: str,
    timeout_message: str,
) -> None:
    timeout = bounded_wait(deadline, maximum)
    budget_expired = timeout <= 0
    if budget_expired:
        timeout = maximum
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        if process.poll() is None:
            message = expired_message if budget_expired else timeout_message
            raise SimulatorLifecycleError(message) from error
    if budget_expired:
        raise SimulatorLifecycleError(expired_message)


def close_direct_descriptor(descriptors: set[int], descriptor: int) -> None:
    if descriptor not in descriptors:
        return
    descriptors.remove(descriptor)
    os.close(descriptor)


def acquire_direct_pipe(resources: DirectSpawnResources) -> tuple[int, int]:
    descriptors = os.pipe()
    resources.descriptors.update(descriptors)
    return descriptors


def cleanup_direct_spawn(
    resources: DirectSpawnResources, deadline: float | None
) -> list[str]:
    errors: list[str] = []
    for descriptor in list(resources.descriptors):
        record_direct_cleanup(
            errors,
            lambda descriptor=descriptor: close_direct_descriptor(
                resources.descriptors, descriptor
            ),
        )
    if resources.process is not None:
        record_direct_cleanup(
            errors, lambda: abort_direct_spawn(resources.process, deadline)
        )
    if resources.root is not None:
        record_direct_cleanup(errors, lambda: shutil.rmtree(resources.root))
    return list(dict.fromkeys(errors))


def append_error_detail(error: Exception, detail: str) -> None:
    if isinstance(error, OSError) and error.strerror is not None:
        error.strerror = f"{error.strerror}; {detail}"
    elif len(error.args) == 1 and isinstance(error.args[0], str):
        error.args = (f"{error.args[0]}; {detail}",)
    else:
        error.add_note(detail)


def append_cleanup_errors(error: Exception, label: str, errors: list[str]) -> None:
    details = list(dict.fromkeys(errors))
    if details:
        append_error_detail(error, f"{label}: {'; '.join(details)}")


def record_cleanup_failure(
    errors: list[str], label: str, operation: Callable[[], object]
) -> None:
    try:
        operation()
    except Exception as error:
        detail = str(error)
        errors.append(f"{label}: {detail}" if label else detail)


def remove_job_root(root: Path) -> None:
    try:
        shutil.rmtree(root)
    except FileNotFoundError:
        pass


def cleanup_error_text(errors: list[str]) -> str | None:
    details = list(dict.fromkeys(errors))
    return "; ".join(details) if details else None


def append_direct_spawn_cleanup(error: Exception, cleanup_errors: list[str]) -> None:
    append_cleanup_errors(error, "direct setup cleanup error", cleanup_errors)


def direct_child_arguments(
    command: list[str],
    event_descriptor: int,
    key_descriptor: int,
    acknowledgement_descriptor: int,
) -> list[str]:
    return [
        sys.executable,
        str(Path(__file__).resolve()),
        DIRECT_CHILD_ARGUMENT,
        str(event_descriptor),
        str(key_descriptor),
        str(acknowledgement_descriptor),
        "--",
        *command,
    ]


def spawn_direct_job(command: list[str], deadline: float | None) -> DirectJob:
    resources = DirectSpawnResources()
    try:
        resources.root = Path(tempfile.mkdtemp(prefix="pomodorough-xcode-lifecycle-"))
        root = resources.root
        stdout_path, stderr_path = root / "stdout.log", root / "stderr.log"
        event_read, event_write = acquire_direct_pipe(resources)
        key_read, key_write = acquire_direct_pipe(resources)
        acknowledgement_read, acknowledgement_write = acquire_direct_pipe(resources)
        key = secrets.token_bytes(DIRECT_CHANNEL_KEY_BYTES)
        arguments = direct_child_arguments(
            command, event_write, key_read, acknowledgement_read
        )
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            process = subprocess.Popen(
                arguments,
                stdout=stdout,
                stderr=stderr,
                start_new_session=True,
                pass_fds=(event_write, key_read, acknowledgement_read),
            )
            resources.process = process
        for descriptor in (event_write, key_read, acknowledgement_read):
            close_direct_descriptor(resources.descriptors, descriptor)
        os.write(key_write, key)
        close_direct_descriptor(resources.descriptors, key_write)
        os.set_blocking(event_read, False)
        channel = DirectChannel(
            event_read, key, target_exec_required=LIBPROC is not None
        )
        identity = await_direct_identity(channel, process, deadline)
        os.write(acknowledgement_write, b"1")
        close_direct_descriptor(resources.descriptors, acknowledgement_write)
        resources.descriptors.remove(event_read)
        return DirectJob(root, stdout_path, stderr_path, process, identity, channel)
    except Exception as error:
        append_direct_spawn_cleanup(error, cleanup_direct_spawn(resources, deadline))
        raise


def launchd_domain() -> str:
    if sys.platform != "darwin" or not Path(LAUNCHCTL).is_file():
        raise SimulatorLifecycleError("Darwin launchd containment is unavailable")
    return f"gui/{os.getuid()}"


def captured_process_output(stream: BinaryIO) -> str:
    stream.flush()
    stream.seek(0)
    return stream.read().decode("utf-8", errors="replace")


def terminate_launchctl_process(
    process: subprocess.Popen[bytes],
    deadline: float | None = None,
) -> None:
    if process.poll() is not None:
        return
    identity = process_identity(process.pid)
    if identity is None:
        if process.poll() is not None:
            return
        raise SimulatorLifecycleError("launchctl process identity unavailable")
    # Unreaped direct child retains its PID, so this identity cannot be PID reuse.
    if not signal_identity(identity, signal.SIGKILL):
        if process.poll() is not None:
            return
        if process_identity(process.pid) == identity:
            raise SimulatorLifecycleError("identity-bound launchctl termination failed")
        raise SimulatorLifecycleError("launchctl process identity changed")
    cleanup_by = cleanup_deadline(deadline, LAUNCHCTL_PROCESS_CLEANUP_SECONDS)
    timeout = bounded_wait(cleanup_by, LAUNCHCTL_PROCESS_CLEANUP_SECONDS)
    if timeout <= 0:
        if process.poll() is not None:
            return
        raise SimulatorLifecycleError("launchctl process cleanup timed out")
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        if process.poll() is not None:
            return
        raise SimulatorLifecycleError("launchctl process cleanup timed out") from error


def wait_for_launchctl_process(
    process: subprocess.Popen[bytes], command: list[str], deadline: float
) -> int:
    timeout = deadline - time.monotonic()
    if timeout > 0:
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            timeout_error = error
    else:
        timeout_error = subprocess.TimeoutExpired(command, 0)
    returncode = process.poll()
    if returncode is not None:
        return returncode
    raise timeout_error


def launchctl_run(
    arguments: list[str],
    deadline: float | None,
    maximum: float = 2.0,
    process_cleanup_deadline: float | None = None,
) -> subprocess.CompletedProcess[str]:
    command = [LAUNCHCTL, *arguments]
    started_at = time.monotonic()
    finish_by = started_at + maximum
    if deadline is not None:
        finish_by = min(finish_by, deadline)
    if finish_by <= started_at:
        raise SimulatorLifecycleError("launchd containment deadline expired")
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        try:
            process = subprocess.Popen(
                command, stdout=stdout, stderr=stderr, start_new_session=True
            )
        except OSError as error:
            raise SimulatorLifecycleError(f"launchctl failed to start: {error}") from error
        try:
            returncode = wait_for_launchctl_process(process, command, finish_by)
        except subprocess.TimeoutExpired as error:
            try:
                terminate_launchctl_process(process, process_cleanup_deadline)
            except SimulatorLifecycleError as cleanup_error:
                raise SimulatorLifecycleError(
                    f"launchctl timeout cleanup failed: {cleanup_error}"
                ) from cleanup_error
            raise SimulatorLifecycleError("launchctl timed out") from error
        return subprocess.CompletedProcess(
            command,
            returncode,
            captured_process_output(stdout),
            captured_process_output(stderr),
        )


def launchctl_retry(
    arguments: list[str], deadline: float, maximum: float = 0.25
) -> subprocess.CompletedProcess[str]:
    last_timeout: SimulatorLifecycleError | None = None
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        attempt_maximum = min(maximum, remaining / 2)
        try:
            return launchctl_run(arguments, deadline, attempt_maximum, deadline)
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
    label = f"com.pomodorough.xcode-tests.{secrets.token_hex(16)}"
    service = f"{launchd_domain()}/{label}"
    root = Path(tempfile.mkdtemp(prefix="pomodorough-xcode-tests-"))
    return LaunchdJob(
        label,
        service,
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


def write_containment_acknowledgement(
    job: LaunchdJob, acknowledgement_token: str, coalition_id: int
) -> None:
    write_atomic_json(
        job.acknowledgement_path,
        {"token": acknowledgement_token, "resource_coalition_id": coalition_id},
    )


def containment_setup_cleanup_errors(
    job: LaunchdJob,
    bootstrap_attempted: bool,
    coalition_id: int | None,
    deadline: float | None,
    cleanup_reserve: float,
) -> list[str]:
    errors: list[str] = []
    if bootstrap_attempted:
        record_cleanup_failure(
            errors,
            "containment abort failed",
            lambda: abort_containment_handshake(
                job, coalition_id, deadline, cleanup_reserve
            ),
        )
    record_cleanup_failure(
        errors, "setup root removal failed", lambda: remove_job_root(job.root)
    )
    return errors


def spawn_contained_job(
    command: list[str],
    combine_stderr: bool,
    deadline: float | None,
    bootstrap_maximum: float = 2.0,
    cleanup_reserve: float = CLEANUP_RESERVE_SECONDS,
) -> LaunchdJob:
    acknowledgement_token = secrets.token_hex(32)
    setup_deadline = reserved_deadline(deadline, cleanup_reserve)
    job = create_launchd_job()
    plist_path = job.root / "job.plist"
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
            ["bootstrap", launchd_domain(), str(plist_path)],
            setup_deadline,
            bootstrap_maximum,
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
        write_containment_acknowledgement(job, acknowledgement_token, coalition_id)
        return bound_job
    except Exception as error:
        cleanup_errors = containment_setup_cleanup_errors(
            job, bootstrap_attempted, coalition_id, deadline, cleanup_reserve
        )
        append_cleanup_errors(error, "launchd setup cleanup error", cleanup_errors)
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
    valid_pid = isinstance(pid, int) and not isinstance(pid, bool) and pid > 0
    if not valid_pid or not isinstance(started_at, list) or len(started_at) != 2:
        raise SimulatorLifecycleError(f"invalid {label}")
    if (
        not all(isinstance(value, int) and not isinstance(value, bool) for value in started_at)
        or started_at[0] <= 0
        or started_at[1] < 0
    ):
        raise SimulatorLifecycleError(f"invalid {label} start time")
    if token is not None and (
        not isinstance(token, list)
        or len(token) != 8
        or not all(
            isinstance(value, int)
            and not isinstance(value, bool)
            and 0 <= value <= 0xFFFFFFFF
            for value in token
        )
    ):
        raise SimulatorLifecycleError(f"invalid {label} audit token")
    return ProcessIdentity(pid, tuple(started_at), None if token is None else tuple(token))


def direct_payload_keys(payload: dict[str, object], expected: set[str]) -> None:
    if set(payload) != expected:
        raise SimulatorLifecycleError("invalid direct channel payload")


def direct_payload_identity(
    payload: dict[str, object], event: str
) -> ProcessIdentity:
    direct_payload_keys(payload, {"event", "identity"})
    return process_identity_from_payload(payload["identity"], f"direct {event} identity")


def direct_identity_in(
    identity: ProcessIdentity, candidates: Iterable[ProcessIdentity]
) -> bool:
    return any(same_direct_process(identity, candidate) for candidate in candidates)


def apply_direct_target_payload(
    channel: DirectChannel, payload: dict[str, object], event: str
) -> None:
    identity = direct_payload_identity(payload, event)
    if event == "target":
        if channel.wrapper is None or channel.target is not None or channel.failure:
            raise SimulatorLifecycleError("duplicate direct target identity")
        if same_direct_process(identity, channel.wrapper):
            raise SimulatorLifecycleError("invalid direct target identity")
        target_version = direct_audit_pid_version(identity)
        if identity.audit_token is not None and target_version is None:
            raise SimulatorLifecycleError("invalid direct target identity")
        if channel.target_exec_required and target_version is None:
            raise SimulatorLifecycleError("invalid direct target identity")
        channel.target_exec_required = target_version is not None
    else:
        previous = channel.target
        if previous is None or channel.failure or channel.returncode is not None:
            raise SimulatorLifecycleError("out-of-order direct target exec identity")
        validate_direct_target_transition(previous, identity)
        channel.target_exec_observed = True
        channel.target_identities.add(previous)
    channel.target = identity
    channel.target_identities.add(identity)


def apply_direct_payload(channel: DirectChannel, payload: dict[str, object]) -> None:
    event = payload.get("event")
    if event == "wrapper":
        identity = direct_payload_identity(payload, event)
        if channel.sequence != 0 or channel.wrapper is not None:
            raise SimulatorLifecycleError("duplicate direct wrapper identity")
        channel.wrapper = identity
    elif event in ("target", "target-exec"):
        apply_direct_target_payload(channel, payload, event)
    elif event == "descendant":
        if channel.target is None or channel.failure:
            raise SimulatorLifecycleError("out-of-order direct descendant identity")
        identity = direct_payload_identity(payload, event)
        if channel.wrapper is not None and same_direct_process(identity, channel.wrapper):
            raise SimulatorLifecycleError("invalid direct descendant identity")
        if same_direct_process(identity, channel.target):
            return
        if not direct_identity_in(identity, channel.descendants):
            channel.descendants.add(identity)
    elif event == "status":
        direct_payload_keys(payload, {"event", "returncode"})
        if channel.target is None or channel.returncode is not None or channel.failure:
            raise SimulatorLifecycleError("duplicate direct command status")
        if channel.target_exec_required and not channel.target_exec_observed:
            raise SimulatorLifecycleError("direct command status precedes target exec identity")
        returncode = payload["returncode"]
        if isinstance(returncode, bool) or not isinstance(returncode, int):
            raise SimulatorLifecycleError("invalid direct command return code")
        channel.returncode = returncode
    elif event == "error":
        direct_payload_keys(payload, {"event", "message"})
        if channel.failure is not None or channel.returncode is not None:
            raise SimulatorLifecycleError("duplicate direct command error")
        if not isinstance(payload["message"], str):
            raise SimulatorLifecycleError("invalid direct command error")
        channel.failure = payload["message"]
    else:
        raise SimulatorLifecycleError("invalid direct channel event")


def apply_direct_message(channel: DirectChannel, content: bytes) -> None:
    try:
        message = json.loads(content)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SimulatorLifecycleError("invalid direct channel message") from error
    if not isinstance(message, dict) or set(message) != {"mac", "payload", "sequence"}:
        raise SimulatorLifecycleError("invalid direct channel message")
    sequence, payload, received = message["sequence"], message["payload"], message["mac"]
    if isinstance(sequence, bool) or sequence != channel.sequence + 1:
        raise SimulatorLifecycleError("invalid direct channel sequence")
    if not isinstance(payload, dict) or not isinstance(received, str):
        raise SimulatorLifecycleError("invalid direct channel message")
    expected = hmac.new(
        channel.key, direct_message_bytes(sequence, payload), hashlib.sha256
    ).hexdigest()
    if not hmac.compare_digest(received, expected):
        raise SimulatorLifecycleError("unauthenticated direct channel message")
    apply_direct_payload(channel, payload)
    channel.sequence = sequence


def close_direct_channel(channel: DirectChannel) -> None:
    descriptor = channel.descriptor
    channel.descriptor = -1
    channel.closed = True
    if descriptor >= 0:
        os.close(descriptor)


def pump_direct_channel(channel: DirectChannel, deadline: float | None) -> None:
    if channel.descriptor < 0:
        return
    work = 0
    try:
        while not channel.closed and work < DIRECT_CHANNEL_WORK_PER_PUMP:
            if deadline is not None and time.monotonic() >= deadline:
                return
            while b"\n" in channel.buffer and work < DIRECT_CHANNEL_WORK_PER_PUMP:
                if deadline is not None and time.monotonic() >= deadline:
                    return
                content, channel.buffer = channel.buffer.split(b"\n", 1)
                if len(content) > DIRECT_CHANNEL_LIMIT_BYTES:
                    raise SimulatorLifecycleError("direct channel frame exceeds limit")
                apply_direct_message(channel, content)
                work += 1
            if work >= DIRECT_CHANNEL_WORK_PER_PUMP:
                return
            chunk = os.read(channel.descriptor, DIRECT_CHANNEL_LIMIT_BYTES)
            work += 1
            if not chunk:
                close_direct_channel(channel)
                break
            channel.buffer += chunk
            if len(channel.buffer) > DIRECT_CHANNEL_LIMIT_BYTES and b"\n" not in channel.buffer:
                raise SimulatorLifecycleError("direct channel frame exceeds limit")
    except BlockingIOError:
        return
    except Exception as error:
        cleanup_errors: list[str] = []
        record_cleanup_failure(
            cleanup_errors, "descriptor close failed", lambda: close_direct_channel(channel)
        )
        append_cleanup_errors(error, "direct channel cleanup error", cleanup_errors)
        raise
    if channel.closed and channel.buffer:
        raise SimulatorLifecycleError("truncated direct channel message")


def bounded_process_identity(
    pid: int, deadline: float, label: str = "direct process identity"
) -> ProcessIdentity | None:
    return deadline_call(
        lambda: direct_process_identity(pid), deadline, f"{label} deadline expired"
    )


def bounded_direct_child_identity(
    parent: ProcessIdentity, pid: int, deadline: float
) -> ProcessIdentity | None:
    return deadline_call(
        lambda: direct_child_identity(parent, pid),
        deadline,
        "direct child identity deadline expired",
    )


def bounded_direct_children(
    parent: ProcessIdentity, deadline: float
) -> set[ProcessIdentity]:
    current = bounded_process_identity(parent.pid, deadline)
    if current is None or not same_direct_process(current, parent):
        return set()
    process_ids = deadline_call(
        lambda: direct_child_process_ids(parent.pid),
        deadline,
        "direct child census deadline expired",
    )
    current = bounded_process_identity(parent.pid, deadline)
    if current is None or not same_direct_process(current, parent):
        return set()
    children = {
        identity
        for pid in process_ids
        if (identity := bounded_direct_child_identity(parent, pid, deadline)) is not None
    }
    current = bounded_process_identity(parent.pid, deadline)
    return children if current is not None and same_direct_process(current, parent) else set()


def await_direct_identity(
    channel: DirectChannel, process: subprocess.Popen[bytes], deadline: float | None
) -> ProcessIdentity:
    handshake_by = time.monotonic() + CONTAINMENT_HANDSHAKE_SECONDS
    setup_deadline = reserved_deadline(deadline, CLEANUP_RESERVE_SECONDS)
    if setup_deadline is not None:
        handshake_by = min(handshake_by, setup_deadline)
    while time.monotonic() < handshake_by:
        pump_direct_channel(channel, handshake_by)
        if channel.failure is not None:
            raise SimulatorLifecycleError(f"direct wrapper failed: {channel.failure}")
        identity = channel.wrapper
        if identity is not None:
            current = bounded_process_identity(process.pid, handshake_by)
            if (
                identity.pid != process.pid
                or current is None
                or not same_direct_process(current, identity)
            ):
                raise SimulatorLifecycleError("forged direct wrapper identity")
            return identity
        if channel.closed or process.poll() is not None:
            raise SimulatorLifecycleError("direct wrapper exited before identity handshake")
        time.sleep(bounded_wait(handshake_by, DESCENDANT_POLL_SECONDS))
    raise SimulatorLifecycleError("direct wrapper identity unavailable")


def collect_darwin_direct_descendants(
    ancestors: set[ProcessIdentity], deadline: float
) -> set[ProcessIdentity]:
    timeout_message = "direct Darwin process census deadline expired"
    children_by_parent: dict[int, list[ProcessIdentity]] = {}
    children_by_original_parent: dict[int, list[ProcessIdentity]] = {}
    for pid in all_process_ids(deadline, timeout_message):
        require_census_budget(deadline, timeout_message)
        info = unique_identifier_info(pid)
        require_census_budget(deadline, timeout_message)
        if info is not None:
            identity = direct_identity(unique_process_identity(pid, info))
            children_by_parent.setdefault(info.p_puniqueid, []).append(identity)
            if info.p_orig_ppidversion > 0:
                children_by_original_parent.setdefault(
                    info.p_orig_ppidversion, []
                ).append(identity)
    known = set(ancestors)
    pending = list(ancestors)
    descendants: set[ProcessIdentity] = set()
    while pending:
        require_census_budget(deadline, timeout_message)
        parent = pending.pop()
        candidates = list(children_by_parent.get(parent.started_at[0], []))
        if parent.audit_token is not None and parent.audit_token[7] > 0:
            candidates.extend(children_by_original_parent.get(parent.audit_token[7], []))
        for identity in candidates:
            require_census_budget(deadline, timeout_message)
            if identity in known:
                continue
            known.add(identity)
            descendants.add(identity)
            pending.append(identity)
    return descendants


def inspect_darwin_direct_descendants(
    ancestors: set[ProcessIdentity], deadline: float
) -> set[ProcessIdentity]:
    return deadline_call(
        lambda: collect_darwin_direct_descendants(ancestors, deadline),
        deadline,
        "direct Darwin process census deadline expired",
    )


def direct_descendant_census(
    job: DirectJob, deadline: float
) -> set[ProcessIdentity]:
    observed = set(job.channel.descendants)
    roots = observed | {job.identity} | set(job.channel.target_identities)
    if job.channel.target is not None:
        roots.add(job.channel.target)
    pending = list(roots)
    while pending:
        for identity in bounded_direct_children(pending.pop(), deadline) - roots:
            roots.add(identity)
            observed.add(identity)
            pending.append(identity)
    if LIBPROC is not None:
        observed |= inspect_darwin_direct_descendants(roots, deadline)
    excluded = {direct_identity_key(job.identity)}
    if job.channel.target is not None:
        excluded.add(direct_identity_key(job.channel.target))
    descendants = {
        direct_identity_key(identity): identity
        for identity in observed
        if direct_identity_key(identity) not in excluded
    }
    return set(descendants.values())


def direct_descendants(job: DirectJob, deadline: float) -> set[ProcessIdentity]:
    pump_direct_channel(job.channel, deadline)
    return direct_descendant_census(job, deadline)


def current_direct_identity(
    identity: ProcessIdentity, deadline: float
) -> ProcessIdentity | None:
    current = bounded_process_identity(identity.pid, deadline)
    if current is None or not same_direct_process(current, identity):
        return None
    return current


def live_direct_descendants(job: DirectJob, deadline: float) -> set[ProcessIdentity]:
    pump_direct_channel(job.channel, deadline)
    return {
        current
        for identity in direct_descendant_census(job, deadline)
        if (current := current_direct_identity(identity, deadline)) is not None
    }


def direct_job_status(job: DirectJob, deadline: float | None = None) -> int | None:
    pump_direct_channel(job.channel, deadline)
    if job.channel.failure is not None:
        raise SimulatorLifecycleError(
            f"direct command failed to start: {job.channel.failure}"
        )
    if job.channel.closed and job.channel.returncode is None:
        raise SimulatorLifecycleError("direct command channel closed before status")
    return job.channel.returncode


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
        wait = bounded_wait(deadline, DESCENDANT_POLL_SECONDS)
        if wait > 0:
            time.sleep(wait)
    raise SimulatorLifecycleError("launchd containment process unavailable")


def launchd_service_containment(
    job: LaunchdJob, deadline: float
) -> tuple[int, ProcessIdentity]:
    pid = launchd_service_pid(job, deadline)
    inspection = deadline_call(
        lambda: inspect_launchd_service_containment(pid),
        deadline,
        "launchd containment validation deadline expired",
    )
    if inspection is None:
        raise SimulatorLifecycleError("unstable launchd containment identity")
    identity, coalition_id, parent_coalition = inspection
    if coalition_id is None or coalition_id <= 0 or coalition_id == parent_coalition:
        raise SimulatorLifecycleError("unsafe contained coalition identity")
    return coalition_id, identity


def inspect_launchd_service_containment(
    pid: int,
) -> tuple[ProcessIdentity, int | None, int | None] | None:
    first_identity = process_identity(pid)
    first_coalition = resource_coalition_id(pid)
    parent_coalition = resource_coalition_id(os.getpid())
    second_coalition = resource_coalition_id(pid)
    second_identity = process_identity(pid)
    if (
        first_identity is None
        or first_identity != second_identity
        or first_coalition != second_coalition
    ):
        return None
    return first_identity, first_coalition, parent_coalition


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
    diagnostic_patterns = {
        3: r"No such process\n?",
        113: (
            r'(?:Could not find service|Bad request\.\nCould not find service "[^"\r\n]+" '
            r"in domain for user gui: [0-9]+)\n?"
        ),
    }
    pattern = diagnostic_patterns.get(result.returncode)
    return (
        result.stdout == ""
        and pattern is not None
        and re.fullmatch(pattern, result.stderr) is not None
    )


def bootout_result_is_absent(result: subprocess.CompletedProcess[str]) -> bool:
    return service_is_absent(result) or (
        result.returncode == 3
        and result.stdout == ""
        and re.fullmatch(
            r"Boot-out failed: 3: No such process\n?", result.stderr
        )
        is not None
    )


def launchd_job_domain(job: LaunchdJob) -> str:
    domain, separator, label = job.service.rpartition("/")
    if not separator or not domain or label != job.label:
        raise SimulatorLifecycleError("invalid launchd containment service")
    return domain


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


def bootout_job(
    job: LaunchdJob,
    deadline: float | None,
    process_cleanup_deadline: float | None = None,
) -> str | None:
    result = launchctl_run(
        ["bootout", launchd_job_domain(job), str(job.root / "job.plist")],
        deadline,
        1.5,
        process_cleanup_deadline,
    )
    if not result.returncode:
        return None
    if not bootout_result_is_absent(result):
        raise SimulatorLifecycleError(
            f"launchd bootout exited {result.returncode}: {result.stderr.strip()}"
        )
    return None


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


def cleanup_deadline(
    deadline: float | None, maximum: float = CLEANUP_RESERVE_SECONDS
) -> float:
    cleanup_by = time.monotonic() + maximum
    return cleanup_by if deadline is None else min(deadline, cleanup_by)


def containment_cleanup_deadlines(
    confirmation_by: float, signal_cap: float | None = None
) -> ContainmentCleanupDeadlines:
    bootout_cleanup_by = (
        confirmation_by - CONTAINMENT_ABSENCE_RESERVE_SECONDS
    )
    bootout_by = (
        bootout_cleanup_by - CONTAINMENT_BOOTOUT_CLEANUP_RESERVE_SECONDS
    )
    drain_by = bootout_by - CONTAINMENT_BOOTOUT_RESERVE_SECONDS
    signal_by = drain_by - CONTAINMENT_DRAIN_RESERVE_SECONDS
    if signal_cap is not None:
        signal_by = min(signal_by, signal_cap)
    return ContainmentCleanupDeadlines(
        signal_by, drain_by, bootout_by, bootout_cleanup_by, confirmation_by
    )


def record_containment_signals(
    errors: list[str], coalition_id: int, deadline: float
) -> None:
    phases = [(signal.SIGINT, 0.05), (signal.SIGTERM, 0.1)]
    if hasattr(signal, "SIGINFO"):
        phases.insert(0, (signal.SIGINFO, 0.02))
    for requested, pause in phases:
        record_cleanup_failure(
            errors,
            f"{requested.name} signal failed",
            lambda requested=requested: signal_coalition_members(
                coalition_id, requested, deadline
            ),
        )
        pause_before_cleanup(deadline, pause)


def record_containment_finalization(
    errors: list[str],
    job: LaunchdJob,
    coalition_id: int | None,
    deadlines: ContainmentCleanupDeadlines,
) -> None:
    if coalition_id is not None:
        record_cleanup_failure(
            errors,
            "coalition drain failed",
            lambda: drain_coalition(coalition_id, deadlines.drain_by),
        )
    record_cleanup_failure(
        errors,
        "bootout failed",
        lambda: bootout_job(
            job, deadlines.bootout_by, deadlines.bootout_cleanup_by
        ),
    )
    record_cleanup_failure(
        errors,
        "absence confirmation failed",
        lambda: confirm_job_absent(job, deadlines.confirmation_by),
    )


def abort_containment_handshake(
    job: LaunchdJob,
    coalition_id: int | None,
    deadline: float | None,
    cleanup_maximum: float = CLEANUP_RESERVE_SECONDS,
) -> None:
    cleanup_by = cleanup_deadline(deadline, cleanup_maximum)
    deadlines = containment_cleanup_deadlines(cleanup_by)
    errors: list[str] = []
    record_containment_finalization(errors, job, coalition_id, deadlines)
    detail = cleanup_error_text(errors)
    if detail is not None:
        raise SimulatorLifecycleError(detail)


def cleanup_coalition_id(
    job: LaunchdJob, deadlines: ContainmentCleanupDeadlines
) -> int:
    try:
        return job_coalition_id(job)
    except SimulatorLifecycleError as error:
        errors: list[str] = []
        record_containment_finalization(errors, job, None, deadlines)
        append_cleanup_errors(error, "containment finalization failed", errors)
        raise


def cleanup_contained_job(
    job: LaunchdJob, deadline: float | None, _signal_root: bool
) -> None:
    cleanup_by = cleanup_deadline(deadline, CONTAINED_JOB_CLEANUP_SECONDS)
    deadlines = containment_cleanup_deadlines(cleanup_by)
    coalition_id = cleanup_coalition_id(job, deadlines)
    errors: list[str] = []
    record_containment_signals(errors, coalition_id, deadlines.signal_by)
    record_containment_finalization(errors, job, coalition_id, deadlines)
    detail = cleanup_error_text(errors)
    if detail is not None:
        raise SimulatorLifecycleError(detail)


def lifecycle_cleanup_error(
    job: LaunchdJob, deadline: float | None, _signal_root: bool
) -> str | None:
    cleanup_by = cleanup_deadline(deadline, LIFECYCLE_CLEANUP_SECONDS)
    teardown_by = reserved_deadline(cleanup_by, CLEANUP_RESERVE_SECONDS)
    assert teardown_by is not None
    deadlines = containment_cleanup_deadlines(cleanup_by, teardown_by)
    coalition_id = cleanup_coalition_id(job, deadlines)
    errors: list[str] = []
    record_containment_signals(errors, coalition_id, deadlines.signal_by)
    record_containment_finalization(errors, job, coalition_id, deadlines)
    return cleanup_error_text(errors)


def record_lifecycle_cleanup(
    errors: list[str], job: LaunchdJob, deadline: float | None, signal_root: bool
) -> None:
    try:
        detail = lifecycle_cleanup_error(job, deadline, signal_root)
    except Exception as error:
        errors.append(str(error))
    else:
        if detail is not None:
            errors.append(detail)


def job_output(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""
    except UnicodeDecodeError as error:
        raise SimulatorLifecycleError(f"invalid UTF-8 command output in {path.name}") from error


def wait_for_job_status(
    job: LaunchdJob,
    timeout: float,
    wall_deadline: float | None = None,
    cleanup_reserve: float = CLEANUP_RESERVE_SECONDS,
) -> int | None:
    deadline = time.monotonic() + timeout
    observation_deadline = reserved_deadline(wall_deadline, cleanup_reserve)
    if observation_deadline is not None:
        deadline = min(deadline, observation_deadline)
    while time.monotonic() < deadline:
        returncode = job_status(job, deadline)
        if returncode is not None:
            return returncode
        time.sleep(bounded_wait(deadline, DESCENDANT_POLL_SECONDS))
    return None


def wait_for_direct_status(
    job: DirectJob, timeout: float, wall_deadline: float | None = None
) -> int | None:
    deadline = time.monotonic() + timeout
    observation_deadline = reserved_deadline(wall_deadline, CLEANUP_RESERVE_SECONDS)
    if observation_deadline is not None:
        deadline = min(deadline, observation_deadline)
    while time.monotonic() < deadline:
        returncode = direct_job_status(job, deadline)
        if returncode is not None:
            return returncode
        time.sleep(bounded_wait(deadline, DESCENDANT_POLL_SECONDS))
    return None


def signal_direct_identity(
    identity: ProcessIdentity, requested: signal.Signals, deadline: float
) -> bool:
    if LIBPROC is None:
        return signal_linux_direct_identity(identity, requested, deadline)
    if identity.audit_token is not None and signal_audit_token(
        identity.audit_token, requested
    ):
        return True
    current = current_direct_identity(identity, deadline)
    if current is None:
        return False
    return (
        current.audit_token is not None
        and signal_audit_token(current.audit_token, requested)
    )


def signal_linux_direct_identity(
    identity: ProcessIdentity, requested: signal.Signals, deadline: float
) -> bool:
    pidfd_open = getattr(os, "pidfd_open", None)
    pidfd_send_signal = getattr(signal, "pidfd_send_signal", None)
    if pidfd_open is None or pidfd_send_signal is None:
        raise SimulatorLifecycleError("Linux identity-bound signaling is unavailable")
    try:
        descriptor = pidfd_open(identity.pid, 0)
    except ProcessLookupError:
        return False
    except OSError as error:
        raise SimulatorLifecycleError("Linux identity handle unavailable") from error
    try:
        current = current_direct_identity(identity, deadline)
        if current is None:
            result = False
        else:
            try:
                pidfd_send_signal(descriptor, requested, None, 0)
                result = True
            except ProcessLookupError:
                result = False
            except OSError as error:
                raise SimulatorLifecycleError("Linux identity-bound signal failed") from error
    except Exception as error:
        cleanup_errors: list[str] = []
        record_cleanup_failure(
            cleanup_errors, "pidfd close failed", lambda: os.close(descriptor)
        )
        append_cleanup_errors(error, "Linux identity cleanup error", cleanup_errors)
        raise
    try:
        os.close(descriptor)
    except OSError as error:
        raise SimulatorLifecycleError(
            f"Linux identity handle cleanup failed: {error}"
        ) from error
    return result


def signal_direct_target(
    job: DirectJob, requested: signal.Signals, deadline: float
) -> None:
    target = job.channel.target
    if target is None or signal_direct_identity(target, requested, deadline):
        return
    if current_direct_identity(target, deadline) is not None:
        raise SimulatorLifecycleError("identity-bound direct target signal failed")


def signal_direct_descendants(
    job: DirectJob, requested: signal.Signals, deadline: float
) -> None:
    for identity in live_direct_descendants(job, deadline):
        require_census_budget(deadline)
        if signal_direct_identity(identity, requested, deadline):
            continue
        current = current_direct_identity(identity, deadline)
        if current is not None and same_direct_process(current, identity):
            raise SimulatorLifecycleError("identity-bound direct signal failed")


def force_direct_wrapper_exit(job: DirectJob, deadline: float) -> None:
    if job.process.poll() is not None:
        return
    if signal_direct_identity(job.identity, signal.SIGKILL, deadline):
        return
    if current_direct_identity(job.identity, deadline) is not None:
        raise SimulatorLifecycleError("identity-bound direct wrapper signal failed")


def reap_direct_wrapper(job: DirectJob, deadline: float) -> None:
    if job.process.poll() is not None:
        return
    reap_process_with_grace(
        job.process,
        deadline,
        DIRECT_WRAPPER_REAP_SECONDS,
        "direct wrapper reap deadline expired",
        "direct wrapper reap timed out",
    )


def record_direct_cleanup(
    errors: list[str], operation: Callable[[], object]
) -> object | None:
    try:
        return operation()
    except Exception as error:
        errors.append(str(error))
        return None


def direct_cleanup_observation(
    job: DirectJob, deadline: float, errors: list[str]
) -> tuple[set[ProcessIdentity], bool]:
    try:
        pump_direct_channel(job.channel, deadline)
    except Exception as error:
        errors.append(str(error))
    try:
        live = {
            current
            for identity in direct_descendant_census(job, deadline)
            if (current := current_direct_identity(identity, deadline)) is not None
        }
        return live, True
    except Exception as error:
        errors.append(str(error))
        return set(), False


def direct_target_is_live(job: DirectJob, deadline: float) -> bool:
    target = job.channel.target
    return target is not None and current_direct_identity(target, deadline) is not None


def drain_direct_job(job: DirectJob, deadline: float, errors: list[str]) -> None:
    empty_since: float | None = None
    while time.monotonic() < deadline:
        live, observed = direct_cleanup_observation(job, deadline, errors)
        for identity in live:
            record_direct_cleanup(
                errors,
                lambda identity=identity: signal_direct_identity(
                    identity, signal.SIGKILL, deadline
                ),
            )
        record_direct_cleanup(
            errors, lambda: signal_direct_target(job, signal.SIGKILL, deadline)
        )
        now = time.monotonic()
        target_live = record_direct_cleanup(
            errors, lambda: direct_target_is_live(job, deadline)
        )
        if observed and not live and target_live is False:
            empty_since = empty_since or now
            if now - empty_since >= DESCENDANT_QUIESCENCE_SECONDS:
                return
        else:
            empty_since = None
        time.sleep(bounded_wait(deadline, DESCENDANT_POLL_SECONDS))
    errors.append("direct process cleanup incomplete")


def cleanup_direct_job(
    job: DirectJob, deadline: float | None, signal_root: bool
) -> None:
    cleanup_by = cleanup_deadline(deadline)
    observation_by = cleanup_by - DIRECT_WRAPPER_REAP_SECONDS
    errors: list[str] = []
    try:
        if signal_root:
            phases = [(signal.SIGINT, 0.05), (signal.SIGTERM, 0.1)]
            if hasattr(signal, "SIGINFO"):
                phases.insert(0, (signal.SIGINFO, 0.02))
            for requested, pause in phases:
                record_direct_cleanup(
                    errors,
                    lambda requested=requested: pump_direct_channel(
                        job.channel, observation_by
                    ),
                )
                record_direct_cleanup(
                    errors,
                    lambda requested=requested: signal_direct_target(
                        job, requested, observation_by
                    ),
                )
                record_direct_cleanup(
                    errors,
                    lambda requested=requested: signal_direct_descendants(
                        job, requested, observation_by
                    ),
                )
                time.sleep(bounded_wait(observation_by, pause))
        drain_direct_job(job, observation_by, errors)
    finally:
        record_direct_cleanup(
            errors, lambda: force_direct_wrapper_exit(job, cleanup_by)
        )
        record_direct_cleanup(errors, lambda: reap_direct_wrapper(job, cleanup_by))
        record_direct_cleanup(errors, lambda: close_direct_channel(job.channel))
    if errors:
        raise SimulatorLifecycleError("; ".join(dict.fromkeys(errors)))


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
        args.diagnostics_dir / "timeout.txt",
        args.diagnostics_dir / f"attempt-{attempt}-timeout.txt",
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
    cleanup_reserve = (
        LIFECYCLE_CLEANUP_SECONDS if sys.platform == "darwin" else CLEANUP_RESERVE_SECONDS
    )
    available = None if remaining is None else remaining - cleanup_reserve
    if available is not None and available <= 0:
        raise SimulatorLifecycleError(f"wall timeout exhausted before {label}")
    return configured if available is None else min(configured, available)


def direct_lifecycle_process(
    command: list[str], timeout: float, deadline: float | None
) -> LifecycleOutcome:
    job = spawn_direct_job(command, deadline)
    cleanup_attempted = False
    cleanup_errors: list[str] = []
    try:
        returncode = wait_for_direct_status(job, timeout, deadline)
        cleanup_attempted = True
        try:
            cleanup_direct_job(job, deadline, returncode is None)
        except SimulatorLifecycleError as error:
            cleanup_errors.append(str(error))
        stdout = job_output(job.stdout_path)
        stderr = job_output(job.stderr_path)
    except Exception as error:
        if not cleanup_attempted and job.root.exists():
            record_cleanup_failure(
                cleanup_errors, "", lambda: cleanup_direct_job(job, deadline, True)
            )
        record_cleanup_failure(
            cleanup_errors, "job root removal failed", lambda: remove_job_root(job.root)
        )
        append_cleanup_errors(error, "direct cleanup error", cleanup_errors)
        raise
    record_cleanup_failure(
        cleanup_errors, "job root removal failed", lambda: remove_job_root(job.root)
    )
    cleanup_error = cleanup_error_text(cleanup_errors)
    if cleanup_error is not None:
        stderr += f"\ndirect cleanup error: {cleanup_error}\n"
        if returncode == 0:
            raise SimulatorLifecycleError(cleanup_error)
    if returncode is None:
        raise subprocess.TimeoutExpired(command, timeout, stdout, stderr)
    return LifecycleOutcome(command, returncode, stdout, stderr)


def contained_lifecycle_process(
    command: list[str], timeout: float, deadline: float | None
) -> LifecycleOutcome:
    job = spawn_contained_job(
        command,
        False,
        deadline,
        bootstrap_maximum=LIFECYCLE_BOOTSTRAP_SECONDS,
        cleanup_reserve=LIFECYCLE_CLEANUP_SECONDS,
    )
    cleanup_attempted = False
    cleanup_errors: list[str] = []
    try:
        returncode = wait_for_job_status(
            job, timeout, deadline, LIFECYCLE_CLEANUP_SECONDS
        )
        cleanup_attempted = True
        record_lifecycle_cleanup(cleanup_errors, job, deadline, returncode is None)
        stdout = job_output(job.stdout_path)
        stderr = job_output(job.stderr_path)
    except Exception as error:
        if not cleanup_attempted and job.root.exists():
            record_lifecycle_cleanup(cleanup_errors, job, deadline, True)
        record_cleanup_failure(
            cleanup_errors, "job root removal failed", lambda: remove_job_root(job.root)
        )
        append_cleanup_errors(error, "coalition cleanup error", cleanup_errors)
        raise
    record_cleanup_failure(
        cleanup_errors, "job root removal failed", lambda: remove_job_root(job.root)
    )
    cleanup_error = cleanup_error_text(cleanup_errors)
    if cleanup_error is not None:
        stderr += f"\ncoalition cleanup error: {cleanup_error}\n"
        if returncode == 0:
            raise SimulatorLifecycleError(cleanup_error)
    if returncode is None:
        raise subprocess.TimeoutExpired(command, timeout, stdout, stderr)
    return LifecycleOutcome(command, returncode, stdout, stderr)


def lifecycle_process(
    command: list[str], timeout: float, deadline: float | None
) -> LifecycleOutcome:
    if sys.platform == "darwin":
        return contained_lifecycle_process(command, timeout, deadline)
    return direct_lifecycle_process(command, timeout, deadline)


def contained_cleanup_error(
    job: LaunchdJob, deadline: float | None, signal_root: bool
) -> SimulatorLifecycleError | None:
    try:
        cleanup_contained_job(job, deadline, signal_root)
    except SimulatorLifecycleError as error:
        return error
    return None


def cleanup_process_evidence(
    evidence: str, cleanup_error: str | None
) -> str:
    if cleanup_error is None:
        return evidence
    separator = "" if not evidence or evidence.endswith("\n") else "\n"
    return f"{evidence}{separator}containment cleanup error = {cleanup_error}\n"


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


def capture_host_process_diagnostic(args: argparse.Namespace, label: str) -> None:
    timeout = min(getattr(args, "simulator_timeout", 120.0), 20.0)
    try:
        deadline = time.monotonic() + lifecycle_timeout(args, label, timeout)
        output = deadline_call(
            lambda: host_process_census(deadline),
            deadline,
            "host process census deadline expired",
        )
        append_lifecycle_evidence(
            args, label, ["libproc", "stable-process-census"], 0, output, ""
        )
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
    capture_host_process_diagnostic(args, f"{label}-host-processes")


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


def append_failed_attempt_cleanup(
    error: Exception,
    job: LaunchdJob,
    deadline: float | None,
    cleanup_attempted: bool,
) -> None:
    cleanup_errors: list[str] = []
    if not cleanup_attempted and job.root.exists():
        record_cleanup_failure(
            cleanup_errors,
            "containment cleanup failed",
            lambda: cleanup_contained_job(job, deadline, True),
        )
    record_cleanup_failure(
        cleanup_errors, "job root removal failed", lambda: remove_job_root(job.root)
    )
    append_cleanup_errors(error, "xcodebuild cleanup error", cleanup_errors)


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
    cleanup_attempted = False
    try:
        returncode, output, timeout_reason = observe_attempt(
            job, args, run_started, log, evidence_errors
        )
        process_evidence = ""
        if timeout_reason:
            evidence_deadline = process_evidence_deadline(deadline)
            process_evidence = launchd_job_evidence(job, evidence_deadline)
        cleanup_attempted = True
        cleanup_errors: list[str] = []
        containment_error = contained_cleanup_error(
            job, deadline, timeout_reason is not None
        )
        if containment_error is not None:
            cleanup_errors.append(str(containment_error))
        record_cleanup_failure(
            cleanup_errors, "job root removal failed", lambda: remove_job_root(job.root)
        )
        cleanup_error = cleanup_error_text(cleanup_errors)
        process_evidence = cleanup_process_evidence(process_evidence, cleanup_error)
        return AttemptOutcome(
            returncode if returncode is not None else -signal.SIGKILL,
            output,
            timeout_reason,
            process_evidence,
            cleanup_error,
        )
    except Exception as error:
        append_failed_attempt_cleanup(error, job, deadline, cleanup_attempted)
        raise


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
                if outcome.cleanup_error is not None:
                    print(
                        "classification=containment-cleanup-failure; "
                        f"{outcome.cleanup_error}",
                        file=sys.stderr,
                    )
                    if outcome.returncode == 0 and outcome.timeout_reason is None:
                        return PRETEST_INFRASTRUCTURE_FAILURE
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


def run_direct_child(arguments: list[str]) -> int:
    if len(arguments) < 6 or arguments[4] != "--":
        print("invalid direct-child arguments", file=sys.stderr)
        return PRETEST_INFRASTRUCTURE_FAILURE
    return direct_child(
        int(arguments[1]),
        int(arguments[2]),
        int(arguments[3]),
        arguments[5:],
    )


def run_direct_target(arguments: list[str]) -> int:
    if len(arguments) < 4 or arguments[2] != "--":
        print("invalid direct-target arguments", file=sys.stderr)
        return PRETEST_INFRASTRUCTURE_FAILURE
    return direct_target(int(arguments[1]), arguments[3:])


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
    if sys.argv[1:2] == [DIRECT_CHILD_ARGUMENT]:
        return run_direct_child(sys.argv[1:])
    if sys.argv[1:2] == [DIRECT_TARGET_ARGUMENT]:
        return run_direct_target(sys.argv[1:])
    if sys.argv[1:2] == [EVIDENCE_WRITER_ARGUMENT]:
        return run_evidence_writer(sys.argv[1:])
    return run(parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
