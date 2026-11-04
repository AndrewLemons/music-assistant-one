"""Build the complete-file control through the real companion's dual-output encoder."""
import asyncio
import importlib.util
from pathlib import Path
import sys

from music_assistant_models.enums import ContentType
from music_assistant_models.media_items.audio_format import AudioFormat

spec = importlib.util.spec_from_file_location("one_seek_adapter", "/companion/music_assistant_one/__init__.py",
                                             submodule_search_locations=["/companion/music_assistant_one"])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


async def main():
    process = await asyncio.create_subprocess_exec(
        "ffmpeg", "-v", "error", "-i", "/w/chirp.flac", "-f", "s16le", "pipe:1",
        stdout=asyncio.subprocess.PIPE)

    async def source():
        while chunk := await process.stdout.read(65536):
            yield chunk
        if await process.wait():
            raise RuntimeError("Fixture decoding failed")

    stream = Path("/w/stream")
    stream.mkdir()
    pcm = AudioFormat(content_type=ContentType.PCM_S16LE, sample_rate=44100, bit_depth=16, channels=2)
    try:
        await module.encode(source(), pcm, Path("/w/chirp.m4a"), stream)
    finally:
        if process.returncode is None:
            process.kill()
        await process.wait()


asyncio.run(main())
