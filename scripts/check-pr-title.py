#!/usr/bin/env python3
"""Validate PR titles without interpolating untrusted text into a shell command."""
import os
import re

if not re.fullmatch(r"(?:feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(?:\([\w./-]+\))?!?: \S[^\r\n]*", os.environ["PR_TITLE"]):
    raise SystemExit("Use a Conventional Commit PR title, e.g. fix(playback): reconnect after network loss")
