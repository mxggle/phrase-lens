import importlib.util
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("release.py")
spec = importlib.util.spec_from_file_location("release", SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "packaging").mkdir()
        (self.root / "landing/zh").mkdir(parents=True)
        self.plist = self.root / "packaging/Info.plist"
        self.plist.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.7.0", "CFBundleVersion": "11"}))
        self.changelog = self.root / "CHANGELOG.md"
        self.changelog.write_text(
            "# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- Curated note.\n\n"
            "## [0.7.0] — 2026-09-24\n\nOld release.\n\n"
            "[Unreleased]: https://github.com/mxggle/phrase-lens/compare/v0.7.0...HEAD\n"
        )
        self.pages = [self.root / "landing/index.html", self.root / "landing/zh/index.html"]
        for page in self.pages:
            page.write_text('<a data-release-version="v0.7.0" '
                            'href="https://github.com/mxggle/phrase-lens/releases/tag/v0.7.0">'
                            'Latest <span data-release-label>0.7.0</span></a>')
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-qm", "base")
        self.git("tag", "v0.7.0")

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def commit(self, message):
        self.git("commit", "--allow-empty", "-qm", message,
                 "--author=Test <test@example.com>")

    def test_no_change_does_not_release(self):
        with patch.multiple(release, ROOT=self.root, PLIST=self.plist, CHANGELOG=self.changelog, LANDING=self.pages):
            self.assertFalse(release.plan()["release"])

    def test_feature_release_updates_every_version_surface_and_keeps_curated_notes(self):
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.com",
                 "commit", "--allow-empty", "-qm", "feat: add a feature")
        with patch.multiple(release, ROOT=self.root, PLIST=self.plist, CHANGELOG=self.changelog, LANDING=self.pages):
            result = release.plan()
            self.assertEqual((result["next"], result["build"]), ("0.8.0", "12"))
            release.prepare(result)
        self.assertEqual(plistlib.loads(self.plist.read_bytes())["CFBundleShortVersionString"], "0.8.0")
        notes = self.changelog.read_text()
        self.assertIn("## [0.8.0]", notes)
        self.assertIn("Curated note.", notes.split("## [0.8.0]")[1].split("## [0.7.0]")[0])
        self.assertIn("add a feature.", notes)
        self.assertIn("compare/v0.7.0...v0.8.0", notes)
        for page in self.pages:
            self.assertIn('data-release-version="v0.8.0"', page.read_text())
            self.assertIn('data-release-label>0.8.0</span>', page.read_text())

    def test_breaking_change_raises_major(self):
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.com",
                 "commit", "--allow-empty", "-qm", "fix!: remove old behavior")
        with patch.multiple(release, ROOT=self.root, PLIST=self.plist):
            self.assertEqual(release.plan()["next"], "1.0.0")


if __name__ == "__main__":
    unittest.main()
