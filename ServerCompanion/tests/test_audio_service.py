"""Transport-level tests use a real loopback HTTP server and completed audio files."""

import asyncio
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

from aiohttp import ClientSession, web
from aiohttp.test_utils import TestServer

SOURCE = Path(__file__).parents[1] / "music_assistant_one" / "audio_service.py"
SPEC = importlib.util.spec_from_file_location("one_audio_service", SOURCE)
SERVICE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SERVICE
SPEC.loader.exec_module(SERVICE)


class AudioServiceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.valid = True
        self.render_count = 0
        self.body = b"fLaC" + b"audio-fixture" * 100

        async def authenticate(request):
            value = request.headers.get("Authorization", "")
            if value != "Bearer fixture":
                raise web.HTTPUnauthorized()
            return SERVICE.AudioIdentity("listener", credential="fixture")

        async def revalidate(identity):
            return self.valid and identity.credential == "fixture"

        async def render(identity, uri, destination):
            self.render_count += 1
            await asyncio.sleep(0.02)
            destination.write_bytes(self.body)

        self.service = SERVICE.AudioService(Path(self.temporary.name), authenticate, revalidate, render)
        await self.service.start()
        application = web.Application()
        application.router.add_get("/one/v1/capabilities", self.service.capabilities)
        application.router.add_post("/one/v1/resolve", self.service.resolve)
        application.router.add_get("/one/v1/file.flac", self.service.file)
        application.router.add_get("/one/v1/audio/{ticket}.flac", self.service.audio)
        self.server = TestServer(application)
        await self.server.start_server()
        self.client = ClientSession()
        self.auth = {"Authorization": "Bearer fixture"}

    async def asyncTearDown(self):
        await self.client.close()
        await self.server.close()
        await self.service.close()
        self.temporary.cleanup()

    def url(self, path):
        return self.server.make_url(path)

    async def ticket(self, uri="library://track/one"):
        async with self.client.post(self.url("/one/v1/resolve"), headers=self.auth, json={"uri": uri}) as response:
            self.assertEqual(response.status, 200)
            body = await response.json()
            self.assertNotIn("fixture", str(body))
            return "/" + body["path"]

    async def test_capabilities_and_full_files_require_authentication(self):
        for path in ["/one/v1/capabilities", "/one/v1/file.flac?uri=library://track/one"]:
            async with self.client.get(self.url(path)) as response:
                self.assertEqual(response.status, 401)
        async with self.client.get(self.url("/one/v1/capabilities"), headers=self.auth) as response:
            self.assertTrue((await response.json())["downloads"])
        self.assertEqual(self.render_count, 0)

    async def test_ticket_supports_native_ranges_without_exposing_account_credentials(self):
        path = await self.ticket()
        async with self.client.get(self.url(path), headers={"Range": "bytes=4-15"}) as response:
            self.assertEqual(response.status, 206)
            self.assertEqual(await response.read(), self.body[4:16])
            self.assertEqual(response.headers["Content-Type"], "audio/flac")
            self.assertEqual(response.headers["Content-Range"], f"bytes 4-15/{len(self.body)}")
            self.assertEqual(response.headers["Cache-Control"], "private, no-store")
        async with self.client.head(self.url(path)) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(int(response.headers["Content-Length"]), len(self.body))
        self.assertEqual(self.render_count, 1)

    async def test_simultaneous_playback_and_download_coalesce_one_render(self):
        path = await self.ticket()

        async def fetch(path, headers=None):
            async with self.client.get(self.url(path), headers=headers) as response:
                self.assertEqual(response.status, 200)
                return await response.read()

        results = await asyncio.gather(fetch(path), fetch("/one/v1/file.flac?uri=library://track/one", self.auth))
        self.assertEqual(results, [self.body, self.body])
        self.assertEqual(self.render_count, 1)

    async def test_revoked_credentials_and_expired_tickets_stop_audio_access(self):
        path = await self.ticket()
        self.valid = False
        async with self.client.get(self.url(path)) as response:
            self.assertEqual(response.status, 401)
        self.valid = True
        path = await self.ticket()
        self.service.clock = lambda: float("inf")
        async with self.client.get(self.url(path)) as response:
            self.assertEqual(response.status, 404)
        self.assertEqual(self.render_count, 0)

    async def test_live_streams_http_urls_and_path_injection_are_rejected(self):
        for uri in ["http://localhost/private", "library://radio/one", "../../secret", "library://track/one\n"]:
            async with self.client.post(self.url("/one/v1/resolve"), headers=self.auth, json={"uri": uri}) as response:
                self.assertIn(response.status, [400, 422])
        self.assertEqual(self.render_count, 0)

    async def test_account_and_provider_preferences_have_separate_cache_keys(self):
        first = SERVICE.AudioIdentity("one", ("local",), "fixture")
        second = SERVICE.AudioIdentity("two", ("local",), "fixture")
        changed = SERVICE.AudioIdentity("one", ("other",), "fixture")
        keys = {self.service.key(identity, "library://track/one") for identity in [first, second, changed]}
        self.assertEqual(len(keys), 3)

    async def test_failed_or_cancelled_render_never_publishes_partial_audio(self):
        async def broken(identity, uri, destination):
            destination.write_bytes(b"fLaCpartial")
            raise RuntimeError("fixture error")

        self.service.render = broken
        path = await self.ticket()
        async with self.client.get(self.url(path)) as response:
            self.assertEqual(response.status, 502)
            self.assertNotIn("fixture error", await response.text())
        self.assertEqual(list(Path(self.temporary.name).glob("*")), [])

    async def test_cache_cleanup_preserves_active_transfers(self):
        path = Path(self.temporary.name) / "active.flac"
        path.write_bytes(self.body)
        self.service.active[path] = 1
        import os
        os.utime(path, (0, 0))
        await self.service.prune()
        self.assertTrue(path.exists())
        self.service.active.clear()
        await self.service.prune()
        self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
