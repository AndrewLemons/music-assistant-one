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
from types import SimpleNamespace
import unittest


@unittest.skipUnless(os.environ.get("MA_SERVER_SOURCE"), "Set MA_SERVER_SOURCE for server adapter interop")
class ProviderAdapterTests(unittest.IsolatedAsyncioTestCase):
    async def test_actual_server_models_and_ffmpeg_produce_seekable_flac(self):
        sys.path.insert(0, os.environ["MA_SERVER_SOURCE"])
        from music_assistant_models.auth import UserRole
        from music_assistant_models.enums import ContentType, MediaType
        from music_assistant_models.media_items import ProviderMapping, Track
        from music_assistant_models.media_items.audio_format import AudioFormat
        from music_assistant_models.streamdetails import StreamDetails
        from mutagen.flac import FLAC

        directory = Path(__file__).parents[1] / "music_assistant_one"
        spec = importlib.util.spec_from_file_location("one_adapter_interop", directory / "__init__.py",
                                                     submodule_search_locations=[str(directory)])
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        user = SimpleNamespace(user_id="listener", role=UserRole.USER, provider_filter=[])

        async def authenticate(token):
            return user if token == "fixture" else None

        async def get_item(uri):
            return Track(item_id="one", provider="fixture", name="Silence", duration=1,
                         provider_mappings={ProviderMapping(item_id="one", provider_domain="fixture", provider_instance="fixture")})

        async def details(queue_item):
            self.assertEqual(queue_item.queue_id, "one-independent")
            return StreamDetails(provider="fixture", item_id="one", media_type=MediaType.TRACK,
                                 audio_format=AudioFormat(content_type=ContentType.PCM_S16LE,
                                                          sample_rate=44100, bit_depth=16, channels=2))

        async def pcm(stream, format):
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
            await provider.render(module.AudioIdentity("listener", credential="fixture"), "fixture://track/one", path)
            info = FLAC(path).info
            self.assertEqual((info.length, info.sample_rate, info.bits_per_sample), (1, 44100, 16))
