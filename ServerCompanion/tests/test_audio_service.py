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
PLAYLIST = "#EXTM3U\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:2.0,\nseg0.m4s\n"


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

        self.release = None

        async def render(identity, uri, destination, stream):
            self.render_count += 1
            (stream / "init.mp4").write_bytes(b"init")
            (stream / "seg0.m4s").write_bytes(b"segment")
            (stream / "index.m3u8").write_text(PLAYLIST)
            if self.release is not None:
                await self.release.wait()
            await asyncio.sleep(0.02)
            (stream / "index.m3u8").write_text(PLAYLIST + "#EXT-X-ENDLIST\n")
            destination.write_bytes(self.body)

        self.service = SERVICE.AudioService(Path(self.temporary.name), authenticate, revalidate, render)
        await self.service.start()
        application = web.Application()
        application.router.add_get("/one/v1/capabilities", self.service.capabilities)
        application.router.add_post("/one/v1/resolve", self.service.resolve)
        application.router.add_get("/one/v1/file.flac", self.service.file)
        application.router.add_get("/one/v1/audio/{ticket}.flac", self.service.audio)
        application.router.add_get("/one/v1/stream/{ticket}/{file}", self.service.stream)
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

    async def resolve(self, uri="library://track/one"):
        async with self.client.post(self.url("/one/v1/resolve"), headers=self.auth, json={"uri": uri}) as response:
            self.assertEqual(response.status, 200)
            body = await response.json()
            self.assertNotIn("fixture", str(body))
            return body

    async def ticket(self, uri="library://track/one"):
        return "/" + (await self.resolve(uri))["path"]

    async def settle(self):
        while self.service.pending:
            await asyncio.sleep(0.01)

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
        await self.settle()
        self.valid = False
        # Segment requests revalidate the account at a bounded rate.
        now = self.service.clock()
        self.service.clock = lambda: now + SERVICE.REVALIDATE_TTL + 1
        async with self.client.get(self.url(path)) as response:
            self.assertEqual(response.status, 401)
        self.valid = True
        path = await self.ticket()
        self.service.clock = lambda: float("inf")
        async with self.client.get(self.url(path)) as response:
            self.assertEqual(response.status, 404)

    async def test_resolve_starts_rendering_and_reports_completed_audio(self):
        first = await self.resolve()
        self.assertFalse(first["ready"])
        self.assertTrue(first["stream"].startswith("one/v1/stream/") and first["stream"].endswith("/index.m3u8"))
        await self.settle()
        self.assertEqual(self.render_count, 1)
        self.assertTrue((await self.resolve())["ready"])
        self.assertEqual(self.render_count, 1)

    async def test_growing_playlist_plays_before_the_file_completes(self):
        self.release = asyncio.Event()
        stream = "/" + (await self.resolve())["stream"]
        async with self.client.get(self.url(stream)) as response:
            self.assertEqual(response.status, 200)
            self.assertTrue(response.headers["Content-Type"].startswith("application/vnd.apple.mpegurl"))
            text = await response.text()
        self.assertIn("#EXT-X-START:TIME-OFFSET=0", text)
        self.assertNotIn("#EXT-X-ENDLIST", text)
        async with self.client.get(self.url(stream.replace("index.m3u8", "seg0.m4s"))) as response:
            self.assertEqual(await response.read(), b"segment")
        self.assertEqual(list(Path(self.temporary.name).glob("*.flac")), [])
        self.release.set()
        await self.settle()
        async with self.client.get(self.url(stream)) as response:
            self.assertIn("#EXT-X-ENDLIST", await response.text())
        for name in ["../index.m3u8", "seg0.flac", "index.m3u8.tmp"]:
            async with self.client.get(self.url(stream.replace("index.m3u8", name))) as response:
                self.assertEqual(response.status, 404)
        self.assertEqual(self.render_count, 1)

    async def test_unattended_renders_stop_and_restart_when_requested(self):
        self.release = asyncio.Event()
        stream = "/" + (await self.resolve())["stream"]
        await asyncio.sleep(0.05)
        now = self.service.clock()
        self.service.clock = lambda: now + SERVICE.ABANDON_AFTER + 1
        await self.settle()
        self.assertEqual(list(Path(self.temporary.name).glob("*")), [])
        # The player's next request renders again rather than serving a stalled playlist.
        self.release.set()
        async with self.client.get(self.url(stream)) as response:
            self.assertEqual(response.status, 200)
        self.assertEqual(self.render_count, 2)

    async def test_starting_another_song_releases_idle_renders(self):
        self.release = asyncio.Event()
        first = await self.resolve("library://track/one")
        await asyncio.sleep(0.05)
        now = self.service.clock()
        self.service.clock = lambda: now + SERVICE.PREEMPT_AFTER + 1
        second = "/" + (await self.resolve("library://track/two"))["stream"]
        async with self.client.get(self.url(second)) as response:
            self.assertEqual(response.status, 200)
        await asyncio.sleep(0.05)
        self.assertEqual(len(self.service.pending), 1)
        self.release.set()
        await self.settle()
        self.assertEqual(len(list(Path(self.temporary.name).glob("*.flac"))), 1)
        self.assertNotEqual(first["path"], second)

    async def test_waiting_downloads_keep_a_render_alive(self):
        self.release = asyncio.Event()
        download = asyncio.create_task(self.client.get(
            self.url("/one/v1/file.flac?uri=library://track/one"), headers=self.auth))
        await asyncio.sleep(0.05)
        now = self.service.clock()
        self.service.clock = lambda: now + SERVICE.ABANDON_AFTER + 1
        await asyncio.sleep(1.2)
        self.assertEqual(len(self.service.pending), 1)
        self.release.set()
        async with await download as response:
            self.assertEqual(await response.read(), self.body)

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
        async def broken(identity, uri, destination, stream):
            destination.write_bytes(b"fLaCpartial")
            (stream / "index.m3u8").write_text(PLAYLIST)
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
