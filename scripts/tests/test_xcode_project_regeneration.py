from __future__ import annotations

from contextlib import chdir
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile
from tempfile import TemporaryDirectory
from textwrap import dedent
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
PROJECT = Path("Pomodorough.xcodeproj")
LOCK = PROJECT / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
GENERATED = PROJECT / "project.pbxproj"
SCHEME = PROJECT / "xcshareddata/xcschemes/Pomodorough-iOS.xcscheme"


def regeneration_shell() -> str:
    workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    step = workflow.split("      - name: Regenerate Xcode project and verify idempotence\n", 1)[1]
    step = step.split("\n      - name:", 1)[0]
    return dedent(step.split("        run: |\n", 1)[1])


def regeneration_script() -> str:
    return regeneration_shell().split("python3 - <<'PY'\n", 1)[1].rsplit("PY", 1)[0]


class XcodeProjectRegenerationTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = TemporaryDirectory(prefix="xcode-project-regeneration-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.original_lock = json.dumps({
            "originHash": "a" * 64,
            "pins": [{"identity": "package", "kind": "remoteSourceControl",
                      "location": "https://example.invalid/package.git",
                      "state": {"revision": "b" * 40, "version": "1.0.0"}}],
            "version": 3,
        }, indent=3).encode() + b"\n\n"
        self.reset_fixture()

    def reset_fixture(self) -> None:
        if (self.root / PROJECT).exists():
            shutil.rmtree(self.root / PROJECT)
        self.tracked = {GENERATED: b"project\n", SCHEME: b"scheme\n", LOCK: self.original_lock}
        self.generations = 0
        self.commands = []
        self.generated_changes = {}
        self.generator_failures = {}
        self.git_failure = None
        for path, content in self.tracked.items():
            self.write(path, content)

    def write(self, path: Path, content: bytes) -> None:
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)

    def generate(self) -> int:
        self.assertFalse((self.root / PROJECT).exists(), "Each generation must start without the project")
        self.generations += 1
        if self.generations in self.generator_failures:
            return self.generator_failures[self.generations]
        for path, content in self.tracked.items():
            if path != LOCK:
                self.write(path, content)
        for path, content in self.generated_changes.get(self.generations, {}).items():
            if content is None:
                (self.root / path).unlink()
            else:
                self.write(path, content)
        return 0

    def command(self, arguments, **kwargs):
        self.commands.append(arguments)
        if arguments == ("xcodegen", "generate"):
            return subprocess.CompletedProcess(arguments, self.generate())
        operation = "cached-diff" if "--cached" in arguments else arguments[1]
        if self.git_failure and operation == self.git_failure[0] and self.generations == self.git_failure[1]:
            return subprocess.CompletedProcess(arguments, self.git_failure[2])
        if arguments[:2] == ("git", "diff"):
            self.assertIn(arguments, (("git", "diff", "--exit-code", "HEAD", "--", str(PROJECT)),
                                      ("git", "diff", "--cached", "--exit-code", "HEAD", "--", str(PROJECT))))
            if "--cached" in arguments:
                return subprocess.CompletedProcess(arguments, 0)
            drift = any(not (self.root / path).is_file() or (self.root / path).read_bytes() != content
                        for path, content in self.tracked.items())
            return subprocess.CompletedProcess(arguments, int(drift))
        if "--error-unmatch" in arguments:
            self.assertEqual(arguments, ("git", "ls-files", "--error-unmatch", "--", str(LOCK)))
            return subprocess.CompletedProcess(arguments, int(LOCK not in self.tracked), b"")
        self.assertEqual(arguments, ("git", "ls-files", "--others", "-z", "--", str(PROJECT)))
        untracked = [path for path in (self.root / PROJECT).rglob("*")
                     if path.is_file() and path.relative_to(self.root) not in self.tracked]
        return subprocess.CompletedProcess(arguments, 0, b"untracked\0" if untracked else b"")

    def execute(self) -> None:
        with chdir(self.root), patch("subprocess.run", side_effect=self.command):
            exec(compile(regeneration_script(), ".github/workflows/ci.yml", "exec"), {})

    def assert_rejected(self, generations: int, code=None) -> None:
        with self.assertRaises(SystemExit) as raised:
            self.execute()
        self.assertEqual(self.generations, generations)
        self.assertNotIn(raised.exception.code, (None, 0), "Rejection must not exit successfully")
        if code is not None:
            self.assertEqual(raised.exception.code, code)

    def test_rejection_assertion_disallows_success_exit_codes(self) -> None:
        for code in (0, None):
            with self.subTest(code=code), patch.object(self, "execute", side_effect=SystemExit(code)):
                with self.assertRaises(AssertionError):
                    self.assert_rejected(0)

    def test_two_clean_generations_preserve_exact_lock_and_full_tree(self) -> None:
        self.execute()
        self.assertEqual(self.generations, 2)
        self.assertEqual((self.root / LOCK).read_bytes(), self.original_lock)
        self.assertEqual(sum(command[1] == "diff" and "--cached" not in command for command in self.commands), 3)
        self.assertEqual(sum("--cached" in command for command in self.commands), 3)
        self.assertEqual(sum("--others" in command for command in self.commands), 3)
        self.assertEqual({path.relative_to(self.root): path.read_bytes()
                          for path in (self.root / PROJECT).rglob("*") if path.is_file()}, self.tracked)

    def test_missing_lock_is_rejected_before_removal(self) -> None:
        (self.root / LOCK).unlink()
        self.assert_rejected(0)
        self.assertTrue((self.root / GENERATED).exists())

    def test_untracked_lock_is_rejected(self) -> None:
        del self.tracked[LOCK]
        self.assert_rejected(0, 1)

    def test_changed_valid_lock_is_not_silently_restored(self) -> None:
        self.write(LOCK, self.original_lock + b" ")
        self.assert_rejected(0, 1)
        self.assertEqual((self.root / LOCK).read_bytes(), self.original_lock + b" ")

    def test_symlink_lock_is_rejected(self) -> None:
        (self.root / LOCK).unlink()
        (self.root / LOCK).symlink_to(self.root / GENERATED)
        self.assert_rejected(0)

    def test_malformed_tracked_locks_are_rejected(self) -> None:
        malformed = [b"{", b"\xff", b"null", b"{}", b"[]"]
        for field, value in (("version", 2), ("originHash", "invalid"), ("pins", []),
                             ("pins", [None]), ("pins", [{}]), ("pins", "invalid")):
            document = json.loads(self.original_lock)
            document[field] = value
            malformed.append(json.dumps(document).encode())
        for content in malformed:
            with self.subTest(content=content):
                self.reset_fixture()
                self.tracked[LOCK] = content
                self.write(LOCK, content)
                self.assert_rejected(0)

    def test_malformed_pin_fields_are_rejected(self) -> None:
        for field in ("identity", "kind", "location", "state"):
            with self.subTest(field=field):
                self.reset_fixture()
                document = json.loads(self.original_lock)
                document["pins"][0][field] = None
                content = json.dumps(document).encode()
                self.tracked[LOCK] = content
                self.write(LOCK, content)
                self.assert_rejected(0)

    def test_malformed_revision_is_rejected(self) -> None:
        document = json.loads(self.original_lock)
        document["pins"][0]["state"]["revision"] = "not-a-revision"
        content = json.dumps(document).encode()
        self.tracked[LOCK] = content
        self.write(LOCK, content)
        self.assert_rejected(0)

    def test_dirty_generated_input_is_rejected_before_removal(self) -> None:
        self.write(GENERATED, b"dirty\n")
        self.assert_rejected(0, 1)
        self.assertEqual((self.root / GENERATED).read_bytes(), b"dirty\n")

    def test_untracked_input_is_rejected_before_removal(self) -> None:
        self.write(PROJECT / ".DS_Store", b"ignored but untracked\n")
        self.assert_rejected(0)

    def test_missing_or_changed_generated_files_fail_each_pass(self) -> None:
        for generation in (1, 2):
            for path in (GENERATED, SCHEME):
                for content in (None, b"drift\n"):
                    with self.subTest(generation=generation, path=path, content=content):
                        self.reset_fixture()
                        self.generated_changes[generation] = {path: content}
                        self.assert_rejected(generation, 1)

    def test_untracked_and_ignored_generated_files_fail_each_pass(self) -> None:
        for generation in (1, 2):
            for name in ("extra.xcscheme", ".DS_Store", "xcuserdata/note.txt"):
                with self.subTest(generation=generation, name=name):
                    self.reset_fixture()
                    self.generated_changes[generation] = {PROJECT / name: b"unexpected\n"}
                    self.assert_rejected(generation)

    def test_generated_lock_drift_is_not_overwritten(self) -> None:
        for generation in (1, 2):
            with self.subTest(generation=generation):
                self.reset_fixture()
                self.generated_changes[generation] = {LOCK: self.original_lock + b" "}
                self.assert_rejected(generation)
                self.assertEqual((self.root / LOCK).read_bytes(), self.original_lock + b" ")

    def test_matching_generated_lock_is_accepted(self) -> None:
        self.generated_changes = {generation: {LOCK: self.original_lock} for generation in (1, 2)}
        self.execute()
        self.assertEqual(self.generations, 2)

    def test_generator_failure_status_survives_each_pass(self) -> None:
        for generation in (1, 2):
            with self.subTest(generation=generation):
                self.reset_fixture()
                self.generator_failures[generation] = 37
                self.assert_rejected(generation, 37)

    def test_git_diff_failure_status_survives_each_gate(self) -> None:
        for generation in (0, 1, 2):
            with self.subTest(generation=generation):
                self.reset_fixture()
                self.git_failure = ("diff", generation, 23)
                self.assert_rejected(generation, 23)

    def test_git_listing_failure_status_is_not_swallowed(self) -> None:
        for generation in (0, 1, 2):
            with self.subTest(generation=generation):
                self.reset_fixture()
                self.git_failure = ("ls-files", generation, 29)
                self.assert_rejected(generation, 29)

    def test_git_cached_diff_failure_status_survives_each_gate(self) -> None:
        for generation in (0, 1, 2):
            with self.subTest(generation=generation):
                self.reset_fixture()
                self.git_failure = ("cached-diff", generation, 31)
                self.assert_rejected(generation, 31)


def stage_fixture_index(fixture: Path, path: Path, kind: str) -> None:
    work = fixture / "work"
    destination = work / path
    original = destination.read_bytes()
    environment = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_OPTIONAL_LOCKS="0")
    if kind == "index-content-only":
        destination.write_bytes(original + b"\nstaged-only drift\n")
        arguments = ["add", "--", str(path)]
    elif kind == "index-mode-only":
        arguments = ["update-index", "--chmod=+x", "--", str(path)]
    else:
        raise AssertionError(kind)
    subprocess.run(["git", *arguments], cwd=work, env=environment, check=True,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    if kind == "index-content-only":
        destination.write_bytes(original)
    entries = subprocess.run(["git", "ls-files", "--stage", "-z"], cwd=work, env=environment,
                             check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10).stdout
    (fixture / "staged-entries").write_bytes(entries)


def create_fixture_node(destination: Path, kind: str, template: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink() or destination.is_file():
        destination.unlink()
    elif destination.is_dir():
        shutil.rmtree(destination)
    if kind == "fifo":
        os.mkfifo(destination)
    elif kind == "directory":
        destination.mkdir()
    elif kind == "symlink":
        destination.symlink_to(template / LOCK)
    elif kind == "directory-symlink":
        destination.symlink_to(template / PROJECT)
    elif kind == "dangling":
        destination.symlink_to(template / "absent")
    elif kind == "regular":
        destination.write_bytes(b"untracked\n")
    else:
        raise AssertionError(kind)


def generate_fixture() -> None:
    fixture = Path(os.environ["REGEN_FIXTURE"])
    assert Path.cwd() == fixture / "work"
    assert not PROJECT.exists() and not PROJECT.is_symlink()
    counter = fixture / "generations"
    generation = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(generation))
    shutil.copytree(fixture / "template" / PROJECT, PROJECT)
    LOCK.unlink()
    mutation = json.loads((fixture / "mutation.json").read_text())
    if mutation.get("generation") == generation:
        if mutation["kind"].startswith("index-"):
            stage_fixture_index(fixture, Path(mutation["path"]), mutation["kind"])
        else:
            create_fixture_node(Path(mutation["path"]), mutation["kind"], fixture / "template")


class XcodeProjectRegenerationShellTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = TemporaryDirectory(prefix="xcode-project-regeneration-shell-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.work = self.root / "work"
        for name in ("work", "template", "bin", "home", "tmp"):
            (self.root / name).mkdir()
        self.environment = dict(os.environ, HOME=str(self.root / "home"), TMPDIR=str(self.root / "tmp"),
                                RUNNER_TEMP=str(self.root / "tmp"), REGEN_FIXTURE=str(self.root),
                                GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                                GIT_OPTIONAL_LOCKS="0", PYTHONDONTWRITEBYTECODE="1")
        self.prepare_git_fixture()
        self.prepare_commands()
        self.reset_project()

    def git(self, *arguments, cwd=None) -> bytes:
        return subprocess.run([self.git_binary, *arguments], cwd=cwd or self.work,
                              env=self.environment, check=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=10).stdout

    def prepare_git_fixture(self) -> None:
        self.git_binary = shutil.which("git")
        self.assertIsNotNone(self.git_binary)
        head = self.git("rev-parse", "HEAD", cwd=ROOT).decode().strip()
        common = self.git("rev-parse", "--git-common-dir", cwd=ROOT).decode().strip()
        objects = (ROOT / common / "objects").resolve()
        archived = self.git("archive", "HEAD", "--", ".gitignore", str(PROJECT), cwd=ROOT)
        with tarfile.open(fileobj=io.BytesIO(archived)) as archive:
            archive.extractall(self.root / "template", filter="data")
        self.original_lock = (self.root / "template" / LOCK).read_bytes()
        shutil.copyfile(self.root / "template/.gitignore", self.work / ".gitignore")
        self.git("init", "--quiet")
        (self.work / ".git/objects/info/alternates").write_text(str(objects) + "\n")
        (self.work / ".git/HEAD").write_text(head + "\n")
        self.git("read-tree", "HEAD")

    def prepare_commands(self) -> None:
        (self.root / "bin/git").symlink_to(self.git_binary)
        (self.root / "bin/python3").symlink_to(sys.executable)
        generator = self.root / "bin/xcodegen"
        generator.write_text(f"#!{sys.executable}\nimport runpy\n"
                             f"runpy.run_path({str(Path(__file__).resolve())!r})['generate_fixture']()\n")
        generator.chmod(0o755)
        self.environment["PATH"] = str(self.root / "bin")
        self.shell = self.root / "regenerate.sh"
        self.shell.write_text(regeneration_shell())

    def reset_project(self) -> None:
        project = self.work / PROJECT
        if project.exists():
            shutil.rmtree(project)
        shutil.copytree(self.root / "template" / PROJECT, project)
        (self.root / "generations").unlink(missing_ok=True)
        (self.root / "mutation.json").write_text("{}")

    def execute_shell(self, arguments=None, timeout=5) -> subprocess.CompletedProcess:
        arguments = arguments or ["/bin/bash", "-e", str(self.shell)]
        process = subprocess.Popen(arguments, cwd=self.work, env=self.environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            output, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            output, _ = process.communicate()
            self.fail(f"Workflow timed out; cleanup is not rejection: {output!r}")
        return subprocess.CompletedProcess(arguments, process.returncode, output)

    def assert_rejected_node(self, generation: int, path: Path, kind: str) -> None:
        self.reset_project()
        mutation = {"generation": generation, "path": str(path), "kind": kind}
        (self.root / "mutation.json").write_text(json.dumps(mutation))
        if generation == 0:
            create_fixture_node(self.work / path, kind, self.root / "template")
        result = self.execute_shell()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        counter = self.root / "generations"
        self.assertEqual(int(counter.read_text()) if counter.exists() else 0, generation)
        self.assertTrue(os.path.lexists(self.work / path), "Dirty nodes must not be normalized away")

    def test_full_shell_preserves_exact_head_lock_after_two_clean_generations(self) -> None:
        result = self.execute_shell()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.root / "generations").read_text(), "2")
        self.assertEqual((self.work / LOCK).read_bytes(), self.original_lock)
        self.assertEqual(self.git("diff", "--exit-code", "HEAD", "--", str(PROJECT)), b"")
        self.assertEqual(self.git("diff", "--cached", "--exit-code", "HEAD", "--", str(PROJECT)), b"")
        self.assertEqual(self.git("ls-files", "--others", "-z", "--", str(PROJECT)), b"")

    def assert_rejected_index(self, generation: int, kind: str) -> None:
        original = (self.work / GENERATED).read_bytes()
        original_mode = (self.work / GENERATED).stat().st_mode
        mutation = {"generation": generation, "path": str(GENERATED), "kind": kind}
        (self.root / "mutation.json").write_text(json.dumps(mutation))
        if generation == 0:
            stage_fixture_index(self.root, GENERATED, kind)
        result = self.execute_shell()
        self.assertEqual(result.returncode, 1, result.stdout)
        counter = self.root / "generations"
        self.assertEqual(int(counter.read_text()) if counter.exists() else 0, generation)
        self.assertEqual((self.work / GENERATED).read_bytes(), original)
        self.assertEqual((self.work / GENERATED).stat().st_mode, original_mode)
        self.assertEqual((self.work / LOCK).read_bytes(), self.original_lock)
        self.assertEqual(self.git("diff", "--exit-code", "HEAD", "--", str(PROJECT)), b"")
        with self.assertRaises(subprocess.CalledProcessError) as raised:
            self.git("diff", "--cached", "--exit-code", "HEAD", "--", str(PROJECT))
        self.assertEqual(raised.exception.returncode, 1)
        self.assertTrue(raised.exception.stdout)
        self.assertEqual(self.git("ls-files", "--stage", "-z"), (self.root / "staged-entries").read_bytes())

    def test_staged_only_bytes_rejected_before_generation(self) -> None:
        self.assert_rejected_index(0, "index-content-only")

    def test_staged_only_mode_rejected_before_generation(self) -> None:
        self.assert_rejected_index(0, "index-mode-only")

    def test_staged_only_bytes_rejected_after_first_generation(self) -> None:
        self.assert_rejected_index(1, "index-content-only")

    def test_staged_only_mode_rejected_after_first_generation(self) -> None:
        self.assert_rejected_index(1, "index-mode-only")

    def test_staged_only_bytes_rejected_after_second_generation(self) -> None:
        self.assert_rejected_index(2, "index-content-only")

    def test_staged_only_mode_rejected_after_second_generation(self) -> None:
        self.assert_rejected_index(2, "index-mode-only")

    def test_nonregular_lock_is_rejected_at_all_three_gates(self) -> None:
        for generation in (0, 1, 2):
            for kind in ("fifo", "directory", "symlink", "directory-symlink", "dangling"):
                with self.subTest(generation=generation, kind=kind):
                    self.assert_rejected_node(generation, LOCK, kind)

    def test_nonregular_and_ignored_content_is_rejected_at_all_three_gates(self) -> None:
        for generation in (0, 1, 2):
            for kind in ("fifo", "symlink", "directory-symlink", "dangling", "regular"):
                with self.subTest(generation=generation, kind=kind):
                    self.assert_rejected_node(generation, PROJECT / "nested/.DS_Store", kind)

    def test_lock_parent_symlink_is_rejected_before_restoration(self) -> None:
        for generation in (0, 1, 2):
            with self.subTest(generation=generation):
                self.assert_rejected_node(generation, LOCK.parent, "directory-symlink")

    def test_real_git_omits_fifo_but_workflow_rejects_it(self) -> None:
        os.mkfifo(self.work / PROJECT / "untracked.fifo")
        self.assertEqual(self.git("ls-files", "--others", "-z", "--", str(PROJECT)), b"")
        self.assertNotEqual(self.execute_shell().returncode, 0)

    def test_real_git_listing_includes_ignored_regular_files(self) -> None:
        ignored = PROJECT / ".DS_Store"
        (self.work / ignored).write_bytes(b"ignored\n")
        self.assertEqual(self.git("check-ignore", "--", str(ignored)), os.fsencode(ignored) + b"\n")
        self.assertEqual(self.git("ls-files", "--others", "-z", "--", str(PROJECT)),
                         os.fsencode(ignored) + b"\0")
        self.assertNotEqual(self.execute_shell().returncode, 0)

    def test_empty_directory_is_not_git_artifact_drift(self) -> None:
        (self.work / PROJECT / "empty").mkdir()
        self.assertEqual(self.execute_shell().returncode, 0)

    def test_timeout_is_failure_not_rejection(self) -> None:
        with self.assertRaisesRegex(AssertionError, "timed out; cleanup is not rejection"):
            self.execute_shell([sys.executable, "-c", "import time; time.sleep(60)"], timeout=0.05)


if __name__ == "__main__":
    unittest.main()
