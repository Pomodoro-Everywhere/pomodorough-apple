#!/usr/bin/env python3
"""Retain original completed native job output using read-only GitHub APIs."""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import re
import signal
import sys
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
ALARM_DRAIN_SECONDS = 0.01


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


def restore_capture_alarm(previous, previous_mask: set[signal.Signals]) -> None:
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
    try:
        signal.signal(signal.SIGALRM, signal.SIG_IGN)
        remaining, _ = signal.setitimer(signal.ITIMER_REAL, 0)
        if remaining == 0.0:
            time.sleep(ALARM_DRAIN_SECONDS)
        signal.signal(signal.SIGALRM, previous)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)


@contextlib.contextmanager
def capture_deadline(client: CaptureHTTP):
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
    previous = None
    failure: BaseException | None = None
    def expired(signum, frame):
        raise CaptureError("capture deadline expired")
    try:
        require(signal.SIGALRM not in previous_mask
                and signal.SIGALRM not in signal.sigpending()
                and signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0),
                "existing process deadline")
        previous = signal.getsignal(signal.SIGALRM)
        signal.signal(signal.SIGALRM, expired)
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        remaining = client.deadline - time.monotonic()
        require(remaining > 0, "capture deadline expired")
        signal.setitimer(signal.ITIMER_REAL, remaining)
        client.check()
        yield
        client.check()
    except BaseException as error:
        failure = error
        raise
    finally:
        try:
            if previous is None:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            else:
                alarm_failure = None
                for _ in range(2):
                    try:
                        restore_capture_alarm(previous, previous_mask)
                        break
                    except CaptureError as error:
                        alarm_failure = error
                if alarm_failure is not None:
                    raise alarm_failure
        except BaseException as error:
            if failure is None:
                raise
            failure.add_note(f"capture alarm cleanup failed: {error}")


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
