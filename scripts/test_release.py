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


class SparkleFeedTests(unittest.TestCase):
    def setUp(self):
        import base64
        spec = importlib.util.spec_from_file_location('sparkle_appcast', SCRIPT.with_name('sparkle-appcast.py'))
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'PhraseLens.zip'
        self.archive.write_bytes(b'archive')
        self.feed = self.root / 'appcast.xml'
        self.info = {'CFBundleVersion': '13', 'CFBundleShortVersionString': '0.9.0',
                     'LSMinimumSystemVersion': '13.0', 'SUFeedURL': self.module.FEED_URL,
                     'SUPublicEDKey': base64.b64encode(b'k' * 32).decode()}
        self.signature = base64.b64encode(b's' * 64).decode()
        self.xml = f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>13</sparkle:version><sparkle:shortVersionString>0.9.0</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
        <enclosure url="{self.module.RELEASE_ROOT}/v0.9.0/PhraseLens.zip" length="7"
        sparkle:edSignature="{self.signature}" /></item></channel></rss>'''

    def test_validates_pinned_signed_feed(self):
        self.feed.write_text(self.xml)
        self.assertEqual(self.module.validate(self.feed, self.archive, self.info), self.signature)

    def test_rejects_unpinned_wrong_length_or_missing_signature(self):
        for old, new in [('v0.9.0', 'latest'), ('length="7"', 'length="8"'),
                         (self.signature, ''), ('<sparkle:version>13', '<sparkle:version>12'),
                         ('<sparkle:minimumSystemVersion>13.0', '<sparkle:minimumSystemVersion>12.0')]:
            with self.subTest(old=old):
                self.feed.write_text(self.xml.replace(old, new))
                with self.assertRaises(ValueError):
                    self.module.validate(self.feed, self.archive, self.info)

    def test_key_mismatch_fails_before_generation_without_output(self):
        app = self.root / 'PhraseLens.app'
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        output = self.root / 'output.xml'
        with patch.object(self.module, 'verify_artifacts', return_value=self.info), patch.object(self.module, 'run', return_value='different key') as run:
            with self.assertRaises(ValueError):
                self.module.generate(self.root, self.archive, app, output)
        self.assertFalse(output.exists())
        self.assertEqual(run.call_args.args[-1], '-p')

    def test_missing_key_fails_without_feed_output(self):
        app = self.root / 'PhraseLens.app'
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        output = self.root / 'output.xml'
        with patch.object(self.module, 'verify_artifacts', return_value=self.info), patch.object(self.module, 'run', side_effect=subprocess.CalledProcessError(1, 'generate_keys')):
            with self.assertRaises(subprocess.CalledProcessError):
                self.module.generate(self.root, self.archive, app, output)
        self.assertFalse(output.exists())


class ArtifactPreflightTests(unittest.TestCase):
    setUp = SparkleFeedTests.setUp

    def production_info(self):
        info = dict(self.info, CFBundleIdentifier='com.harry.phraselens', CFBundleExecutable='PhraseLens',
                    SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
                    SUSignedFeedFailureExpirationInterval=0, SUEnableSystemProfiling=False,
                    SUAutomaticallyUpdate=False)
        return info

    def test_security_and_identity_mismatch_rejected(self):
        info = self.production_info()
        self.module.validate_metadata(info, info)
        for key, value in [('CFBundleIdentifier', 'test.app'), ('SUPublicEDKey', self.signature),
                           ('CFBundleVersion', '12'), ('SURequireSignedFeed', False),
                           ('SUVerifyUpdateBeforeExtraction', False),
                           ('SUSignedFeedFailureExpirationInterval', 1728000),
                           ('SUAutomaticallyUpdate', True), ('SUEnableSystemProfiling', True)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.module.validate_metadata(dict(info, **{key: value}), info)
        for key in ('SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction'):
            insecure = dict(info, **{key: False})
            with self.assertRaises(ValueError):
                self.module.validate_metadata(insecure, insecure)

    def test_zip_rejects_traversal_absolute_and_symlink_escape(self):
        import stat, zipfile
        for name in ('../escape', '/absolute', 'PhraseLens.app/../../escape', 'bad\\path'):
            with self.subTest(name=name):
                with zipfile.ZipFile(self.archive, 'w') as archive:
                    archive.writestr(name, b'bad')
                with self.assertRaises(ValueError):
                    self.module.validate_zip_entries(self.archive)
        with zipfile.ZipFile(self.archive, 'w') as archive:
            link = zipfile.ZipInfo('PhraseLens.app/link')
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(link, '../../escape')
        with self.assertRaises(ValueError):
            self.module.validate_zip_entries(self.archive)

    def test_zip_rejects_writing_through_symlink(self):
        import stat, zipfile
        with zipfile.ZipFile(self.archive, 'w') as archive:
            link = zipfile.ZipInfo('PhraseLens.app/link')
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(link, 'Contents')
            archive.writestr('PhraseLens.app/link/file', b'bad')
        with self.assertRaises(ValueError):
            self.module.validate_zip_entries(self.archive)

    def test_same_version_content_permissions_and_links_must_match(self):
        import shutil
        app = self.root / 'PhraseLens.app'
        (app / 'Contents').mkdir(parents=True)
        info = self.production_info()
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        file = app / 'Contents/executable'
        file.write_bytes(b'original')
        candidate = self.root / 'other.app'
        shutil.copytree(app, candidate)
        with patch.object(self.module, 'run'):
            self.module.compare_bundle(candidate, app, info)
            (candidate / 'Contents/executable').write_bytes(b'changed')
            with self.assertRaises(ValueError):
                self.module.compare_bundle(candidate, app, info)
            (candidate / 'Contents/executable').write_bytes(b'original')
            (candidate / 'Contents/executable').chmod(0o755)
            with self.assertRaises(ValueError):
                self.module.compare_bundle(candidate, app, info)
            (candidate / 'Contents/executable').unlink()
            (candidate / 'Contents/executable').symlink_to('/tmp')
            with self.assertRaises(ValueError):
                self.module.compare_bundle(candidate, app, info)

    def test_dmg_detaches_when_bundle_validation_fails(self):
        import zipfile
        app = self.root / 'PhraseLens.app'
        (app / 'Contents').mkdir(parents=True)
        info = self.production_info()
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        production = self.root / 'production.plist'
        production.write_bytes(plistlib.dumps(info))
        with zipfile.ZipFile(self.archive, 'w') as archive:
            archive.writestr('PhraseLens.app/Contents/Info.plist', plistlib.dumps(info))
        with patch.object(self.module, 'run') as run, patch.object(self.module, 'compare_bundle', side_effect=[None, ValueError('stale dmg')]):
            with self.assertRaises(ValueError):
                self.module.verify_artifacts(self.archive, app, self.root / 'release.dmg', production)
        self.assertEqual(run.call_args.args[1], 'detach')


if __name__ == "__main__":
    unittest.main()
