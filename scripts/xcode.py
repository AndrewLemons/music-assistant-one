#!/usr/bin/env python3
"""Build and test the app the same way locally and in CI.

  xcode.py build --platform macos|ios        Unsigned Release build
  xcode.py test --suite unit|ui              Simulator tests on an iOS 27+ iPhone
  xcode.py archive / export                  Signed delivery builds (used by the release workflow)

xcodebuild's complete output goes to artifacts/ci/<name>.log. The console shows errors, test
results, and the end of the log on failure. In GitHub Actions, first-party compiler errors
become annotations and a result summary is written to the job summary.
"""
import argparse
from collections import deque
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "artifacts" / "ci"
DERIVED_DATA = ROOT / "DerivedData-ci"
PROJECT = ["-project", "MusicAssistantOne.xcodeproj", "-scheme", "MusicAssistantOne"]
# Settings shared by every CI build: no signing identity, no indexing, and exactly the
# committed package versions (a lock change must be reviewed, never resolved silently).
COMMON = ["-derivedDataPath", str(DERIVED_DATA), "-onlyUsePackageVersionsFromResolvedFile", "-showBuildTimingSummary",
          "CODE_SIGNING_ALLOWED=NO", "COMPILER_INDEX_STORE_ENABLE=NO"]
# Runners and current Macs are Apple silicon; an Intel simulator slice doubles the work for nothing.
SIMULATOR = ["ARCHS=arm64"]
DESTINATIONS = {"macos": "generic/platform=macOS", "ios": "generic/platform=iOS Simulator"}
SUITES = {"unit": "PlaybackTests", "ui": "MusicAssistantOneUITests"}
CONSOLE = re.compile(r"error:|\*\* (BUILD|TEST|ARCHIVE|EXPORT)|Test Case .* (passed|failed) \(|"
                     r"^\s*✘|^✔ Test run|Executed \d+ test|Testing failed|encountered an error|"
                     r"Failing tests:|^\s+\S+\(\) \(|Restarting after")
DIAGNOSTIC = re.compile(r"^(/[^:]+):(\d+):(?:(\d+):)? (error): (.*)$")
# The runner never started, so retrying is not hiding a product failure.
INFRASTRUCTURE = re.compile(r"failed to initialize for UI testing|Timed out waiting for AX loaded|"
                            r"Failed to (?:boot|prepare|install|connect to) .*[Ss]imulator|"
                            r"Test runner exited before starting test execution|"
                            r"The test runner (?:hung|timed out|failed to initialize)", re.I)


def in_ci():
    return os.environ.get("GITHUB_ACTIONS") == "true"


def write_summary(markdown):
    if path := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(path, "a") as file:
            file.write(markdown + "\n")
    else:
        print(markdown)


def annotate(line, seen):
    """Turn a first-party compiler error into a GitHub annotation, once per location."""
    match = DIAGNOSTIC.match(line)
    if not match or not in_ci():
        return
    path, number, column, _, message = match.groups()
    try:
        relative = Path(path).resolve().relative_to(ROOT)
    except ValueError:
        return
    if relative.parts[0] in {".dependencies", "DerivedData-ci"} or (relative, number) in seen:
        return
    seen.add((relative, number))
    message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::error file={relative},line={number},col={column or 1}::{message}", flush=True)


def xcodebuild(name, arguments, timeout, project=True):
    """Run xcodebuild, keeping its full output in a log. Returns (exit status, log path)."""
    OUTPUT.mkdir(parents=True, exist_ok=True)
    log = OUTPUT / f"{name}.log"
    command = ["xcodebuild", *(PROJECT if project else []), *arguments]
    print("+ " + " ".join(command), flush=True)
    started, tail, seen = time.monotonic(), deque(maxlen=150), set()
    with open(log, "w") as file, subprocess.Popen(
            command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            errors="replace") as process:
        # A watchdog, because a hung xcodebuild may print nothing at all.
        watchdog = threading.Timer(timeout, process.kill)
        watchdog.start()
        try:
            for line in process.stdout:
                # Elapsed seconds make stalls visible when reading a slow build's log.
                file.write(f"[{time.monotonic() - started:7.1f}] {line}")
                tail.append(line)
                if CONSOLE.search(line):
                    print(line, end="", flush=True)
                annotate(line.rstrip("\n"), seen)
        finally:
            status = process.wait()
            if not watchdog.is_alive():
                print(f"::error::xcodebuild exceeded {timeout // 60} minutes and was stopped.")
                status = status or 1
            watchdog.cancel()
    print(f"xcodebuild finished with status {status} in {int(time.monotonic() - started)}s; log: {log}")
    if timing := timing_summary(log.read_text(errors="replace")):
        print("Slowest build tasks (CPU time across cores):\n" + "\n".join(f"  {row}" for row in timing))
        write_summary(f"<details><summary>{name}: slowest build tasks</summary>\n\n" +
                      "\n".join(f"- {row}" for row in timing) + "\n</details>\n")
    if status:
        print("::group::Last lines of the xcodebuild log" if in_ci() else "--- last lines ---")
        print("".join(tail), end="")
        if in_ci():
            print("::endgroup::")
    return status, log


def timing_summary(text, limit=8):
    """The top entries of xcodebuild's -showBuildTimingSummary, such as "SwiftCompile (98 tasks) | 98.9 seconds"."""
    section = text.rsplit("Build Timing Summary", 1)
    if len(section) < 2:
        return []
    rows = re.findall(r"^(?:\[ *[\d.]+\] )?(\S.*? \(\d+ tasks?\) \| [\d.]+ seconds)$", section[1], re.M)
    return rows[:limit]


def cache_settings(cache):
    """Xcode's compilation cache, persisted by CI between runs. Never used for shipped builds."""
    if not cache:
        return []
    return ["COMPILATION_CACHE_ENABLE_CACHING=YES", f"COMPILATION_CACHE_CAS_PATH={Path(cache).resolve()}"]


def build(options):
    arguments = ["-configuration", "Release", "-destination", DESTINATIONS[options.platform], *COMMON,
                 *(SIMULATOR if options.platform == "ios" else []), *cache_settings(options.cache), "build"]
    status, _ = xcodebuild(f"build-{options.platform}", arguments, timeout=40 * 60)
    return status


STANDARD_IPHONE = re.compile(r"^iPhone (\d+)( Pro)?$")


def choose_simulator(listing):
    """The newest iOS 27+ runtime's standard iPhone ("iPhone N Pro", else "iPhone N").

    Images also carry unusual models (an "iPhone Duo" once got a wide layout without a tab bar
    and failed UI tests that pass on every regular iPhone), so other models are a last resort."""
    candidates = []
    for runtime, devices in listing["devices"].items():
        match = re.search(r"\.iOS-(\d+)-(\d+)", runtime)
        if not match or int(match[1]) < 27:
            continue
        for device in devices:
            if not device["name"].startswith("iPhone"):
                continue
            standard = STANDARD_IPHONE.match(device["name"])
            rank = (2 if standard[2] else 1, int(standard[1])) if standard else (0, 0)
            candidates.append(((int(match[1]), int(match[2])), rank, device["name"], device["udid"]))
    if not candidates:
        raise SystemExit("Install an iOS 27+ iPhone simulator runtime in Xcode.")
    # A standard model outranks a newer runtime that has none.
    version, _, name, udid = max(candidates, key=lambda c: (c[1][0] > 0, c[0], c[1], c[2]))
    return version, name, udid


def simulator():
    listing = json.loads(subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True))
    version, name, udid = choose_simulator(listing)
    print(f"Simulator: {name}, iOS {version[0]}.{version[1]} ({udid})")
    return udid


def start_boot(udid, erase=False):
    """Begin booting without waiting, so the boot overlaps the build."""
    if erase:
        subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
        subprocess.run(["xcrun", "simctl", "erase", udid], check=True, timeout=300)
    subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True)


def wait_for_boot(udid):
    # Testing only once the simulator is fully booted avoids the runner racing a cold device,
    # which caused "Timed out waiting for AX loaded notification" failures in CI.
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, timeout=600,
                   stdout=subprocess.DEVNULL)


def xcresult(path, *query):
    output = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", *query, "--path", str(path),
                             "--compact"], capture_output=True, text=True)
    return json.loads(output.stdout) if output.returncode == 0 and output.stdout.strip() else None


def flaky_tests(nodes, parents=()):
    """Tests that passed only after a retry: a passing test case with a failed repetition."""
    found = []
    for node in nodes or []:
        path = (*parents, node.get("name", "?"))
        children = node.get("children") or []
        if node.get("nodeType") == "Test Case":
            repetitions = [child for child in children if child.get("nodeType") == "Repetition"]
            if node.get("result") == "Passed" and any(r.get("result") == "Failed" for r in repetitions):
                found.append(" › ".join(path[-2:]))
        else:
            found += flaky_tests(children, path)
    return found


def summarize(suite, bundle, coverage):
    summary = xcresult(bundle, "summary")
    if summary is None:
        write_summary(f"### {suite} tests\nNo result bundle was produced.")
        return None
    lines = [f"### {suite} tests: {summary.get('result', 'Unknown')}", "",
             f"{summary.get('passedTests', 0)} passed, {summary.get('failedTests', 0)} failed, "
             f"{summary.get('skippedTests', 0)} skipped of {summary.get('totalTestCount', 0)}."]
    for failure in summary.get("testFailures", [])[:20]:
        text = failure.get("failureText", "").strip().splitlines()[0][:300] if failure.get("failureText") else ""
        lines.append(f"- ✘ `{failure.get('testName', '?')}` {text}")
    flaky = flaky_tests((xcresult(bundle, "tests") or {}).get("testNodes"))
    if flaky:
        lines += ["", "**Passed only after a retry (flaky):**", *[f"- ⚠️ `{name}`" for name in flaky]]
        for name in flaky:
            print(f"::warning title=Flaky test::{name} failed, then passed when retried.")
    if coverage:
        lines += coverage_table(bundle)
    write_summary("\n".join(lines))
    return summary


def coverage_table(bundle):
    report = subprocess.run(["xcrun", "xccov", "view", "--report", "--only-targets", "--json", str(bundle)],
                            capture_output=True, text=True)
    if report.returncode:
        return ["", "Coverage report unavailable."]
    rows = [(target["name"], target["lineCoverage"], target["coveredLines"], target["executableLines"])
            for target in json.loads(report.stdout) if not target["name"].endswith(".xctest")]
    lines = ["", "| Target | Line coverage | Lines |", "| --- | ---: | ---: |"]
    lines += [f"| {name} | {rate:.1%} | {covered}/{total} |" for name, rate, covered, total in sorted(rows)]
    return lines


def test(options):
    """Build once while the simulator boots, then test; an infrastructure retry reuses the build."""
    udid = simulator()
    started = time.monotonic()
    phases = []
    start_boot(udid)
    coverage = ["-enableCodeCoverage", "YES"] if options.coverage else []
    only = f"-only-testing:{SUITES[options.suite]}"
    status, _ = xcodebuild(f"build-for-testing-{options.suite}", [
        "-configuration", "Debug", "-destination", DESTINATIONS["ios"], *COMMON, *SIMULATOR, *cache_settings(options.cache),
        *coverage, only, "build-for-testing"], timeout=options.timeout * 60)
    phases.append(("Build", time.monotonic() - started))
    if status:
        write_timings(options.suite, phases)
        return status
    bundle = OUTPUT / f"test-{options.suite}.xcresult"
    arguments = ["-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={udid}", *COMMON, *SIMULATOR,
                 *coverage, only, "-resultBundlePath", str(bundle),
                 # Collecting diagnostics after a failure once hung for the full 600 s default.
                 "-collect-test-diagnostics", "never",
                 "-test-timeouts-enabled", "YES",
                 "-default-test-execution-time-allowance", "300",
                 "-maximum-test-execution-time-allowance", "600"]
    if options.retries:
        arguments += ["-retry-tests-on-failure", "-test-iterations", str(options.retries + 1)]
    for attempt in range(options.infrastructure_retries + 1):
        if attempt:
            start_boot(udid, erase=True)
        mark = time.monotonic()
        wait_for_boot(udid)
        phases.append(("Simulator ready" + (" (retry)" if attempt else ""), time.monotonic() - mark))
        shutil.rmtree(bundle, ignore_errors=True)
        mark = time.monotonic()
        status, log = xcodebuild(f"test-{options.suite}", [*arguments, "test-without-building"],
                                 timeout=options.timeout * 60)
        phases.append(("Tests" + (" (retry)" if attempt else ""), time.monotonic() - mark))
        summary = summarize(options.suite, bundle, options.coverage)
        infrastructure = status and INFRASTRUCTURE.search(log.read_text(errors="replace")) and \
            not (summary and summary.get("failedTests"))
        if not infrastructure or attempt == options.infrastructure_retries:
            break
        print("::warning title=Simulator failure::The test runner did not start; erasing the simulator "
              "and running the tests again.")
    write_timings(options.suite, phases)
    return status


def write_timings(suite, phases):
    rows = " · ".join(f"{name} {seconds / 60:.1f} min" for name, seconds in phases)
    print(f"{suite} timings: {rows}")
    write_summary(f"<sub>{suite} timings: {rows}</sub>\n")


def authentication():
    """App Store Connect API key arguments, so Xcode can manage signing without an Apple Account."""
    keys = ("ASC_KEY_PATH", "ASC_KEY_ID", "ASC_ISSUER_ID")
    if not all(os.environ.get(key) for key in keys):
        raise SystemExit(f"Set {', '.join(keys)} for signed delivery builds.")
    return ["-allowProvisioningUpdates", "-authenticationKeyPath", os.environ["ASC_KEY_PATH"],
            "-authenticationKeyID", os.environ["ASC_KEY_ID"], "-authenticationKeyIssuerID", os.environ["ASC_ISSUER_ID"]]


def bundle_versions(archive):
    """(path, short version, build) for each app and extension in an archive."""
    found = []
    bundles = [path for path in Path(archive, "Products").rglob("*")
               if path.suffix in {".app", ".appex"} and path.is_dir()]
    for bundle in sorted(bundles, key=lambda path: (len(path.parts), str(path))):
        info = next((p for p in (bundle / "Info.plist", bundle / "Contents/Info.plist") if p.is_file()), None)
        if info is None:
            found.append((bundle.name, None, None))
            continue
        values = plistlib.loads(info.read_bytes())
        found.append((bundle.name, values.get("CFBundleShortVersionString"), values.get("CFBundleVersion")))
    return found


def archive(options):
    """A clean, signed Release archive for delivery. Never uses the compilation cache."""
    signing = [f"DEVELOPMENT_TEAM={options.team}"]
    if options.platform == "ios":
        signing += authentication()
    else:
        # Developer ID signing from the stored certificate and the API-provisioned profile.
        # Automatic signing would register each ephemeral runner as a development Mac.
        signing += ["CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=Developer ID Application",
                    f"PROVISIONING_PROFILE_SPECIFIER={options.profile}"]
    destination = {"ios": "generic/platform=iOS", "macos": "generic/platform=macOS"}[options.platform]
    arguments = ["-configuration", "Release", "-destination", destination,
                 "-derivedDataPath", str(ROOT / "DerivedData-release"), "-onlyUsePackageVersionsFromResolvedFile",
                 "-archivePath", options.path, "COMPILER_INDEX_STORE_ENABLE=NO",
                 f"MARKETING_VERSION={options.version}", f"CURRENT_PROJECT_VERSION={options.build}",
                 *signing, "archive"]
    status, _ = xcodebuild(f"archive-{options.platform}", arguments, timeout=45 * 60)
    if status:
        return status
    versions = bundle_versions(options.path)
    for name, short, build in versions:
        print(f"{name}: {short} ({build})")
    wrong = [v for v in versions if v[1:] != (options.version, str(options.build))]
    if not versions or wrong:
        print(f"::error::Archived bundles do not all have version {options.version} ({options.build}): {wrong}")
        return 1
    return 0


def export(options):
    arguments = ["-exportArchive", "-archivePath", options.archive, "-exportOptionsPlist", options.options,
                 "-exportPath", options.path]
    if options.upload:
        arguments += authentication()
    # -exportArchive takes no project or scheme.
    status, _ = xcodebuild("export", arguments, timeout=40 * 60, project=False)
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    archive_parser = commands.add_parser("archive", help="Signed Release archive for delivery")
    archive_parser.add_argument("--platform", choices=["ios", "macos"], required=True)
    archive_parser.add_argument("--path", required=True, help="Output .xcarchive")
    archive_parser.add_argument("--version", required=True)
    archive_parser.add_argument("--build", type=int, required=True)
    archive_parser.add_argument("--team", required=True)
    archive_parser.add_argument("--profile", help="Developer ID provisioning profile UUID (macOS)")
    export_parser = commands.add_parser("export", help="Export (and optionally upload) an archive")
    export_parser.add_argument("--archive", required=True)
    export_parser.add_argument("--options", required=True)
    export_parser.add_argument("--path", required=True)
    export_parser.add_argument("--upload", action="store_true", help="Authenticate for App Store Connect upload")
    build_parser = commands.add_parser("build")
    build_parser.add_argument("--platform", choices=DESTINATIONS, required=True)
    test_parser = commands.add_parser("test")
    test_parser.add_argument("--suite", choices=SUITES, required=True)
    test_parser.add_argument("--retries", type=int, default=0, help="Retry each failing test this many times")
    test_parser.add_argument("--infrastructure-retries", type=int, default=0,
                             help="Rerun the suite on a fresh simulator if the test runner never starts")
    test_parser.add_argument("--coverage", action="store_true")
    test_parser.add_argument("--timeout", type=int, default=30, help="Minutes before xcodebuild is stopped")
    for subparser in (build_parser, test_parser):
        subparser.add_argument("--cache", help="Compilation cache directory (CI only)")
    options = parser.parse_args()
    if options.command == "archive" and options.platform == "macos" and not options.profile:
        parser.error("--profile is required for a macOS archive")
    return {"build": build, "test": test, "archive": archive, "export": export}[options.command](options)


if __name__ == "__main__":
    sys.exit(main())
