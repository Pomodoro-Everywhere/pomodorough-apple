#!/usr/bin/env python3
"""Run xcodebuild with bounded execution and reviewable timeout evidence."""

from __future__ import annotations

import argparse
from pathlib import Path
import os
import re
import signal
import subprocess
import sys
import threading
import time
from typing import TextIO


FINAL_TEST_MARKERS = (
    re.compile(
        r"Test Suite 'All tests' passed[^\n]*\n\s*Executed [1-9][0-9]* tests, with 0 failures"
    ),
)
POST_TEST_TIMEOUT = 124
TEST_EXECUTION_TIMEOUT = 125
EVIDENCE_FAILURE = 126


def tests_completed(output: str, completion_marker: str) -> bool:
    return completion_marker in output and any(
        pattern.search(output) for pattern in FINAL_TEST_MARKERS
    )


def process_rows() -> dict[int, tuple[int, str]]:
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,etime=,state=,command="],
        capture_output=True,
        check=False,
        text=True,
    )
    rows: dict[int, tuple[int, str]] = {}
    for line in result.stdout.splitlines():
        fields = line.strip().split(maxsplit=4)
        if len(fields) == 5 and fields[0].isdigit() and fields[1].isdigit():
            rows[int(fields[0])] = (int(fields[1]), line)
    return rows


def descendant_pids(root_pid: int) -> set[int]:
    rows = process_rows()
    selected = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, (parent, _) in rows.items():
            if parent in selected and pid not in selected:
                selected.add(pid)
                changed = True
    selected.discard(root_pid)
    return selected


def descendant_processes(root_pid: int) -> str:
    rows = process_rows()
    selected = descendant_pids(root_pid) | {root_pid}
    return "\n".join(rows[pid][1] for pid in sorted(selected) if pid in rows) + "\n"


def signal_process_group(process: subprocess.Popen[str], requested: signal.Signals) -> bool:
    try:
        os.killpg(process.pid, requested)
        return True
    except (PermissionError, ProcessLookupError):
        return False


def process_group_exists(group_id: int) -> bool:
    result = subprocess.run(
        ["ps", "-axo", "pgid="],
        capture_output=True,
        check=False,
        text=True,
    )
    return str(group_id) in {line.strip() for line in result.stdout.splitlines()}


def wait_for_process_group_exit(group_id: int, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while process_group_exists(group_id):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)
    return True


def signal_pid(pid: int, requested: signal.Signals) -> bool:
    try:
        os.kill(pid, requested)
        return True
    except (PermissionError, ProcessLookupError):
        return False


def wait_for_pids_exit(pids: set[int], timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while pids & process_rows().keys():
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)
    return True


def terminate_descendants(pids: set[int]) -> None:
    live = {pid for pid in pids if signal_pid(pid, signal.SIGTERM)}
    if live and not wait_for_pids_exit(live, 2):
        for pid in live:
            signal_pid(pid, signal.SIGKILL)
        wait_for_pids_exit(live, 2)


def terminate_process_group(process: subprocess.Popen[str]) -> None:
    escaped_descendants = descendant_pids(process.pid)
    group_active = True
    if hasattr(signal, "SIGINFO"):
        group_active = signal_process_group(process, signal.SIGINFO)
        if group_active:
            time.sleep(0.2)
    if group_active:
        group_active = signal_process_group(process, signal.SIGINT)
    if group_active:
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        if not wait_for_process_group_exit(process.pid, 0.2):
            if signal_process_group(process, signal.SIGTERM):
                if not wait_for_process_group_exit(process.pid, 2):
                    signal_process_group(process, signal.SIGKILL)
                    wait_for_process_group_exit(process.pid, 2)
    terminate_descendants(escaped_descendants)


def wait_for_timeout(
    process: subprocess.Popen[str],
    started: float,
    last_output: list[float],
    output_lock: threading.Lock,
    args: argparse.Namespace,
) -> str | None:
    while process.poll() is None:
        now = time.monotonic()
        if now - started >= args.wall_timeout:
            return f"wall-timeout={args.wall_timeout:g}s"
        with output_lock:
            idle_for = now - last_output[0]
        if idle_for >= args.idle_timeout:
            return f"idle-timeout={args.idle_timeout:g}s"
        time.sleep(min(0.05, args.idle_timeout / 4))
    return None


def write_timeout_evidence(
    args: argparse.Namespace,
    process: subprocess.Popen[str],
    classification: str,
    timeout_reason: str,
    started: float,
) -> None:
    (args.diagnostics_dir / "timeout.txt").write_text(
        "\n".join(
            [
                f"classification={classification}",
                timeout_reason,
                f"elapsed={time.monotonic() - started:.1f}s",
                f"pid={process.pid}",
                "",
                descendant_processes(process.pid),
            ]
        ),
        encoding="utf-8",
    )


def drain_output(
    process: subprocess.Popen[str],
    log: TextIO,
    last_output: list[float],
    output_lines: list[str],
    output_lock: threading.Lock,
    evidence_errors: list[OSError],
) -> None:
    assert process.stdout is not None
    log_available = True
    for line in process.stdout:
        with output_lock:
            last_output[0] = time.monotonic()
            output_lines.append(line)
        if log_available:
            try:
                log.write(line)
            except OSError as error:
                evidence_errors.append(error)
                log_available = False
        sys.stdout.write(line)
        sys.stdout.flush()


def evidence_failed(evidence_errors: list[OSError]) -> bool:
    if not evidence_errors:
        return False
    print(f"classification=evidence-write-failure; {evidence_errors[0]}", file=sys.stderr)
    return True


def run(args: argparse.Namespace) -> int:
    args.log_path.parent.mkdir(parents=True, exist_ok=True)
    args.diagnostics_dir.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    last_output = [started]
    output_lines: list[str] = []
    output_lock = threading.Lock()
    evidence_errors: list[OSError] = []

    with args.log_path.open("w", encoding="utf-8", buffering=1) as log:
        process = subprocess.Popen(
            args.command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
        reader = threading.Thread(
            target=drain_output,
            args=(process, log, last_output, output_lines, output_lock, evidence_errors),
            daemon=True,
        )
        reader.start()
        timeout_reason = wait_for_timeout(process, started, last_output, output_lock, args)
        if timeout_reason is None:
            reader.join(timeout=2)
            return EVIDENCE_FAILURE if evidence_failed(evidence_errors) else process.returncode

        with output_lock:
            timeout_output = "".join(output_lines)
        post_test_timeout = tests_completed(timeout_output, args.completion_marker)
        classification = (
            "post-test-finalization-timeout"
            if post_test_timeout
            else "test-execution-timeout"
        )
        try:
            write_timeout_evidence(args, process, classification, timeout_reason, started)
        except OSError as error:
            evidence_errors.append(error)
        print(f"classification={classification}; {timeout_reason}", file=sys.stderr)
        terminate_process_group(process)
        reader.join(timeout=2)
        if evidence_failed(evidence_errors):
            return EVIDENCE_FAILURE
        return POST_TEST_TIMEOUT if post_test_timeout else TEST_EXECUTION_TIMEOUT


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--idle-timeout", type=float, required=True)
    parser.add_argument("--wall-timeout", type=float, required=True)
    parser.add_argument("--log-path", type=Path, required=True)
    parser.add_argument("--diagnostics-dir", type=Path, required=True)
    parser.add_argument("--completion-marker", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command[:1] == ["--"]:
        args.command = args.command[1:]
    if not args.command:
        parser.error("a command is required after --")
    if args.idle_timeout <= 0 or args.wall_timeout <= 0:
        parser.error("timeouts must be positive")
    return args


def main() -> int:
    return run(parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
