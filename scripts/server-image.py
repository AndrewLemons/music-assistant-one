#!/usr/bin/env python3
"""Build and verify the server image: the upstream image plus the optional audio provider.

  server-image.py version        Print the Music Assistant version the Dockerfile targets
  server-image.py build [TAG]    Build for this machine's architecture
  server-image.py test [TAG]     Verify the provider and a fresh server inside a built image
"""
import json
from pathlib import Path
import re
import secrets
import subprocess
import sys
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen

root = Path(__file__).resolve().parents[1]
context = root / "ServerCompanion"
BASE = re.compile(r"^FROM ghcr\.io/music-assistant/server:(\d+\.\d+\.\d+)@sha256:[0-9a-f]{64}$", re.M)
PROVIDERS = "import music_assistant, pathlib; print(pathlib.Path(music_assistant.__file__).parent / 'providers')"
SITE_PACKAGES = "import sysconfig; print(sysconfig.get_path('purelib'))"


def music_assistant_version(dockerfile=None):
    match = BASE.search(dockerfile if dockerfile is not None else (context / "Dockerfile").read_text())
    if not match:
        raise ValueError("Dockerfile must use ghcr.io/music-assistant/server:X.Y.Z@sha256:<digest>")
    return match[1]


def docker_run(image, options, command=(), timeout=300, **kwargs):
    return subprocess.run(["docker", "run", "--rm", "--pull", "never", *options, image, *command],
                          check=True, timeout=timeout, **kwargs)


def call(url, body=None, token=None):
    headers = {"Content-Type": "application/json"} | ({"Authorization": f"Bearer {token}"} if token else {})
    data = json.dumps(body).encode() if body is not None else None
    with urlopen(Request(url, data, headers), timeout=10) as response:
        return response.status, json.load(response)


def eventually(action, what, seconds=180):
    deadline = time.monotonic() + seconds
    while True:
        try:
            return action()
        except (OSError, ValueError) as error:
            if time.monotonic() > deadline:
                raise RuntimeError(f"{what} did not succeed within {seconds} seconds: {error}") from None
            time.sleep(2)


def check_server(url, version):
    """Set up a fresh server, add the provider through the API, and use its authenticated route."""
    info = eventually(lambda: call(f"{url}/info")[1], "Server startup")
    if info.get("server_version") != version:
        raise RuntimeError(f"Expected Music Assistant {version}, got {info.get('server_version')}")
    _, setup = call(f"{url}/setup", {"username": "image-test", "password": secrets.token_urlsafe(24)})
    token = setup["token"]
    call(f"{url}/api", {"message_id": "1", "command": "config/providers/setup",
                        "args": {"provider_domain": "music_assistant_one"}}, token)
    _, capabilities = eventually(lambda: call(f"{url}/one/v1/capabilities", token=token), "Provider setup", 60)
    if capabilities.get("version") != 1:
        raise RuntimeError(f"Unexpected capabilities: {capabilities}")
    try:
        call(f"{url}/one/v1/capabilities")
    except HTTPError as error:
        if error.code != 401:
            raise
    else:
        raise RuntimeError("Capabilities answered without authentication")


def test(image, version):
    # The installed copy must import against this server's internals and declare its manifest.
    docker_run(image, ["--entrypoint", "sh"], ["-c", f'''set -e
python -c "import music_assistant.providers.music_assistant_one"
python -c "import json, sys; assert json.load(open(sys.argv[1]))['domain'] == 'music_assistant_one'" \\
  "$(python -c "{PROVIDERS}")/music_assistant_one/manifest.json"'''])
    # Transport tests plus the adapter interop test with this server's models and FFmpeg.
    docker_run(image, ["--volume", f"{context}:/companion:ro", "--entrypoint", "sh"], ["-c", f'''
MA_SERVER_SOURCE="$(python -c "{SITE_PACKAGES}")" python -m unittest discover -s /companion/tests -v'''])
    # The unchanged upstream entrypoint, volume, and port serve a working provider.
    container = docker_run(image, ["--detach", "--publish", "127.0.0.1::8095"], timeout=60,
                           capture_output=True, text=True).stdout.strip()
    try:
        port = subprocess.check_output(["docker", "port", container, "8095/tcp"], text=True)
        check_server("http://127.0.0.1:" + port.splitlines()[0].rsplit(":", 1)[1], version)
        logs = subprocess.run(["docker", "logs", container], capture_output=True, text=True, check=True)
        problems = [line for line in (logs.stdout + logs.stderr).splitlines()
                    if "music_assistant_one" in line and re.search(r"error|exception|traceback", line, re.I)]
        if problems:
            raise RuntimeError("Provider errors in server log:\n" + "\n".join(problems))
    finally:
        subprocess.run(["docker", "rm", "--force", container], capture_output=True, check=False)
    print(f"Server image {image} passed with Music Assistant {version}.")


def main():
    command, *arguments = sys.argv[1:] or ["help"]
    version = music_assistant_version()
    image = arguments[0] if arguments else f"music-assistant-one-server:{version}"
    if command == "version":
        print(version)
    elif command == "build":
        subprocess.run(["docker", "buildx", "build", "--pull", "--load", "--tag", image, str(context)],
                       check=True, timeout=1800)
    elif command == "test":
        test(image, version)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
