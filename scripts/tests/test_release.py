import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("release", Path(__file__).parents[1] / "prepare-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_reserves_once_and_preserves_marketing_version(self):
        base = "MARKETING_VERSION = 0.1.0\nCURRENT_PROJECT_VERSION = 3\n"
        proposed = "MARKETING_VERSION = 0.2.0\nCURRENT_PROJECT_VERSION = 3\n"
        result = release.reserve_build(base, proposed)
        self.assertEqual(result, "MARKETING_VERSION = 0.2.0\nCURRENT_PROJECT_VERSION = 4\n")
        self.assertEqual(release.reserve_build(base, result), result)

    def test_manual_upload_number_is_never_lowered(self):
        self.assertEqual(release.reserve_build("CURRENT_PROJECT_VERSION = 3", "CURRENT_PROJECT_VERSION = 9"),
                         "CURRENT_PROJECT_VERSION = 9")

    def test_invalid_build_fails_closed(self):
        with self.assertRaises(ValueError):
            release.reserve_build("CURRENT_PROJECT_VERSION = nope", "CURRENT_PROJECT_VERSION = 3")
