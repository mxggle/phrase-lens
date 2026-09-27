#!/usr/bin/env python3
"""Generate a signed, version-pinned Sparkle feed using login Keychain tools."""
import argparse
import base64
import html
import hashlib
import stat
import zipfile
import posixpath
import re
import os
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path, PurePosixPath

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
FEED_URL = 'https://github.com/mxggle/phrase-lens/releases/latest/download/appcast.xml'
RELEASE_ROOT = 'https://github.com/mxggle/phrase-lens/releases/download'


def run(*args):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True)
    if result.returncode:
        diagnostic = (result.stderr or result.stdout)[-2000:].strip()
        raise ValueError(f'{Path(str(args[0])).name} failed ({result.returncode}): {diagnostic}')
    return result.stdout.strip()


def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def validate(feed, archive, info):
    items = ET.parse(feed).getroot().findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected exactly one current update in appcast')
    item = items[0]
    enclosure = item.find('enclosure')
    if enclosure is None:
        raise ValueError('Missing update enclosure')
    expected = f"{RELEASE_ROOT}/v{info['CFBundleShortVersionString']}/{archive.name}"
    if enclosure.get('url') != expected:
        raise ValueError('Update URL must be pinned to this release version')
    if enclosure.get('length') != str(archive.stat().st_size):
        raise ValueError('Archive length does not match feed')
    signature = enclosure.get(SPARKLE + 'edSignature', '')
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Missing or malformed Ed25519 signature')
    for key, plist_key in [('version', 'CFBundleVersion'), ('shortVersionString', 'CFBundleShortVersionString')]:
        value = item.findtext(SPARKLE + key) or enclosure.get(SPARKLE + key)
        if value != info[plist_key]:
            raise ValueError(f'Appcast {key} does not match packaged app')
    if item.findtext(SPARKLE + 'minimumSystemVersion') != info['LSMinimumSystemVersion']:
        raise ValueError('Appcast minimum macOS version does not match packaged app')
    return signature


PRODUCTION_PLIST = Path(__file__).resolve().parents[1] / 'packaging/Info.plist'
METADATA_KEYS = ('CFBundleIdentifier', 'CFBundleExecutable', 'CFBundleVersion',
                 'CFBundleShortVersionString', 'LSMinimumSystemVersion', 'SUPublicEDKey', 'SUFeedURL',
                 'SUVerifyUpdateBeforeExtraction', 'SURequireSignedFeed',
                 'SUSignedFeedFailureExpirationInterval', 'SUEnableSystemProfiling', 'SUAutomaticallyUpdate')


def validate_metadata(info, expected):
    for key in METADATA_KEYS:
        if key not in expected or key not in info or type(info[key]) is not type(expected[key]) or info[key] != expected[key]:
            raise ValueError(f'Packaged app {key} does not match production configuration')
    if info['SUFeedURL'] != FEED_URL or info['CFBundleIdentifier'] != 'com.harry.phraselens':
        raise ValueError('Invalid production update identity')
    for key in ('SUVerifyUpdateBeforeExtraction', 'SURequireSignedFeed'):
        if info[key] is not True:
            raise ValueError(f'{key} must remain enabled')
    if info['SUSignedFeedFailureExpirationInterval'] != 0 or info['SUEnableSystemProfiling'] is not False or info['SUAutomaticallyUpdate'] is not False:
        raise ValueError('Unsafe production update security or consent settings')
    if len(base64.b64decode(info['SUPublicEDKey'], validate=True)) != 32:
        raise ValueError('Invalid production update public key')


def bundle_tree(bundle):
    result = {}
    for path in [bundle, *sorted(bundle.rglob('*'))]:
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        name = str(path.relative_to(bundle))
        if stat.S_ISLNK(metadata.st_mode):
            target = os.readlink(path)
            if not path.resolve().is_relative_to(bundle.resolve()):
                raise ValueError(f'Bundle symlink escapes application: {name}')
            result[name] = ('link', mode, target)
        elif stat.S_ISDIR(metadata.st_mode):
            result[name] = ('directory', mode)
        elif stat.S_ISREG(metadata.st_mode):
            result[name] = ('file', mode, file_hash(path))
        else:
            raise ValueError(f'Unsupported bundle entry: {name}')
    return result


def compare_bundle(candidate, app, expected):
    validate_metadata(plistlib.loads((candidate / 'Contents/Info.plist').read_bytes()), expected)
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', candidate)
    if bundle_tree(candidate) != bundle_tree(app):
        raise ValueError('Archive application differs from the signed packaged application')


def validate_zip_entries(archive):
    with zipfile.ZipFile(archive) as compressed:
        links = set()
        names = set()
        for entry in compressed.infolist():
            path = PurePosixPath(entry.filename)
            if path.is_absolute() or '..' in path.parts or '\\' in entry.filename or not path.parts:
                raise ValueError('Unsafe ZIP entry path')
            name = str(path)
            if name in names:
                raise ValueError('Duplicate ZIP entry')
            names.add(name)
            mode = entry.external_attr >> 16
            if stat.S_ISLNK(mode):
                target = compressed.read(entry).decode('utf-8')
                resolved = posixpath.normpath(posixpath.join(str(path.parent), target))
                if target.startswith('/') or resolved == '..' or resolved.startswith('../'):
                    raise ValueError('ZIP symlink escapes extraction directory')
                links.add(name)
            elif stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError('Unsupported ZIP entry type')
        for name in names:
            if any(str(parent) in links for parent in PurePosixPath(name).parents):
                raise ValueError('ZIP entry traverses a symlink')


def verify_artifacts(archive, app, dmg=None, production_plist=PRODUCTION_PLIST):
    expected = plistlib.loads(production_plist.read_bytes())
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    validate_metadata(info, expected)
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    validate_zip_entries(archive)
    with tempfile.TemporaryDirectory(prefix='phrase-lens-verify-') as directory:
        staging = Path(directory)
        extracted = staging / 'zip'
        extracted.mkdir()
        run('/usr/bin/ditto', '-x', '-k', archive, extracted)
        if {entry.name for entry in extracted.iterdir()} - {app.name, '__MACOSX'}:
            raise ValueError('Unexpected ZIP root entries')
        compare_bundle(extracted / app.name, app, expected)
        if dmg is not None:
            mount = staging / 'dmg'
            mount.mkdir()
            run('/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, dmg)
            try:
                compare_bundle(mount / app.name, app, expected)
            finally:
                run('/usr/bin/hdiutil', 'detach', mount)
    return info


def generate(tools, archive, app, output, account='phraselens-updates', dmg=None):
    verified_archive_hash = file_hash(archive)
    info = verify_artifacts(archive, app, dmg)
    if info.get('SUFeedURL') != FEED_URL:
        raise ValueError('Packaged app does not use the production update feed')
    public_key = info.get('SUPublicEDKey', '')
    if len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError('Packaged app is missing a valid Sparkle public key')
    # -p only reads an existing public key. Never generate or export a private key here.
    if run(tools / 'generate_keys', '--account', account, '-p') != public_key:
        raise ValueError('Keychain signing key does not match the packaged public key')
    with tempfile.TemporaryDirectory(prefix='phrase-lens-appcast-') as directory:
        staging = Path(directory)
        shutil.copy2(archive, staging / archive.name)
        if file_hash(staging / archive.name) != verified_archive_hash:
            raise ValueError('Archive changed after artifact verification')
        feed = staging / 'appcast.xml'
        changelog = Path(__file__).resolve().parents[1] / 'CHANGELOG.md'
        if changelog.exists():
            version = re.escape(info['CFBundleShortVersionString'])
            notes = re.search(rf'^## \[{version}\].*?\n(.*?)(?=^## \[|\Z)',
                              changelog.read_text(), re.M | re.S)
            if notes:
                # Inline HTML avoids unsigned external release-note requests.
                (staging / (archive.stem + '.html')).write_text(
                    '<pre>' + html.escape(notes.group(1).strip()) + '</pre>')
        run(tools / 'generate_appcast', '--account', account,
            '--maximum-deltas', '0', '--maximum-versions', '1', '--embed-release-notes',
            '--download-url-prefix', f"{RELEASE_ROOT}/v{info['CFBundleShortVersionString']}/",
            '-o', feed, staging)
        signature = validate(feed, archive, info)
        run(tools / 'sign_update', '--account', account, '--verify', archive, signature)
        if info.get('SURequireSignedFeed'):
            run(tools / 'sign_update', '--account', account, '--verify', feed)
        output.parent.mkdir(parents=True, exist_ok=True)
        pending = output.with_suffix('.xml.pending')
        shutil.copy2(feed, pending)
        os.replace(pending, output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools', type=Path, default=Path('.build/artifacts/sparkle/Sparkle/bin'))
    parser.add_argument('--archive', type=Path, default=Path('dist/PhraseLens.zip'))
    parser.add_argument('--app', type=Path, default=Path('dist/PhraseLens.app'))
    parser.add_argument('--output', type=Path, default=Path('dist/appcast.xml'))
    parser.add_argument('--dmg', type=Path, help='Also verify the release disk image')
    parser.add_argument('--verify-artifacts-only', action='store_true', help='Verify bundles without Keychain access or signing')
    parser.add_argument('--account', default='phraselens-updates')
    args = parser.parse_args()
    try:
        dmg = args.dmg.resolve() if args.dmg else None
        if args.verify_artifacts_only:
            verify_artifacts(args.archive.resolve(), args.app.resolve(), dmg)
            print('Release artifacts verified; no signing or Keychain access performed.')
        else:
            generate(args.tools.resolve(), args.archive.resolve(), args.app.resolve(), args.output.resolve(), args.account, dmg)
    except (ValueError, OSError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Sparkle feed generation failed: {error}') from error
