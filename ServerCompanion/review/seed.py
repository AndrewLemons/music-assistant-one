#!/usr/bin/env python3
"""Entrypoint of the App Review server: a fresh, seeded Music Assistant on every start.

Each start erases /data, runs the upstream server, then seeds it over the local API:
  - a random administrator that is never stored or printed, so nobody holds admin rights;
  - a regular (non-admin) reviewer account from REVIEW_USERNAME and REVIEW_PASSWORD;
  - the bundled sample library through the local-files provider, plus the companion provider.

It fails closed. If seeding fails, or another client completes first-time setup before the
seeder does, the process exits nonzero. The platform then restarts it, and the restart erases
everything again.
"""
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

DATA = Path("/data")
MEDIA = "/review-media"
BASE = "http://127.0.0.1:8095"
UPSTREAM = ["/usr/local/bin/entrypoint.sh", "--data-dir", str(DATA), "--cache-dir", str(DATA / ".cache")]
ALBUM = "Review Samples"
PLAYLISTS = {"Morning Mix", "Evening Mix"}


def log(message):
    print(f"[review] {message}", flush=True)


def call(path, body=None, token=None, timeout=30):
    headers = {"Content-Type": "application/json"} | ({"Authorization": f"Bearer {token}"} if token else {})
    data = json.dumps(body).encode() if body is not None else None
    with urlopen(Request(BASE + path, data, headers), timeout=timeout) as response:
        return json.load(response)


class Api:
    def __init__(self, token):
        self.token, self.counter = token, 0

    def __call__(self, command, **args):
        self.counter += 1
        return call("/api", {"message_id": str(self.counter), "command": command, "args": args}, self.token,
                    timeout=120)


def eventually(action, what, seconds):
    deadline = time.monotonic() + seconds
    while True:
        try:
            if (result := action()) is not None:
                return result
        except (OSError, ValueError, KeyError, HTTPError):
            pass
        if time.monotonic() > deadline:
            raise RuntimeError(f"{what} did not happen within {seconds} seconds")
        time.sleep(1)


def erase_data():
    """Start from nothing, even if a volume is still mounted at /data."""
    DATA.mkdir(exist_ok=True)
    for entry in DATA.iterdir():
        shutil.rmtree(entry) if entry.is_dir() and not entry.is_symlink() else entry.unlink()


def setup_provider(api, domain, values=None):
    step = api("config/providers/setup", provider_domain=domain)
    while step.get("type") == "form":
        step = api("config/flows/submit", flow_id=step["flow_id"], values=values or {})
    if step.get("type") != "finish":
        raise RuntimeError(f"Setting up {domain} ended with {step.get('type')}: {step.get('reason')}")


def seed(username, password):
    eventually(lambda: call("/info"), "Server startup", 300)
    # Claim first-time setup at once. If another client claimed it first, setup fails here
    # and the process exits, so a restart erases whatever that client did.
    owner = call("/setup", {"username": "review-owner", "password": secrets.token_urlsafe(32)})
    api = Api(owner["token"])
    api("config/onboard_complete")
    api("auth/user/create", username=username, password=password, role="user", display_name="App Review")
    setup_provider(api, "filesystem_local", {"path": MEDIA, "content_type": "music"})
    setup_provider(api, "music_assistant_one")
    api("music/sync")

    def library_ready():
        albums = api("music/albums/library_items", search=ALBUM, limit=10)
        tracks = [a for a in albums if a.get("name") == ALBUM]
        playlists = {p.get("name") for p in api("music/playlists/library_items", limit=50)}
        return True if tracks and PLAYLISTS <= playlists else None

    eventually(library_ready, "Library sync", 300)
    admins = [u for u in api("auth/users") if u.get("role") == "admin"]
    if [u.get("username") for u in admins] != ["review-owner"]:
        raise RuntimeError("Unexpected administrator accounts; refusing to serve")


def main():
    username = os.environ.get("REVIEW_USERNAME", "apple-review")
    password = os.environ.get("REVIEW_PASSWORD", "")
    if len(password) < 8 or len(username) < 2:
        log("Set REVIEW_USERNAME (2+ characters) and REVIEW_PASSWORD (8+ characters).")
        return 2
    erase_data()
    server = subprocess.Popen(UPSTREAM)
    signal.signal(signal.SIGTERM, lambda *_: server.terminate())
    signal.signal(signal.SIGINT, lambda *_: server.terminate())
    try:
        seed(username, password)
    except Exception as error:  # noqa: BLE001 - any seeding problem must stop the server.
        log(f"Seeding failed, stopping: {type(error).__name__}: {error}")
        server.terminate()
        try:
            server.wait(timeout=30)
        except subprocess.TimeoutExpired:
            server.kill()
        return 1
    Path("/tmp/review-ready").touch()
    log(f"Review server ready: {username} can sign in to the {ALBUM} library.")
    return server.wait()


if __name__ == "__main__":
    sys.exit(main())
