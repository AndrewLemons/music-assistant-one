"""Authenticated, bounded file delivery, independent of Music Assistant speaker queues."""

from __future__ import annotations

import asyncio
import hashlib
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
CACHE_TTL = 60 * 60
TICKET_TTL = 12 * 60 * 60


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
    """A completed FLAC supports native seeking, background transfers, and integrity checks.

    Identical requests coalesce into one render. Files are scoped to the account and
    its provider preferences. Requests never replace, start, or mutate a player queue.
    """

    def __init__(
        self,
        directory: Path,
        authenticate: Callable[[web.Request], Awaitable[AudioIdentity]],
        revalidate: Callable[[AudioIdentity], Awaitable[bool]],
        render: Callable[[AudioIdentity, str, Path], Awaitable[None]],
    ) -> None:
        self.directory = directory
        self.authenticate = authenticate
        self.revalidate = revalidate
        self.render = render
        self.tickets: dict[str, Ticket] = {}
        self.pending: dict[str, asyncio.Task[Path]] = {}
        self.semaphore = asyncio.Semaphore(2)
        self.clock = time.monotonic
        self.active: dict[Path, int] = {}

    async def start(self) -> None:
        await asyncio.to_thread(self.directory.mkdir, parents=True, exist_ok=True, mode=0o700)
        # No bearer tickets survive a restart, and incomplete renders are never served.
        for path in self.directory.glob("*.partial"):
            await asyncio.to_thread(path.unlink, missing_ok=True)
        await self.prune()

    async def close(self) -> None:
        tasks = list(self.pending.values())
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self.pending.clear()
        self.tickets.clear()

    async def capabilities(self, request: web.Request) -> web.Response:
        await self.authenticate(request)
        return web.json_response(
            {"version": 1, "independent_audio": True, "downloads": True, "format": "flac"},
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
        self.tickets[ticket] = Ticket(identity, uri, now + TICKET_TTL)
        return web.json_response(
            {"path": f"one/v1/audio/{ticket}.flac"}, headers={"Cache-Control": "no-store"}
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
        ticket = self.tickets.get(value)
        if ticket is None or ticket.expires <= self.clock():
            raise web.HTTPNotFound()
        if not await self.revalidate(ticket.identity):
            self.tickets.pop(value, None)
            raise web.HTTPUnauthorized()
        return await self.serve(request, ticket.identity, ticket.uri)

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
            if not path.is_file():
                task = self.pending.get(key)
                if task is None:
                    if len(self.pending) >= MAX_PENDING:
                        raise web.HTTPTooManyRequests(text="The audio preparation queue is full.")
                    task = asyncio.create_task(self.prepare(identity, uri, path))
                    self.pending[key] = task
                    task.add_done_callback(lambda done: self.finished(key, done))
                try:
                    # Other listeners may still be waiting if this request disconnects.
                    path = await asyncio.shield(task)
                except web.HTTPException:
                    raise
                except Exception as error:
                    raise web.HTTPBadGateway(text="This song could not be prepared.") from error
            await asyncio.to_thread(path.touch)
            return LeasedFileResponse(path, release, headers={
                "Content-Type": "audio/flac", "Cache-Control": "private, no-store",
                "X-Content-Type-Options": "nosniff", "Content-Disposition": "inline; filename=track.flac",
            })
        except BaseException:
            release()
            raise

    def finished(self, key: str, task: asyncio.Task[Path]) -> None:
        self.pending.pop(key, None)
        # Retrieve errors even when every requesting client has disconnected.
        if not task.cancelled():
            task.exception()

    async def prepare(self, identity: AudioIdentity, uri: str, path: Path) -> Path:
        temporary = path.with_suffix(".partial")
        async with self.semaphore:
            if not await self.revalidate(identity):
                raise web.HTTPUnauthorized()
            await self.prune()
            usage = await asyncio.to_thread(shutil.disk_usage, self.directory)
            if usage.free < MAX_FILE_BYTES + 128 * 1024 * 1024:
                raise web.HTTPInsufficientStorage()
            try:
                async with asyncio.timeout(180):
                    await self.render(identity, uri, temporary)
                size = temporary.stat().st_size
                if not 4 < size <= MAX_FILE_BYTES:
                    raise web.HTTPUnprocessableEntity(text="The prepared audio is too large or empty.")
                with temporary.open("rb") as handle:
                    if handle.read(4) != b"fLaC":
                        raise web.HTTPBadGateway(text="The source did not produce FLAC audio.")
                await asyncio.to_thread(temporary.replace, path)
                return path
            finally:
                await asyncio.to_thread(temporary.unlink, missing_ok=True)

    async def prune(self) -> None:
        def candidates() -> list[tuple[Path, float, int]]:
            return sorted(((path, path.stat().st_mtime, path.stat().st_size)
                           for path in self.directory.glob("*.flac")), key=lambda entry: entry[1])

        files = await asyncio.to_thread(candidates)
        total = sum(size for _, _, size in files)
        for path, modified, size in files:
            if path in self.active or path.stem in self.pending:
                continue
            if total <= MAX_CACHE_BYTES - MAX_FILE_BYTES and time.time() - modified < CACHE_TTL:
                continue
            await asyncio.to_thread(path.unlink, missing_ok=True)
            total -= size
