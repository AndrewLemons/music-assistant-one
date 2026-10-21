#!/usr/bin/env python3
"""Check version metadata, dependency lock parity, and private-file exclusions."""
import importlib.util
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[1]
version = (root / "version.txt").read_text().strip()
config = (root / "Config/Version.xcconfig").read_text()
assert re.search(r"^MARKETING_VERSION = " + re.escape(version) + r" //", config, re.M)
assert re.search(r"^CURRENT_PROJECT_VERSION = [1-9][0-9]*$", config, re.M)
assert json.loads((root / ".release-please-manifest.json").read_text())["."] == version
locks = [root / "Integration/Package.resolved", root / "MusicAssistantOne.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"]
# Xcode also resolves the dependency's documentation plugins; SwiftPM prunes them.
def runtime_pins(path):
    return [pin for pin in json.loads(path.read_text())["pins"]
            if pin["identity"] not in {"swift-docc-plugin", "swift-docc-symbolkit"}]
assert runtime_pins(locks[0]) == runtime_pins(locks[1]), "Runtime dependency locks differ"
# The server image's base is the supported Music Assistant version; user-facing text must agree.
spec = importlib.util.spec_from_file_location("server_image", root / "scripts/server-image.py")
server_image = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server_image)
server = server_image.music_assistant_version()
for path, text in [("README.md", f"Music Assistant **{server}**"), ("ServerCompanion/README.md", f"Music Assistant **{server}**"),
                   ("App/Services/LocalPlayer.swift", f"Music Assistant {server}.")]:
    assert text in (root / path).read_text(), f"ServerCompanion/Dockerfile targets {server}; update the supported version in {path}"
files = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
for name in files:
    assert not re.search(r"(^|/)(Vendor|\.dependencies|xcuserdata|artifacts|DerivedData[^/]*)/|\.local\.xcconfig$|\.(p12|p8|pem|key|mobileprovision|provisionprofile)$", name), f"Private/generated file tracked: {name}"
print("Repository metadata checks passed.")
