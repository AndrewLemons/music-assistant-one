"""Optional interop with an installed Music Assistant source tree and real FFmpeg.

Set MA_SERVER_SOURCE and run with that server's Python environment to enable it.
The regular HTTP suite needs only aiohttp; it never installs a server or ML packages.
"""

import asyncio
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest


@unittest.skipUnless(os.environ.get("MA_SERVER_SOURCE"), "Set MA_SERVER_SOURCE for server adapter interop")
class ProviderAdapterTests(unittest.IsolatedAsyncioTestCase):
    def adapter(self):
        sys.path.insert(0, os.environ["MA_SERVER_SOURCE"])
        directory = Path(__file__).parents[1] / "music_assistant_one"
        spec = importlib.util.spec_from_file_location("one_adapter_interop", directory / "__init__.py",
                                                     submodule_search_locations=[str(directory)])
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        return module

    async def test_actual_server_models_and_ffmpeg_produce_hls_and_seekable_flac(self):
        sys.path.insert(0, os.environ["MA_SERVER_SOURCE"])
        from music_assistant_models.auth import UserRole
        from music_assistant_models.enums import ContentType, MediaType
        from music_assistant_models.media_items import ProviderMapping, Track
        from music_assistant_models.media_items.audio_format import AudioFormat
        from music_assistant_models.streamdetails import StreamDetails
        from mutagen.flac import FLAC

        module = self.adapter()
        user = SimpleNamespace(user_id="listener", role=UserRole.USER, provider_filter=[])

        async def authenticate(token):
            return user if token == "fixture" else None

        async def get_item(uri):
            return Track(item_id="one", provider="fixture", name="Silence", duration=3,
                         provider_mappings={ProviderMapping(item_id="one", provider_domain="fixture", provider_instance="fixture")})

        async def details(queue_item):
            self.assertEqual(queue_item.queue_id, "one-independent")
            return StreamDetails(provider="fixture", item_id="one", media_type=MediaType.TRACK,
                                 audio_format=AudioFormat(content_type=ContentType.PCM_S16LE,
                                                          sample_rate=44100, bit_depth=16, channels=2))

        async def pcm(stream, format):
            for _ in range(3):
                yield bytes(44100 * 4)

        # The adapter's real QueueItem, auth scope check, and FFMpeg process run
        # against a deterministic source without operating a real music account.
        provider = object.__new__(module.OneAudioProvider)
        provider.mass = SimpleNamespace(
            webserver=SimpleNamespace(auth=SimpleNamespace(authenticate_with_token=authenticate)),
            music=SimpleNamespace(get_item_by_uri=get_item),
            streams=SimpleNamespace(audio=SimpleNamespace(get_stream_details=details, get_media_stream=pcm)),
        )
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "output.partial"
            stream = Path(temporary) / "output.hls"
            stream.mkdir()
            await provider.render(module.AudioIdentity("listener", credential="fixture"), "fixture://track/one",
                                  path, stream)
            info = FLAC(path).info
            self.assertEqual((info.length, info.sample_rate, info.bits_per_sample), (3, 44100, 16))
            playlist = (stream / "index.m3u8").read_text()
            self.assertIn("#EXT-X-PLAYLIST-TYPE:EVENT", playlist)
            self.assertIn("#EXT-X-ENDLIST", playlist)
            self.assertTrue((stream / "init.mp4").read_bytes()[4:8] == b"ftyp")
            self.assertGreaterEqual(len(list(stream.glob("seg*.m4s"))), 1)
            self.assertEqual(list(stream.glob("*.tmp")), [])

    async def test_realtime_source_publishes_audio_without_default_probe_delay(self):
        from music_assistant_models.enums import ContentType
        from music_assistant_models.media_items.audio_format import AudioFormat

        module = self.adapter()
        pcm = AudioFormat(content_type=ContentType.PCM_S16LE, sample_rate=44100, bit_depth=16, channels=2)
        stopped = asyncio.Event()

        async def source():
            try:
                # Fifty milliseconds of audio at a time, paced like a live provider.
                for _ in range(200):
                    yield bytes(8820)
                    await asyncio.sleep(0.05)
            finally:
                stopped.set()

        with tempfile.TemporaryDirectory() as temporary:
            stream = Path(temporary) / "stream"
            stream.mkdir()
            started = time.monotonic()
            task = asyncio.create_task(module.encode(source(), pcm, Path(temporary) / "audio.flac", stream))
            try:
                async with asyncio.timeout(3):
                    while not (stream / "index.m3u8").exists():
                        if task.done():
                            await task
                        await asyncio.sleep(0.01)
                elapsed = time.monotonic() - started
                print(f"Realtime source first segment: {elapsed:.3f}s", flush=True)
                self.assertFalse(task.done(), "Playback must start while the provider is still streaming")
                self.assertTrue((stream / "seg0.m4s").is_file())
                self.assertNotIn("#EXT-X-ENDLIST", (stream / "index.m3u8").read_text())
            finally:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)
            self.assertTrue(stopped.is_set(), "Cancelling playback must close the provider stream")

    async def test_low_latency_encoding_preserves_high_resolution_pcm_exactly(self):
        from music_assistant_models.enums import ContentType
        from music_assistant_models.media_items.audio_format import AudioFormat
        from mutagen.flac import FLAC

        module = self.adapter()
        pcm = AudioFormat(content_type=ContentType.PCM_S24LE, sample_rate=192000, bit_depth=24, channels=2)
        samples = bytes([1, 2, 3, 241, 242, 243]) * 192000 * 2

        async def source():
            yield samples

        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "audio.flac"
            stream = Path(temporary) / "stream"
            stream.mkdir()
            await module.encode(source(), pcm, path, stream)
            info = FLAC(path).info
            self.assertEqual((info.length, info.sample_rate, info.bits_per_sample), (2, 192000, 24))
            process = await asyncio.create_subprocess_exec(
                "ffmpeg", "-v", "error", "-i", str(path), "-f", "s24le", "pipe:1",
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            decoded, errors = await process.communicate()
            self.assertEqual(process.returncode, 0, errors)
            self.assertEqual(decoded, samples)
