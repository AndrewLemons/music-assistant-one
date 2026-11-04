#!/usr/bin/env python3
"""Build and verify the server image: the upstream image plus the optional audio provider.

  server-image.py version        Print the Music Assistant version the Dockerfile targets
  server-image.py build [TAG]    Build for this machine's architecture
  server-image.py test [TAG]     Verify the provider and a fresh server inside a built image
  server-image.py build-review   Build the App Review image on top of the local server image
  server-image.py test-review    Verify the review image seeds a fresh library and resets on restart
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


REVIEW_CONTEXT = context / "review"
REVIEW_ALBUM = "Review Samples"
REVIEW_PLAYLISTS = {"Morning Mix", "Evening Mix"}


def call(url, body=None, token=None):
    headers = {"Content-Type": "application/json", "User-Agent": "music-assistant-one-tests"} | (
        {"Authorization": f"Bearer {token}"} if token else {})
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
    if capabilities.get("version") != 3:
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


def review_session(url, username, password):
    """Sign in as the reviewer; returns a function that runs API commands with that account."""
    _, login = eventually(lambda: call(f"{url}/auth/login", {
        "provider_id": "builtin", "credentials": {"username": username, "password": password}}), "Reviewer sign-in")
    token = login["token"]

    def api(command, **args):
        return call(f"{url}/api", {"message_id": "1", "command": command, "args": args}, token)[1]
    return api, token


def check_review_library(api):
    me = api("auth/me")
    if me.get("role") != "user":
        raise RuntimeError(f"The reviewer must be a regular user, not {me.get('role')!r}")
    albums = [a for a in api("music/albums/library_items", search=REVIEW_ALBUM, limit=10) if a["name"] == REVIEW_ALBUM]
    if not albums or [x["name"] for x in albums[0]["artists"]] != ["Various Artists"]:
        raise RuntimeError(f"Missing the {REVIEW_ALBUM!r} album by Various Artists: {albums}")
    tracks = api("music/albums/album_tracks", item_id=albums[0]["item_id"], provider_instance_id_or_domain="library")
    if len(tracks) < 4:
        raise RuntimeError(f"Expected at least 4 sample tracks, found {len(tracks)}")
    playlists = {p["name"] for p in api("music/playlists/library_items", limit=100)}
    if not REVIEW_PLAYLISTS <= playlists:
        raise RuntimeError(f"Missing sample playlists: {REVIEW_PLAYLISTS - playlists}")
    return tracks


def wait_for_review_ready(container, starts=1, seconds=300):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        logs = subprocess.run(["docker", "logs", container], capture_output=True, text=True).stdout
        if "[review] Seeding failed" in logs:
            raise RuntimeError("Review seeding failed:\n" + logs[-3000:])
        if logs.count("[review] Review server ready") >= starts:
            return
        time.sleep(2)
    raise RuntimeError(f"The review server was not ready within {seconds} seconds")


def test_review(image):
    username, password = "apple-review", secrets.token_urlsafe(18)
    container = docker_run(image, ["--detach", "--publish", "127.0.0.1::8095", "--env", f"REVIEW_PASSWORD={password}"],
                           timeout=60, capture_output=True, text=True).stdout.strip()
    try:
        port = subprocess.check_output(["docker", "port", container, "8095/tcp"], text=True)
        url = "http://127.0.0.1:" + port.splitlines()[0].rsplit(":", 1)[1]
        wait_for_review_ready(container)
        api, token = review_session(url, username, password)
        tracks = check_review_library(api)
        # Reviewer limits: no server administration, and setup can't be claimed again.
        for command, args in [("auth/user/create", {"username": "intruder", "password": "intruder-pass"}),
                              ("config/providers/remove", {"instance_id": "x"})]:
            try:
                call(f"{url}/api", {"message_id": "1", "command": command, "args": args}, token)
            except HTTPError as error:
                if error.code != 403:
                    raise
            else:
                raise RuntimeError(f"The reviewer could run {command}")
        try:
            call(f"{url}/setup", {"username": "intruder", "password": "intruder-password"})
        except HTTPError as error:
            if error.code != 400:
                raise
        else:
            raise RuntimeError("First-time setup was still open after seeding")
        if call(f"{url}/one/v1/capabilities", token=token)[1].get("version") != 3:
            raise RuntimeError("The companion provider is not serving the reviewer")
        # Changes made during a review disappear on the next start.
        api("music/favorites/add_item", item=tracks[0]["uri"])
        api("music/playlists/create_playlist", name="Reviewer Scratch")
        subprocess.run(["docker", "restart", container], check=True, capture_output=True, timeout=120)
        wait_for_review_ready(container, starts=2)
        port = subprocess.check_output(["docker", "port", container, "8095/tcp"], text=True)
        url = "http://127.0.0.1:" + port.splitlines()[0].rsplit(":", 1)[1]
        api, _ = review_session(url, username, password)
        check_review_library(api)
        if api("music/tracks/library_items", favorite=True, limit=10) or \
                "Reviewer Scratch" in {p["name"] for p in api("music/playlists/library_items", limit=100)}:
            raise RuntimeError("State survived a restart; the review server must start fresh")
    finally:
        subprocess.run(["docker", "rm", "--force", container], capture_output=True, check=False)
    print(f"Review image {image} passed: fresh seeded library, regular reviewer, reset on restart.")


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
    elif command == "build-review":
        review = arguments[1] if len(arguments) > 1 else f"music-assistant-one-review:{version}"
        # `docker build` uses the local image store, so it can build on the image just built.
        subprocess.run(["docker", "build", "--build-arg", f"SERVER_IMAGE={image}", "--tag", review,
                        str(REVIEW_CONTEXT)], check=True, timeout=1800)
    elif command == "test-review":
        test_review(arguments[0] if arguments else f"music-assistant-one-review:{version}")
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
