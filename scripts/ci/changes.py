#!/usr/bin/env python3
"""Decide which CI suites a change needs, failing open to running everything.

Pull requests list their changed files through the GitHub API. Pushes, manual runs, and
any lookup problem run every suite: skipping is an optimization, never a correctness risk.

Writes `app=true|false` and `server=true|false` to $GITHUB_OUTPUT (or prints them).
"""
from fnmatch import fnmatch
import json
import os
import subprocess
import sys

# Files that never affect a build, test, or image. Anything unlisted counts as app code, so a
# new top-level directory is tested until someone decides otherwise.
DOCUMENTATION = (
    "docs/*", "*.md", ".github/ISSUE_TEMPLATE/*", ".github/pull_request_template.md",
    ".github/CODEOWNERS", ".github/dependabot.yml", ".github/workflows/pr-title.yml",
    ".github/workflows/release.yml", ".github/workflows/tools-update.yml", ".github/workflows/certificates.yml",
    ".github/zizmor.yml",
    ".github/actionlint.yaml", ".editorconfig", ".gitignore", ".gitleaks.toml",
    "release-please-config.json", ".release-please-manifest.json", "version.txt",
    "scripts/release/*", "scripts/ci/changes.py", "scripts/tests/*", "scripts/playback-research/*",
    "scripts/check-pr-title.py", "scripts/check-repository.py", "scripts/scan-files.py",
    "scripts/benchmark-playback.py", ".vscode/*",
)
# Bundled into the app even though they are Markdown or plain text.
APP_RESOURCES = ("THIRD_PARTY_NOTICES.md", "LICENSE", "NOTICE")
SERVER = ("ServerCompanion/*", "scripts/server-image.py", "scripts/test-companion.py",
          ".github/workflows/server-image.yml")
# Changing the pipeline itself must exercise every suite it defines.
EVERYTHING = (".github/workflows/ci.yml", "Makefile", "mise.toml", "mise.lock")


def matches(path, patterns):
    return any(fnmatch(path, pattern) for pattern in patterns)


def classify(paths):
    suites = {"app": False, "server": False}
    for path in paths:
        if matches(path, EVERYTHING):
            return {suite: True for suite in suites}
        if matches(path, SERVER):
            suites["server"] = True
        elif matches(path, APP_RESOURCES) or not matches(path, DOCUMENTATION):
            suites["app"] = True
    return suites


def pull_request_files(repository, number):
    output = subprocess.check_output(
        ["gh", "api", "--paginate", f"repos/{repository}/pulls/{number}/files?per_page=100",
         "--jq", ".[] | .filename, (.previous_filename // empty)"], text=True, timeout=120)
    return [line for line in output.splitlines() if line]


def main():
    event = os.environ.get("GITHUB_EVENT_NAME", "")
    suites = {"app": True, "server": True}
    if event == "pull_request":
        with open(os.environ["GITHUB_EVENT_PATH"]) as file:
            pull = json.load(file)["pull_request"]
        try:
            files = pull_request_files(os.environ["GITHUB_REPOSITORY"], pull["number"])
        except (subprocess.SubprocessError, OSError) as error:
            print(f"::warning::Could not list changed files ({error}); running every suite.")
        else:
            # The files endpoint stops at 3000 entries; a truncated list must not skip suites.
            if files and len(files) < 3000:
                suites = classify(files)
            print("\n".join(f"changed: {path}" for path in files))
    lines = [f"{suite}={str(value).lower()}" for suite, value in suites.items()]
    print("\n".join(lines))
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as file:
            file.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    sys.exit(main())
