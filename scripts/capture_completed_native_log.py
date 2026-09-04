#!/usr/bin/env python3
"""Retain original completed native job output using read-only GitHub APIs."""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import math
import os
import re
import signal
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

WORKFLOW = ".github/workflows/ci.yml"
CAPTURE_JOB = "Retain completed native job log"
MAX_JSON_BYTES = 16 * 1024**2
MAX_LOG_BYTES = 512 * 1024**2
MAX_JOBS = 1000
CHUNK_BYTES = 64 * 1024
MIN_TIMER_SECONDS = 0.000001
CAPTURE_ALARM_OWNER = None
CAPTURE_ALARM_RESTORE = None
ALARM_CONTEXT = "context"
ALARM_CALLER = "caller"
ALARM_CAPTURE = "capture"
ALARM_MASK = "mask"
ALARM_CALLER_MASK = "caller-mask"
ALARM_RESTORED = "restored"
OWNER_ACTIVE = "active"
OWNER_RECOVERABLE = "recoverable"
ALARM_PHASES = frozenset((ALARM_CONTEXT, ALARM_CALLER, ALARM_CAPTURE, ALARM_MASK,
                          ALARM_CALLER_MASK, ALARM_RESTORED))
VALID_SIGNALS = frozenset(signal.valid_signals())


class CaptureError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CaptureError(message)


def unique_object(pairs: list) -> dict:
    result = {}
    for name, value in pairs:
        require(name not in result, "duplicate JSON key")
        result[name] = value
    return result


def decode_json(raw: bytes) -> dict:
    result = json.loads(raw, object_pairs_hook=unique_object,
                        parse_constant=lambda value: require(False, "invalid JSON constant"))
    require(type(result) is dict, "JSON object required")
    return result


def same_json(first: dict, second: dict) -> bool:
    return json.dumps(first, sort_keys=True) == json.dumps(second, sort_keys=True)


def clock(value: str) -> datetime:
    require(type(value) is str, "invalid timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(parsed.tzinfo is not None, "timestamp requires timezone")
    return parsed


def positive_id(value) -> bool:
    return type(value) is int and value > 0


def capture_context(environment: dict) -> dict:
    require(environment["GITHUB_EVENT_NAME"] == "workflow_dispatch", "dispatch required")
    require(environment["GITHUB_RUN_ATTEMPT"] == "1", "first attempt required")
    require(environment["GITHUB_JOB"] == "retain-completed-native-log", "wrong capture job")
    require(environment["RUNNER_ENVIRONMENT"] == "github-hosted", "hosted runner required")
    repository, ref = environment["GITHUB_REPOSITORY"], environment["GITHUB_REF"]
    source = environment["GITHUB_SHA"]
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository), "invalid repository")
    require(re.fullmatch(r"refs/heads/[A-Za-z0-9][A-Za-z0-9_.-]*", ref)
            and ".." not in ref and not ref.endswith((".", ".lock")), "invalid branch")
    require(re.fullmatch(r"[0-9a-f]{40}", source), "invalid source")
    require(environment["GITHUB_WORKFLOW_SHA"] == source, "workflow source mismatch")
    require(environment["GITHUB_WORKFLOW_REF"] == f"{repository}/{WORKFLOW}@{ref}",
            "workflow ref mismatch")
    require(re.fullmatch(r"[1-9][0-9]{0,19}", environment["GITHUB_RUN_ID"]), "invalid run id")
    inputs = decode_json(environment["CANDIDATE_INPUTS"].encode())
    require(set(inputs) == {"candidate-request", "expected-sha", "command-sha256"}, "invalid inputs")
    require(all(type(value) is str for value in inputs.values()), "invalid input types")
    require(re.fullmatch(r"[0-9a-f]{32}", inputs["candidate-request"]), "invalid request")
    require(re.fullmatch(r"[0-9a-f]{64}", inputs["command-sha256"]), "invalid command digest")
    require(inputs["expected-sha"] == source, "input source mismatch")
    return {"inputs": inputs, "repository": repository, "ref": ref, "source": source,
            "workflow_ref": environment["GITHUB_WORKFLOW_REF"], "workflow_sha": source,
            "run_id": int(environment["GITHUB_RUN_ID"]), "run_attempt": 1,
            "runner_environment": "github-hosted"}


def native_steps(workflow: Path) -> list[str]:
    require(workflow.stat().st_size <= MAX_JSON_BYTES, "workflow too large")
    section = workflow.read_text().split("\n  build-and-test:\n")
    require(len(section) == 2, "native source job missing or ambiguous")
    section = re.split(r"\n  [A-Za-z0-9_-]+:\n", section[1], maxsplit=1)[0]
    names = re.findall(r"^      - name: ([^\r\n]+)$", section, re.MULTILINE)
    require(bool(names) and len(set(names)) == len(names), "invalid native source steps")
    return names


def validate_job_identity(job: dict, context: dict, label: str) -> None:
    require(positive_id(job["id"]) and positive_id(job["runner_id"]), "invalid job/runner id")
    require(type(job["run_id"]) is int and job["run_id"] == context["run_id"], "wrong job run")
    require(type(job["run_attempt"]) is int and job["run_attempt"] == 1, "wrong job attempt")
    require(job["head_sha"] == context["source"], "wrong job source")
    require(job["head_branch"] == context["ref"].removeprefix("refs/heads/"), "wrong job branch")
    require(job["run_url"] == f"https://api.github.com/repos/{context['repository']}/actions/runs/"
            f"{context['run_id']}", "wrong job repository")
    require(type(job["labels"]) is list and label in job["labels"]
            and "self-hosted" not in job["labels"], "wrong runner labels")
    require(job["runner_group_name"] == "GitHub Actions", "wrong runner group")
    clock(job["started_at"])


def validate_native(job: dict, context: dict, expected_steps: list[str]) -> None:
    validate_job_identity(job, context, "macos-26")
    require(job["name"] == "build-and-test", "wrong native job")
    require(job["status"] == "completed" and job["conclusion"] == "success", "native job failed")
    require(clock(job["completed_at"]) >= clock(job["started_at"]), "invalid native duration")
    steps = job["steps"]
    require(type(steps) is list and bool(steps), "missing native steps")
    numbers, names = [step["number"] for step in steps], [step["name"] for step in steps]
    require(all(positive_id(number) for number in numbers)
            and numbers == sorted(set(numbers)), "invalid step numbering")
    require(all(type(name) is str for name in names) and len(set(names)) == len(names),
            "duplicate native steps")
    require(names[0] == "Set up job" and names[-1] == "Complete job", "missing runner steps")
    require([name for name in names if name in expected_steps] == expected_steps,
            "missing or reordered native steps")
    for step in steps:
        required = step["name"] in ["Set up job", "Complete job", *expected_steps]
        require(required or step["name"].startswith("Post "), "unexpected native step")
        require(step["status"] == "completed", "unfinished native step")
        require(step["conclusion"] == "success" if required else
                step["conclusion"] in ("success", "skipped"), "unsuccessful native step")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


class CaptureHTTP:
    def __init__(self, token: str, timeout: float = 120, opener=None) -> None:
        require(bool(token) and len(token) <= 4096 and not any(char.isspace() for char in token),
                "invalid API credential")
        self.secret = token.encode()
        self.deadline = time.monotonic() + timeout
        self.json_bytes = 0
        self.opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def check(self) -> None:
        require(time.monotonic() < self.deadline, "capture deadline expired")

    def response(self, url: str, authenticated: bool):
        self.check()
        headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
                   "User-Agent": "pomodorough-completed-native-log"}
        if authenticated:
            headers["Authorization"] = "Bearer " + self.secret.decode()
        request = urllib.request.Request(url, headers=headers, method="GET")
        try:
            return self.opener.open(request, timeout=min(30, self.deadline - time.monotonic()))
        except urllib.error.HTTPError as error:
            return error

    def stream(self, response, output, limit: int) -> int:
        declared = response.headers.get("Content-Length")
        require(declared is None or re.fullmatch(r"[0-9]+", declared), "invalid response length")
        require(declared is None or int(declared) <= limit, "response exceeds quota")
        total, tail = 0, b""
        while True:
            self.check()
            chunk = response.read(CHUNK_BYTES)
            self.check()
            if not chunk:
                break
            total += len(chunk)
            require(total <= limit, "response exceeds quota")
            require(self.secret not in tail + chunk, "credential in response")
            tail = (tail + chunk)[-len(self.secret):]
            output.write(chunk)
        require(total > 0 and (declared is None or total == int(declared)), "truncated or empty response")
        return total

    def get(self, url: str, output, limit: int, redirects: bool = False) -> int:
        require(url.startswith("https://api.github.com/repos/"), "invalid API URL")
        for hop in range(4):
            with self.response(url, authenticated=hop == 0) as response:
                if response.status == 200:
                    return self.stream(response, output, limit)
                require(redirects and response.status in (301, 302, 303, 307, 308) and hop < 3,
                        "API request failed")
                url = redirect_url(response.headers.get("Location", ""))
                require(self.secret not in url.encode(), "credential in redirect")
        raise CaptureError("redirect quota exceeded")

    def json(self, url: str) -> tuple[dict, bytes]:
        output = io.BytesIO()
        self.json_bytes += self.get(url, output, MAX_JSON_BYTES)
        require(self.json_bytes <= 4 * MAX_JSON_BYTES, "JSON total quota exceeded")
        result = decode_json(output.getvalue())
        self.check()
        return result, output.getvalue()


def redirect_url(value: str) -> str:
    require(bool(value) and len(value) <= 16384 and not any(char.isspace() for char in value)
            and "\\" not in value and all(ord(char) >= 32 for char in value), "invalid redirect")
    parsed = urllib.parse.urlsplit(value)
    require(parsed.scheme == "https" and parsed.port in (None, 443) and parsed.username is None
            and parsed.password is None and not parsed.fragment, "unsafe redirect")
    require(parsed.hostname is not None and any(parsed.hostname.endswith(suffix)
            for suffix in (".blob.core.windows.net", ".actions.githubusercontent.com")),
            "untrusted redirect host")
    return value


def restore_caller_timer(previous_timer: tuple[float, float], suspended_at: float,
                         caller_pending: bool) -> bool:
    delay, interval = previous_timer
    if delay == 0.0:
        return False
    elapsed = max(0.0, time.monotonic() - suspended_at)
    expired = elapsed >= delay
    if elapsed < delay:
        next_delay = delay - elapsed
    elif interval > 0.0:
        overdue = elapsed - delay
        next_delay = interval - overdue % interval
    else:
        return expired and not caller_pending
    signal.setitimer(signal.ITIMER_REAL, max(next_delay, MIN_TIMER_SECONDS), interval)
    return expired and not caller_pending


def replay_caller_alarm(previous, previous_mask: set[signal.Signals]) -> None:
    if signal.SIGALRM in previous_mask:
        signal.raise_signal(signal.SIGALRM)
        return
    if previous is signal.SIG_IGN:
        return
    if callable(previous):
        previous(signal.SIGALRM, sys._getframe(1))
        return
    signal.raise_signal(signal.SIGALRM)


def restore_caller_alarm(restore: dict) -> None:
    previous_timer, suspended_at, caller_pending = restore["caller"]
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
    signal.setitimer(signal.ITIMER_REAL, 0)
    if signal.SIGALRM in signal.sigpending():
        signal.sigwait({signal.SIGALRM})
    signal.signal(signal.SIGALRM, restore["previous"])
    timer_expired = restore_caller_timer(
        previous_timer, suspended_at, caller_pending
    )
    restore["phase"] = ALARM_CALLER_MASK
    signal.pthread_sigmask(signal.SIG_SETMASK, restore["previous_mask"])
    restore["phase"] = ALARM_RESTORED
    if caller_pending or timer_expired:
        replay_caller_alarm(restore["previous"], restore["previous_mask"])


def valid_capture_alarm_token(token) -> bool:
    return type(token) is object


def valid_signal_handler(handler) -> bool:
    return handler is signal.SIG_DFL or handler is signal.SIG_IGN or callable(handler)


def valid_signal_mask(mask) -> bool:
    if type(mask) is not set:
        return False
    return all((type(value) is int or type(value) is signal.Signals)
               and value in VALID_SIGNALS for value in mask)


def valid_timer_value(value) -> bool:
    return type(value) is float and math.isfinite(value) and value >= 0.0


def valid_capture_alarm_owner(owner) -> bool:
    return (type(owner) is list and len(owner) == 3
            and type(owner[0]) is int and owner[0] > 0
            and valid_capture_alarm_token(owner[1])
            and type(owner[2]) is str
            and owner[2] in (OWNER_ACTIVE, OWNER_RECOVERABLE))


def valid_caller_alarm_restore(caller) -> bool:
    if type(caller) is not tuple or len(caller) != 3:
        return False
    previous_timer, suspended_at, caller_pending = caller
    return (type(previous_timer) is tuple and len(previous_timer) == 2
            and all(valid_timer_value(value) for value in previous_timer)
            and valid_timer_value(suspended_at)
            and type(caller_pending) is bool)


def valid_capture_alarm_restore(restore) -> bool:
    fields = {"token", "previous", "previous_mask", "phase", "caller",
              "deadline_pending"}
    if type(restore) is not dict or restore.keys() != fields:
        return False
    return (valid_capture_alarm_token(restore["token"])
            and valid_signal_handler(restore["previous"])
            and valid_signal_mask(restore["previous_mask"])
            and type(restore["phase"]) is str
            and restore["phase"] in ALARM_PHASES
            and valid_caller_alarm_restore(restore["caller"])
            and type(restore["deadline_pending"]) is bool)


def valid_capture_alarm_recovery(owner, restore) -> bool:
    if not valid_capture_alarm_owner(owner):
        return False
    return (restore is None
            or (valid_capture_alarm_restore(restore) and restore["token"] is owner[1]))


def owns_capture_alarm(token: object) -> bool:
    owner = CAPTURE_ALARM_OWNER
    return (valid_capture_alarm_owner(owner)
            and owner[0] == os.getpid() and owner[1] is token)


def remember_capture_alarm(token: object, previous,
                           previous_mask: set[signal.Signals]) -> dict:
    global CAPTURE_ALARM_RESTORE
    require(owns_capture_alarm(token), "existing process deadline")
    restore = {
        "token": token,
        "previous": previous,
        "previous_mask": previous_mask,
        "phase": ALARM_CONTEXT,
        "caller": ((0.0, 0.0), time.monotonic(), False),
        "deadline_pending": False,
    }
    CAPTURE_ALARM_RESTORE = restore
    return restore


def capture_alarm_context(token: object) -> dict:
    previous = signal.getsignal(signal.SIGALRM)
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
    restore = remember_capture_alarm(token, previous, previous_mask)
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
    previous_timer = signal.getitimer(signal.ITIMER_REAL)
    suspended_at = time.monotonic()
    restore["caller"] = (previous_timer, suspended_at, False)
    return restore


def capture_alarm_restore(token: object) -> dict | None:
    restore = CAPTURE_ALARM_RESTORE
    if (not owns_capture_alarm(token) or not valid_capture_alarm_restore(restore)
            or restore["token"] is not token):
        return None
    return restore


def forget_capture_alarm_restore(token: object) -> None:
    global CAPTURE_ALARM_RESTORE
    restore = CAPTURE_ALARM_RESTORE
    if valid_capture_alarm_restore(restore) and restore["token"] is token:
        CAPTURE_ALARM_RESTORE = None


def reset_capture_alarm_after_fork() -> None:
    global CAPTURE_ALARM_OWNER, CAPTURE_ALARM_RESTORE
    inherited_owner = CAPTURE_ALARM_OWNER
    inherited = CAPTURE_ALARM_RESTORE
    CAPTURE_ALARM_OWNER, CAPTURE_ALARM_RESTORE = None, None
    if (inherited_owner is None and inherited is None):
        return
    if (not valid_capture_alarm_recovery(inherited_owner, inherited)
            or inherited is None or inherited["phase"] == ALARM_RESTORED):
        return
    if inherited["phase"] == ALARM_CAPTURE:
        signal.setitimer(signal.ITIMER_REAL, 0)
    signal.signal(signal.SIGALRM, inherited["previous"])
    signal.pthread_sigmask(signal.SIG_SETMASK, inherited["previous_mask"])


os.register_at_fork(after_in_child=reset_capture_alarm_after_fork)


def prepare_caller_alarm(restore: dict) -> tuple[tuple[float, float], bool]:
    previous_timer, suspended_at, _ = restore["caller"]
    restore["phase"] = ALARM_CALLER
    signal.setitimer(signal.ITIMER_REAL, 0)
    caller_pending = signal.SIGALRM in signal.sigpending()
    restore["caller"] = (previous_timer, suspended_at, caller_pending)
    return previous_timer, caller_pending


def claim_capture_alarm(
    client: CaptureHTTP, expired, token: object, observed_timer: tuple[float, float]
) -> dict:
    client.check()
    restore = capture_alarm_context(token)
    previous_timer, caller_pending = prepare_caller_alarm(restore)
    conflict = (signal.SIGALRM in restore["previous_mask"]
                or observed_timer != (0.0, 0.0)
                or previous_timer != (0.0, 0.0) or caller_pending)
    require(not conflict, "existing process deadline")
    remaining = client.deadline - time.monotonic()
    require(remaining > 0, "capture deadline expired")
    restore["phase"] = ALARM_CAPTURE
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, remaining)
    signal.pthread_sigmask(signal.SIG_SETMASK, restore["previous_mask"])
    client.check()
    return restore


def restore_capture_context(restore: dict) -> None:
    signal.signal(signal.SIGALRM, restore["previous"])
    signal.pthread_sigmask(signal.SIG_SETMASK, restore["previous_mask"])
    restore["phase"] = ALARM_RESTORED


def release_capture_alarm(restore: dict, deadline: float) -> CaptureError | None:
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
    signal.setitimer(signal.ITIMER_REAL, 0)
    pending_deadline = signal.SIGALRM in signal.sigpending()
    restore["deadline_pending"] |= pending_deadline
    if pending_deadline:
        signal.sigwait({signal.SIGALRM})
    signal.signal(signal.SIGALRM, signal.SIG_IGN)
    signal.signal(signal.SIGALRM, restore["previous"])
    restore["phase"] = ALARM_MASK
    signal.pthread_sigmask(signal.SIG_SETMASK, restore["previous_mask"])
    restore["phase"] = ALARM_RESTORED
    deadline_failure = None
    if restore["deadline_pending"] or time.monotonic() >= deadline:
        deadline_failure = CaptureError("capture deadline expired")
    return deadline_failure


def recover_capture_alarm(token: object, deadline: float) -> CaptureError | None:
    restore = capture_alarm_restore(token)
    if restore is None:
        return None
    phase = restore["phase"]
    if phase in (ALARM_CONTEXT, ALARM_MASK, ALARM_CALLER_MASK):
        restore_capture_context(restore)
    elif phase == ALARM_CALLER:
        restore_caller_alarm(restore)
    elif phase == ALARM_CAPTURE:
        return release_capture_alarm(restore, deadline)
    if restore["deadline_pending"] or time.monotonic() >= deadline:
        return CaptureError("capture deadline expired")
    return None


def finish_capture_alarm(token: object, deadline: float) -> CaptureError | None:
    deadline_failure = None
    cleanup_failures = []
    for _ in range(2):
        try:
            recovered_deadline = recover_capture_alarm(token, deadline)
        except CaptureError as error:
            deadline_failure = deadline_failure or error
        except BaseException as error:
            cleanup_failures.append(error)
        else:
            deadline_failure = deadline_failure or recovered_deadline
            break
    if cleanup_failures:
        for secondary in cleanup_failures[1:]:
            cleanup_failures[0].add_note(f"capture alarm cleanup failed: {secondary}")
        raise cleanup_failures[0]
    return deadline_failure


def reject_malformed_capture_alarm_state() -> None:
    global CAPTURE_ALARM_OWNER, CAPTURE_ALARM_RESTORE
    CAPTURE_ALARM_OWNER, CAPTURE_ALARM_RESTORE = None, None
    raise CaptureError("invalid capture alarm recovery state")


def recover_stale_capture_ownership() -> None:
    owner = CAPTURE_ALARM_OWNER
    restore = CAPTURE_ALARM_RESTORE
    if owner is None and restore is None:
        return
    if not valid_capture_alarm_recovery(owner, restore):
        reject_malformed_capture_alarm_state()
    if owner[0] != os.getpid():
        reset_capture_alarm_after_fork()
        return
    recovered = restore is not None and restore["phase"] == ALARM_RESTORED
    if owner[2] != OWNER_RECOVERABLE and not recovered:
        return
    try:
        finish_capture_alarm(owner[1], float("inf"))
    finally:
        restore = capture_alarm_restore(owner[1])
        if restore is None or restore["phase"] == ALARM_RESTORED:
            release_capture_ownership(owner[1])


def claim_capture_ownership(token: object) -> None:
    global CAPTURE_ALARM_OWNER
    require(threading.current_thread() is threading.main_thread(),
            "capture deadline requires main thread")
    recover_stale_capture_ownership()
    require(CAPTURE_ALARM_OWNER is None, "existing process deadline")
    CAPTURE_ALARM_OWNER = [os.getpid(), token, OWNER_ACTIVE]


def claim_capture_alarm_entry(token: object) -> tuple[float, float]:
    existing = CAPTURE_ALARM_OWNER is not None or CAPTURE_ALARM_RESTORE is not None
    if existing:
        if not valid_capture_alarm_recovery(CAPTURE_ALARM_OWNER, CAPTURE_ALARM_RESTORE):
            reject_malformed_capture_alarm_state()
        claim_capture_ownership(token)
        return signal.getitimer(signal.ITIMER_REAL)
    observed_timer = signal.getitimer(signal.ITIMER_REAL)
    claim_capture_ownership(token)
    return observed_timer


def mark_capture_ownership_recoverable(token: object) -> None:
    if owns_capture_alarm(token):
        CAPTURE_ALARM_OWNER[2] = OWNER_RECOVERABLE


def release_capture_ownership(token: object) -> None:
    global CAPTURE_ALARM_OWNER, CAPTURE_ALARM_RESTORE
    if not owns_capture_alarm(token):
        return
    restore = capture_alarm_restore(token)
    require(restore is None or restore["phase"] == ALARM_RESTORED,
            "capture alarm cleanup incomplete")
    CAPTURE_ALARM_OWNER = None
    if CAPTURE_ALARM_RESTORE is restore:
        CAPTURE_ALARM_RESTORE = None


def complete_capture_alarm(token: object, deadline: float) -> CaptureError | None:
    deadline_failure = None
    try:
        if capture_alarm_restore(token) is not None:
            deadline_failure = finish_capture_alarm(token, deadline)
    except BaseException as error:
        mark_capture_ownership_recoverable(token)
        restore = capture_alarm_restore(token)
        if restore is not None and restore["phase"] == ALARM_RESTORED:
            try:
                release_capture_ownership(token)
            except BaseException as release_error:
                error.add_note(f"capture alarm cleanup failed: {release_error}")
        raise
    mark_capture_ownership_recoverable(token)
    release_capture_ownership(token)
    return deadline_failure


def raise_capture_failure(failure: BaseException | None,
                          deadline_failure: CaptureError | None,
                          cleanup_failure: BaseException | None,
                          deadline: float) -> None:
    if failure is not None:
        for secondary in (deadline_failure, cleanup_failure):
            if secondary is not None and secondary is not failure:
                failure.add_note(f"capture alarm cleanup failed: {secondary}")
        raise failure
    if deadline_failure is not None:
        if cleanup_failure is not None:
            deadline_failure.add_note(f"capture alarm cleanup failed: {cleanup_failure}")
        raise deadline_failure
    if cleanup_failure is not None:
        raise cleanup_failure
    require(time.monotonic() < deadline, "capture deadline expired")


@contextlib.contextmanager
def capture_deadline(client: CaptureHTTP):
    token = object()
    alarm = {"deadline": None, "teardown": False}
    claimed_alarm = None
    failure: BaseException | None = None
    cleanup_failure: BaseException | None = None
    def expired(signum, frame):
        if alarm["deadline"] is None:
            alarm["deadline"] = CaptureError("capture deadline expired")
        if alarm["teardown"]:
            return
        alarm["teardown"] = True
        raise alarm["deadline"]
    try:
        observed_timer = claim_capture_alarm_entry(token)
        claimed_alarm = claim_capture_alarm(client, expired, token, observed_timer)
        yield
        client.check()
        alarm["teardown"] = True
    except BaseException as error:
        failure = error
        alarm["teardown"] = True
    finally:
        alarm["teardown"] = True
        if owns_capture_alarm(token):
            try:
                cleanup_deadline = complete_capture_alarm(token, client.deadline)
                if alarm["deadline"] is None:
                    alarm["deadline"] = cleanup_deadline
            except BaseException as error:
                cleanup_failure = error
    raise_capture_failure(failure, alarm["deadline"], cleanup_failure, client.deadline)


def attempt_jobs(client: CaptureHTTP, base: str, run_id: int) -> list[dict]:
    jobs, total = [], None
    for page in range(1, MAX_JOBS // 100 + 1):
        result, _ = client.json(f"{base}/actions/runs/{run_id}/attempts/1/jobs?per_page=100&page={page}")
        count = result["total_count"]
        require(type(count) is int and 0 < count <= MAX_JOBS, "invalid jobs count")
        require(total is None or total == count, "jobs count changed")
        total = count
        require(type(result["jobs"]) is list and len(result["jobs"]) == min(100, total - len(jobs)),
                "incomplete jobs pagination")
        jobs.extend(result["jobs"])
        identifiers = [job["id"] for job in jobs]
        require(all(positive_id(identifier) for identifier in identifiers)
                and len(set(identifiers)) == len(jobs), "duplicate or invalid job id")
        if len(jobs) == total:
            return jobs
    raise CaptureError("jobs pagination quota exceeded")


def select_native(jobs: list[dict], context: dict, expected: list[str]) -> dict:
    native = [job for job in jobs if job["name"] == "build-and-test"]
    capture = [job for job in jobs if job["name"] == CAPTURE_JOB]
    require(len(native) == len(capture) == 1, "ambiguous native or capture job")
    validate_native(native[0], context, expected)
    validate_job_identity(capture[0], context, "ubuntu-24.04")
    require(capture[0]["status"] == "in_progress" and capture[0]["conclusion"] is None,
            "capture job is not running")
    require(clock(capture[0]["started_at"]) >= clock(native[0]["completed_at"]),
            "capture preceded native completion")
    return native[0]


def capture(client: CaptureHTTP, context: dict, expected: list[str], output: Path) -> None:
    with capture_deadline(client):
        require(client.secret not in json.dumps(context, sort_keys=True).encode(), "credential in context")
        base = f"https://api.github.com/repos/{context['repository']}"
        native = select_native(attempt_jobs(client, base, context["run_id"]), context, expected)
        endpoint = f"{base}/actions/jobs/{native['id']}"
        before, original_metadata = client.json(endpoint)
        validate_native(before, context, expected)
        require(same_json(before, native), "native metadata changed before capture")
        output.mkdir(parents=False, exist_ok=False)
        with (output / "native-job.log").open("xb") as stream:
            client.get(endpoint + "/logs", stream, MAX_LOG_BYTES, redirects=True)
        after, _ = client.json(endpoint)
        validate_native(after, context, expected)
        require(same_json(before, after), "native metadata changed during capture")
        (output / "native-job.json").write_bytes(original_metadata)
        (output / "capture-context.json").write_text(json.dumps(context, sort_keys=True) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args(argv)
    try:
        client = CaptureHTTP(os.environ["GITHUB_TOKEN"])
        context = capture_context(os.environ)
        expected = native_steps(Path(__file__).resolve().parents[1] / WORKFLOW)
        capture(client, context, expected, arguments.output)
        return 0
    except Exception:
        print("completed native log capture rejected", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
