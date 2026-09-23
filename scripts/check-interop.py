#!/usr/bin/env python3
"""Run the loopback protocol fixture with bounded setup and execution."""
from pathlib import Path
import selectors
import subprocess

root = Path(__file__).resolve().parents[1]
subprocess.run(["swift", "build", "--package-path", "Integration", "-c", "release"], cwd=root, check=True, timeout=600)
fixture = subprocess.Popen(
    ["uv", "run", "--python", "3.12", "--with", "aiosendspin[server]==9.1.1", "scripts/sendspin-fixture.py"],
    cwd=root, stdout=subprocess.PIPE, text=True,
)
try:
    with selectors.DefaultSelector() as selector:
        selector.register(fixture.stdout, selectors.EVENT_READ)
        if not selector.select(timeout=120):
            raise RuntimeError("Fixture did not start within 120 seconds")
        address = fixture.stdout.readline().strip()
    if not address.startswith("http://127.0.0.1:"):
        raise RuntimeError("Fixture did not provide a loopback URL")
    subprocess.run(["swift", "run", "--skip-build", "--package-path", "Integration", "-c", "release", "SendspinInterop", address],
                   cwd=root, check=True, timeout=60)
finally:
    fixture.terminate()
    try:
        fixture.wait(timeout=10)
    except subprocess.TimeoutExpired:
        fixture.kill()
        fixture.wait()
