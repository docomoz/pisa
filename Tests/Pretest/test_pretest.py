import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("pisya_pretest", ROOT / "scripts/pretest.py")
pretest = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = pretest
SPEC.loader.exec_module(pretest)


class PretestRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        self.output = self.repo / "build/pretest"
        self.capabilities = pretest.Capabilities(True, True, frozenset({"git", "node", "npm", "bash", "swift", "swiftc", "xcrun"}))
        self.snapshot = {"head": "fixture", "fingerprint": "unchanged"}
        self.calls = []

    def execute(self, check, repo, logs, timeout):
        self.calls.append((check.id, repo, logs, timeout))
        (logs / "stdout.log").write_text("fixture stdout\n")
        (logs / "stderr.log").write_text("fixture stderr\n")
        return pretest.Execution(0, 0.01)

    def run_suite(self, checks, **kwargs):
        options = dict(checks=checks, capabilities=self.capabilities, command_runner=self.execute,
                       snapshotter=lambda *_: self.snapshot)
        options.update(kwargs)
        return pretest.run_suite(self.repo, self.output, **options)

    def test_default_plan_covers_every_required_suite(self):
        plan = pretest.default_checks()
        self.assertEqual([check.id for check in plan], [
            "diff-check", "design-system", "versioning", "pretest-runner", "website", "swift-core",
            "native-quit-shortcut", "native-capture-window", "native-status-menu", "native-interface-controls",
        ])
        self.assertEqual(next(c.command for c in plan if c.id == "swift-core"), ("swift", "test"))
        self.assertEqual(sum(check.portable for check in plan), 5)
        self.assertTrue(all(check.macos and check.gui for check in plan if check.native))

    def test_runs_sequentially_from_repo_and_writes_reviewable_reports(self):
        checks = [pretest.Check("first", ("first",)), pretest.Check("second", ("second",))]
        report = self.run_suite(checks, timeout=12)
        self.assertEqual(report["status"], "PASS")
        self.assertEqual(report["exit_code"], 0)
        self.assertEqual([call[0] for call in self.calls], ["first", "second"])
        self.assertTrue(all(call[1] == self.repo.resolve() and call[3] == 12 for call in self.calls))
        directory = Path(report["directory"])
        self.assertEqual(json.loads((directory / "summary.json").read_text()), report)
        self.assertIn("Source integrity: **PASS**", (directory / "report.md").read_text())
        for check in report["checks"]:
            self.assertTrue((directory / check["stdout_log"]).is_file())
            self.assertTrue((directory / check["stderr_log"]).is_file())

    def test_failed_check_does_not_prevent_later_evidence(self):
        checks = [pretest.Check("failed", ("fixture",)), pretest.Check("later", ("fixture",))]
        def execute(check, *args):
            self.calls.append(check.id)
            return pretest.Execution(7 if check.id == "failed" else 0, 0)
        report = self.run_suite(checks, command_runner=execute)
        self.assertEqual(self.calls, ["failed", "later"])
        self.assertEqual([c["status"] for c in report["checks"]], ["FAIL", "PASS"])
        self.assertEqual(report["exit_code"], 1)
        self.assertEqual(report["checks"][0]["returncode"], 7)

    def test_missing_tools_or_gui_are_blocked_and_never_invoked(self):
        checks = [pretest.Check("swift", ("swift",), tools=("swift",)),
                  pretest.Check("native", ("fixture",), macos=True, gui=True, native=True)]
        report = self.run_suite(checks, capabilities=pretest.Capabilities(False, False, frozenset()))
        self.assertEqual(self.calls, [])
        self.assertEqual([c["status"] for c in report["checks"]], ["BLOCKED", "BLOCKED"])
        self.assertEqual(report["exit_code"], 2)

    def test_missing_test_file_is_failure_even_on_unsupported_platform(self):
        check = pretest.Check("missing", ("fixture",), files=("missing.swift",), macos=True)
        report = self.run_suite([check], capabilities=pretest.Capabilities(False, False, frozenset()))
        self.assertEqual(self.calls, [])
        self.assertEqual(report["status"], "FAIL")

    def test_portable_success_explicitly_excludes_native_and_swift(self):
        checks = [pretest.Check("portable", ("fixture",)),
                  pretest.Check("native", ("fixture",), portable=False, macos=True)]
        report = self.run_suite(checks, portable=True, capabilities=pretest.Capabilities(False, False, frozenset()))
        self.assertEqual(report["exit_code"], 0)
        self.assertEqual(report["scope"], "portable")
        self.assertEqual(report["outside_scope"], ["native"])
        self.assertEqual([c["id"] for c in report["checks"]], ["portable"])
        self.assertIn("not a full Pretest pass", (Path(report["directory"]) / "report.md").read_text())

    def test_native_exit_77_is_blocked_but_other_failures_are_not_hidden(self):
        check = pretest.Check("fixture", ("fixture",), native=True)
        runner = lambda *_: pretest.Execution(77, 0)
        self.assertEqual(self.run_suite([check], command_runner=runner)["status"], "BLOCKED")
        self.assertEqual(self.run_suite([check], command_runner=lambda *_: pretest.Execution(2, 0))["status"], "FAIL")
        check = pretest.Check("fixture", ("fixture",))
        self.assertEqual(self.run_suite([check], command_runner=runner)["status"], "FAIL")

    def test_timeout_and_unavailable_executable_never_pass(self):
        check = pretest.Check("fixture", ("fixture",))
        report = self.run_suite([check], command_runner=lambda *_: pretest.Execution(0, 0.1, timed_out=True))
        self.assertEqual(report["status"], "FAIL")
        self.assertTrue(report["checks"][0]["timed_out"])
        report = self.run_suite([check], command_runner=lambda *_: pretest.Execution(None, 0, unavailable=True))
        self.assertEqual(report["status"], "BLOCKED")

    def test_source_drift_fails_despite_passing_commands(self):
        snapshots = iter([self.snapshot, {"head": "changed", "fingerprint": "new"}])
        report = self.run_suite([pretest.Check("fixture", ("fixture",))], snapshotter=lambda *_: next(snapshots))
        self.assertEqual(report["checks"][0]["status"], "PASS")
        self.assertEqual(report["source_integrity"]["status"], "FAIL")
        self.assertEqual(report["exit_code"], 1)

    def test_snapshot_failure_and_empty_plan_never_pass(self):
        def unavailable(*_):
            raise OSError("fixture unavailable")
        report = self.run_suite([pretest.Check("fixture", ("fixture",))], snapshotter=unavailable)
        self.assertEqual(report["exit_code"], 2)
        self.assertEqual(report["source_integrity"]["status"], "BLOCKED")
        self.assertEqual(self.run_suite([])["exit_code"], 1)

    def test_runs_always_have_unique_directories(self):
        check = pretest.Check("fixture", ("fixture",))
        first, second = self.run_suite([check]), self.run_suite([check])
        self.assertNotEqual(first["directory"], second["directory"])

    def test_native_evidence_and_swift_scratch_are_isolated_per_run(self):
        commands = []
        checks = [pretest.Check("swift-core", ("swift", "test")),
                  pretest.Check("native-interface-controls", ("bash", "fixture.sh"))]
        def execute(check, *args):
            commands.append(check.command)
            return pretest.Execution(0, 0)
        report = self.run_suite(checks, command_runner=execute)
        directory = Path(report["directory"])
        self.assertEqual(commands[0], ("swift", "test", "--scratch-path", str(directory / "swift-build")))
        self.assertEqual(commands[1][-2:], ("--render", str(directory / "renders/native-interface-controls")))
        self.assertEqual(report["status"], "PASS")

    def test_real_process_logs_and_timeout_are_preserved(self):
        logs = self.repo / "logs"
        logs.mkdir()
        command = (sys.executable, "-c", "import sys,time; print('started',flush=True); print('error',file=sys.stderr,flush=True); time.sleep(20)")
        start = time.monotonic()
        result = pretest.run_command(pretest.Check("timeout", command), self.repo, logs, 0.2)
        self.assertTrue(result.timed_out)
        self.assertLess(time.monotonic() - start, 5)
        self.assertIn("started", (logs / "stdout.log").read_text())
        self.assertIn("error", (logs / "stderr.log").read_text())
        self.assertIn("Pretest timeout", (logs / "stderr.log").read_text())

    def test_timeout_also_terminates_the_checks_child_process(self):
        logs = self.repo / "child-logs"
        logs.mkdir()
        marker = self.repo / "child-survived"
        child = "import pathlib,time; time.sleep(.7); pathlib.Path('child-survived').write_text('bad')"
        parent = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c'," + repr(child) + "]); time.sleep(20)"
        result = pretest.run_command(pretest.Check("child", (sys.executable, "-c", parent)), self.repo, logs, 0.2)
        self.assertTrue(result.timed_out)
        time.sleep(0.8)
        self.assertFalse(marker.exists(), "Timed-out child process survived the check")

    def test_cli_list_and_import_have_no_run_side_effects(self):
        with patch.object(pretest, "run_suite", side_effect=AssertionError("must not run")):
            with patch("builtins.print"):
                self.assertEqual(pretest.main(["--list"]), 0)
        self.assertFalse(self.output.exists())
        imported = subprocess.run([sys.executable, "-B", "-c", "import runpy; runpy.run_path('scripts/pretest.py',run_name='imported')"],
                                  cwd=ROOT, capture_output=True, text=True, check=False)
        self.assertEqual(imported.returncode, 0, imported.stderr)
        self.assertEqual(imported.stdout, "")


class ChangedChecksTests(unittest.TestCase):
    def select(self, *changes):
        records = b"".join(f"{added}\t{deleted}\t{path}\0".encode()
                           for path, added, deleted in changes)
        with patch.object(pretest.subprocess, "check_output", return_value=records):
            scope, checks = pretest.changed_checks(ROOT, "a" * 40, pretest.default_checks())
        return scope, {check.id: check.command for check in checks}

    def test_small_layout_change_does_not_run_core_or_unrelated_native_checks(self):
        scope, checks = self.select(("Sources/Pisya/MainView.swift", 4, 1), ("Resources/Info.plist", 2, 2))
        self.assertEqual(scope, "targeted")
        self.assertEqual(list(checks), ["diff-check", "design-system"])
        self.assertEqual(checks["diff-check"], ("git", "diff", "--check", "a" * 40, "HEAD", "--"))
        self.assertEqual(checks["design-system"][-1], "Sources/Pisya/MainView.swift")

    def test_shared_control_uses_its_probe(self):
        scope, checks = self.select(("Sources/Pisya/Appearance.swift", 1, 1))
        self.assertEqual(scope, "targeted")
        self.assertEqual(list(checks), ["diff-check", "design-system", "native-interface-controls"])

    def test_small_core_change_runs_matching_suites_or_builds_tests(self):
        for path, expected in [
            ("Sources/PisyaCore/VoiceSampleSelection.swift",
             ("swift", "test", "--filter", r"^(PisyaCoreTests\.)?(AutomaticVoiceSampleTests|VoiceSampleSelectionTests)/")),
            ("Sources/PisyaCore/Models.swift", ("swift", "build", "--build-tests")),
            ("Sources/PisyaMCP/Launcher.swift",
             ("swift", "test", "--filter", r"^(PisyaCoreTests\.)?(MCPTransportTests)/")),
        ]:
            with self.subTest(path=path):
                scope, checks = self.select((path, 1, 1))
                self.assertEqual(scope, "targeted")
                self.assertNotIn("swift-core", checks)
                self.assertIn(expected, checks.values())

    def test_broad_app_changes_and_dependency_changes_run_full_suite(self):
        for changes in [
            [("Sources/Pisya/MainView.swift", 151, 149)],
            [(f"Sources/Pisya/View{i}.swift", 1, 0) for i in range(10)],
            [("Package.swift", 1, 1)],
            [("Vendor/mlx-audio-swift", 1, 1)],
        ]:
            with self.subTest(changes=changes):
                scope, checks = self.select(*changes)
                self.assertEqual(scope, "full")
                self.assertEqual(list(checks), [check.id for check in pretest.default_checks()])

    def test_docs_website_and_ci_changes_stay_local_to_their_checks(self):
        scope, checks = self.select(("docs/pretest.md", 5, 5), ("website/page.html", 10, 1),
                                    (".github/workflows/pretest.yml", 2, 1))
        self.assertEqual(scope, "targeted")
        self.assertEqual(list(checks), ["diff-check", "pretest-runner", "website"])


@unittest.skipUnless(shutil.which("git"), "Git is required for source fingerprint tests")
class SourceFingerprintTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Pretest fixture")
        self.git("config", "user.email", "pretest@example.invalid")
        (self.repo / "Sources").mkdir()
        (self.repo / "Sources/example.swift").write_text("initial\n")
        (self.repo / ".gitignore").write_text("build/\n.signing.env\n")
        self.git("add", ".")
        self.git("-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false", "commit", "-qm", "fixture")
        self.run_directory = self.repo / "build/pretest/fixture"

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True).stdout

    def snapshot(self):
        return pretest.snapshot_sources(self.repo, self.run_directory)

    def test_tracks_unstaged_staged_untracked_and_deleted_source_changes(self):
        clean = self.snapshot()
        source = self.repo / "Sources/example.swift"
        source.write_text("edited\n")
        dirty = self.snapshot()
        self.assertNotEqual(clean["fingerprint"], dirty["fingerprint"])
        self.git("add", "Sources/example.swift")
        staged = self.snapshot()
        self.assertNotEqual(dirty["index_sha256"], staged["index_sha256"])
        (self.repo / "Tests").mkdir()
        (self.repo / "Tests/new.swift").write_text("new test\n")
        added = self.snapshot()
        self.assertIn("Tests/new.swift", added["changed_files"])
        (self.repo / "Tests/new.swift").write_text("changed test\n")
        self.assertNotEqual(added["fingerprint"], self.snapshot()["fingerprint"])
        source.unlink()
        self.assertEqual(self.snapshot()["changed_files"]["Sources/example.swift"]["kind"], "deleted")

    def test_staged_deletion_is_in_the_dirty_diff_fingerprint(self):
        before = self.snapshot()
        self.git("rm", "Sources/example.swift")
        after = self.snapshot()
        self.assertNotEqual(before["dirty_diff_sha256"], after["dirty_diff_sha256"])
        self.assertEqual(after["changed_files"]["Sources/example.swift"]["kind"], "deleted")

    def test_custom_report_directory_does_not_hide_adjacent_source_changes(self):
        (self.repo / "docs").mkdir()
        (self.repo / "docs/contract.md").write_text("contract")
        self.run_directory = self.repo / "docs/reports/run-unique"
        before = self.snapshot()
        self.run_directory.mkdir(parents=True)
        (self.run_directory / "summary.json").write_text("output")
        self.assertEqual(before, self.snapshot())
        (self.repo / "docs/contract.md").write_text("changed contract")
        self.assertNotEqual(before["fingerprint"], self.snapshot()["fingerprint"])

    def test_generated_outputs_and_ignored_private_files_do_not_change_fingerprint(self):
        before = self.snapshot()
        self.run_directory.mkdir(parents=True)
        (self.run_directory / "summary.json").write_text("output")
        (self.repo / ".signing.env").write_text("PRIVATE_KEY=never-log-this")
        (self.repo / "Sources/__pycache__").mkdir()
        (self.repo / "Sources/__pycache__/fixture.pyc").write_bytes(b"output")
        self.assertEqual(before, self.snapshot())
        self.assertNotIn("never-log-this", json.dumps(self.snapshot()))

    def test_changed_source_report_contains_hashes_not_contents(self):
        (self.repo / "Sources/example.swift").write_text("sensitive fixture content")
        snapshot = self.snapshot()
        self.assertIn("Sources/example.swift", snapshot["changed_files"])
        self.assertNotIn("sensitive fixture content", json.dumps(snapshot))
        self.assertEqual(len(snapshot["changed_files"]["Sources/example.swift"]["sha256"]), 64)

    def test_website_dist_sources_are_fingerprinted_but_generated_worker_is_not(self):
        dist = self.repo / "website/dist"
        dist.mkdir(parents=True)
        (dist / "index.html").write_text("source page")
        before = self.snapshot()
        self.assertIn("website/dist/index.html", before["changed_files"])
        (dist / "server").mkdir()
        (dist / "server/index.js").write_text("generated worker")
        self.assertEqual(before, self.snapshot())
        (dist / "index.html").write_text("changed page")
        self.assertNotEqual(before["fingerprint"], self.snapshot()["fingerprint"])

    def test_symlink_fingerprint_does_not_read_its_external_target(self):
        (self.repo / "Sources/external.swift").symlink_to("/path/which/does/not/exist")
        self.assertEqual(self.snapshot()["changed_files"]["Sources/external.swift"]["kind"], "symlink")


if __name__ == "__main__":
    unittest.main()
