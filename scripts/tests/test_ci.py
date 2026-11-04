"""Tests for the CI helpers: change detection, the Xcode driver's result parsing, and coverage."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


changes = load("changes", "ci/changes.py")
xcode = load("xcode", "xcode.py")
coverage = load("swiftpm_coverage", "ci/swiftpm-coverage.py")


class ChangeDetectionTests(unittest.TestCase):
    def test_documentation_only_runs_nothing(self):
        self.assertEqual(changes.classify(["README.md", "docs/RELEASING.md", ".github/workflows/release.yml"]),
                         {"app": False, "server": False})

    def test_app_sources_run_the_app_suites(self):
        self.assertEqual(changes.classify(["App/AppModel.swift"]), {"app": True, "server": False})

    def test_bundled_notices_count_as_app_changes(self):
        self.assertTrue(changes.classify(["THIRD_PARTY_NOTICES.md"])["app"])

    def test_unknown_paths_fail_open(self):
        self.assertTrue(changes.classify(["NewModule/Thing.swift"])["app"])
        self.assertTrue(changes.classify(["Config/Version.xcconfig"])["app"])

    def test_server_changes_build_only_the_image(self):
        self.assertEqual(changes.classify(["ServerCompanion/Dockerfile", "ServerCompanion/README.md"]),
                         {"app": False, "server": True})

    def test_pipeline_changes_run_everything(self):
        for path in ("Makefile", "mise.lock", ".github/workflows/ci.yml"):
            self.assertEqual(changes.classify([path]), {"app": True, "server": True})

    def test_no_files_runs_nothing(self):
        self.assertEqual(changes.classify([]), {"app": False, "server": False})


class XcodeDriverTests(unittest.TestCase):
    def test_flaky_detection_needs_a_failed_repetition_and_a_final_pass(self):
        def case(name, result, *repetitions):
            return {"nodeType": "Test Case", "name": name, "result": result,
                    "children": [{"nodeType": "Repetition", "result": r} for r in repetitions]}
        nodes = [{"nodeType": "Test Plan", "name": "Plan", "children": [
            {"nodeType": "Unit test bundle", "name": "PlaybackTests", "children": [
                case("flaky()", "Passed", "Failed", "Passed"),
                case("broken()", "Failed", "Failed", "Failed"),
                case("steady()", "Passed"),
            ]}]}]
        self.assertEqual(xcode.flaky_tests(nodes), ["PlaybackTests › flaky()"])

    def test_infrastructure_failures_are_recognized(self):
        for line in ("MusicAssistantOneUITests-Runner (27600) encountered an error (The test runner failed to "
                     "initialize for UI testing. (Underlying Error: Timed out waiting for AX loaded notification))",
                     "Test runner exited before starting test execution."):
            self.assertTrue(xcode.INFRASTRUCTURE.search(line), line)
        self.assertIsNone(xcode.INFRASTRUCTURE.search("XCTAssertTrue failed"))

    def test_archive_versions_cover_the_app_and_extensions_but_not_frameworks(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory, "Products/Applications/Music Assistant One.app")
            for path, version in [(app, "1"), (app / "Extensions/RemoteMedia.appex", "1"),
                                  (app / "Frameworks/FLAC.framework", "999")]:
                path.mkdir(parents=True)
                (path / "Info.plist").write_bytes(plistlib.dumps(
                    {"CFBundleShortVersionString": "0.2.0", "CFBundleVersion": version}))
            self.assertEqual(xcode.bundle_versions(directory), [
                ("Music Assistant One.app", "0.2.0", "1"), ("RemoteMedia.appex", "0.2.0", "1")])

    def test_mac_bundle_versions_are_read_from_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            contents = Path(directory, "Products/Applications/Music Assistant One.app/Contents")
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_bytes(plistlib.dumps(
                {"CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "12"}))
            self.assertEqual(xcode.bundle_versions(directory), [("Music Assistant One.app", "0.2.0", "12")])


class CoverageTests(unittest.TestCase):
    def test_report_counts_only_package_sources(self):
        sources = Path("/repo/Core/Sources")
        export = {"data": [{"files": [
            {"filename": "/repo/Core/Sources/A.swift", "summary": {"lines": {"count": 10, "covered": 9, "percent": 90}}},
            {"filename": "/repo/Core/Sources/B.swift", "summary": {"lines": {"count": 10, "covered": 1, "percent": 10}}},
            {"filename": "/repo/Core/Tests/T.swift", "summary": {"lines": {"count": 50, "covered": 50, "percent": 100}}},
        ]}]}
        markdown = coverage.report(export, sources)
        self.assertIn("Core coverage: 50.0% of lines (10/20)", markdown)
        self.assertNotIn("T.swift", markdown)
        self.assertLess(markdown.index("B.swift"), markdown.index("A.swift"))  # Least covered first.


if __name__ == "__main__":
    unittest.main()
