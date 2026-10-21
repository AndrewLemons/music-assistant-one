"""Optional Music Assistant provider; no additional ports, accounts, or dependencies."""

from __future__ import annotations

import asyncio
from contextlib import aclosing, suppress
from pathlib import Path

from aiohttp import web
from mutagen.flac import FLAC
from music_assistant_models.auth import Scope
from music_assistant_models.enums import ContentType, MediaType
from music_assistant_models.media_items.audio_format import AudioFormat
from music_assistant_models.queue_item import QueueItem

from music_assistant.controllers.webserver.helpers.auth_middleware import (
    current_user,
    get_authenticated_user,
    has_scope,
)
from music_assistant.models.plugin import PluginProvider

from .audio_service import MAX_FILE_BYTES, AudioIdentity, AudioService


async def setup(mass, manifest, config):
    """Use the server's provider lifecycle and existing authenticated webserver."""
    return OneAudioProvider(mass, manifest, config, set())


class OneAudioProvider(PluginProvider):
    async def loaded_in_mass(self) -> None:
        self.service = AudioService(
            Path(self.mass.storage_path) / ".one-audio", self.authenticate, self.revalidate, self.render
        )
        await self.service.start()
        self.unregister = []
        for path, handler, method in [
            ("/one/v1/capabilities", self.service.capabilities, "GET"),
            ("/one/v1/resolve", self.service.resolve, "POST"),
            ("/one/v1/file.flac", self.service.file, "*"),
            ("/one/v1/audio/*", self.service.audio, "*"),
            ("/one/v1/stream/*", self.service.stream, "*"),
        ]:
            self.unregister.append(self.mass.webserver.register_dynamic_route(path, handler, method))

    async def unload(self, is_removed: bool = False) -> None:
        for unregister in getattr(self, "unregister", []):
            unregister()
        if hasattr(self, "service"):
            await self.service.close()

    async def authenticate(self, request: web.Request) -> AudioIdentity:
        user = await get_authenticated_user(request)
        if user is None:
            raise web.HTTPUnauthorized()
        if not has_scope(user, Scope.LIBRARY_READ):
            raise web.HTTPForbidden()
        authorization = request.headers.get("Authorization", "")
        if not authorization.lower().startswith("bearer "):
            raise web.HTTPUnauthorized()
        return AudioIdentity(user.user_id, tuple(user.provider_filter or ()), authorization[7:])

    async def revalidate(self, identity: AudioIdentity) -> bool:
        user = await self.mass.webserver.auth.authenticate_with_token(identity.credential)
        return bool(user and user.user_id == identity.user_id and has_scope(user, Scope.LIBRARY_READ)
                    and tuple(user.provider_filter or ()) == identity.provider_filter)

    async def render(self, identity: AudioIdentity, uri: str, destination: Path, stream: Path) -> None:
        user = await self.mass.webserver.auth.authenticate_with_token(identity.credential)
        if user is None or not await self.revalidate(identity):
            raise web.HTTPUnauthorized()
        context = current_user.set(user)
        try:
            item = await self.mass.music.get_item_by_uri(uri)
            if item.media_type != MediaType.TRACK or not item.duration or item.duration > 6 * 60 * 60:
                raise web.HTTPUnprocessableEntity(text="Only finite music tracks can be prepared.")
            # Respect account provider preferences even without a speaker queue's userid.
            if identity.provider_filter:
                item.provider_mappings = {
                    mapping for mapping in item.provider_mappings
                    if mapping.provider_instance in identity.provider_filter
                }
                if not item.provider_mappings:
                    raise web.HTTPForbidden()
            queue_item = QueueItem.from_media_item(queue_id="one-independent", media_item=item)
            details = await self.mass.streams.audio.get_stream_details(queue_item)
            rate = min(192000, details.audio_format.sample_rate or 44100)
            depth = 24 if details.audio_format.bit_depth > 16 else 16
            pcm = AudioFormat(content_type=ContentType.PCM_S24LE if depth == 24 else ContentType.PCM_S16LE,
                              sample_rate=rate, bit_depth=depth, channels=details.audio_format.channels or 2)
            source = self.mass.streams.audio.get_media_stream(details, pcm)
            # Realtime providers deliver at playback speed, so the deadline follows the song.
            async with aclosing(source), asyncio.timeout(max(180, item.duration * 2 + 60)):
                await encode(source, pcm, destination, stream)
            actual_duration = await asyncio.to_thread(lambda: FLAC(destination).info.length)
            if actual_duration < item.duration - max(3, item.duration * 0.02):
                raise web.HTTPBadGateway(text="The audio source returned an incomplete song.")
        finally:
            current_user.reset(context)


async def encode(source, pcm: AudioFormat, destination: Path, stream: Path) -> None:
    """Encode one provider stream twice: lossless HLS segments for immediate playback, and a
    seekable FLAC file. Writing to a file gives FLAC its final sample count and MD5, so native
    players seek by byte range without restarting the provider.
    """
    flac = ["-c:a", "flac", "-sample_fmt", "s32" if pcm.bit_depth > 16 else "s16"]
    process = await asyncio.create_subprocess_exec(
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostats",
        "-f", pcm.content_type.value, "-ar", str(pcm.sample_rate), "-ac", str(pcm.channels), "-i", "pipe:0",
        "-map", "0:a", *flac, "-strict", "-2", "-f", "hls", "-hls_time", "2", "-hls_segment_type", "fmp4",
        "-hls_playlist_type", "event", "-hls_flags", "temp_file", "-hls_fmp4_init_filename", "init.mp4",
        "-hls_segment_filename", str(stream / "seg%d.m4s"), str(stream / "index.m3u8"),
        "-map", "0:a", *flac, "-f", "flac", "-fs", str(MAX_FILE_BYTES), str(destination),
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
    )

    async def feed() -> None:
        try:
            async for chunk in source:
                process.stdin.write(chunk)
                await process.stdin.drain()
        except ConnectionError:
            return  # FFmpeg exited; its status explains why.
        finally:
            process.stdin.close()
            with suppress(ConnectionError):
                await process.stdin.wait_closed()

    feeder = asyncio.create_task(feed())
    try:
        await asyncio.gather(feeder, process.wait())
        if process.returncode != 0:
            raise web.HTTPBadGateway(text="The audio source ended unexpectedly.")
    finally:
        if process.returncode is None:
            process.kill()
            await process.wait()
        if not feeder.done():
            feeder.cancel()
            await asyncio.gather(feeder, return_exceptions=True)
