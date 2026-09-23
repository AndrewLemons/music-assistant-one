#!/usr/bin/env python3
"""Materialize the exact compatibility dependency; never edit SwiftPM's cache."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def git(directory, *args):
    return subprocess.check_output(["git", "-C", str(directory), *args], text=True)


def main():
    lock = json.loads((ROOT / "patches/sendspinkit.json").read_text())
    patch = ROOT / lock["patch"]
    if hashlib.sha256(patch.read_bytes()).hexdigest() != lock["sha256"]:
        raise SystemExit("Patch checksum mismatch; review the patch and update its lock.")
    destination = ROOT / ".dependencies/SendspinKit"
    destination.parent.mkdir(exist_ok=True)
    if not destination.exists():
        with tempfile.TemporaryDirectory(dir=destination.parent) as temporary:
            checkout = Path(temporary) / "SendspinKit"
            subprocess.run(["git", "init", "-q", str(checkout)], check=True)
            git(checkout, "remote", "add", "origin", lock["url"])
            git(checkout, "fetch", "--depth=1", "origin", lock["revision"])
            git(checkout, "checkout", "--detach", "FETCH_HEAD")
            git(checkout, "apply", "--check", str(patch))
            git(checkout, "apply", str(patch))
            checkout.rename(destination)
    if git(destination, "rev-parse", "HEAD").strip() != lock["revision"]:
        raise SystemExit("Dependency revision differs from lock; move .dependencies/SendspinKit aside and retry.")
    if git(destination, "remote", "get-url", "origin").strip() != lock["url"]:
        raise SystemExit("Unexpected dependency origin.")
    # Compare the complete tracked diff, not just a marker or the patched lines.
    expected = subprocess.check_output(
        ["git", "apply", "--numstat", str(patch)], text=True
    )
    if git(destination, "diff", "HEAD", "--numstat") != expected:
        raise SystemExit("Dependency has unexpected changes; move it aside and retry.")
    git(destination, "apply", "--reverse", "--check", str(patch))
    # Verify the entire tree against the expected patched tree in a temporary index.
    import os
    with tempfile.TemporaryDirectory() as temporary:
        env = dict(os.environ, GIT_INDEX_FILE=str(Path(temporary) / "index"))
        command = ["git", "-C", str(destination)]
        subprocess.run(command + ["read-tree", "HEAD"], env=env, check=True)
        subprocess.run(command + ["apply", "--cached", str(patch)], env=env, check=True)
        subprocess.run(command + ["diff", "--exit-code"], env=env, check=True, stdout=subprocess.DEVNULL)
    if git(destination, "ls-files", "--others", "--exclude-standard").strip():
        raise SystemExit("Dependency contains unexpected untracked files.")
    print("SendspinKit revision and compatibility patch verified.")


if __name__ == "__main__":
    main()
