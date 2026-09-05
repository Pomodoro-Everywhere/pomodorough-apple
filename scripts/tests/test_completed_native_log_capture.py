"""Fake HTTP only: never contact GitHub or execute native tooling."""

from __future__ import annotations

import copy
import hashlib
import io
import json
import re
import subprocess
import tempfile
import textwrap
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import capture_completed_native_log as capture

REAL_SUBPROCESS_RUN = subprocess.run
TOKEN = "fake-secret-never-retained"
BASE = "https://api.github.com/repos/example/apple"
SIGNED = "https://production.blob.core.windows.net/logs/job?signature=fake"
SUCCESSOR_BOUNDARY = "\n  retain-completed-native-log:\n"
WORKFLOW_PREFIX_SHA256 = "aef595bac2451ffb415ab7f9249e6d241193dbb6388e8384eb5052aeef61c2da"
SUCCESSOR_SOURCE = '''    name: <name>
    if: <condition>
    needs: <needs>
    runs-on: <runner>
    timeout-minutes: <timeout>
    permissions:
      contents: <contents>
      actions: <actions>
    steps:
      - name: Check out repository
        uses: <checkout> # v5
        with:
          persist-credentials: <persist_credentials>
      - name: Verify checked out source
        run: <verify>
      - name: Capture completed native job log
        env:
          GITHUB_TOKEN: <token>
          CANDIDATE_INPUTS: <inputs>
        run: <command>
      - name: Retain completed native job log
        uses: <upload>
        with:
          name: <artifact>
          path: <path>
          if-no-files-found: <missing_files>
          retention-days: 14
          overwrite: <overwrite>
'''


def successor_workflow_job(source):
    """Decode only this source schema, not YAML; enclosing-source drift requires review.

    The pinned prefix fixes the jobs mapping and native dependency. Full matching
    rejects duplicate keys/jobs, extra steps, and comment or block-scalar decoys.
    """
    prefix, boundary, successor = source.partition(SUCCESSOR_BOUNDARY)
    if boundary != SUCCESSOR_BOUNDARY or hashlib.sha256(prefix.encode()).hexdigest() != WORKFLOW_PREFIX_SHA256:
        raise AssertionError("CI workflow prefix changed; review enclosing jobs before updating the source pin")
    scalar_patterns = {"timeout": r"[0-9]+", "persist_credentials": "true|false", "overwrite": "true|false"}
    pattern = re.sub(r"<([a-z_]+)>",
                     lambda field: "(?P<{}>{})".format(field[1], scalar_patterns.get(field[1], r"[^\n]+")),
                     re.escape(SUCCESSOR_SOURCE))
    match = re.fullmatch(pattern, successor)
    if match is None:
        raise AssertionError("Successor job source changed; review the complete job schema")
    fields = match.groupdict()
    return {"name": fields["name"], "needs": fields["needs"], "if": fields["condition"],
            "runs-on": fields["runner"], "timeout-minutes": json.loads(fields["timeout"]),
            "permissions": {"contents": fields["contents"], "actions": fields["actions"]},
            "steps": [{"uses": fields["checkout"],
                       "with": {"persist-credentials": json.loads(fields["persist_credentials"])}},
                      {"run": fields["verify"]},
                      {"run": fields["command"], "env": {"GITHUB_TOKEN": fields["token"],
                                                          "CANDIDATE_INPUTS": fields["inputs"]}},
                      {"uses": fields["upload"],
                       "with": {"name": fields["artifact"], "path": fields["path"],
                                "if-no-files-found": fields["missing_files"],
                                "overwrite": json.loads(fields["overwrite"])}}]}


class Response(io.BytesIO):
    def __init__(self, body=b"", status=200, headers=None):
        raw = json.dumps(body).encode() if isinstance(body, dict) else body
        super().__init__(raw)
        self.status = status
        self.headers = {"Content-Length": str(len(raw))} if headers is None else headers


class FakeHTTP:
    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def open(self, request, timeout):
        self.calls.append((request, timeout))
        if not self.responses:
            raise AssertionError("unexpected HTTP request")
        result = self.responses.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


def environment():
    return {"GITHUB_TOKEN": TOKEN, "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_JOB": "retain-completed-native-log", "RUNNER_ENVIRONMENT": "github-hosted",
            "GITHUB_REPOSITORY": "example/apple", "GITHUB_REF": "refs/heads/candidate",
            "GITHUB_SHA": "a" * 40, "GITHUB_WORKFLOW_SHA": "a" * 40, "GITHUB_RUN_ID": "100",
            "GITHUB_WORKFLOW_REF": "example/apple/.github/workflows/ci.yml@refs/heads/candidate",
            "CANDIDATE_INPUTS": json.dumps({"candidate-request": "b" * 32, "expected-sha": "a" * 40,
                                            "command-sha256": "c" * 64})}


def native_job(names):
    return {"id": 200, "runner_id": 300, "name": "build-and-test", "run_id": 100, "run_attempt": 1,
            "head_sha": "a" * 40, "head_branch": "candidate", "run_url": BASE + "/actions/runs/100",
            "labels": ["macos-26"], "runner_group_name": "GitHub Actions", "status": "completed",
            "conclusion": "success", "started_at": "2026-08-30T00:00:00Z",
            "completed_at": "2026-08-30T00:01:00Z",
            "steps": [{"name": name, "number": number, "status": "completed", "conclusion": "success"}
                      for number, name in enumerate(["Set up job", *names, "Complete job"], 1)]}


def assert_subprocess_success(test, source, output, timeout=5):
    result = REAL_SUBPROCESS_RUN(
        [sys.executable, "-c", source], capture_output=True, text=True, timeout=timeout
    )
    test.assertEqual(result.returncode, 0, result.stderr)
    test.assertEqual(result.stdout, output)


def capture_subprocess_source(source):
    module_dir = repr(str(Path(capture.__file__).parent))
    return textwrap.dedent(source).replace("__CAPTURE_MODULE_DIR__", module_dir)


FORK_BOUNDARY_SOURCE = """
import os, signal, sys, time, traceback
sys.path.insert(0, __CAPTURE_MODULE_DIR__)
import capture_completed_native_log as capture

parent_pid = os.getpid()
boundary_children = []
forked = []
ownership_forked = []
real_mask = signal.pthread_sigmask
real_claim = capture.claim_capture_ownership

class Client:
    def __init__(self, timeout=3):
        self.deadline = time.monotonic() + timeout
    def check(self):
        capture.require(time.monotonic() < self.deadline, "capture deadline expired")

def caller_alarm(signum, frame):
    raise AssertionError("caller alarm fired")

def child_check():
    try:
        assert capture.CAPTURE_ALARM_OWNER is None
        assert capture.CAPTURE_ALARM_RESTORE is None
        assert signal.getsignal(signal.SIGALRM) is caller_alarm
        assert signal.SIGALRM not in real_mask(signal.SIG_BLOCK, set())
        assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)
        with capture.capture_deadline(Client(1)):
            pass
        assert capture.CAPTURE_ALARM_OWNER is None
        assert capture.CAPTURE_ALARM_RESTORE is None
        assert signal.getsignal(signal.SIGALRM) is caller_alarm
        assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)
    except BaseException:
        traceback.print_exc()
        os._exit(1)
    os._exit(0)

def fork_checked():
    child = os.fork()
    if child == 0:
        child_check()
    return child

def wait_child(child):
    waited, status = os.waitpid(child, 0)
    assert waited == child and os.waitstatus_to_exitcode(status) == 0, status

def claim_with_fork(token):
    real_claim(token)
    if os.getpid() == parent_pid and not ownership_forked:
        ownership_forked.append("owned")
        boundary_children.append(fork_checked())

def intercept_mask(how, mask):
    previous = real_mask(how, mask)
    boundary = how == signal.SIG_BLOCK and mask == {signal.SIGALRM}
    if boundary and os.getpid() == parent_pid and not forked:
        forked.append("blocked")
        boundary_children.append(fork_checked())
    return previous

signal.signal(signal.SIGALRM, caller_alarm)
original_mask = real_mask(signal.SIG_BLOCK, set())
wait_child(fork_checked())
capture.claim_capture_ownership = claim_with_fork
capture.signal.pthread_sigmask = intercept_mask
try:
    with capture.capture_deadline(Client()):
        assert len(boundary_children) == 2, boundary_children
        for child in boundary_children:
            wait_child(child)
        owner = capture.CAPTURE_ALARM_OWNER
        assert ownership_forked == ["owned"] and forked == ["blocked"]
        assert owner[0] == parent_pid, owner
        assert capture.CAPTURE_ALARM_RESTORE["token"] is owner[1]
        assert signal.getsignal(signal.SIGALRM) is not caller_alarm
        assert real_mask(signal.SIG_BLOCK, set()) == original_mask
        assert signal.getitimer(signal.ITIMER_REAL)[0] > 0.0
        wait_child(fork_checked())
        assert capture.CAPTURE_ALARM_OWNER == owner
        assert capture.CAPTURE_ALARM_RESTORE["token"] is owner[1]
finally:
    capture.claim_capture_ownership = real_claim
    capture.signal.pthread_sigmask = real_mask
assert capture.CAPTURE_ALARM_OWNER is None
assert capture.CAPTURE_ALARM_RESTORE is None
assert signal.getsignal(signal.SIGALRM) is caller_alarm
assert real_mask(signal.SIG_BLOCK, set()) == original_mask
assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)
print("fork boundaries preserved")
"""


OWNERSHIP_ALARM_BOUNDARY_SOURCE = """
import dis, signal, sys, time
sys.path.insert(0, __CAPTURE_MODULE_DIR__)
import capture_completed_native_log as capture

class CallerAlarm(Exception): pass
class Client:
    deadline = time.monotonic() + 60
    def check(self):
        capture.require(time.monotonic() < self.deadline, "capture deadline expired")

def caller_alarm(signum, frame):
    raise CallerAlarm("caller alarm")

code = capture.claim_capture_alarm_entry.__code__
instructions = list(dis.get_instructions(code))
load = max(index for index, item in enumerate(instructions)
           if item.opname == "LOAD_GLOBAL" and item.argval == "claim_capture_ownership")
call = next(index for index in range(load, len(instructions))
            if instructions[index].opname == "CALL")
original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
signal.signal(signal.SIGALRM, caller_alarm)
for interval in (0.0, 0.2):
    for boundary in (instructions[call], instructions[call + 1]):
        hits = []
        def trace(frame, event, argument):
            if frame.f_code is code:
                frame.f_trace_opcodes = True
                if event == "opcode" and frame.f_lasti == boundary.offset and not hits:
                    hits.append(boundary.offset)
                    signal.pause()
            return trace
        signal.setitimer(signal.ITIMER_REAL, 0.01, interval)
        sys.settrace(trace)
        try:
            with capture.capture_deadline(Client()):
                raise AssertionError("capture entered")
        except CallerAlarm:
            pass
        finally:
            sys.settrace(None)
        remaining, repeating = signal.getitimer(signal.ITIMER_REAL)
        assert hits == [boundary.offset] and capture.CAPTURE_ALARM_OWNER is None
        assert capture.CAPTURE_ALARM_RESTORE is None
        assert signal.getsignal(signal.SIGALRM) is caller_alarm
        assert signal.pthread_sigmask(signal.SIG_BLOCK, set()) == original_mask
        assert repeating == interval and (interval == 0.0 or remaining > 0.0)
        signal.setitimer(signal.ITIMER_REAL, 0)
        with capture.capture_deadline(Client()): pass
print("ownership alarms recovered")
"""


ENTRY_ALARM_BOUNDARY_SOURCE = """
import linecache, signal, sys, time
sys.path.insert(0, __CAPTURE_MODULE_DIR__)
import capture_completed_native_log as capture

class Client:
    deadline = time.monotonic() + 60
    def check(self):
        capture.require(time.monotonic() < self.deadline, "capture deadline expired")

caller_hits = []
def caller_alarm(signum, frame):
    caller_hits.append(signum)

code = capture.claim_capture_alarm_entry.__code__
original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
signal.signal(signal.SIGALRM, caller_alarm)
for interval in (0.0, 0.2):
    windows = []
    def trace(frame, event, argument):
        line = linecache.getline(frame.f_code.co_filename, frame.f_lineno).strip()
        if frame.f_code is code and event == "line" \
                and line == "claim_capture_ownership(token)" and not windows:
            windows.append(line)
            signal.pause()
        return trace
    signal.setitimer(signal.ITIMER_REAL, 0.02, interval)
    sys.settrace(trace)
    try:
        with capture.capture_deadline(Client()):
            raise AssertionError("capture entered")
    except capture.CaptureError as error:
        assert str(error) == "existing process deadline", error
    finally:
        sys.settrace(None)
    remaining, repeating = signal.getitimer(signal.ITIMER_REAL)
    assert windows == ["claim_capture_ownership(token)"], windows
    assert caller_hits.pop(0) == signal.SIGALRM
    assert capture.CAPTURE_ALARM_OWNER is None
    assert capture.CAPTURE_ALARM_RESTORE is None
    assert signal.getsignal(signal.SIGALRM) is caller_alarm
    assert signal.pthread_sigmask(signal.SIG_BLOCK, set()) == original_mask
    assert repeating == interval and (interval == 0.0 or remaining > 0.0)
    signal.setitimer(signal.ITIMER_REAL, 0)
    with capture.capture_deadline(Client()): pass
assert caller_hits == [], caller_hits
print("entry alarms preserved")
"""


DISARM_RECOVERY_SOURCE = """
import os, signal, sys, time
sys.path.insert(0, __CAPTURE_MODULE_DIR__)
import capture_completed_native_log as capture

class Client:
    deadline = time.monotonic() + 60
    def check(self):
        capture.require(time.monotonic() < self.deadline, "capture deadline expired")

def caller_alarm(signum, frame):
    raise AssertionError("caller alarm fired")

real_setitimer = signal.setitimer
original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
signal.signal(signal.SIGALRM, caller_alarm)
armed = []
failures = []
def fail_live_disarm(which, seconds, interval=0.0):
    if seconds > 0.0:
        armed.append(seconds)
    if armed and seconds == 0.0:
        failures.append(seconds)
        raise OSError("disarm failed")
    return real_setitimer(which, seconds, interval)

capture.signal.setitimer = fail_live_disarm
try:
    try:
        with capture.capture_deadline(Client()):
            raise ValueError("primary")
    except ValueError as error:
        assert str(error) == "primary"
        assert error.__notes__ == ["capture alarm cleanup failed: disarm failed"]
    else:
        raise AssertionError("primary exception lost")
    owner = capture.CAPTURE_ALARM_OWNER
    restore = capture.CAPTURE_ALARM_RESTORE
    assert failures == [0.0, 0.0] and owner[0] == os.getpid()
    assert owner[2] == capture.OWNER_RECOVERABLE
    assert restore["token"] is owner[1] and restore["phase"] == capture.ALARM_CAPTURE
    assert signal.getsignal(signal.SIGALRM) is not caller_alarm
    assert signal.getitimer(signal.ITIMER_REAL)[0] > 0.0
    assert signal.SIGALRM in signal.pthread_sigmask(signal.SIG_BLOCK, set())
finally:
    capture.signal.setitimer = real_setitimer
with capture.capture_deadline(Client()): pass
assert capture.CAPTURE_ALARM_OWNER is None and capture.CAPTURE_ALARM_RESTORE is None
assert signal.getsignal(signal.SIGALRM) is caller_alarm
assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)
assert signal.pthread_sigmask(signal.SIG_BLOCK, set()) == original_mask
print("live disarm recovered")
"""


CALLER_RESTORE_RAISE_SOURCE = """
import linecache, signal, sys, time
sys.path.insert(0, __CAPTURE_MODULE_DIR__)
import capture_completed_native_log as capture

class CallerAlarm(Exception): pass
class Client:
    deadline = time.monotonic() + 60
    def check(self):
        capture.require(time.monotonic() < self.deadline, "capture deadline expired")

original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
for interval in (0.0, 0.2):
    delayed, hits = [], []
    def caller_alarm(signum, frame):
        hits.append(signum)
        raise CallerAlarm("caller alarm")
    def trace(frame, event, argument):
        line = linecache.getline(frame.f_code.co_filename, frame.f_lineno).strip()
        if frame.f_code is capture.claim_capture_alarm.__code__ and event == "line" \
                and line.startswith("conflict =") and not delayed:
            delayed.append(line)
            time.sleep(0.03)
        return trace
    signal.signal(signal.SIGALRM, caller_alarm)
    signal.setitimer(signal.ITIMER_REAL, 0.01, interval)
    sys.settrace(trace)
    try:
        with capture.capture_deadline(Client()):
            raise AssertionError("capture entered")
    except capture.CaptureError as error:
        assert str(error) == "existing process deadline", error
        assert error.__notes__ == ["capture alarm cleanup failed: caller alarm"], error.__notes__
    finally:
        sys.settrace(None)
    remaining, repeating = signal.getitimer(signal.ITIMER_REAL)
    assert delayed and hits == [signal.SIGALRM], (delayed, hits)
    assert capture.CAPTURE_ALARM_OWNER is None and capture.CAPTURE_ALARM_RESTORE is None
    assert signal.getsignal(signal.SIGALRM) is caller_alarm
    assert signal.pthread_sigmask(signal.SIG_BLOCK, set()) == original_mask
    assert repeating == interval and (interval == 0.0 or remaining > 0.0)
    signal.setitimer(signal.ITIMER_REAL, 0)
    with capture.capture_deadline(Client()): pass
print("raising caller alarms recovered")
"""


MALFORMED_RECOVERY_SOURCE = """
import os, signal, sys, time
sys.path.insert(0, __CAPTURE_MODULE_DIR__)
import capture_completed_native_log as capture

SIGNAL_APIS = ("getsignal", "getitimer", "pthread_sigmask", "raise_signal", "setitimer",
               "signal", "sigpending", "sigwait")

class Client:
    def __init__(self):
        self.deadline = time.monotonic() + 60
    def check(self):
        capture.require(time.monotonic() < self.deadline, "capture deadline expired")

class Marker: pass

def valid_restore(token):
    return {
        "token": token,
        "previous": signal.getsignal(signal.SIGALRM),
        "previous_mask": signal.pthread_sigmask(signal.SIG_BLOCK, set()),
        "phase": capture.ALARM_CAPTURE,
        "caller": ((0.0, 0.0), time.monotonic(), False),
        "deadline_pending": False,
    }

def without_signal_calls(action):
    originals = {name: getattr(capture.signal, name) for name in SIGNAL_APIS}
    calls = []
    def unsafe(*args, **kwargs):
        calls.append((args, kwargs))
        raise AssertionError("signal API used for malformed state")
    try:
        for name in SIGNAL_APIS:
            setattr(capture.signal, name, unsafe)
        action()
    finally:
        for name, implementation in originals.items():
            setattr(capture.signal, name, implementation)
    assert calls == [], calls

def reject_once(owner, restore):
    capture.CAPTURE_ALARM_OWNER = owner
    capture.CAPTURE_ALARM_RESTORE = restore
    def reject():
        try:
            with capture.capture_deadline(Client()):
                raise AssertionError("malformed state accepted")
        except capture.CaptureError as error:
            assert str(error) == "invalid capture alarm recovery state", error
        else:
            raise AssertionError("malformed state accepted")
    without_signal_calls(reject)
    assert capture.CAPTURE_ALARM_OWNER is None
    assert capture.CAPTURE_ALARM_RESTORE is None
    with capture.capture_deadline(Client()): pass

def reset_once(owner, restore):
    capture.CAPTURE_ALARM_OWNER = owner
    capture.CAPTURE_ALARM_RESTORE = restore
    without_signal_calls(capture.reset_capture_alarm_after_fork)
    assert capture.CAPTURE_ALARM_OWNER is None
    assert capture.CAPTURE_ALARM_RESTORE is None
    with capture.capture_deadline(Client()): pass

def reject_restore(**changes):
    token = object()
    restore = valid_restore(token)
    restore.update(changes)
    reject_once([os.getpid(), token, capture.OWNER_RECOVERABLE], restore)

bad_owners = (
    [], [os.getpid()], [os.getpid(), object()],
    [os.getpid(), object(), capture.OWNER_ACTIVE, None],
    (os.getpid(), object(), capture.OWNER_ACTIVE),
    [0, object(), capture.OWNER_ACTIVE],
    [True, object(), capture.OWNER_ACTIVE],
    [os.getpid(), None, capture.OWNER_ACTIVE],
    [os.getpid(), 7, capture.OWNER_RECOVERABLE],
    [os.getpid(), Marker(), capture.OWNER_RECOVERABLE],
    [os.getpid(), object(), []],
    [os.getpid(), object(), "invalid"],
)
for bad_owner in bad_owners:
    reject_once(bad_owner, None)

token = object()
reject_once(None, valid_restore(token))
reject_once([os.getpid(), 7, capture.OWNER_RECOVERABLE], valid_restore(token))
reject_restore(token=None)
reject_restore(token=7)
reject_restore(token=Marker())
reject_restore(token=object())
reject_restore(phase=[])
reject_restore(phase="invalid")
reject_restore(previous=None)
reject_restore(previous=object())
reject_restore(previous=2)
reject_restore(previous_mask=[])
reject_restore(previous_mask={object()})
reject_restore(previous_mask={signal.SIGALRM, "invalid"})
reject_restore(previous_mask={0})
reject_restore(caller=[])
reject_restore(caller=((0.0,), time.monotonic(), False))
reject_restore(caller=((0.0, 0.0), time.monotonic(), 0))
reject_restore(deadline_pending=0)

for bad_timer in (float("nan"), float("inf"), float("-inf"), -1.0):
    reject_restore(caller=((bad_timer, 0.0), time.monotonic(), False))
    reject_restore(caller=((0.0, bad_timer), time.monotonic(), False))
    reject_restore(caller=((0.0, 0.0), bad_timer, False))

for missing in tuple(valid_restore(object())):
    token = object()
    restore = valid_restore(token)
    del restore[missing]
    reject_once([os.getpid(), token, capture.OWNER_RECOVERABLE], restore)

token = object()
restore = valid_restore(token)
restore["extra"] = False
reject_once([os.getpid(), token, capture.OWNER_RECOVERABLE], restore)
reset_once([os.getpid(), 7, capture.OWNER_RECOVERABLE], None)
reset_once([os.getpid(), object(), capture.OWNER_RECOVERABLE], valid_restore(object()))
print("malformed recovery rejected")
"""


class CompletedNativeLogCaptureTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.names = capture.native_steps(Path(capture.__file__).resolve().parents[1] / capture.WORKFLOW)
        self.context = capture.capture_context(environment())
        self.native = native_job(self.names)
        self.successor = dict(self.native, id=201, name=capture.CAPTURE_JOB, labels=["ubuntu-24.04"],
                              status="in_progress", conclusion=None, started_at="2026-08-30T00:01:01Z",
                              completed_at=None, steps=[])
        self.raw = b"2026-08-30T00:00:00.0000001Z original\n\x1b[32mcontinued\r\n"
        for target in ("socket.socket", "socket.create_connection", "subprocess.run"):
            guard = patch(target, side_effect=AssertionError("real operations forbidden"))
            guard.start()
            self.addCleanup(guard.stop)

    def client(self, responses):
        opener = FakeHTTP(responses)
        return capture.CaptureHTTP(TOKEN, opener=opener), opener

    def responses(self, native=None, before=None, after=None, successor=None, raw=None):
        native = native if native is not None else self.native
        return [Response({"total_count": 2, "jobs": [native, successor or self.successor]}),
                Response(before or native), Response(status=302, headers={"Location": SIGNED}),
                Response(self.raw if raw is None else raw), Response(after or native)]

    def run_capture(self, responses):
        client, opener = self.client(responses)
        output = self.root / ("output-" + str(len(list(self.root.iterdir()))))
        capture.capture(client, self.context, self.names, output)
        return output, opener

    def test_original_bytes_and_complete_metadata_retained(self):
        output, opener = self.run_capture(self.responses())
        self.assertEqual({path.name for path in output.iterdir()},
                         {"native-job.log", "native-job.json", "capture-context.json"})
        self.assertEqual((output / "native-job.log").read_bytes(), self.raw)
        self.assertEqual(json.loads((output / "native-job.json").read_bytes()), self.native)
        self.assertEqual(json.loads((output / "capture-context.json").read_bytes()), self.context)
        self.assertEqual(len(opener.calls), 5)
        for request, timeout in opener.calls:
            self.assertEqual(request.get_method(), "GET")
            self.assertGreater(timeout, 0)
            self.assertLessEqual(timeout, 30)
            self.assertNotIn(TOKEN, request.full_url)
            self.assertEqual(request.get_header("Authorization"),
                             None if request.full_url == SIGNED else "Bearer " + TOKEN)
        self.assertFalse(any(TOKEN.encode() in path.read_bytes() for path in output.iterdir()))

    def test_successor_workflow_is_bounded_read_only_and_temp_scoped(self):
        source = (Path(capture.__file__).resolve().parents[1] / capture.WORKFLOW).read_text()
        self.assert_successor_workflow_contract(source)

    def assert_successor_workflow_contract(self, source):
        job = successor_workflow_job(source)
        self.assertEqual(job["name"], capture.CAPTURE_JOB)
        self.assertEqual(job["needs"], "build-and-test")
        self.assertEqual(job["if"], "github.event_name == 'workflow_dispatch' && needs.build-and-test.result == 'success'")
        self.assertEqual(job["runs-on"], "ubuntu-24.04")
        self.assertEqual(job["timeout-minutes"], 5)
        self.assertEqual(job["permissions"], {"contents": "read", "actions": "read"})
        steps = job["steps"]
        self.assertFalse(steps[0]["with"]["persist-credentials"])
        self.assertEqual(steps[1]["run"], 'test "$(git rev-parse HEAD)" = "$GITHUB_SHA"')
        self.assertEqual(steps[2]["run"], 'python3 scripts/capture_completed_native_log.py --output "$RUNNER_TEMP/completed-native-log"')
        self.assertEqual(steps[2]["env"], {"GITHUB_TOKEN": "${{ github.token }}",
                                        "CANDIDATE_INPUTS": "${{ toJSON(github.event.inputs) }}"})
        self.assertEqual(steps[3]["with"]["name"], "completed-native-log-${{ inputs.candidate-request }}")
        self.assertEqual(steps[3]["with"]["path"], "${{ runner.temp }}/completed-native-log/")
        self.assertEqual(steps[3]["with"]["if-no-files-found"], "error")
        self.assertFalse(steps[3]["with"]["overwrite"])
        self.assertTrue(all("if" not in step for step in steps))
        for step in (steps[0], steps[3]):
            self.assertRegex(step["uses"], r"@[0-9a-f]{40}$")
        self.assertRegex(steps[0]["uses"], r"^actions/checkout@[0-9a-f]{40}$")
        self.assertRegex(steps[3]["uses"], r"^actions/upload-artifact@[0-9a-f]{40}$")

    def test_successor_workflow_rejects_changed_contract_values(self):
        source = (Path(capture.__file__).resolve().parents[1] / capture.WORKFLOW).read_text()
        prefix, boundary, successor = source.partition(SUCCESSOR_BOUNDARY)
        changes = [
            ("    name: Retain completed native job log", "    name: Other job"),
            ("github.event_name == 'workflow_dispatch'", "github.event_name == 'push'"),
            (" && needs.build-and-test.result == 'success'", ""),
            (" && needs.build-and-test.result == 'success'", " || needs.build-and-test.result == 'success'"),
            ("needs.build-and-test.result == 'success'", "needs.build-and-test.result != 'success'"),
            ("needs: build-and-test", "needs: candidate-source"),
            ("runs-on: ubuntu-24.04", "runs-on: self-hosted"),
            ("timeout-minutes: 5", "timeout-minutes: 50"),
            ("timeout-minutes: 5", "timeout-minutes: 5e0"),
            ("contents: read", "contents: write"),
            ("actions: read", "actions: write"),
            ("persist-credentials: false", "persist-credentials: true"),
            ("persist-credentials: false", "persist-credentials: null"),
            ('run: test "$(git rev-parse HEAD)" = "$GITHUB_SHA"', "run: true"),
            ('--output "$RUNNER_TEMP/completed-native-log"', '--output "$GITHUB_WORKSPACE/completed-native-log"'),
            ("GITHUB_TOKEN: ${{ github.token }}", "GITHUB_TOKEN: ${{ secrets.OTHER_TOKEN }}"),
            ("CANDIDATE_INPUTS: ${{ toJSON(github.event.inputs) }}", "CANDIDATE_INPUTS: '{}'"),
            ("name: completed-native-log-${{ inputs.candidate-request }}", "name: completed-native-log"),
            ("path: ${{ runner.temp }}/completed-native-log/", "path: ${{ github.workspace }}/"),
            ("if-no-files-found: error", "if-no-files-found: warn"),
            ("overwrite: false", "overwrite: true"),
            ("overwrite: false", "overwrite: null"),
            ("uses: actions/checkout@", "uses: attacker/checkout@"),
            ("uses: actions/upload-artifact@", "uses: invalid: actions/upload-artifact@"),
            ("@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09", "@v5"),
            ("@ea165f8d65b6e75b540449e92b4886f43607fa02", "@" + "a" * 39),
        ]
        for original, replacement in changes:
            with self.subTest(original=original):
                self.assertEqual(successor.count(original), 1)
                changed = prefix + boundary + successor.replace(original, replacement)
                with self.assertRaises(AssertionError):
                    self.assert_successor_workflow_contract(changed)

    def test_successor_workflow_rejects_structural_and_context_decoys(self):
        source = (Path(capture.__file__).resolve().parents[1] / capture.WORKFLOW).read_text()
        prefix, boundary, successor = source.partition(SUCCESSOR_BOUNDARY)
        condition = next(line for line in successor.splitlines(keepends=True) if line.startswith("    if:"))
        changes = {
            "missing condition": successor.replace(condition, ""),
            "commented condition": successor.replace(condition, "    #" + condition[4:]),
            "condition in block scalar": successor.replace(condition, "    description: |\n  " + condition),
            "duplicate condition before": "    if: always()\n" + successor,
            "duplicate condition after": successor + "    if: always()\n",
            "missing dependency": successor.replace("    needs: build-and-test\n", ""),
            "duplicate dependency": successor + "    needs: other-job\n",
            "extra permission": successor.replace("    steps:\n", "      checks: write\n    steps:\n"),
            "extra environment": successor.replace("        run: python3", "          EXTRA: unsafe\n        run: python3"),
            "extra job": successor + "  other-job:\n    runs-on: self-hosted\n",
            "duplicate job": successor + boundary + successor,
            "duplicate jobs mapping": successor + "jobs: {}\n",
            "second document": successor + "---\njobs: {}\n",
            "merge alias": "    <<: *unsafe\n" + successor,
        }
        candidates = {name: prefix + boundary + changed for name, changed in changes.items()}
        candidates.update({
            "renamed job": prefix + boundary.replace("retain-completed-native-log", "other-job") + successor,
            "wrong parent": source.replace("\njobs:\n", "\nother:\n"),
            "renamed native dependency": source.replace("\n  build-and-test:\n", "\n  other-native:\n"),
            "block scalar job decoy": "description: |\n" + "\n".join("  " + line for line in source.splitlines()),
            "comment job decoy": "\n".join("# " + line for line in source.splitlines()),
        })
        for name, changed in candidates.items():
            with self.subTest(name=name):
                self.assertNotEqual(changed, source)
                with self.assertRaises(AssertionError):
                    self.assert_successor_workflow_contract(changed)

    def test_successor_workflow_rejects_missing_duplicate_reordered_or_conditional_steps(self):
        source = (Path(capture.__file__).resolve().parents[1] / capture.WORKFLOW).read_text()
        prefix, boundary, successor = source.partition(SUCCESSOR_BOUNDARY)
        header, *steps = successor.split("      - name: ")
        self.assertEqual(len(steps), 4)
        for index in range(len(steps)):
            reordered = steps.copy()
            other = (index + 1) % len(steps)
            reordered[index], reordered[other] = reordered[other], reordered[index]
            changes = {"missing": steps[:index] + steps[index + 1:],
                       "duplicate": steps[:index] + [steps[index]] + steps[index:],
                       "reordered": reordered,
                       "conditional": steps[:index] + [steps[index].replace("\n", "\n        if: always()\n", 1)] + steps[index + 1:]}
            for name, changed in changes.items():
                candidate = prefix + boundary + header + "".join("      - name: " + step for step in changed)
                with self.subTest(index=index, name=name), self.assertRaises(AssertionError):
                    self.assert_successor_workflow_contract(candidate)

    def test_successor_workflow_accepts_full_length_action_pins(self):
        source = (Path(capture.__file__).resolve().parents[1] / capture.WORKFLOW).read_text()
        prefix, boundary, successor = source.partition(SUCCESSOR_BOUNDARY)
        for original in ("fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09", "ea165f8d65b6e75b540449e92b4886f43607fa02"):
            with self.subTest(original=original):
                self.assertEqual(successor.count(original), 1)
                self.assert_successor_workflow_contract(prefix + boundary + successor.replace(original, "a" * 40))

    def test_dispatch_identity_and_types_reject(self):
        changes = {"GITHUB_EVENT_NAME": "push", "GITHUB_RUN_ATTEMPT": "2", "GITHUB_JOB": "build-and-test",
                   "RUNNER_ENVIRONMENT": "self-hosted", "GITHUB_REPOSITORY": "x/y/z",
                   "GITHUB_REF": "refs/heads/../main", "GITHUB_SHA": "A" * 40,
                   "GITHUB_WORKFLOW_SHA": "d" * 40, "GITHUB_RUN_ID": "0",
                   "GITHUB_WORKFLOW_REF": "example/other/.github/workflows/ci.yml@refs/heads/candidate"}
        for key, value in changes.items():
            with self.subTest(key=key), self.assertRaises(capture.CaptureError):
                capture.capture_context(dict(environment(), **{key: value}))
        for raw in ('[]', '{"x":1,"x":2}', '{"x":NaN}', '{"candidate-request":true}'):
            with self.subTest(raw=raw), self.assertRaises(capture.CaptureError):
                capture.capture_context(dict(environment(), CANDIDATE_INPUTS=raw))

    def test_native_identity_and_full_step_matrix_reject(self):
        changes = {"id": True, "runner_id": 0, "run_id": True, "run_attempt": 2, "head_sha": "d" * 40,
                   "head_branch": "other", "run_url": BASE.replace("apple", "other") + "/actions/runs/100",
                   "labels": ["macos-26", "self-hosted"], "runner_group_name": "private",
                   "status": "in_progress", "conclusion": "failure", "completed_at": "2025-01-01T00:00:00Z"}
        for key, value in changes.items():
            with self.subTest(key=key), self.assertRaises(capture.CaptureError):
                self.run_capture(self.responses(native=dict(self.native, **{key: value})))
        for kind in ("missing", "extra", "duplicate", "reorder", "skipped", "failure", "pending", "number"):
            native = copy.deepcopy(self.native)
            steps = native["steps"]
            if kind == "missing":
                steps.pop(2)
            elif kind in ("extra", "duplicate"):
                steps[2]["name"] = "Unknown" if kind == "extra" else steps[1]["name"]
            elif kind == "reorder":
                steps[1]["name"], steps[2]["name"] = steps[2]["name"], steps[1]["name"]
            else:
                field = "number" if kind == "number" else "status" if kind == "pending" else "conclusion"
                steps[2][field] = True if kind == "number" else kind
            with self.subTest(kind=kind), self.assertRaises(capture.CaptureError):
                self.run_capture(self.responses(native=native))

    def test_successor_and_changed_completed_metadata_reject(self):
        for change in ({"started_at": "2026-08-30T00:00:59Z"}, {"status": "completed"},
                       {"conclusion": "failure"}, {"run_attempt": True}, {"labels": ["self-hosted"]}):
            with self.subTest(change=change), self.assertRaises(capture.CaptureError):
                self.run_capture(self.responses(successor=dict(self.successor, **change)))
        for position in ("before", "after"):
            for change in ({"extra_metadata": "changed"}, {"runner_id": 999}, {"status": "queued"}):
                with self.subTest(position=position, change=change), self.assertRaises(capture.CaptureError):
                    self.run_capture(self.responses(**{position: dict(self.native, **change)}))

    def test_pagination_complete_unique_and_bounded(self):
        jobs = [dict(self.native, id=number, name=f"other-{number}") for number in range(1, 102)]
        client, opener = self.client([Response({"total_count": 101, "jobs": jobs[:100]}),
                                     Response({"total_count": 101, "jobs": jobs[100:]})])
        self.assertEqual(capture.attempt_jobs(client, BASE, 100), jobs)
        self.assertTrue(opener.calls[-1][0].full_url.endswith("page=2"))
        bad_pages = [({"total_count": True, "jobs": []},), ({"total_count": 1001, "jobs": []},),
                     ({"total_count": 101, "jobs": jobs[:99]},),
                     ({"total_count": 2, "jobs": [self.native, self.native]},),
                     ({"total_count": 101, "jobs": jobs[:100]}, {"total_count": 100, "jobs": jobs[100:]}),
                     ({"total_count": 101, "jobs": jobs[:100]}, {"total_count": 101, "jobs": jobs[:1]})]
        for pages in bad_pages:
            with self.subTest(pages=len(pages)), self.assertRaises(capture.CaptureError):
                capture.attempt_jobs(self.client([Response(page) for page in pages])[0], BASE, 100)

    def test_missing_or_ambiguous_native_and_capture_reject(self):
        for jobs in ([self.native], [self.successor], [self.native, self.native, self.successor],
                     [self.native, self.successor, self.successor]):
            with self.subTest(count=len(jobs)), self.assertRaises(capture.CaptureError):
                capture.select_native(jobs, self.context, self.names)

    def test_redirect_auth_isolation_across_hops(self):
        client, opener = self.client([Response(status=302, headers={"Location": SIGNED}),
                                     Response(status=307, headers={"Location": SIGNED + "2"}), Response(b"raw")])
        output = io.BytesIO()
        client.get(BASE + "/actions/jobs/200/logs", output, 100, redirects=True)
        self.assertEqual(output.getvalue(), b"raw")
        self.assertTrue(opener.calls[0][0].has_header("Authorization"))
        self.assertTrue(all(not request.has_header("Authorization") for request, _ in opener.calls[1:]))

    def test_unsafe_redirects_and_json_redirects_reject(self):
        urls = ["http://production.blob.core.windows.net/x", "https://attacker.invalid/x",
                "https://production.blob.core.windows.net.attacker.invalid/x", "//production.blob.core.windows.net/x",
                "https://user:password@production.blob.core.windows.net/x", SIGNED + "#fragment",
                "https://production.blob.core.windows.net:8443/x", SIGNED + "\nheader", SIGNED + "\\evil",
                BASE + "/actions/jobs/200/logs", SIGNED + TOKEN, "file:///tmp/log", ""]
        for url in urls:
            with self.subTest(url=url), self.assertRaises(capture.CaptureError):
                client, opener = self.client([Response(status=302, headers={"Location": url})])
                client.get(BASE + "/actions/jobs/200/logs", io.BytesIO(), 100, redirects=True)
            self.assertEqual(len(opener.calls), 1)
        with self.assertRaises(capture.CaptureError):
            self.client([Response(status=302, headers={"Location": SIGNED})])[0].json(BASE + "/jobs")

    def test_http_failure_redirect_limit_empty_truncated_and_quota_reject(self):
        cases = [[Response(status=status)] for status in (201, 401, 403, 404, 429, 500)]
        cases += [[Response(status=302, headers={"Location": SIGNED}) for _ in range(4)],
                  [Response(b"")], [Response(b"short", headers={"Content-Length": "6"})],
                  [Response(b"123456", headers={})], [Response(b"x", headers={"Content-Length": "-1"})],
                  [Response(b"x", headers={"Content-Length": "1000"})]]
        for responses in cases:
            with self.subTest(count=len(responses)), self.assertRaises(capture.CaptureError):
                self.client(responses)[0].get(BASE + "/logs", io.BytesIO(), 5, redirects=True)

    def test_secret_echo_split_across_chunks_and_json_reject(self):
        for raw in (TOKEN.encode(), b"prefix " + TOKEN.encode() + b" suffix"):
            with patch.object(capture, "CHUNK_BYTES", 3), self.assertRaises(capture.CaptureError):
                self.run_capture(self.responses(raw=raw))
        with self.assertRaises(capture.CaptureError):
            self.client([Response({"message": TOKEN})])[0].json(BASE + "/jobs")

    def test_json_and_log_quotas_and_invalid_json_reject(self):
        for raw in (b"[]", b'{"x":1,"x":2}', b'{"x":NaN}', b'{"broken"'):
            with self.subTest(raw=raw), self.assertRaises((capture.CaptureError, ValueError)):
                self.client([Response(raw)])[0].json(BASE + "/jobs")
        with patch.object(capture, "MAX_JSON_BYTES", 2), self.assertRaises(capture.CaptureError):
            self.client([Response(b'{"x":1}')])[0].json(BASE + "/jobs")
        client, _ = self.client([Response(b"{}")])
        client.json_bytes = 4 * capture.MAX_JSON_BYTES
        with self.assertRaises(capture.CaptureError):
            client.json(BASE + "/jobs")
        with patch.object(capture, "MAX_LOG_BYTES", 3), self.assertRaises(capture.CaptureError):
            self.run_capture(self.responses())

    def test_deadline_before_request_and_during_body_reject(self):
        client, opener = self.client([Response(b"raw")])
        client.deadline = 0
        with self.assertRaisesRegex(capture.CaptureError, "deadline"):
            client.get(BASE + "/logs", io.BytesIO(), 100)
        self.assertFalse(opener.calls)
        response = Response(b"raw")
        client, _ = self.client([response])
        original = response.read
        def slow_read(size):
            client.deadline = 0
            return original(size)
        response.read = slow_read
        with self.assertRaisesRegex(capture.CaptureError, "deadline"):
            client.get(BASE + "/logs", io.BytesIO(), 100)

    def test_hard_deadline_and_existing_output_reject(self):
        client, _ = self.client([])
        client.deadline = 0
        with self.assertRaisesRegex(capture.CaptureError, "deadline"):
            capture.capture(client, self.context, self.names, self.root / "expired")
        self.assertFalse((self.root / "expired").exists())
        client, _ = self.client(self.responses())
        with self.assertRaises(FileExistsError):
            capture.capture(client, self.context, self.names, self.root)

    def test_worker_capture_rejects_without_touching_caller_alarm(self):
        source = textwrap.dedent(
            f"""
            import signal
            import sys
            import threading
            import time
            sys.path.insert(0, {str(Path(capture.__file__).parent)!r})
            import capture_completed_native_log as capture

            failures = []
            class Client:
                deadline = time.monotonic() + 60
                def check(self):
                    capture.require(time.monotonic() < self.deadline,
                                    "capture deadline expired")
            def caller_expired(signum, frame):
                raise AssertionError("caller timer unexpectedly fired")
            def worker():
                try:
                    with capture.capture_deadline(Client()):
                        raise AssertionError("worker capture entered")
                except BaseException as error:
                    failures.append(error)

            signal.signal(signal.SIGALRM, caller_expired)
            original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
            signal.setitimer(signal.ITIMER_REAL, 1.0)
            thread = threading.Thread(target=worker)
            thread.start()
            thread.join()
            remaining, interval = signal.getitimer(signal.ITIMER_REAL)
            assert len(failures) == 1, failures
            assert isinstance(failures[0], capture.CaptureError), failures
            assert str(failures[0]) == "capture deadline requires main thread", failures
            assert signal.getsignal(signal.SIGALRM) is caller_expired
            assert signal.pthread_sigmask(signal.SIG_BLOCK, set()) == original_mask
            assert 0.0 < remaining <= 1.0 and interval == 0.0, (remaining, interval)
            signal.setitimer(signal.ITIMER_REAL, 0)
            with capture.capture_deadline(Client()):
                pass
            assert capture.CAPTURE_ALARM_OWNER is None
            print("worker rejected")
            """
        )
        result = REAL_SUBPROCESS_RUN(
            [sys.executable, "-c", source], capture_output=True, text=True, timeout=5
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "worker rejected\n")

    def test_stalled_http_alarm_restores_process_watchdog(self):
        client, opener = self.client(self.responses())
        prior = capture.signal.getsignal(capture.signal.SIGALRM)
        def stalled(request, timeout):
            capture.signal.raise_signal(capture.signal.SIGALRM)
            raise AssertionError("watchdog did not interrupt")
        opener.open = stalled
        with self.assertRaisesRegex(capture.CaptureError, "deadline"):
            capture.capture(client, self.context, self.names, self.root / "alarm")
        self.assertEqual(capture.signal.getsignal(capture.signal.SIGALRM), prior)
        self.assertEqual(capture.signal.getitimer(capture.signal.ITIMER_REAL), (0.0, 0.0))

    def test_repeated_expired_deadline_survives_alarm_teardown(self):
        source = textwrap.dedent(
            f"""
            import sys
            import time
            sys.path.insert(0, {str(Path(capture.__file__).parent)!r})
            import capture_completed_native_log as capture

            class Client:
                deadline = 0.0
                def check(self):
                    capture.require(time.monotonic() < self.deadline,
                                    "capture deadline expired")

            for _ in range(100):
                client = Client()
                client.deadline = time.monotonic() + 0.002
                try:
                    with capture.capture_deadline(client):
                        time.sleep(0.02)
                except capture.CaptureError:
                    pass
                else:
                    raise AssertionError("deadline did not interrupt")
                time.sleep(0.001)
                assert capture.signal.SIGALRM not in capture.signal.sigpending()
            assert capture.signal.getsignal(capture.signal.SIGALRM) == capture.signal.SIG_DFL
            assert capture.signal.getitimer(capture.signal.ITIMER_REAL) == (0.0, 0.0)
            print("survived")
            """
        )
        result = REAL_SUBPROCESS_RUN(
            [sys.executable, "-c", source], capture_output=True, text=True, timeout=5
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "survived\n")

    def test_deadline_at_body_exit_restores_alarm_before_rejecting(self):
        source = textwrap.dedent(
            f"""
            import linecache, signal, sys, time
            sys.path.insert(0, {str(Path(capture.__file__).parent)!r})
            import capture_completed_native_log as capture

            windows = []
            class Client:
                def __init__(self, timeout):
                    self.deadline = time.monotonic() + timeout
                def check(self):
                    capture.require(time.monotonic() < self.deadline,
                                    "capture deadline expired")
            def trace(frame, event, argument):
                line = linecache.getline(frame.f_code.co_filename, frame.f_lineno).strip()
                if frame.f_code is capture.capture_deadline.__wrapped__.__code__ \
                        and event == "line" and line == 'alarm["teardown"] = True' \
                        and not windows:
                    windows.append(line)
                    time.sleep(0.05)
                return trace

            sys.settrace(trace)
            try:
                with capture.capture_deadline(Client(0.03)):
                    pass
            except capture.CaptureError as error:
                assert str(error) == "capture deadline expired", error
            else:
                raise AssertionError("body-exit deadline was swallowed")
            finally:
                sys.settrace(None)
            assert windows == ['alarm["teardown"] = True'], windows
            assert signal.getsignal(signal.SIGALRM) == signal.SIG_DFL
            assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)
            assert signal.SIGALRM not in signal.sigpending()
            assert capture.CAPTURE_ALARM_OWNER is None
            with capture.capture_deadline(Client(1)):
                pass
            print("body exit restored")
            """
        )
        assert_subprocess_success(self, source, "body exit restored\n")

    def test_caller_alarm_expiring_between_pending_and_timer_read_is_preserved(self):
        source = textwrap.dedent(
            f"""
            import linecache
            import signal
            import sys
            import time
            sys.path.insert(0, {str(Path(capture.__file__).parent)!r})
            import capture_completed_native_log as capture
            class Client:
                deadline = time.monotonic() + 60
                def check(self):
                    capture.require(time.monotonic() < self.deadline,
                                    "capture deadline expired")
            markers = ("previous_timer = signal.getitimer(signal.ITIMER_REAL)",
                       "previous_timer, caller_pending = prepare_caller_alarm(restore)",
                       "caller_pending = signal.SIGALRM in signal.sigpending()",
                       'conflict = (signal.SIGALRM in restore["previous_mask"]')
            for marker in markers:
                caller_hits, windows = [], []
                def caller_expired(signum, frame):
                    caller_hits.append(signum)
                def trace(frame, event, argument):
                    line = linecache.getline(frame.f_code.co_filename, frame.f_lineno).strip()
                    alarm_codes = (capture.capture_alarm_context.__code__,
                                   capture.claim_capture_alarm.__code__,
                                   capture.prepare_caller_alarm.__code__)
                    if frame.f_code in alarm_codes and event == "line" \
                            and marker in line and not windows:
                        windows.append(marker)
                        caller_hits.clear()
                        signal.setitimer(signal.ITIMER_REAL, 0.03)
                        time.sleep(0.05)
                    return trace
                signal.signal(signal.SIGALRM, caller_expired)
                signal.setitimer(signal.ITIMER_REAL, 0.03)
                sys.settrace(trace)
                try:
                    with capture.capture_deadline(Client()):
                        raise AssertionError("caller deadline was replaced")
                except capture.CaptureError as error:
                    assert str(error) == "existing process deadline", error
                finally:
                    sys.settrace(None)
                assert windows == [marker], (marker, windows)
                assert caller_hits == [signal.SIGALRM], (marker, caller_hits)
                assert signal.getsignal(signal.SIGALRM) is caller_expired
                assert signal.SIGALRM not in signal.pthread_sigmask(signal.SIG_BLOCK, set())
                assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)
            print("preserved")
            """
        )
        assert_subprocess_success(self, source, "preserved\n")

    def test_pending_deadline_not_drained_silently(self):
        class Client:
            deadline = capture.time.monotonic() + 60

            def check(self):
                capture.require(capture.time.monotonic() < self.deadline,
                                "capture deadline expired")

        with self.assertRaisesRegex(capture.CaptureError, "deadline"):
            with capture.capture_deadline(Client()):
                capture.signal.pthread_sigmask(capture.signal.SIG_BLOCK,
                                               {capture.signal.SIGALRM})
                capture.signal.setitimer(capture.signal.ITIMER_REAL, 0.001)
                capture.time.sleep(0.01)
                self.assertIn(capture.signal.SIGALRM, capture.signal.sigpending())
        self.assertNotIn(capture.signal.SIGALRM, capture.signal.sigpending())
        self.assertEqual(capture.signal.getitimer(capture.signal.ITIMER_REAL), (0.0, 0.0))

    def test_deadline_crosses_after_cleanup_disarm(self):
        source = textwrap.dedent(
            f"""
            import linecache, signal, sys, time
            sys.path.insert(0, {str(Path(capture.__file__).parent)!r})
            import capture_completed_native_log as capture

            delayed = []
            class Client:
                deadline = time.monotonic() + 0.03
                def check(self):
                    capture.require(time.monotonic() < self.deadline,
                                    "capture deadline expired")
            def trace(frame, event, argument):
                line = linecache.getline(frame.f_code.co_filename, frame.f_lineno).strip()
                if frame.f_code is capture.release_capture_alarm.__code__ and event == "line" \
                        and line.startswith("pending_deadline =") and not delayed:
                    delayed.append(line)
                    time.sleep(0.05)
                return trace

            sys.settrace(trace)
            try:
                with capture.capture_deadline(Client()):
                    pass
            except capture.CaptureError as error:
                assert str(error) == "capture deadline expired", error
            else:
                raise AssertionError("cleanup deadline was swallowed")
            finally:
                sys.settrace(None)
            assert len(delayed) == 1, delayed
            assert signal.getsignal(signal.SIGALRM) == signal.SIG_DFL
            assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)
            assert signal.SIGALRM not in signal.sigpending()
            assert capture.CAPTURE_ALARM_OWNER is None
            print("cleanup deadline rejected")
            """
        )
        assert_subprocess_success(self, source, "cleanup deadline rejected\n")

    def test_alarm_expiring_during_teardown_rejects_after_cleanup(self):
        source = textwrap.dedent(
            f"""
            import linecache
            import sys
            import time
            sys.path.insert(0, {str(Path(capture.__file__).parent)!r})
            import capture_completed_native_log as capture

            window = []

            class Client:
                deadline = time.monotonic() + 0.03
                def check(self):
                    capture.require(time.monotonic() < self.deadline,
                                    "capture deadline expired")

            def trace(frame, event, argument):
                line = linecache.getline(frame.f_code.co_filename, frame.f_lineno).strip()
                if frame.f_code is capture.release_capture_alarm.__code__ \
                        and event == "line" and "signal.pthread_sigmask" in line and not window:
                    window.append(time.monotonic())
                    time.sleep(0.05)
                return trace

            sys.settrace(trace)
            try:
                with capture.capture_deadline(Client()):
                    pass
            except capture.CaptureError as error:
                assert str(error) == "capture deadline expired", error
            else:
                raise AssertionError("teardown deadline was swallowed")
            finally:
                sys.settrace(None)
            assert len(window) == 1, window
            assert capture.signal.getsignal(capture.signal.SIGALRM) == capture.signal.SIG_DFL
            assert capture.signal.getitimer(capture.signal.ITIMER_REAL) == (0.0, 0.0)
            assert capture.signal.SIGALRM not in capture.signal.sigpending()
            time.sleep(0.03)
            print("deadline rejected")
            """
        )
        result = REAL_SUBPROCESS_RUN(
            [sys.executable, "-c", source], capture_output=True, text=True, timeout=5
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "deadline rejected\n")

    def test_call_store_alarm_interrupt_releases_owned_state(self):
        source = textwrap.dedent(f"""
            import dis, signal, sys, time
            sys.path.insert(0, {str(Path(capture.__file__).parent)!r})
            import capture_completed_native_log as capture
            class Client:
                deadline = time.monotonic() + 60
                def check(self):
                    capture.require(time.monotonic() < self.deadline, "capture deadline expired")
            code = capture.capture_deadline.__wrapped__.__code__
            instructions = list(dis.get_instructions(code))
            store = next(item for index, item in enumerate(instructions)
                         if "claimed_alarm" in item.argrepr
                         and instructions[index - 1].opname == "CALL")
            injected = []
            def trace(frame, event, argument):
                if frame.f_code is code:
                    frame.f_trace_opcodes = True
                    if event == "opcode" and frame.f_lasti == store.offset and not injected:
                        injected.append(frame.f_lasti)
                        signal.raise_signal(signal.SIGALRM)
                return trace
            sys.settrace(trace)
            try:
                with capture.capture_deadline(Client()):
                    raise AssertionError("capture entered")
            except capture.CaptureError as error:
                assert str(error) == "capture deadline expired", error
            finally:
                sys.settrace(None)
            assert injected == [store.offset], injected
            assert signal.getsignal(signal.SIGALRM) == signal.SIG_DFL
            assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)
            assert capture.CAPTURE_ALARM_OWNER is None
            assert capture.CAPTURE_ALARM_RESTORE is None
            with capture.capture_deadline(Client()): pass
            print("call store recovered")
            """)
        assert_subprocess_success(self, source, "call store recovered\n")

    def test_ownership_call_store_preserves_one_shot_and_repeating_alarms(self):
        source = capture_subprocess_source(OWNERSHIP_ALARM_BOUNDARY_SOURCE)
        assert_subprocess_success(self, source, "ownership alarms recovered\n")

    def test_entry_alarm_expiry_cannot_be_mistaken_for_an_idle_timer(self):
        source = capture_subprocess_source(ENTRY_ALARM_BOUNDARY_SOURCE)
        assert_subprocess_success(self, source, "entry alarms preserved\n")

    def test_live_alarm_state_survives_disarm_failure_until_recovery(self):
        source = capture_subprocess_source(DISARM_RECOVERY_SOURCE)
        assert_subprocess_success(self, source, "live disarm recovered\n")

    def test_raising_caller_alarm_during_mask_restore_releases_ownership(self):
        source = capture_subprocess_source(CALLER_RESTORE_RAISE_SOURCE)
        assert_subprocess_success(self, source, "raising caller alarms recovered\n")

    def test_malformed_alarm_recovery_fails_closed_without_wedge(self):
        source = capture_subprocess_source(MALFORMED_RECOVERY_SOURCE)
        assert_subprocess_success(self, source, "malformed recovery rejected\n", timeout=10)

    def test_deadline_crossing_after_release_final_check_rejects(self):
        source = textwrap.dedent(f"""
            import linecache, signal, sys, time
            sys.path.insert(0, {str(Path(capture.__file__).parent)!r})
            import capture_completed_native_log as capture
            class Client:
                def __init__(self): self.deadline = time.monotonic() + 0.1
                def check(self):
                    capture.require(time.monotonic() < self.deadline, "capture deadline expired")
            delayed = []
            def trace(frame, event, argument):
                line = linecache.getline(frame.f_code.co_filename, frame.f_lineno).strip()
                if frame.f_code is capture.release_capture_alarm.__code__ and event == "line" \
                        and line == "return deadline_failure" and not delayed:
                    delayed.append(line)
                    time.sleep(0.15)
                return trace
            sys.settrace(trace)
            try:
                with capture.capture_deadline(Client()): pass
            except capture.CaptureError as error:
                assert str(error) == "capture deadline expired", error
            else:
                raise AssertionError("post-check deadline was swallowed")
            finally:
                sys.settrace(None)
            assert delayed == ["return deadline_failure"], delayed
            assert signal.getsignal(signal.SIGALRM) == signal.SIG_DFL
            assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)
            assert capture.CAPTURE_ALARM_OWNER is None
            print("post-check rejected")
            """)
        assert_subprocess_success(self, source, "post-check rejected\n")

    def test_post_drain_pending_alarm_avoids_restored_handler(self):
        source = textwrap.dedent(f"""
            import linecache, signal, sys, time
            sys.path.insert(0, {str(Path(capture.__file__).parent)!r})
            import capture_completed_native_log as capture
            class Client:
                deadline = time.monotonic() + 60
                def check(self): pass
            caller_hits, events = [], []
            def caller_expired(signum, frame): caller_hits.append(signum)
            def trace(frame, event, argument):
                if frame.f_code is not capture.release_capture_alarm.__code__ or event != "line":
                    return trace
                line = linecache.getline(frame.f_code.co_filename, frame.f_lineno).strip()
                if line == "signal.sigwait({{signal.SIGALRM}})": events.append("drain")
                elif events == ["drain"]:
                    events.append("pending")
                    signal.raise_signal(signal.SIGALRM)
                return trace
            signal.signal(signal.SIGALRM, caller_expired)
            sys.settrace(trace)
            try:
                with capture.capture_deadline(Client()):
                    signal.pthread_sigmask(signal.SIG_BLOCK, {{signal.SIGALRM}})
                    signal.setitimer(signal.ITIMER_REAL, 0.001)
                    time.sleep(0.01)
            except capture.CaptureError as error:
                assert str(error) == "capture deadline expired", error
            finally:
                sys.settrace(None)
            assert events == ["drain", "pending"], events
            assert caller_hits == [], caller_hits
            assert signal.getsignal(signal.SIGALRM) is caller_expired
            assert signal.SIGALRM not in signal.sigpending()
            assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)
            assert capture.CAPTURE_ALARM_OWNER is None
            print("post-drain quarantined")
            """)
        assert_subprocess_success(self, source, "post-drain quarantined\n")

    def test_nested_deadline_rejects_without_consuming_outer_alarm(self):
        source = textwrap.dedent(f"""
            import linecache, signal, sys, time
            sys.path.insert(0, {str(Path(capture.__file__).parent)!r})
            import capture_completed_native_log as capture
            class Client:
                def __init__(self, timeout): self.deadline = time.monotonic() + timeout
                def check(self):
                    capture.require(time.monotonic() < self.deadline, "capture deadline expired")
            events, windows = [], []
            def delay_inner_cleanup(frame, event, argument):
                line = linecache.getline(frame.f_code.co_filename, frame.f_lineno).strip()
                if frame.f_code is capture.claim_capture_alarm.__code__ and event == "line" \
                        and line == "signal.signal(signal.SIGALRM, expired)":
                    windows.append(line)
                    time.sleep(0.16)
                return delay_inner_cleanup
            started = time.monotonic()
            try:
                with capture.capture_deadline(Client(0.08)):
                    events.append("outer entered")
                    sys.settrace(delay_inner_cleanup)
                    try:
                        with capture.capture_deadline(Client(60)):
                            raise AssertionError("nested deadline entered")
                    except capture.CaptureError as error:
                        assert str(error) == "existing process deadline", error
                        assert getattr(error, "__notes__", []) == [], error.__notes__
                        events.append("nested rejected")
                    finally:
                        sys.settrace(None)
                    remaining = signal.getitimer(signal.ITIMER_REAL)[0]
                    assert remaining > 0.0, (windows, remaining)
                    assert windows == [], windows
                    time.sleep(1)
            except capture.CaptureError as error:
                assert str(error) == "capture deadline expired", error
            else:
                raise AssertionError("outer deadline did not interrupt")
            assert events == ["outer entered", "nested rejected"], events
            assert time.monotonic() - started < 0.3
            assert signal.getsignal(signal.SIGALRM) == signal.SIG_DFL
            assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)
            print("nested deadline preserved")
            """)
        result = REAL_SUBPROCESS_RUN(
            [sys.executable, "-c", source], capture_output=True, text=True, timeout=5
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "nested deadline preserved\n")

    def test_forks_before_during_and_after_alarm_claim_preserve_state(self):
        source = capture_subprocess_source(FORK_BOUNDARY_SOURCE)
        assert_subprocess_success(self, source, "fork boundaries preserved\n", timeout=8)

    def test_blocked_pending_caller_alarm_is_preserved(self):
        source = textwrap.dedent(
            f"""
            import signal
            import sys
            import time
            sys.path.insert(0, {str(Path(capture.__file__).parent)!r})
            import capture_completed_native_log as capture
            hits = []
            class Client:
                deadline = time.monotonic() + 60
                def check(self):
                    capture.require(time.monotonic() < self.deadline,
                                    "capture deadline expired")
            def caller_expired(signum, frame):
                hits.append(signum)
            signal.signal(signal.SIGALRM, caller_expired)
            original = signal.pthread_sigmask(signal.SIG_BLOCK, {{signal.SIGALRM}})
            signal.raise_signal(signal.SIGALRM)
            try:
                try:
                    with capture.capture_deadline(Client()):
                        raise AssertionError("blocked caller deadline was replaced")
                except capture.CaptureError as error:
                    assert str(error) == "existing process deadline", error
                assert signal.SIGALRM in signal.sigpending()
                assert signal.SIGALRM in signal.pthread_sigmask(signal.SIG_BLOCK, set())
                assert signal.getsignal(signal.SIGALRM) is caller_expired
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, original)
            assert hits == [signal.SIGALRM], hits
            print("pending preserved")
            """
        )
        result = REAL_SUBPROCESS_RUN(
            [sys.executable, "-c", source], capture_output=True, text=True, timeout=5
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "pending preserved\n")

    def test_repeating_caller_alarm_phase_is_preserved(self):
        source = textwrap.dedent(f"""
            import linecache
            import signal
            import sys
            import time
            sys.path.insert(0, {str(Path(capture.__file__).parent)!r})
            import capture_completed_native_log as capture
            hits = []
            class Client:
                deadline = time.monotonic() + 60
                def check(self):
                    capture.require(time.monotonic() < self.deadline,
                                    "capture deadline expired")
            def caller_expired(signum, frame):
                hits.append(time.monotonic())
                if len(hits) == 1:
                    signal.pthread_sigmask(signal.SIG_BLOCK, {{signal.SIGALRM}})
            def trace(frame, event, argument):
                line = linecache.getline(frame.f_code.co_filename, frame.f_lineno).strip()
                if frame.f_code is capture.claim_capture_alarm.__code__ and event == "line" \
                        and line.startswith("conflict ="):
                    sys.settrace(None)
                    time.sleep(0.11)
                return trace
            signal.signal(signal.SIGALRM, caller_expired)
            signal.setitimer(signal.ITIMER_REAL, 0.02, 0.04)
            sys.settrace(trace)
            try:
                with capture.capture_deadline(Client()):
                    raise AssertionError("caller interval was replaced")
            except capture.CaptureError as error:
                assert str(error) == "existing process deadline", error
            remaining, interval = signal.getitimer(signal.ITIMER_REAL)
            assert hits == [hits[0]], hits
            assert 0.0 < remaining <= 0.04, remaining
            assert 0.039 <= interval <= 0.041, interval
            signal.pthread_sigmask(signal.SIG_UNBLOCK, {{signal.SIGALRM}})
            deadline = time.monotonic() + 0.1
            while len(hits) < 2 and time.monotonic() < deadline:
                time.sleep(0.002)
            signal.setitimer(signal.ITIMER_REAL, 0)
            assert len(hits) >= 2, hits
            print("interval preserved")
            """
        )
        result = REAL_SUBPROCESS_RUN(
            [sys.executable, "-c", source], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "interval preserved\n")

    def test_repeating_alarm_rearms_and_requests_one_replay(self):
        events = []
        with patch.object(
            capture.time, "monotonic", return_value=10.11
        ), patch.object(
            capture.signal,
            "setitimer",
            side_effect=lambda *values: events.append(("timer", *values)),
        ):
            replay = capture.restore_caller_timer((0.02, 0.04), 10.0, False)
        self.assertTrue(replay)
        self.assertEqual(events[0][:2], ("timer", capture.signal.ITIMER_REAL))
        self.assertAlmostEqual(events[0][2], 0.03)
        self.assertEqual(events[0][3], 0.04)

    def test_pending_caller_alarm_replays_after_restoration(self):
        previous_mask = set()
        replay_phases = []

        def previous(_signum, _frame):
            replay_phases.append(restore["phase"])

        restore = {
            "caller": ((0.0, 0.0), 10.0, True),
            "previous": previous,
            "previous_mask": previous_mask,
            "phase": capture.ALARM_CALLER,
        }
        with patch.object(
            capture.signal, "sigpending", return_value={capture.signal.SIGALRM}
        ), patch.object(capture.signal, "sigwait") as wait, patch.object(
            capture.signal, "pthread_sigmask"
        ), patch.object(capture.signal, "setitimer"), patch.object(
            capture.signal, "signal"
        ), patch.object(
            capture, "restore_caller_timer", return_value=False
        ), patch.object(capture.signal, "raise_signal") as replay:
            capture.restore_caller_alarm(restore)
        wait.assert_called_once_with({capture.signal.SIGALRM})
        replay.assert_not_called()
        self.assertEqual(replay_phases, [capture.ALARM_RESTORED])

    def test_expired_caller_timer_replays_after_restoration(self):
        replay_phases = []
        restore = {
            "caller": ((0.02, 0.0), 10.0, False),
            "previous": lambda _signum, _frame: replay_phases.append(restore["phase"]),
            "previous_mask": set(),
            "phase": capture.ALARM_CALLER,
        }
        with patch.object(
            capture.signal, "sigpending", return_value=set()
        ), patch.object(capture.signal, "pthread_sigmask"), patch.object(
            capture.signal, "setitimer"
        ), patch.object(capture.signal, "signal"), patch.object(
            capture, "restore_caller_timer", return_value=True
        ), patch.object(capture.signal, "raise_signal") as replay:
            capture.restore_caller_alarm(restore)
        replay.assert_not_called()
        self.assertEqual(replay_phases, [capture.ALARM_RESTORED])

    def test_primary_exception_survives_cleanup_failure(self):
        class Client:
            deadline = capture.time.monotonic() + 60

            def check(self):
                capture.require(capture.time.monotonic() < self.deadline,
                                "capture deadline expired")

        release = capture.release_capture_alarm
        def fail_after_release(*arguments):
            release(*arguments)
            raise RuntimeError("cleanup failed")
        with patch.object(capture, "release_capture_alarm", side_effect=fail_after_release):
            with self.assertRaisesRegex(ValueError, "primary") as caught:
                with capture.capture_deadline(Client()):
                    raise ValueError("primary")
        self.assertEqual(caught.exception.__notes__,
                         ["capture alarm cleanup failed: cleanup failed"])

    def test_main_errors_never_print_secret_or_signed_url(self):
        client, _ = self.client([OSError(TOKEN + " " + SIGNED)])
        stderr = io.StringIO()
        with patch.dict(capture.os.environ, environment(), clear=True), redirect_stderr(stderr), \
                patch.object(capture, "CaptureHTTP", return_value=client):
            self.assertEqual(capture.main(["--output", str(self.root / "output")]), 1)
        self.assertEqual(stderr.getvalue(), "completed native log capture rejected\n")


if __name__ == "__main__":
    unittest.main()
