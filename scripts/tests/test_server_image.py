import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("server_image", Path(__file__).parents[1] / "server-image.py")
server_image = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server_image)
DIGEST = "sha256:" + "a" * 64


class ServerImageTests(unittest.TestCase):
    def test_reads_the_pinned_upstream_release(self):
        dockerfile = f"# syntax=docker/dockerfile:1\nFROM ghcr.io/music-assistant/server:2.10.7@{DIGEST}\nRUN true\n"
        self.assertEqual(server_image.music_assistant_version(dockerfile), "2.10.7")

    def test_unpinned_or_prerelease_bases_fail_closed(self):
        for base in ["ghcr.io/music-assistant/server:2.10.7", f"ghcr.io/music-assistant/server:latest@{DIGEST}",
                     f"ghcr.io/music-assistant/server:2.11.0b1@{DIGEST}", f"example.com/server:2.10.7@{DIGEST}"]:
            with self.subTest(base=base), self.assertRaises(ValueError):
                server_image.music_assistant_version(f"FROM {base}\n")


if __name__ == "__main__":
    unittest.main()
