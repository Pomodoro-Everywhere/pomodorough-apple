from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/release.yml"
GATES = {"preflight", "selftest", "test-ios", "test-macos",
         "build-ios-simulator", "build-ios-device", "build-macos", "package"}


def job(workflow, name):
    return workflow.split(f"\n  {name}:\n", 1)[1].split("\n  ", 1)[0]


def step_script(workflow, name):
    step = workflow.split(f"      - name: {name}\n", 1)[1]
    return textwrap.dedent(step.split("        run: |\n", 1)[1]
                           .split("\n      - name:", 1)[0].split("\n  package-and-release:", 1)[0])


class ReleaseTransferTests(unittest.TestCase):
    def assert_contract(self, workflow):
        jobs = dict(re.findall(r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:|\Z)",
                               workflow, re.MULTILINE | re.DOTALL))
        package, publish = jobs["package"], jobs["package-and-release"]
        for body, expected in ((package, GATES - {"preflight", "selftest", "test-ios", "test-macos", "package"}),
                               (publish, GATES)):
            needs = body.split("    needs:\n", 1)[1].split("    runs-on:", 1)[0]
            self.assertEqual(set(re.findall(r"^      - ([\w-]+)$", needs, re.MULTILINE)), expected)
            self.assertNotRegex(body, r"(?m)^\s+(?:if|continue-on-error):")
        self.assertIn("contents: read", package)
        self.assertNotIn("gh release", package)
        self.assertNotIn("attest-build-provenance", package)
        self.assertLess(package.index("Clean-install and launch packaged"), package.index("Seal release transfer"))
        self.assertIn("artifact-ids: ${{ needs.package.outputs.artifact-id }}", publish)
        self.assertIn("EXPECTED_BUNDLE_SHA256: ${{ needs.package.outputs.bundle-sha256 }}", publish)
        self.assertIn("bundle-sha256: ${{ steps.bundle.outputs.sha256 }}", package)
        self.assertIn("artifact-id: ${{ steps.upload.outputs.artifact-id }}", package)
        self.assertLess(publish.index("Verify and restore sealed release"), publish.index("Attest artifact provenance"))
        self.assertLess(publish.index("Attest artifact provenance"), publish.index("Create GitHub Release"))

    def test_workflow_gate_contract_and_mutations(self):
        workflow = WORKFLOW.read_text()
        self.assert_contract(workflow)
        for gate in GATES:
            with self.subTest(gate=gate):
                prefix, publish = workflow.split("\n  package-and-release:", 1)
                mutated = prefix + "\n  package-and-release:" + publish.replace(f"      - {gate}\n", "", 1)
                with self.assertRaises(AssertionError):
                    self.assert_contract(mutated)
        for mutation in ("    if: always()\n", "    continue-on-error: true\n"):
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError):
                self.assert_contract(workflow.replace("  package-and-release:\n", "  package-and-release:\n" + mutation))

    def make_payload(self, root):
        assets = root / "release"
        assets.mkdir()
        for name in ("simulator.zip", "device.ipa", "macos.zip", "sbom.spdx.json"):
            (assets / name).write_bytes(name.encode())
        manifest = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  ./{path.name}\n"
                           for path in sorted(assets.iterdir()))
        (assets / "SHA256SUMS.txt").write_text(manifest)
        provenance = root / "core-provenance-ios-simulator"
        provenance.mkdir()
        for name in ("CORE_RELEASE_TAG", "CORE_COMMIT", "CORE_SHA256"):
            (provenance / name).write_text(name)
        return assets, provenance

    def run_transfer(self, corruption="", restore_mutation=False):
        workflow = WORKFLOW.read_text()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assets, provenance = self.make_payload(root)
            expected = {path.relative_to(root): path.read_bytes()
                        for folder in (assets, provenance) for path in folder.iterdir()}
            env = dict(os.environ, RUNNER_TEMP=str(root), RELEASE_DIR=str(assets),
                       GITHUB_OUTPUT=str(root / "output"))
            sealed = subprocess.run(["bash", "-c", step_script(workflow, "Seal release transfer")],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(sealed.returncode, 0, sealed.stderr)
            checksum = (root / "output").read_text().strip().split("=", 1)[1]
            archive = root / "release-transfer.tar"
            if corruption in ("assets/simulator.zip", "assets/SHA256SUMS.txt", "core-provenance-ios-simulator/CORE_COMMIT"):
                (root / "release-transfer" / corruption).write_text("tampered")
                subprocess.run(["tar", "-cf", str(archive), "-C", str(root / "release-transfer"), "."], check=True)
            elif corruption == "truncated":
                archive.write_bytes(archive.read_bytes()[:100])
            shutil.rmtree(root / "release-transfer")
            shutil.rmtree(assets)
            shutil.rmtree(provenance)
            (root / "sealed-release").mkdir()
            archive.rename(root / "sealed-release/release-transfer.tar")
            env["EXPECTED_BUNDLE_SHA256"] = "" if corruption == "missing-digest" else checksum
            script = step_script(workflow, "Verify and restore sealed release")
            if restore_mutation:
                script = script.replace('test "$actual_sha" = "$EXPECTED_BUNDLE_SHA256"', ":")
            result = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True, timeout=10)
            if corruption and not restore_mutation:
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(assets.exists(), result.stderr)
                self.assertFalse((root / "release-transfer").exists(), result.stderr)
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                if not restore_mutation:
                    for path, payload in expected.items():
                        self.assertEqual((root / path).read_bytes(), payload)
            return result

    def test_exact_round_trip_and_corruption_rejected_before_extraction(self):
        for corruption in ("", "assets/simulator.zip", "assets/SHA256SUMS.txt",
                           "core-provenance-ios-simulator/CORE_COMMIT", "truncated", "missing-digest"):
            with self.subTest(corruption=corruption):
                self.run_transfer(corruption)

    def test_digest_check_mutation_allows_provenance_tampering(self):
        self.run_transfer("core-provenance-ios-simulator/CORE_COMMIT", restore_mutation=True)


if __name__ == "__main__":
    unittest.main()
