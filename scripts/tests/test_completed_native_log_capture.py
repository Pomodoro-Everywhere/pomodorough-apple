"""Fake HTTP only: never contact GitHub or execute native tooling."""

from __future__ import annotations

import copy
import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch
import sys

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import capture_completed_native_log as capture

TOKEN = "fake-secret-never-retained"
BASE = "https://api.github.com/repos/example/apple"
SIGNED = "https://production.blob.core.windows.net/logs/job?signature=fake"


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
        workflow = yaml.safe_load((Path(capture.__file__).resolve().parents[1] / capture.WORKFLOW).read_text())
        job = workflow["jobs"]["retain-completed-native-log"]
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

    def test_main_errors_never_print_secret_or_signed_url(self):
        client, _ = self.client([OSError(TOKEN + " " + SIGNED)])
        stderr = io.StringIO()
        with patch.dict(capture.os.environ, environment(), clear=True), redirect_stderr(stderr), \
                patch.object(capture, "CaptureHTTP", return_value=client):
            self.assertEqual(capture.main(["--output", str(self.root / "output")]), 1)
        self.assertEqual(stderr.getvalue(), "completed native log capture rejected\n")


if __name__ == "__main__":
    unittest.main()
