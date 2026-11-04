"""A minimal GitHub REST client for workflow helpers (standard library only)."""
import json
import os
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


class GitHubError(RuntimeError):
    def __init__(self, status, method, path, body):
        self.status = status
        super().__init__(f"GitHub {method} {path} failed with HTTP {status}: {body[:500]}")


class GitHub:
    def __init__(self, token=None, repository=None, api=None):
        self.token = token or os.environ["GH_TOKEN"]
        self.repository = repository or os.environ["GITHUB_REPOSITORY"]
        self.api = (api or os.environ.get("GITHUB_API_URL") or "https://api.github.com").rstrip("/")

    def request(self, method, path, body=None):
        url = path if path.startswith("https://") else f"{self.api}/repos/{self.repository}{path}"
        data = json.dumps(body).encode() if body is not None else None
        for attempt in range(4):
            request = Request(url, data=data, method=method, headers={
                "Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28", "Content-Type": "application/json"})
            try:
                with urlopen(request, timeout=60) as response:
                    raw = response.read()
                    return json.loads(raw) if raw else {}
            except HTTPError as error:
                text = error.read().decode(errors="replace")
                if error.code in {500, 502, 503, 504} and attempt < 3:
                    time.sleep(2 ** attempt * 3)
                    continue
                raise GitHubError(error.code, method, path, text) from None
            except URLError:
                if attempt == 3:
                    raise
                time.sleep(2 ** attempt * 3)

    def get(self, path):
        return self.request("GET", path)

    def paginate(self, path, limit=10):
        """Up to `limit` pages of a list endpoint."""
        items = []
        separator = "&" if "?" in path else "?"
        for page in range(1, limit + 1):
            batch = self.get(f"{path}{separator}per_page=100&page={page}")
            items += batch
            if len(batch) < 100:
                break
        return items

    def post(self, path, body):
        return self.request("POST", path, body)
