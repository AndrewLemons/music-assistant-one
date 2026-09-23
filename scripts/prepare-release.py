#!/usr/bin/env python3
"""Update only release PR metadata through the API; never execute PR content."""
import base64
import json
import os
import re
import subprocess
from urllib.parse import quote

PATTERN = re.compile(r"^CURRENT_PROJECT_VERSION = ([1-9][0-9]*)$", re.M)


def reserve_build(base, proposed):
    baseline = PATTERN.search(base)
    current = PATTERN.search(proposed)
    if not baseline or not current:
        raise ValueError("Missing integer build number")
    number = max(int(baseline[1]) + 1, int(current[1]))
    return PATTERN.sub(f"CURRENT_PROJECT_VERSION = {number}", proposed)


def api(path, payload=None):
    command = ["gh", "api", path]
    if payload is not None:
        command += ["--method", "PUT", "--input", "-"]
    return json.loads(subprocess.check_output(
        command, input=json.dumps(payload) if payload is not None else None, text=True
    ))


def main():
    repository = os.environ["GITHUB_REPOSITORY"]
    for summary in json.loads(os.environ["RELEASE_PRS"]):
        pr = api(f"repos/{repository}/pulls/{int(summary['number'])}")
        branch = pr["head"]["ref"]
        if (pr["head"]["repo"]["full_name"] != repository
                or not branch.startswith("release-please--") or pr["base"]["ref"] != "main"):
            raise ValueError("Unexpected release PR source or target")
        path = f"repos/{repository}/contents/Config/Version.xcconfig"
        base = api(path + "?ref=" + quote(pr["base"]["sha"], safe=""))
        head = api(path + "?ref=" + quote(pr["head"]["sha"], safe=""))
        decode = lambda entry: base64.b64decode(entry["content"]).decode()
        updated = reserve_build(decode(base), decode(head))
        if updated != decode(head):
            api(path, {"message": "chore(release): reserve next build number", "branch": branch,
                       "sha": head["sha"], "content": base64.b64encode(updated.encode()).decode()})


if __name__ == "__main__":
    main()
