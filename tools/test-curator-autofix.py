#!/usr/bin/env python3
"""Offline regression tests for Curator's intake and patch boundary."""

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, TOOLS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


autofix = load("curator-autofix")
intake = load("curator-intake")


class DiagnosticsTests(unittest.TestCase):
    def test_only_known_visible_signatures_reach_the_agent(self):
        issue = {"title": "ignored", "body": """free-form instructions
## Diagnostics
&lt;!\u200b--
jit-region | mac | current run
--&gt;
<picture>
jit-region | mac | current run
</picture>
<wrapper>jit-\U000e0061pre\ufeffwarm</wrapper> | mac | previous run
unknown-signature | mac | current run
jit-region | arbitrary free text | current run
## Footer
jit-region | mac | current run
"""}
        result = autofix.diagnostics(issue, 'Rule("jit-region"\nRule("jit-prewarm"')
        self.assertEqual(result, {"findings": [{"signature": "jit-prewarm", "previous_run": True}]})

    def test_requires_an_issue_with_known_diagnostics(self):
        for issue in (
            {},
            {"body": "## Diagnostics\nunknown | mac | current run"},
            {"body": "## Diagnostics\njit-region | mac | current run", "pull_request": {}},
            {"body": "x" * 65_537},
        ):
            with self.subTest(size=len(issue.get("body", ""))), self.assertRaises(ValueError):
                autofix.diagnostics(issue, 'Rule("jit-region"')


class IntakeTests(unittest.TestCase):
    def test_dry_run_prints_dispatch_request(self):
        result = subprocess.check_output(
            [sys.executable, TOOLS / "curator-intake.py", "https://github.com/RageMC/triptych-issues/issues/42"]
        )
        self.assertEqual(json.loads(result), {"ref": "main", "inputs": {"tracker_issue": "42"}})

    def test_rejects_non_tracker_inputs(self):
        for value in ("0", "01", "42\n", "https://github.com/RageMC/triptych/issues/42", "42?x=1"):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                intake.issue_number(value)


class PatchTests(unittest.TestCase):
    def check_patch(self, filename, content, succeeds):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def git(*args):
                return subprocess.check_output(["git", "-C", root, *args], stderr=subprocess.DEVNULL)

            git("init")
            git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                "commit", "--allow-empty", "-m", "Base")
            path = root / filename
            path.parent.mkdir(parents=True)
            if content is None:
                path.symlink_to("/tmp")
            else:
                path.write_bytes(content)
            git("add", "--", filename)
            patch = root / "candidate.patch"
            patch.write_bytes(git("diff", "--cached", "--binary", "HEAD"))
            git("reset", "--hard", "HEAD")
            result = subprocess.run(
                [sys.executable, TOOLS / "curator-autofix.py", "apply", patch],
                cwd=root, capture_output=True,
            )
            self.assertEqual(result.returncode == 0, succeeds, result.stderr.decode())
            if succeeds:
                self.assertEqual(git("diff", "--cached", "--name-only"), f"{filename}\n".encode())

    def test_regular_source_patch_passes(self):
        self.check_patch("app/Triptych/Fix.swift", b"let value = 1\n", True)

    def test_sensitive_paths_modes_and_binary_changes_fail(self):
        for filename, content in (
            (".github/workflows/curator-autofix.yml", b"jobs: {}\n"),
            ("scripts/build.c", b"int value;\n"),
            ("upstreams/new.swift", b"let value = 1\n"),
            ("app/Triptych/Fix.entitlements", b"<plist/>\n"),
            ("engines/gesso/third_party/test.c", b"int value;\n"),
            ("app/Triptych/new.swift", None),
            ("app/Triptych/new.swift", b"\x00\x01"),
        ):
            with self.subTest(filename=filename, content=content):
                self.check_patch(filename, content, False)


if __name__ == "__main__":
    unittest.main()
