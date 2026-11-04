#!/usr/bin/env python3
"""Steps of the app delivery workflow (.github/workflows/release.yml). Run with --help per command.

Every command is safe to rerun: build numbers are reserved atomically, App Store Connect
changes are idempotent, and nothing here moves a release tag.
"""
import argparse
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from asc import AscError, Client  # noqa: E402
from github import GitHub, GitHubError  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
RELEASE_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
BUILD_TAG = "builds/"
RELEASE_BRANCH = "release-please--branches--main"
WHAT_TO_TEST_LIMIT = 4000  # App Store Connect's limit for "What to Test".
KEYCHAIN = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "delivery-signing.keychain-db"


# ---------------------------------------------------------------------------------------------
# Small helpers


def output(**values):
    """Record step outputs for GitHub Actions and echo them for the log."""
    lines = [f"{key}={value}" for key, value in values.items()]
    print("\n".join(lines))
    if path := os.environ.get("GITHUB_OUTPUT"):
        with open(path, "a") as file:
            file.write("\n".join(lines) + "\n")


def xcconfig(name, text=None):
    text = text if text is not None else (ROOT / "Config/Version.xcconfig").read_text()
    match = re.search(rf"^{name} = ([^\s/]+)", text, re.M)
    if not match:
        raise SystemExit(f"{name} is missing from Config/Version.xcconfig")
    return match[1]


def bump_patch(version):
    major, minor, patch = (int(part) for part in version.split("."))
    return f"{major}.{minor}.{patch + 1}"


def classify_changes(paths):
    spec = importlib.util.spec_from_file_location("changes", ROOT / "scripts/ci/changes.py")
    changes = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(changes)
    return changes.classify(paths)


# ---------------------------------------------------------------------------------------------
# context: what this run delivers


def release_pr_version(pulls):
    """The version proposed by the open release PR, if there is one."""
    versions = []
    for pull in pulls:
        if pull["head"]["ref"].startswith(RELEASE_BRANCH) and pull["base"]["ref"] == "main":
            if match := re.search(r"release v?(\d+\.\d+\.\d+)$", pull["title"]):
                versions.append(tuple(int(part) for part in match[1].split(".")))
    return ".".join(map(str, max(versions))) if versions else None


def internal_version(current, pulls):
    """Internal builds use the upcoming version: once a version ships on the App Store its build
    train closes, so builds made after a release must not reuse the released version."""
    return release_pr_version(pulls) or bump_patch(current)


def release_context(github, tag, source):
    """Releases are always built from the tagged commit. That may differ from the pushed commit
    when a later push superseded the run that merged the release PR."""
    if not RELEASE_TAG.match(tag):
        raise SystemExit(f"{source} gave {tag!r}; expected a vX.Y.Z release tag")
    try:
        sha = github.get(f"/commits/{tag}")["sha"]
    except GitHubError as error:
        raise SystemExit(f"Tag {tag} does not exist: {error}") from None
    return output(mode="release", tag=tag, version=tag[1:], sha=sha)


def command_context(options):
    github = GitHub()
    event = os.environ.get("GITHUB_EVENT_NAME", "")
    if dispatch_tag := os.environ.get("DISPATCH_TAG", "").strip():
        return release_context(github, dispatch_tag, "The tag input")
    if os.environ.get("RELEASE_CREATED") == "true":
        return release_context(github, os.environ["RELEASE_TAG"], "Release Please")
    sha = os.environ["GITHUB_SHA"]
    before = os.environ.get("BEFORE", "")
    if event == "push" and before and set(before) != {"0"}:
        try:
            files = [entry["filename"] for entry in github.get(f"/compare/{before}...{sha}").get("files", [])]
        except GitHubError as error:
            print(f"::warning::Could not compare {before[:7]}...{sha[:7]} ({error}); building anyway.")
        else:
            # The compare endpoint lists at most 300 files; only skip on a complete list.
            if 0 < len(files) < 300 and not classify_changes(files)["app"]:
                print("No app changes in this push; skipping the internal TestFlight build.")
                return output(mode="skip", tag="", version="", sha=sha)
    pulls = github.paginate("/pulls?state=open&base=main", limit=3)
    version = internal_version((ROOT / "version.txt").read_text().strip(), pulls)
    return output(mode="internal", tag="", version=version, sha=sha)


# ---------------------------------------------------------------------------------------------
# reserve-build: a unique, increasing CFBundleVersion


def highest_asc_build(client, app_id):
    builds = client.get("/v1/builds", **{"filter[app]": app_id, "sort": "-uploadedDate",
                                          "fields[builds]": "version", "limit": 200}).get("data", [])
    numbers = [int(b["attributes"]["version"]) for b in builds if b["attributes"]["version"].isdigit()]
    return max(numbers, default=0)


def build_tags(github):
    """Reserved build numbers mapped to the commits they were built from."""
    refs = github.get(f"/git/matching-refs/tags/{BUILD_TAG}")
    tags = {}
    for ref in refs:
        name = ref["ref"].removeprefix(f"refs/tags/{BUILD_TAG}")
        if name.isdigit():
            tags[int(name)] = ref["object"]["sha"]
    return tags


def reserve(github, sha, start, attempts=20):
    """Create builds/<n> at `sha` for the first free n >= start. Ref creation is atomic, so two
    concurrent runs can never receive the same number."""
    for number in range(start, start + attempts):
        try:
            github.post("/git/refs", {"ref": f"refs/tags/{BUILD_TAG}{number}", "sha": sha})
            return number
        except GitHubError as error:
            if error.status != 422:  # 422: the reference already exists.
                raise
    raise SystemExit(f"Could not reserve a build number after {attempts} attempts")


def command_reserve_build(options):
    github = GitHub()
    client = Client()
    app_id = client.app_id(xcconfig("ONE_BUNDLE_ID"))
    uploaded = highest_asc_build(client, app_id)
    reserved = max(build_tags(github), default=0)
    print(f"Highest build in App Store Connect: {uploaded}; highest reserved tag: {reserved}")
    number = reserve(github, options.sha, max(uploaded, reserved) + 1)
    output(build=number, app_id=app_id)


# ---------------------------------------------------------------------------------------------
# notes: "What to Test"


def plain_text(markdown):
    """Release Please's Markdown as readable plain text for TestFlight."""
    lines = []
    for line in markdown.splitlines():
        if re.match(r"^#{1,2} \[?\d+\.\d+\.\d+", line):
            continue  # The version heading; TestFlight already shows the version.
        line = re.sub(r"\s*\(\[[0-9a-f]{7,40}\]\([^)]*\)\)", "", line)  # Commit links.
        line = re.sub(r"\s*\(\[#\d+\]\([^)]*\)\)", "", line)  # Pull request links.
        line = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", line)
        line = re.sub(r"^#{3,} (.+)$", r"\1:", line)
        line = re.sub(r"^[*-] ", "• ", line)
        line = line.replace("**", "")
        lines.append(line.rstrip())
    return truncate(re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip())


def truncate(text, limit=WHAT_TO_TEST_LIMIT):
    if len(text) <= limit:
        return text
    cut = text[:limit - 2].rsplit("\n", 1)[0]
    return cut + "\n…"


def internal_notes(subjects, sha, previous):
    changes = [s for s in subjects if not s.startswith("chore(main): release")][-30:]
    heading = f"Internal build from {sha[:7]}"
    if not changes:
        return heading + "."
    since = f" since build {previous}" if previous else ""
    return truncate(f"{heading}. Changes{since}:\n" + "\n".join(f"• {s}" for s in changes))


def command_notes(options):
    github = GitHub()
    if options.tag:
        body = github.get(f"/releases/tags/{options.tag}").get("body") or ""
        text = plain_text(body) or f"Music Assistant One {options.tag}."
    else:
        previous = {n: sha for n, sha in build_tags(github).items() if n < options.build and sha != options.sha}
        subjects, last = [], None
        if previous:
            last = max(previous)
            compare = github.get(f"/compare/{previous[last]}...{options.sha}")
            subjects = [c["commit"]["message"].splitlines()[0] for c in compare.get("commits", [])]
        text = internal_notes(subjects, options.sha, last)
    Path(options.out).write_text(text + "\n")
    print(text)


# ---------------------------------------------------------------------------------------------
# Signing: a temporary keychain holding only the identities this job needs


def security(*arguments, **kwargs):
    return subprocess.run(["security", *arguments], check=True, **kwargs)


def command_signing_import(options):
    password = secrets.token_urlsafe(24)
    if KEYCHAIN.exists():
        security("delete-keychain", str(KEYCHAIN))
    security("create-keychain", "-p", password, str(KEYCHAIN))
    security("set-keychain-settings", "-lut", "21600", str(KEYCHAIN))
    security("unlock-keychain", "-p", password, str(KEYCHAIN))
    certificate_password = os.environ[options.password_env]
    security("import", options.p12, "-k", str(KEYCHAIN), "-f", "pkcs12", "-P", certificate_password,
             "-T", "/usr/bin/codesign", "-T", "/usr/bin/security", "-T", "/usr/bin/xcodebuild",
             stdout=subprocess.DEVNULL)
    security("set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password,
             str(KEYCHAIN), stdout=subprocess.DEVNULL)
    existing = subprocess.check_output(["security", "list-keychains", "-d", "user"], text=True)
    others = [line.strip().strip('"') for line in existing.splitlines() if line.strip()]
    security("list-keychains", "-d", "user", "-s", str(KEYCHAIN), *[k for k in others if k != str(KEYCHAIN)])
    if not valid_identities():
        # An identity is only valid with its issuing intermediate. Runner images normally have
        # Apple's intermediates; import them if this one does not.
        print("No valid identity yet; importing Apple's intermediate certificates.")
        import_intermediates()
    identities = valid_identities()
    if not identities:
        raise SystemExit("The certificate did not import as a valid code signing identity "
                         "(wrong password, expired, revoked, or missing its private key).")
    print("\n".join(identities))
    check_expiry(options.warn_days)


def valid_identities():
    output = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning", str(KEYCHAIN)],
                                     text=True)
    return [line.strip() for line in output.splitlines() if re.match(r"\s*\d+\)", line)]


INTERMEDIATES = ["AppleWWDRCAG3.cer", "AppleWWDRCAG4.cer", "AppleWWDRCAG5.cer", "AppleWWDRCAG6.cer",
                 "DeveloperIDCA.cer", "DeveloperIDG2CA.cer"]


def import_intermediates():
    from urllib.request import urlopen
    for name in INTERMEDIATES:
        path = KEYCHAIN.parent / name
        with urlopen(f"https://www.apple.com/certificateauthority/{name}", timeout=30) as response:
            path.write_bytes(response.read())
        subprocess.run(["security", "import", str(path), "-k", str(KEYCHAIN)], capture_output=True)
        path.unlink()


def check_expiry(warn_days):
    """Warn well before a stored signing certificate expires, so a release never fails on it."""
    pem = subprocess.check_output(["security", "find-certificate", "-a", "-p", str(KEYCHAIN)], text=True)
    for block in re.findall(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", pem, re.S):
        details = subprocess.run(["openssl", "x509", "-noout", "-subject", "-enddate"], input=block,
                                 capture_output=True, text=True, check=True).stdout
        subject = re.search(r"CN\s*=\s*([^,/\n]+)", details)
        end = datetime.strptime(re.search(r"notAfter=(.+)", details)[1].strip(), "%b %d %H:%M:%S %Y %Z")
        remaining = (end.replace(tzinfo=timezone.utc) - datetime.now(timezone.utc)).days
        name = subject[1].strip() if subject else "certificate"
        print(f"{name} expires {end:%Y-%m-%d} ({remaining} days)")
        if remaining < warn_days:
            print(f"::warning title=Signing certificate expiring::{name} expires in {remaining} days. "
                  "Renew it and update the secret; see docs/RELEASING.md.")


def p12_expiry(path, password):
    """Subject and expiry of the certificate in a .p12. OpenSSL 3 needs -legacy for the RC2/3DES
    encryption that Keychain Access uses when exporting."""
    for extra in ([], ["-legacy"]):
        result = subprocess.run(["openssl", "pkcs12", "-in", path, "-nokeys", "-clcerts", "-passin", "env:P12_PASS",
                                 *extra], capture_output=True, text=True, env=dict(os.environ, P12_PASS=password))
        if result.returncode == 0 and "BEGIN CERTIFICATE" in result.stdout:
            details = subprocess.run(["openssl", "x509", "-noout", "-subject", "-enddate"], input=result.stdout,
                                     capture_output=True, text=True, check=True).stdout
            subject = re.search(r"CN\s*=\s*([^,/\n]+)", details)
            end = datetime.strptime(re.search(r"notAfter=(.+)", details)[1].strip(), "%b %d %H:%M:%S %Y %Z")
            return (subject[1].strip() if subject else Path(path).name), end.replace(tzinfo=timezone.utc)
    raise SystemExit(f"Could not read {Path(path).name}; check the certificate secret and its password.")


def command_certificate_check(options):
    """Report every stored certificate's expiry; list those inside the warning window."""
    expiring = []
    for path, password_env in zip(options.p12, options.password_env):
        name, end = p12_expiry(path, os.environ[password_env])
        remaining = (end - datetime.now(timezone.utc)).days
        print(f"{name}: expires {end:%Y-%m-%d} ({remaining} days)")
        if remaining < options.warn_days:
            expiring.append(f"{name} expires {end:%Y-%m-%d} ({remaining} days)")
    output(expiring=json.dumps(expiring))


def command_signing_cleanup(options):
    if KEYCHAIN.exists():
        subprocess.run(["security", "delete-keychain", str(KEYCHAIN)], check=False)
    for path in options.remove:
        Path(path).unlink(missing_ok=True)


# ---------------------------------------------------------------------------------------------
# Developer ID provisioning profile for the Mac app


def normalized_serial(serial):
    return serial.upper().replace(":", "").lstrip("0")


def keychain_serials():
    pem = subprocess.check_output(["security", "find-certificate", "-a", "-c", "Developer ID Application", "-p",
                                   str(KEYCHAIN)], text=True)
    serials = []
    for block in re.findall(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", pem, re.S):
        result = subprocess.run(["openssl", "x509", "-noout", "-serial"], input=block, capture_output=True,
                                text=True, check=True).stdout
        serials.append(normalized_serial(result.split("=", 1)[1].strip()))
    if not serials:
        raise SystemExit("No Developer ID Application certificate is in the signing keychain.")
    return serials


def choose_profile(profiles, certificate_id, now):
    """The longest-lived active Developer ID profile that includes the certificate."""
    usable = [p for p in profiles
              if p["attributes"]["profileType"] == "MAC_APP_DIRECT"
              and p["attributes"]["profileState"] == "ACTIVE"
              and certificate_id in p["certificates"]
              and datetime.fromisoformat(p["attributes"]["expirationDate"].replace("Z", "+00:00")) > now + timedelta(days=2)]
    return max(usable, key=lambda p: p["attributes"]["expirationDate"], default=None)


def install_profile(content, uuid):
    data = __import__("base64").b64decode(content)
    for directory in (Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
                      Path.home() / "Library/MobileDevice/Provisioning Profiles"):
        directory.mkdir(parents=True, exist_ok=True)
        (directory / f"{uuid}.provisionprofile").write_bytes(data)


def command_mac_profile(options):
    client = Client()
    serials = keychain_serials()
    certificates = [c for kind in ("DEVELOPER_ID_APPLICATION_G2", "DEVELOPER_ID_APPLICATION")
                    for c in client.all("/v1/certificates", **{"filter[certificateType]": kind, "limit": 200})]
    matching = [c for c in certificates if normalized_serial(c["attributes"]["serialNumber"]) in serials]
    if not matching:
        raise SystemExit("The stored Developer ID certificate is not on the App Store Connect team "
                         "(revoked, or from another team).")
    certificate_id = matching[0]["id"]
    bundles = [b for b in client.all("/v1/bundleIds", **{"filter[identifier]": options.bundle_id})
               if b["attributes"]["identifier"] == options.bundle_id]
    if not bundles:
        raise SystemExit(f"Bundle ID {options.bundle_id} is not registered for the team.")
    bundle_id = bundles[0]["id"]
    profiles = client.all(f"/v1/bundleIds/{bundle_id}/profiles", limit=200)
    for profile in profiles:
        profile["certificates"] = [c["id"] for c in client.all(f"/v1/profiles/{profile['id']}/certificates")]
    chosen = choose_profile(profiles, certificate_id, datetime.now(timezone.utc))
    if chosen is None:
        name = f"Music Assistant One Developer ID CI {datetime.now(timezone.utc):%Y-%m-%d %H%M}"
        print(f"Creating provisioning profile {name!r}")
        chosen = client.post("/v1/profiles", {"data": {
            "type": "profiles", "attributes": {"name": name, "profileType": "MAC_APP_DIRECT"},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                              "certificates": {"data": [{"type": "certificates", "id": certificate_id}]}}}})["data"]
    else:
        chosen = client.get(f"/v1/profiles/{chosen['id']}")["data"]
    attributes = chosen["attributes"]
    install_profile(attributes["profileContent"], attributes["uuid"])
    print(f"Installed {attributes['name']} (expires {attributes['expirationDate']})")
    output(profile_uuid=attributes["uuid"], profile_name=attributes["name"])


# ---------------------------------------------------------------------------------------------
# export-options: CI's variant of the committed ExportOptions plists


def export_options(base, platform, team, profile_uuid=None, bundle_id=None):
    options = dict(base, teamID=team)
    if platform == "ios":
        # Upload straight to App Store Connect, signed by the cloud-managed distribution certificate.
        options.update(destination="upload", signingStyle="automatic", manageAppVersionAndBuildNumber=False,
                       uploadSymbols=True, testFlightInternalTestingOnly=False)
    else:
        options.update(destination="export", signingStyle="manual", signingCertificate="Developer ID Application",
                       provisioningProfiles={bundle_id: profile_uuid})
    return options


def command_export_options(options):
    name = "iOS" if options.platform == "ios" else "macOS"
    base = plistlib.loads((ROOT / f"Distribution/ExportOptions-{name}.plist").read_bytes())
    if options.platform == "macos" and not options.profile_uuid:
        raise SystemExit("--profile-uuid is required for macOS")
    result = export_options(base, options.platform, options.team, options.profile_uuid, xcconfig("ONE_BUNDLE_ID"))
    Path(options.out).write_bytes(plistlib.dumps(result))
    print(json.dumps(result, indent=2))


def command_verify_version(options):
    committed = xcconfig("MARKETING_VERSION")
    if committed != options.version:
        raise SystemExit(f"Config/Version.xcconfig has {committed}, but this delivery is for {options.version}.")
    print(f"Marketing version {committed} matches.")


# ---------------------------------------------------------------------------------------------
# wait and distribute: TestFlight


def find_build(client, app_id, version, build, platform):
    builds = client.get("/v1/builds", **{
        "filter[app]": app_id, "filter[version]": str(build), "filter[preReleaseVersion.version]": version,
        "filter[preReleaseVersion.platform]": platform, "limit": 5,
        "fields[builds]": "version,processingState,usesNonExemptEncryption,expired"}).get("data", [])
    return builds[0] if builds else None


def command_wait(options):
    client = Client()
    app_id = client.app_id(xcconfig("ONE_BUNDLE_ID"))
    deadline = time.monotonic() + options.timeout * 60
    state = None
    while time.monotonic() < deadline:
        build = find_build(client, app_id, options.version, options.build, options.platform)
        if build:
            state = build["attributes"]["processingState"]
            if state == "VALID":
                if build["attributes"].get("usesNonExemptEncryption") is None:
                    print("::warning::Export compliance is unanswered; check ITSAppUsesNonExemptEncryption.")
                print(f"Build {options.version} ({options.build}) finished processing.")
                return output(build_id=build["id"])
            if state in {"FAILED", "INVALID"}:
                raise SystemExit(f"App Store Connect rejected build {options.build}: {state}. "
                                 "Check the email Apple sent for the reason.")
        print(f"Waiting for build {options.build} ({state or 'not visible yet'})…", flush=True)
        time.sleep(30)
    raise SystemExit(f"Build {options.build} did not finish processing within {options.timeout} minutes.")


def set_what_to_test(client, build_id, text, locale="en-US"):
    localizations = client.all(f"/v1/builds/{build_id}/betaBuildLocalizations")
    existing = next((l for l in localizations if l["attributes"]["locale"] == locale), None)
    if existing:
        client.patch(f"/v1/betaBuildLocalizations/{existing['id']}", {"data": {
            "type": "betaBuildLocalizations", "id": existing["id"], "attributes": {"whatsNew": text}}})
    else:
        client.post("/v1/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations", "attributes": {"locale": locale, "whatsNew": text},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})


def command_distribute(options):
    client = Client()
    app_id = client.app_id(xcconfig("ONE_BUNDLE_ID"))
    if options.notes:
        set_what_to_test(client, options.build_id, Path(options.notes).read_text().strip())
        print("Set What to Test.")
    if not options.group or not all(name.strip() for name in options.group):
        raise SystemExit("A TestFlight group name is empty; set TESTFLIGHT_INTERNAL_GROUP and "
                         "TESTFLIGHT_PUBLIC_GROUP in the app-store environment.")
    groups = {g["attributes"]["name"]: g for g in client.all(f"/v1/apps/{app_id}/betaGroups", limit=200)}
    missing = [name for name in options.group if name not in groups]
    if missing:
        raise SystemExit(f"TestFlight group(s) {missing} not found. Available: {sorted(groups)}")
    if options.submit_review:
        try:
            client.post("/v1/betaAppReviewSubmissions", {"data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {"build": {"data": {"type": "builds", "id": options.build_id}}}}})
            print("Submitted for Beta App Review.")
        except AscError as error:
            if error.status in {409, 422} and error.mentions("already", "approved", "not required"):
                print(f"Beta App Review submission not needed: {error}")
            else:
                raise
    for name in options.group:
        try:
            client.post(f"/v1/betaGroups/{groups[name]['id']}/relationships/builds",
                        {"data": [{"type": "builds", "id": options.build_id}]})
            print(f"Added to TestFlight group {name!r}.")
        except AscError as error:
            if error.status == 409 or error.mentions("already"):
                print(f"Group {name!r} already has this build.")
            else:
                raise


# ---------------------------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("context", help="Decide what this run delivers (env: GITHUB_*, RELEASE_*, DISPATCH_TAG, BEFORE)")
    reserve_parser = commands.add_parser("reserve-build", help="Reserve the next build number")
    reserve_parser.add_argument("--sha", required=True)
    notes_parser = commands.add_parser("notes", help="Write TestFlight What to Test text")
    notes_parser.add_argument("--tag", default="")
    notes_parser.add_argument("--sha", required=True)
    notes_parser.add_argument("--build", type=int, required=True)
    notes_parser.add_argument("--out", required=True)
    import_parser = commands.add_parser("signing-import", help="Create a temporary keychain with a .p12")
    import_parser.add_argument("--p12", required=True)
    import_parser.add_argument("--password-env", required=True)
    import_parser.add_argument("--warn-days", type=int, default=30)
    check_parser = commands.add_parser("certificate-check", help="Report stored certificates' expiry")
    check_parser.add_argument("--p12", action="append", required=True)
    check_parser.add_argument("--password-env", action="append", required=True)
    check_parser.add_argument("--warn-days", type=int, default=30)
    cleanup_parser = commands.add_parser("signing-cleanup", help="Delete the keychain and secret files")
    cleanup_parser.add_argument("remove", nargs="*")
    profile_parser = commands.add_parser("mac-profile", help="Install the Developer ID profile")
    profile_parser.add_argument("--bundle-id", required=True)
    options_parser = commands.add_parser("export-options", help="Write CI export options")
    options_parser.add_argument("--platform", choices=["ios", "macos"], required=True)
    options_parser.add_argument("--team", required=True)
    options_parser.add_argument("--profile-uuid")
    options_parser.add_argument("--out", required=True)
    verify_parser = commands.add_parser("verify-version", help="Check the committed marketing version")
    verify_parser.add_argument("--version", required=True)
    wait_parser = commands.add_parser("wait", help="Wait for App Store Connect processing")
    wait_parser.add_argument("--version", required=True)
    wait_parser.add_argument("--build", type=int, required=True)
    wait_parser.add_argument("--platform", default="IOS")
    wait_parser.add_argument("--timeout", type=int, default=60, help="Minutes")
    distribute_parser = commands.add_parser("distribute", help="Send a processed build to TestFlight groups")
    distribute_parser.add_argument("--build-id", required=True)
    distribute_parser.add_argument("--group", action="append", default=[])
    distribute_parser.add_argument("--notes")
    distribute_parser.add_argument("--submit-review", action="store_true")
    options = parser.parse_args()
    handler = globals()["command_" + options.command.replace("-", "_")]
    return handler(options)


if __name__ == "__main__":
    sys.exit(main())
