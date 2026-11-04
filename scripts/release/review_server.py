#!/usr/bin/env python3
"""Deploy and verify the App Review server on Railway (standard library only).

  review_server.py deploy --image NAME:TAG   Point the service at the image, set the reviewer
                                             credentials, and wait for the deployment to succeed
  review_server.py verify --url URL --server-version X.Y.Z
                                             Check the live server like the image test does

Environment: RAILWAY_TOKEN (a project token for the review environment), RAILWAY_ENVIRONMENT_ID,
RAILWAY_SERVICE_ID, REVIEW_USERNAME (default apple-review), REVIEW_PASSWORD.
"""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[2]
GRAPHQL = "https://backboard.railway.com/graphql/v2"
USER_AGENT = "music-assistant-one-release (+https://github.com/AndrewLemons/music-assistant-one)"
DONE = {"SUCCESS"}
FAILED = {"FAILED", "CRASHED", "REMOVED", "SKIPPED"}


def graphql(query, variables, token=None):
    request = Request(GRAPHQL, json.dumps({"query": query, "variables": variables}).encode(), {
        "Content-Type": "application/json", "Project-Access-Token": token or os.environ["RAILWAY_TOKEN"],
        # Railway's edge rejects the default Python-urllib user agent with 403.
        "User-Agent": USER_AGENT})
    for attempt in range(4):
        try:
            with urlopen(request, timeout=60) as response:
                body = json.load(response)
            break
        except (HTTPError, URLError) as error:
            if attempt == 3 or (isinstance(error, HTTPError) and error.code < 500 and error.code != 429):
                raise
            time.sleep(2 ** attempt * 3)
    if body.get("errors"):
        raise RuntimeError("Railway API error: " + "; ".join(e.get("message", "?") for e in body["errors"]))
    return body["data"]


def service_patch(service_id, image, username, password):
    """The environment patch: image, reviewer credentials, health check, and restart policy."""
    return {"services": {service_id: {
        "source": {"image": image},
        "variables": {"REVIEW_USERNAME": {"value": username}, "REVIEW_PASSWORD": {"value": password}},
        # /info answers once the server is up; the entrypoint exits (and restarts fresh) if seeding fails.
        "deploy": {"healthcheckPath": "/info", "healthcheckTimeout": 300, "restartPolicyType": "ALWAYS"},
    }}}


def newest_deployment(service_id, environment_id, after):
    data = graphql("""query($input: DeploymentListInput!) {
        deployments(input: $input, first: 5) { edges { node { id status createdAt meta } } } }""",
                   {"input": {"serviceId": service_id, "environmentId": environment_id}})
    nodes = [edge["node"] for edge in data["deployments"]["edges"]]
    created = [n for n in nodes if datetime.fromisoformat(n["createdAt"].replace("Z", "+00:00")) >= after]
    return max(created, key=lambda n: n["createdAt"], default=None)


def command_deploy(options):
    service_id, environment_id = os.environ["RAILWAY_SERVICE_ID"], os.environ["RAILWAY_ENVIRONMENT_ID"]
    username = os.environ.get("REVIEW_USERNAME") or "apple-review"
    password = os.environ["REVIEW_PASSWORD"]
    if len(password) < 8:
        raise SystemExit("REVIEW_PASSWORD must have at least 8 characters.")
    started = datetime.now(timezone.utc).replace(microsecond=0)
    graphql("""mutation($environmentId: String!, $patch: EnvironmentConfig!, $message: String) {
        environmentPatchCommit(environmentId: $environmentId, patch: $patch, commitMessage: $message) }""",
            {"environmentId": environment_id, "patch": service_patch(service_id, options.image, username, password),
             "message": f"Deploy {options.image}"})
    print(f"Committed {options.image}; waiting for the deployment.")
    deadline = time.monotonic() + options.timeout * 60
    while time.monotonic() < deadline:
        deployment = newest_deployment(service_id, environment_id, started)
        status = deployment["status"] if deployment else "not created yet"
        if status in DONE:
            print(f"Deployment {deployment['id']} succeeded.")
            return 0
        if status in FAILED:
            raise SystemExit(f"Deployment {deployment['id']} ended {status}; check its logs in Railway.")
        print(f"Deployment status: {status}", flush=True)
        time.sleep(15)
    raise SystemExit(f"The deployment did not succeed within {options.timeout} minutes.")


def load_image_checks():
    spec = importlib.util.spec_from_file_location("server_image", ROOT / "scripts/server-image.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def command_verify(options):
    checks = load_image_checks()
    url = options.url.rstrip("/")
    # The edge may briefly keep serving the previous deployment.
    info = checks.eventually(lambda: _expect_version(checks, url, options.server_version), "Expected server version",
                             options.timeout * 60)
    if not info.get("onboard_done"):
        raise SystemExit("The live server has not completed setup.")
    api, _ = checks.review_session(url, os.environ.get("REVIEW_USERNAME") or "apple-review",
                                   os.environ["REVIEW_PASSWORD"])
    tracks = checks.check_review_library(api)
    print(f"{url} serves Music Assistant {options.server_version} with {len(tracks)} sample tracks; "
          "the reviewer can sign in.")


def _expect_version(checks, url, version):
    info = checks.call(f"{url}/info")[1]
    if info.get("server_version") != version:
        raise ValueError(f"serving {info.get('server_version')}, expected {version}")
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    deploy = commands.add_parser("deploy")
    deploy.add_argument("--image", required=True)
    deploy.add_argument("--timeout", type=int, default=15, help="Minutes")
    verify = commands.add_parser("verify")
    verify.add_argument("--url", required=True)
    verify.add_argument("--server-version", required=True)
    verify.add_argument("--timeout", type=int, default=5, help="Minutes")
    options = parser.parse_args()
    return command_deploy(options) if options.command == "deploy" else command_verify(options)


if __name__ == "__main__":
    sys.exit(main())
