"""A minimal App Store Connect API client using only the standard library and `openssl`.

Authentication uses an API key (.p8): https://developer.apple.com/documentation/appstoreconnectapi
"""
import base64
import json
import os
import subprocess
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

API = "https://api.appstoreconnect.apple.com"
RETRYABLE = {429, 500, 502, 503, 504}


class AscError(RuntimeError):
    def __init__(self, status, method, path, errors):
        self.status, self.errors = status, errors
        details = "; ".join(f"{e.get('code', '?')}: {e.get('detail') or e.get('title', '')}" for e in errors)
        super().__init__(f"App Store Connect {method} {path} failed with HTTP {status}: {details}")

    def mentions(self, *phrases):
        text = json.dumps(self.errors).lower()
        return any(phrase.lower() in text for phrase in phrases)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw_signature(der, size=32):
    """Convert an ASN.1 DER ECDSA signature (what openssl emits) to JOSE's raw r || s form."""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("Not a DER ECDSA signature")
    offset = 3 if der[1] & 0x80 else 2  # A long-form length byte only appears for big curves.
    values = []
    for _ in range(2):
        if der[offset] != 0x02:
            raise ValueError("Malformed DER integer")
        length = der[offset + 1]
        value = der[offset + 2:offset + 2 + length].lstrip(b"\0")
        if len(value) > size:
            raise ValueError("DER integer too large for the curve")
        values.append(value.rjust(size, b"\0"))
        offset += 2 + length
    return values[0] + values[1]


def token(key_id, issuer_id, key_path, now=None, lifetime=1200):
    """An ES256 JWT for the App Store Connect API. Apple accepts a lifetime of at most 20 minutes."""
    now = int(now if now is not None else time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = b64url(json.dumps({"iss": issuer_id, "iat": now, "exp": now + lifetime,
                                 "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{header}.{payload}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path], input=signing_input,
                         capture_output=True, check=True).stdout
    return f"{header}.{payload}.{b64url(der_to_raw_signature(der))}"


class Client:
    def __init__(self, key_id=None, issuer_id=None, key_path=None):
        self.key_id = key_id or os.environ["ASC_KEY_ID"]
        self.issuer_id = issuer_id or os.environ["ASC_ISSUER_ID"]
        self.key_path = key_path or os.environ["ASC_KEY_PATH"]
        self._token, self._expires = None, 0

    def _authorization(self):
        if time.time() > self._expires - 120:
            self._token = token(self.key_id, self.issuer_id, self.key_path)
            self._expires = time.time() + 1200
        return f"Bearer {self._token}"

    def request(self, method, path, query=None, body=None):
        url = path if path.startswith("https://") else API + path
        if query:
            url += ("&" if "?" in url else "?") + urlencode(query)
        data = json.dumps(body).encode() if body is not None else None
        for attempt in range(6):
            request = Request(url, data=data, method=method, headers={
                "Authorization": self._authorization(), "Content-Type": "application/json",
                "User-Agent": "music-assistant-one-release (+https://github.com/AndrewLemons/music-assistant-one)"})
            try:
                with urlopen(request, timeout=60) as response:
                    raw = response.read()
                    return json.loads(raw) if raw else {}
            except HTTPError as error:
                raw = error.read()
                if error.code in RETRYABLE and attempt < 5:
                    time.sleep(min(60, 2 ** attempt * 3))
                    continue
                try:
                    errors = json.loads(raw).get("errors", [])
                except ValueError:
                    errors = [{"detail": raw.decode(errors="replace")[:500]}]
                raise AscError(error.code, method, path, errors) from None
            except URLError:
                if attempt == 5:
                    raise
                time.sleep(min(60, 2 ** attempt * 3))

    def get(self, path, **query):
        return self.request("GET", path, query or None)

    def all(self, path, **query):
        """Every item across pages."""
        page = self.get(path, **query)
        items = list(page.get("data", []))
        while next_url := page.get("links", {}).get("next"):
            page = self.request("GET", next_url)
            items += page.get("data", [])
        return items

    def post(self, path, body):
        return self.request("POST", path, body=body)

    def patch(self, path, body):
        return self.request("PATCH", path, body=body)

    def app_id(self, bundle_id):
        apps = [app for app in self.all("/v1/apps", **{"filter[bundleId]": bundle_id})
                if app["attributes"]["bundleId"] == bundle_id]
        if len(apps) != 1:
            raise SystemExit(f"Expected one App Store Connect app for {bundle_id}, found {len(apps)}.")
        return apps[0]["id"]
