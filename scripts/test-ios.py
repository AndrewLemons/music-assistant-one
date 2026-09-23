#!/usr/bin/env python3
"""Select an available iOS 27+ iPhone instead of hard-coding a runner's device name."""
import json
import subprocess

available = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
devices = [device for runtime, entries in available["devices"].items()
           if ".iOS-" in runtime and int(runtime.split(".iOS-")[1].split("-")[0]) >= 27
           for device in entries if device["name"].startswith("iPhone")]
if not devices:
    raise SystemExit("Install an iOS 27+ iPhone simulator runtime in Xcode.")
subprocess.run([
    "xcodebuild", "-project", "MusicAssistantOne.xcodeproj", "-scheme", "MusicAssistantOne",
    "-destination", "platform=iOS Simulator,id=" + devices[0]["udid"],
    "-derivedDataPath", "DerivedData-ci", "CODE_SIGNING_ALLOWED=NO", "test",
], check=True, timeout=1200)
