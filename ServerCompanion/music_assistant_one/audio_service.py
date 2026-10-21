"""Authenticated, bounded audio delivery, independent of Music Assistant speaker queues."""

from __future__ import annotations

import asyncio
import hashlib
import logging
import re
import shutil
import time
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from pathlib import Path

from aiohttp import web

MAX_FILE_BYTES = 512 * 1024 * 1024
MAX_CACHE_BYTES = 2 * 1024 * 1024 * 1024
MAX_PENDING = 32
MAX_RENDERS = 4
RENDER_LIMIT = 13 * 60 * 60
CACHE_TTL = 60 * 60
TICKET_TTL = 12 * 60 * 60
# Players reload a growing playlist every segment, including while paused. An unfinished
# render nobody requests or downloads stops, releasing realtime provider stream slots.
ABANDON_AFTER = 30
# A listener starting another song releases its idle renders sooner.
PREEMPT_AFTER = 8
REVALIDATE_TTL = 30
FIRST_SEGMENT_WAIT = 120
STREAM_FILE = re.compile(r"^(index\.m3u8|init\.mp4|seg\d{1,6}\.m4s)$")
LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class AudioIdentity:
    """A credential is kept in memory only, never in paths, manifests, or log output."""

    user_id: str
    provider_filter: tuple[str, ...] = ()
    credential: str = field(default="", repr=False, compare=False)


@dataclass
class Ticket:
    identity: AudioIdentity
    uri: str
    expires: float
    validated: float = 0


@dataclass
class Render:
    """One provider stream feeding a growing HLS playlist and the complete FLAC file."""

    identity: AudioIdentity
    stream: Path
    accessed: float
    task: asyncio.Task[Path] | None = None
    waiters: int = 0


class AbandonedRender(Exception):
    """Nobody is listening to or downloading this render anymore."""


class LeasedFileResponse(web.FileResponse):
    """Release a cache lease after aiohttp's FileResponse finishes sending bytes."""

    def __init__(self, path, release, **kwargs):
        super().__init__(path, **kwargs)
        self.release = release

    async def prepare(self, request):
        try:
            return await super().prepare(request)
        finally:
            if self.release is not None:
                self.release()
                self.release = None


class AudioService:
    """Playback starts from HLS segments while the provider is still delivering audio.

    The same render completes a FLAC file that supports byte ranges, background
    downloads, and integrity checks. Identical requests coalesce into one render.
    Files are scoped to the account and its provider preferences. Requests never
    replace, start, or mutate a player queue.
    """

    def __init__(
        self,
        directory: Path,
        authenticate: Callable[[web.Request], Awaitable[AudioIdentity]],
        revalidate: Callable[[AudioIdentity], Awaitable[bool]],
        render: Callable[[AudioIdentity, str, Path, Path], Awaitable[None]],
    ) -> None:
        self.directory = directory
        self.authenticate = authenticate
        self.revalidate = revalidate
        self.render = render
        self.tickets: dict[str, Ticket] = {}
        self.pending: dict[str, Render] = {}
        self.semaphore = asyncio.Semaphore(MAX_RENDERS)
        self.clock = time.monotonic
        self.active: dict[Path, int] = {}

    async def start(self) -> None:
        await asyncio.to_thread(self.directory.mkdir, parents=True, exist_ok=True, mode=0o700)
        # No bearer tickets survive a restart, and incomplete renders are never served.
        for path in self.directory.glob("*.partial"):
            await asyncio.to_thread(path.unlink, missing_ok=True)
        for path in self.directory.glob("*.hls"):
            await asyncio.to_thread(shutil.rmtree, path, True)
        await self.prune()

    async def close(self) -> None:
        tasks = [render.task for render in self.pending.values() if render.task]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self.pending.clear()
        self.tickets.clear()

    async def capabilities(self, request: web.Request) -> web.Response:
        await self.authenticate(request)
        return web.json_response(
            {"version": 1, "independent_audio": True, "downloads": True, "format": "flac", "streaming": ["hls"]},
            headers={"Cache-Control": "no-store"},
        )

    async def resolve(self, request: web.Request) -> web.Response:
        identity = await self.authenticate(request)
        if request.content_length is None or request.content_length > 8192:
            raise web.HTTPRequestEntityTooLarge(max_size=8192, actual_size=request.content_length or 0)
        try:
            body = await request.json()
            uri = self.validate_uri(body.get("uri"))
        except (ValueError, TypeError, AttributeError) as error:
            raise web.HTTPBadRequest(text="A valid music URI is required.") from error
        now = self.clock()
        self.tickets = {key: value for key, value in self.tickets.items() if value.expires > now}
        if len(self.tickets) >= 4096:
            raise web.HTTPTooManyRequests(text="Too many audio requests.")
        ticket = str(uuid.uuid4())
        self.tickets[ticket] = Ticket(identity, uri, now + TICKET_TTL, validated=now)
        key = self.key(identity, uri)
        ready = (self.directory / (key + ".flac")).is_file()
        if not ready:
            # Begin with the provider now; the player's first request saves a round trip.
            self.ensure(key, identity, uri).accessed = now
        return web.json_response(
            {"path": f"one/v1/audio/{ticket}.flac", "stream": f"one/v1/stream/{ticket}/index.m3u8", "ready": ready},
            headers={"Cache-Control": "no-store"},
        )

    async def file(self, request: web.Request) -> web.StreamResponse:
        identity = await self.authenticate(request)
        return await self.serve(request, identity, self.validate_uri(request.query.get("uri")))

    async def audio(self, request: web.Request) -> web.StreamResponse:
        # Dynamic-route dispatch does not populate match_info, so parse only the
        # exact final UUID component, never a filesystem path supplied by a caller.
        value = request.path.rsplit("/", 1)[-1].removesuffix(".flac")
        if not request.path.endswith(".flac"):
            raise web.HTTPNotFound()
        ticket = await self.ticket(value)
        return await self.serve(request, ticket.identity, ticket.uri)

    async def stream(self, request: web.Request) -> web.StreamResponse:
        """Serve `stream/<ticket>/<file>` from the growing HLS rendition."""
        if request.method not in {"GET", "HEAD"}:
            raise web.HTTPMethodNotAllowed(request.method, ["GET", "HEAD"])
        parts = request.path.rsplit("/", 2)
        if len(parts) != 3 or not STREAM_FILE.match(parts[2]):
            raise web.HTTPNotFound()
        ticket = await self.ticket(parts[1])
        name = parts[2]
        key = self.key(ticket.identity, ticket.uri)
        render = self.pending.get(key)
        directory = self.directory / (key + ".hls")
        if render is None and not (directory / "index.m3u8").is_file():
            if name != "index.m3u8":
                raise web.HTTPNotFound()
            # The complete file outlived its stream, or an idle render stopped. Render again.
            render = self.ensure(key, ticket.identity, ticket.uri)
        if render is not None:
            render.accessed = self.clock()
            if name == "index.m3u8":
                self.preempt(ticket.identity, key)
        path = directory / name
        deadline = self.clock() + (FIRST_SEGMENT_WAIT if name == "index.m3u8" else 15)
        while not path.is_file():
            if render is None or render.task is None or render.task.done() or self.clock() > deadline:
                if render is not None and render.task and render.task.done() and not render.task.cancelled():
                    error = render.task.exception()
                    # Report the actual reason, such as a server out of storage.
                    if isinstance(error, web.HTTPException):
                        raise type(error)(text=error.text)
                raise web.HTTPBadGateway(text="This song could not be prepared.")
            await asyncio.sleep(0.05)
        await asyncio.to_thread(directory.touch)
        if name == "index.m3u8":
            text = await asyncio.to_thread(path.read_text)
            # Growing playlists start at the beginning instead of the live edge. AVFoundation
            # ignores this tag when it also carries PRECISE=YES.
            text = text.replace("#EXTM3U", "#EXTM3U\n#EXT-X-START:TIME-OFFSET=0", 1)
            return web.Response(
                text=text, content_type="application/vnd.apple.mpegurl",
                headers={"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"},
            )
        return web.FileResponse(path, headers={
            "Content-Type": "audio/mp4" if name.endswith(".m4s") else "video/mp4",
            "Cache-Control": "private, max-age=3600", "X-Content-Type-Options": "nosniff",
        })

    async def ticket(self, value: str) -> Ticket:
        ticket = self.tickets.get(value)
        if ticket is None or ticket.expires <= self.clock():
            raise web.HTTPNotFound()
        # Segments arrive every few seconds; revalidate the account at a bounded rate.
        if self.clock() - ticket.validated > REVALIDATE_TTL:
            if not await self.revalidate(ticket.identity):
                self.tickets.pop(value, None)
                raise web.HTTPUnauthorized()
            ticket.validated = self.clock()
        return ticket

    @staticmethod
    def validate_uri(value: object) -> str:
        # Resolve provider URIs through Music Assistant. This is never an HTTP fetch proxy.
        if not isinstance(value, str) or len(value) > 4096 or "://track/" not in value:
            raise web.HTTPUnprocessableEntity(text="Only finite music tracks can be prepared.")
        if any(ord(character) < 32 for character in value):
            raise web.HTTPBadRequest()
        return value

    def key(self, identity: AudioIdentity, uri: str) -> str:
        return hashlib.sha256(
            (identity.user_id + "\n" + "\n".join(identity.provider_filter) + "\n" + uri).encode()
        ).hexdigest()

    def ensure(self, key: str, identity: AudioIdentity, uri: str) -> Render:
        render = self.pending.get(key)
        if render is None:
            if len(self.pending) >= MAX_PENDING:
                raise web.HTTPTooManyRequests(text="The audio preparation queue is full.")
            render = Render(identity, self.directory / (key + ".hls"), self.clock())
            render.task = asyncio.create_task(self.prepare(render, uri, self.directory / (key + ".flac")))
            self.pending[key] = render
            render.task.add_done_callback(lambda done: self.finished(key, done))
        return render

    def preempt(self, identity: AudioIdentity, keep: str) -> None:
        now = self.clock()
        for key, render in self.pending.items():
            if (key != keep and render.identity.user_id == identity.user_id and render.waiters == 0
                    and now - render.accessed > PREEMPT_AFTER and render.task):
                render.task.cancel()

    async def serve(self, request: web.Request, identity: AudioIdentity, uri: str) -> web.StreamResponse:
        if request.method not in {"GET", "HEAD"}:
            raise web.HTTPMethodNotAllowed(request.method, ["GET", "HEAD"])
        key = self.key(identity, uri)
        path = self.directory / (key + ".flac")
        self.active[path] = self.active.get(path, 0) + 1

        def release():
            self.active[path] -= 1
            if self.active[path] == 0:
                self.active.pop(path, None)

        try:
            while not path.is_file():
                render = self.ensure(key, identity, uri)
                render.waiters += 1
                try:
                    # Other listeners may still be waiting if this request disconnects.
                    path = await asyncio.shield(render.task)
                except asyncio.CancelledError:
                    # A render stopped for lack of listeners just as this request arrived.
                    current = asyncio.current_task()
                    if render.task.cancelled() and not (current and current.cancelling()):
                        continue
                    raise
                except web.HTTPException:
                    raise
                except Exception as error:
                    raise web.HTTPBadGateway(text="This song could not be prepared.") from error
                finally:
                    render.waiters -= 1
                    render.accessed = self.clock()
            await asyncio.to_thread(path.touch)
            return LeasedFileResponse(path, release, headers={
                "Content-Type": "audio/flac", "Cache-Control": "private, no-store",
                "X-Content-Type-Options": "nosniff", "Content-Disposition": "inline; filename=track.flac",
            })
        except BaseException:
            release()
            raise

    def finished(self, key: str, task: asyncio.Task[Path]) -> None:
        if (render := self.pending.get(key)) is not None and render.task is task:
            self.pending.pop(key, None)
        # Retrieve errors even when every requesting client has disconnected. Provider
        # errors can contain stream URLs, so only the error type is logged.
        if not task.cancelled() and (error := task.exception()) and not isinstance(error, AbandonedRender):
            detail = error.text if isinstance(error, web.HTTPException) else type(error).__name__
            LOGGER.warning("Couldn't prepare audio: %s", detail)

    def abandoned(self, render: Render) -> bool:
        return render.waiters == 0 and self.clock() - render.accessed > ABANDON_AFTER

    async def prepare(self, render: Render, uri: str, path: Path) -> Path:
        temporary = path.with_suffix(".partial")
        complete = False
        try:
            async with self.semaphore:
                if self.abandoned(render):
                    raise AbandonedRender()
                if not await self.revalidate(render.identity):
                    raise web.HTTPUnauthorized()
                await self.prune()
                usage = await asyncio.to_thread(shutil.disk_usage, self.directory)
                if usage.free < 2 * MAX_FILE_BYTES + 128 * 1024 * 1024:
                    raise web.HTTPInsufficientStorage()
                await asyncio.to_thread(shutil.rmtree, render.stream, True)
                await asyncio.to_thread(render.stream.mkdir, mode=0o700)
                work = asyncio.create_task(self.render(render.identity, uri, temporary, render.stream))
                try:
                    async with asyncio.timeout(RENDER_LIMIT):
                        while not work.done():
                            await asyncio.wait({work}, timeout=1)
                            if not work.done() and self.abandoned(render):
                                raise AbandonedRender()
                        work.result()
                finally:
                    if not work.done():
                        work.cancel()
                        await asyncio.gather(work, return_exceptions=True)
                size = temporary.stat().st_size
                if not 4 < size <= MAX_FILE_BYTES:
                    raise web.HTTPUnprocessableEntity(text="The prepared audio is too large or empty.")
                with temporary.open("rb") as handle:
                    if handle.read(4) != b"fLaC":
                        raise web.HTTPBadGateway(text="The source did not produce FLAC audio.")
                await asyncio.to_thread(temporary.replace, path)
                complete = True
                return path
        finally:
            await asyncio.to_thread(temporary.unlink, missing_ok=True)
            if not complete:
                # Never leave a playlist that stops growing without an end marker.
                await asyncio.to_thread(shutil.rmtree, render.stream, True)

    async def prune(self) -> None:
        def size(path: Path) -> int:
            if path.is_dir():
                return sum(child.stat().st_size for child in path.iterdir() if child.is_file())
            return path.stat().st_size

        def candidates() -> list[tuple[Path, float, int]]:
            entries = []
            for path in [*self.directory.glob("*.flac"), *self.directory.glob("*.hls")]:
                try:
                    entries.append((path, path.stat().st_mtime, size(path)))
                except FileNotFoundError:
                    continue
            return sorted(entries, key=lambda entry: entry[1])

        files = await asyncio.to_thread(candidates)
        total = sum(size for _, _, size in files)
        for path, modified, size in files:
            if path in self.active or path.stem in self.pending:
                continue
            if total <= MAX_CACHE_BYTES - MAX_FILE_BYTES and time.time() - modified < CACHE_TTL:
                continue
            if path.is_dir():
                await asyncio.to_thread(shutil.rmtree, path, True)
            else:
                await asyncio.to_thread(path.unlink, missing_ok=True)
            total -= size
