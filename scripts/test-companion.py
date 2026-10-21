#!/usr/bin/env python3
"""Run the optional provider's HTTP tests in an isolated, pinned environment."""

import hashlib
import os
from pathlib import Path
import subprocess
import sys
import venv

root = Path(__file__).resolve().parents[1]
environment = root / ".build" / "companion-tests"
python = environment / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
requirements = root / "ServerCompanion" / "requirements-test.txt"
fingerprint = hashlib.sha256(requirements.read_bytes()).hexdigest()
marker = environment / ".requirements.sha256"
if not python.exists():
    venv.create(environment, with_pip=True)
if not marker.exists() or marker.read_text() != fingerprint:
    subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check", "--quiet",
                    "-r", str(requirements)], check=True, timeout=180)
    marker.write_text(fingerprint)
subprocess.run([str(python), "-m", "unittest", "discover", "-s", "ServerCompanion/tests", "-v"],
               cwd=root, check=True, timeout=120)
