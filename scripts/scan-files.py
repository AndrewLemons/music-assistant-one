#!/usr/bin/env python3
"""Scan exactly the files eligible for a normal git add, including new files."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
files = subprocess.check_output(
    ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=root
).decode().split("\0")
with tempfile.TemporaryDirectory() as temporary:
    for name in set(files) - {""}:
        source = root / name
        if source.is_symlink():
            raise SystemExit(f"Review symlink before publishing: {name}")
        if not source.is_file():
            continue
        destination = Path(temporary) / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    subprocess.run(["gitleaks", "dir", "--redact", temporary], check=True)
