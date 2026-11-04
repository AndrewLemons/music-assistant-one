#!/usr/bin/env python3
"""Run a Swift package's tests with coverage and report line coverage for its Sources.

  swiftpm-coverage.py PACKAGE_PATH

The report goes to $GITHUB_STEP_SUMMARY when set, otherwise to standard output.
"""
import json
import os
from pathlib import Path
import subprocess
import sys


def report(export, sources):
    """Markdown for an `llvm-cov export` document, limited to files under `sources`."""
    files = [(Path(f["filename"]).relative_to(sources), f["summary"]["lines"])
             for f in export["data"][0]["files"] if Path(f["filename"]).is_relative_to(sources)]
    covered = sum(lines["covered"] for _, lines in files)
    total = sum(lines["count"] for _, lines in files)
    rate = covered / total if total else 0
    rows = [f"| {path} | {lines['percent'] / 100:.1%} | {lines['covered']}/{lines['count']} |"
            for path, lines in sorted(files, key=lambda item: item[1]["percent"])]
    return "\n".join([f"### {sources.parent.name} coverage: {rate:.1%} of lines ({covered}/{total})", "",
                      "<details><summary>By file</summary>", "",
                      "| File | Lines | Covered |", "| --- | ---: | ---: |", *rows, "", "</details>"])


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    package = Path(sys.argv[1]).resolve()
    subprocess.run(["swift", "test", "--package-path", str(package), "--enable-code-coverage"], check=True,
                   timeout=1200)
    path = subprocess.check_output(["swift", "test", "--package-path", str(package), "--show-codecov-path"],
                                   text=True).strip()
    markdown = report(json.loads(Path(path).read_text()), package / "Sources")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a") as file:
            file.write(markdown + "\n")
    print(markdown)


if __name__ == "__main__":
    main()
