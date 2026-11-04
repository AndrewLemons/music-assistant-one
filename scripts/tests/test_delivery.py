"""Tests for the delivery helpers in scripts/release."""
import base64
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "release"))
import asc  # noqa: E402
import deliver  # noqa: E402
from github import GitHubError  # noqa: E402

RELEASE_BODY = """## [0.2.0](https://github.com/AndrewLemons/music-assistant-one/compare/v0.1.6...v0.2.0) (2026-11-04)


### ⚠ BREAKING CHANGES

* **playback:** downloads now require the companion ([#12](https://github.com/o/r/issues/12)) ([d4ac6ba](https://github.com/o/r/commit/d4ac6ba0000000000000000000000000000000000))

### Features

* speed up playback and fix music navigation ([#7](https://github.com/o/r/issues/7)) ([23e658a](https://github.com/o/r/commit/23e658aeaca8d0a875f903d27d011310ecc748d9))
* **library:** add album details ([abcdef1](https://github.com/o/r/commit/abcdef1))
"""


def raw_to_der(raw):
    def integer(value):
        value = value.lstrip(b"\0") or b"\0"
        if value[0] & 0x80:
            value = b"\0" + value
        return b"\x02" + bytes([len(value)]) + value
    body = integer(raw[:32]) + integer(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


class TokenTests(unittest.TestCase):
    def test_jwt_signature_verifies_with_the_public_key(self):
        with tempfile.TemporaryDirectory() as directory:
            key, public = Path(directory, "key.p8"), Path(directory, "public.pem")
            ec = subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout"],
                                capture_output=True, check=True).stdout
            key.write_bytes(subprocess.run(["openssl", "pkcs8", "-topk8", "-nocrypt"], input=ec,
                                           capture_output=True, check=True).stdout)
            subprocess.run(["openssl", "ec", "-in", str(key), "-pubout", "-out", str(public)],
                           capture_output=True, check=True)
            jwt = asc.token("KEY123", "issuer-id", str(key), now=1_800_000_000)
            header, payload, signature = jwt.split(".")
            decode = lambda part: base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))
            self.assertEqual(json.loads(decode(header)), {"alg": "ES256", "kid": "KEY123", "typ": "JWT"})
            claims = json.loads(decode(payload))
            self.assertEqual(claims["aud"], "appstoreconnect-v1")
            self.assertEqual(claims["exp"] - claims["iat"], 1200)
            raw = decode(signature)
            self.assertEqual(len(raw), 64)
            Path(directory, "sig.der").write_bytes(raw_to_der(raw))
            Path(directory, "input").write_bytes(f"{header}.{payload}".encode())
            verified = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(public), "-signature",
                                       str(Path(directory, "sig.der")), str(Path(directory, "input"))],
                                      capture_output=True, text=True)
            self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)

    def test_der_conversion_pads_short_integers_and_strips_sign_bytes(self):
        r, s = b"\x00\x81" + b"\x01" * 31, b"\x05"
        der = b"\x30" + bytes([4 + len(r) + len(s)]) + b"\x02" + bytes([len(r)]) + r + b"\x02\x01" + s
        raw = asc.der_to_raw_signature(der)
        self.assertEqual(raw[:32], b"\x81" + b"\x01" * 31)
        self.assertEqual(raw[32:], b"\0" * 31 + b"\x05")
        with self.assertRaises(ValueError):
            asc.der_to_raw_signature(b"\x31\x00")

    def test_errors_match_phrases_case_insensitively(self):
        error = asc.AscError(409, "POST", "/v1/x", [{"code": "ENTITY_ERROR", "detail": "Build is ALREADY in group"}])
        self.assertTrue(error.mentions("already"))
        self.assertFalse(error.mentions("expired"))


class VersionTests(unittest.TestCase):
    def pull(self, title, branch="release-please--branches--main--components--music-assistant-one", base="main"):
        return {"title": title, "head": {"ref": branch}, "base": {"ref": base}}

    def test_internal_builds_use_the_release_pr_version(self):
        pulls = [self.pull("chore(main): release 0.2.0"), self.pull("feat: thing", branch="feature")]
        self.assertEqual(deliver.internal_version("0.1.6", pulls), "0.2.0")

    def test_without_a_release_pr_internal_builds_use_the_next_patch(self):
        self.assertEqual(deliver.internal_version("0.1.6", []), "0.1.7")
        self.assertEqual(deliver.internal_version("0.1.6", [self.pull("chore(main): release 9.9.9", base="other")]),
                         "0.1.7")

    def test_the_highest_release_pr_version_wins(self):
        pulls = [self.pull("chore(main): release 0.10.0"), self.pull("chore(main): release 0.9.0")]
        self.assertEqual(deliver.release_pr_version(pulls), "0.10.0")


class FakeGitHub:
    def __init__(self, taken):
        self.taken, self.created = set(taken), []

    def post(self, path, body):
        number = int(body["ref"].rsplit("/", 1)[1])
        if number in self.taken:
            raise GitHubError(422, "POST", path, "Reference already exists")
        self.taken.add(number)
        self.created.append((body["ref"], body["sha"]))


class BuildNumberTests(unittest.TestCase):
    def test_reservation_skips_numbers_another_run_took(self):
        github = FakeGitHub(taken={10, 11})
        self.assertEqual(deliver.reserve(github, "abc", 10), 12)
        self.assertEqual(github.created, [("refs/tags/builds/12", "abc")])

    def test_unexpected_errors_are_not_mistaken_for_conflicts(self):
        class Broken:
            def post(self, path, body):
                raise GitHubError(403, "POST", path, "Resource not accessible by integration")
        with self.assertRaises(GitHubError):
            deliver.reserve(Broken(), "abc", 1)


class NotesTests(unittest.TestCase):
    def test_release_notes_become_readable_plain_text(self):
        text = deliver.plain_text(RELEASE_BODY)
        self.assertEqual(text, "⚠ BREAKING CHANGES:\n\n• playback: downloads now require the companion\n\n"
                               "Features:\n\n• speed up playback and fix music navigation\n• library: add album details")

    def test_notes_never_exceed_the_testflight_limit(self):
        text = deliver.truncate("\n".join(f"• change {i}" for i in range(2000)))
        self.assertLessEqual(len(text), deliver.WHAT_TO_TEST_LIMIT)
        self.assertTrue(text.endswith("\n…"))

    def test_internal_notes_list_changes_and_omit_release_commits(self):
        text = deliver.internal_notes(["fix: a", "chore(main): release 0.2.0", "feat: b"], "abcdef123", 41)
        self.assertEqual(text, "Internal build from abcdef1. Changes since build 41:\n• fix: a\n• feat: b")
        self.assertEqual(deliver.internal_notes([], "abcdef123", None), "Internal build from abcdef1.")


class SigningTests(unittest.TestCase):
    def profile(self, days, state="ACTIVE", kind="MAC_APP_DIRECT", certificates=("cert",)):
        expiry = (datetime(2026, 1, 1, tzinfo=timezone.utc) + timedelta(days=days)).isoformat().replace("+00:00", "Z")
        return {"id": f"{days}-{state}", "certificates": list(certificates),
                "attributes": {"profileType": kind, "profileState": state, "expirationDate": expiry}}

    def test_profile_choice_requires_an_active_long_lived_matching_profile(self):
        now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        profiles = [self.profile(1), self.profile(400, state="INVALID"), self.profile(500, kind="MAC_APP_STORE"),
                    self.profile(600, certificates=("other",)), self.profile(300), self.profile(200)]
        self.assertEqual(deliver.choose_profile(profiles, "cert", now)["id"], "300-ACTIVE")
        self.assertIsNone(deliver.choose_profile(profiles[:4], "cert", now))

    def test_serials_compare_regardless_of_format(self):
        self.assertEqual(deliver.normalized_serial("0a:1B:2c"), deliver.normalized_serial("A1B2C"))

    def test_ios_export_uploads_with_cloud_signing(self):
        options = deliver.export_options({"method": "app-store-connect", "destination": "export"}, "ios", "TEAM")
        self.assertEqual((options["destination"], options["signingStyle"], options["teamID"]),
                         ("upload", "automatic", "TEAM"))
        self.assertFalse(options["manageAppVersionAndBuildNumber"])

    def test_mac_export_signs_manually_with_the_profile(self):
        options = deliver.export_options({"method": "developer-id"}, "macos", "TEAM", "uuid", "com.example.app")
        self.assertEqual(options["provisioningProfiles"], {"com.example.app": "uuid"})
        self.assertEqual(options["signingCertificate"], "Developer ID Application")


class ConfigTests(unittest.TestCase):
    def test_reads_values_without_trailing_comments(self):
        text = "MARKETING_VERSION = 0.2.0 // x-release-please-version\nONE_BUNDLE_ID = com.example.app\n"
        self.assertEqual(deliver.xcconfig("MARKETING_VERSION", text), "0.2.0")
        self.assertEqual(deliver.xcconfig("ONE_BUNDLE_ID", text), "com.example.app")
        with self.assertRaises(SystemExit):
            deliver.xcconfig("MISSING", text)


if __name__ == "__main__":
    unittest.main()


import importlib.util as _util  # noqa: E402

_spec = _util.spec_from_file_location("review_server", Path(__file__).resolve().parents[1] / "release/review_server.py")
review_server = _util.module_from_spec(_spec)
_spec.loader.exec_module(review_server)


class ReviewServerTests(unittest.TestCase):
    def test_patch_sets_image_credentials_and_fail_safe_deploy_settings(self):
        patch = review_server.service_patch("svc", "ghcr.io/o/i:2.10.9-0.2.0-review", "apple-review", "secret-pass")
        service = patch["services"]["svc"]
        self.assertEqual(service["source"], {"image": "ghcr.io/o/i:2.10.9-0.2.0-review"})
        self.assertEqual(service["variables"]["REVIEW_PASSWORD"], {"value": "secret-pass"})
        self.assertEqual(service["deploy"]["restartPolicyType"], "ALWAYS")
        self.assertEqual(service["deploy"]["healthcheckPath"], "/info")

    def test_waits_only_for_a_deployment_created_by_this_commit(self):
        after = datetime(2026, 11, 4, 12, 0, tzinfo=timezone.utc)
        nodes = [{"id": "old", "status": "SUCCESS", "createdAt": "2026-11-04T11:59:59Z", "meta": {}},
                 {"id": "new", "status": "DEPLOYING", "createdAt": "2026-11-04T12:00:05Z", "meta": {}}]
        original = review_server.graphql
        review_server.graphql = lambda *args, **kwargs: {"deployments": {"edges": [{"node": n} for n in nodes]}}
        try:
            self.assertEqual(review_server.newest_deployment("svc", "env", after)["id"], "new")
            nodes.pop()
            self.assertIsNone(review_server.newest_deployment("svc", "env", after))
        finally:
            review_server.graphql = original


class TestFlightGroupTests(unittest.TestCase):
    class Client:
        def __init__(self, error=None):
            self.posts, self.error = [], error

        def post(self, path, body):
            if self.error:
                raise self.error
            self.posts.append(path)

    def group(self, internal, automatic=False):
        return {"id": "g1", "attributes": {"name": "Group", "isInternalGroup": internal,
                                           "hasAccessToAllBuilds": automatic}}

    def test_internal_groups_with_automatic_distribution_need_no_call(self):
        client = self.Client()
        deliver.add_to_group(client, self.group(internal=True, automatic=True), "b1")
        self.assertEqual(client.posts, [])

    def test_internal_groups_without_automatic_distribution_fail_with_instructions(self):
        with self.assertRaises(SystemExit) as raised:
            deliver.add_to_group(self.Client(), self.group(internal=True), "b1")
        self.assertIn("automatic distribution", str(raised.exception))

    def test_external_groups_get_the_build_and_tolerate_repeats(self):
        client = self.Client()
        deliver.add_to_group(client, self.group(internal=False), "b1")
        self.assertEqual(client.posts, ["/v1/betaGroups/g1/relationships/builds"])
        repeat = self.Client(asc.AscError(409, "POST", "/x", [{"detail": "Build already in group"}]))
        deliver.add_to_group(repeat, self.group(internal=False), "b1")
