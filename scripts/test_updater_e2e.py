#!/usr/bin/env python3
"""Real Sparkle fixture; never launches an app or accesses production signing keys.

python3 scripts/test_updater_e2e.py prepare
python3 scripts/test_updater_e2e.py serve /tmp/phraselens-updater-...
Open the printed install/PhraseLens.app using the UI and select Check for Updates.
After installing, use status; scenario tampered changes only the served archive,
scenario no-update serves B again. For rejection tests open pristine source/A copy
in a separate writable directory (do not replace a currently running bundle).
The temporary directory contains a private test key: delete it after testing.
"""
import argparse
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import tempfile
import uuid

REPO = Path(__file__).resolve().parents[1]
SPARKLE = REPO / '.build/artifacts/sparkle/Sparkle'
FRAMEWORK = SPARKLE / 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
SIGN = SPARKLE / 'bin/sign_update'


def run(*args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True).stdout


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(root):
    root = Path(root).resolve()
    state = json.loads((root / 'fixture.json').read_text())
    if not state['bundle_id'].startswith('com.harry.phraselens.updater-test.'):
        raise ValueError('Not an isolated updater fixture')
    return root, state


def prepare(identity):
    if not FRAMEWORK.is_dir() or not SIGN.is_file():
        raise ValueError('Resolve Sparkle package first; framework/tools missing')
    executable = REPO / '.build/debug/PhraseLens'
    resources = REPO / '.build/debug/PhraseLens_PhraseLens.bundle'
    if not executable.is_file() or not resources.is_dir():
        raise ValueError('Run swift build first')
    root = Path(tempfile.mkdtemp(prefix='phraselens-updater-'))
    os.chmod(root, 0o700)
    # Generate outside Keychain. Sparkle accepts the base64 encoded 32-byte seed.
    der = run('openssl', 'genpkey', '-algorithm', 'ED25519', '-outform', 'DER')
    pem = root / 'ephemeral.der'
    pem.write_bytes(der)
    os.chmod(pem, 0o600)
    public_der = run('openssl', 'pkey', '-inform', 'DER', '-in', pem, '-pubout', '-outform', 'DER')
    key = root / 'test-key.txt'
    key.write_bytes(base64.b64encode(der[-32:]))
    os.chmod(key, 0o600)
    pem.unlink()
    public = base64.b64encode(public_der[-32:]).decode()
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    identifier = 'com.harry.phraselens.updater-test.' + uuid.uuid4().hex
    feed = f'http://127.0.0.1:{port}/appcast.xml'
    entitlements = root / 'entitlements.plist'
    entitlements.write_bytes(plistlib.dumps({'com.apple.security.cs.disable-library-validation': True}))
    for label, version in [('A', '9001'), ('B', '9002')]:
        app = root / 'source' / label / 'PhraseLens.app'
        contents = app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Resources').mkdir()
        (contents / 'Frameworks').mkdir()
        shutil.copy2(executable, contents / 'MacOS/PhraseLens')
        shutil.copytree(resources, contents / 'Resources/PhraseLens_PhraseLens.bundle', symlinks=True)
        shutil.copytree(FRAMEWORK, contents / 'Frameworks/Sparkle.framework', symlinks=True)
        info = plistlib.loads((REPO / 'packaging/Info.plist').read_bytes())
        info.update(CFBundleIdentifier=identifier, CFBundleVersion=version,
                    CFBundleShortVersionString=f'0.0.{version}', SUPublicEDKey=public,
                    SUFeedURL=feed, SUVerifyUpdateBeforeExtraction=True,
                    SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
                    SURequireSignedFeed=True, SUSignedFeedFailureExpirationInterval=0,
                    PhraseLensUpdateTest=True, PhraseLensUpdateTestDirectory=str(root / 'data'),
                    NSAppTransportSecurity={'NSAllowsLocalNetworking': True,
                      'NSExceptionDomains': {'127.0.0.1': {'NSExceptionAllowsInsecureHTTPLoads': True}}})
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        framework = contents / 'Frameworks/Sparkle.framework'
        for relative in ['Versions/B/XPCServices/Installer.xpc', 'Versions/B/XPCServices/Downloader.xpc',
                         'Versions/B/Autoupdate', 'Versions/B/Updater.app']:
            target = framework / relative
            if target.exists():
                run('codesign', '--force', '--sign', identity, '--options', 'runtime',
                    '--preserve-metadata=entitlements', target)
        run('codesign', '--force', '--sign', identity, '--options', 'runtime', framework)
        run('codesign', '--force', '--sign', identity, '--options', 'runtime', '--entitlements', entitlements, app)
        run('codesign', '--verify', '--deep', '--strict', app)
    (root / 'install').mkdir()
    shutil.copytree(root / 'source/A/PhraseLens.app', root / 'install/PhraseLens.app', symlinks=True)
    (root / 'served').mkdir()
    archive = root / 'served/PhraseLens-B.zip'
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', root / 'source/B/PhraseLens.app', archive)
    shutil.copy2(archive, root / 'pristine-B.zip')
    signature = run(SIGN, '-f', key, '-p', archive).decode().strip()
    run(SIGN, '--verify', '-f', key, archive, signature)
    state = dict(bundle_id=identifier, port=port, feed=feed, signature=signature,
                 archive_sha256=digest(archive), archive_length=archive.stat().st_size,
                 source_versions={'A': '9001', 'B': '9002'}, scenario='update')
    (root / 'fixture.json').write_text(json.dumps(state, indent=2))
    scenario(root, 'update')
    status(root)


def scenario(root, name):
    root, state = load(root)
    archive = root / 'served/PhraseLens-B.zip'
    shutil.copy2(root / 'pristine-B.zip', archive)
    if name == 'tampered':
        data = bytearray(archive.read_bytes())
        data[len(data) // 2] ^= 1
        archive.write_bytes(data)
    # no-update intentionally advertises B: run from installed B to verify comparison.
    xml = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>Isolated PhraseLens updater test</title><item><title>Fixture B</title>
<sparkle:version>9002</sparkle:version><sparkle:shortVersionString>0.0.9002</sparkle:shortVersionString>
<enclosure url="http://127.0.0.1:{state['port']}/PhraseLens-B.zip" length="{state['archive_length']}" type="application/octet-stream" sparkle:edSignature="{state['signature']}"/>
</item></channel></rss>'''
    feed = root / 'served/appcast.xml'
    feed.write_text(xml)
    run(SIGN, '-f', root / 'test-key.txt', feed)
    run(SIGN, '--verify', '-f', root / 'test-key.txt', feed)
    if name == 'tampered-feed':
        feed.write_text(feed.read_text().replace('Fixture B', 'Fixture C'))
    state['scenario'] = name
    (root / 'fixture.json').write_text(json.dumps(state, indent=2))
    print(json.dumps({'directory': str(root), 'scenario': name, 'served_sha256': digest(archive)}))


def status(root):
    root, state = load(root)
    installed = root / 'install/PhraseLens.app'
    info = plistlib.loads((installed / 'Contents/Info.plist').read_bytes())
    result = {'directory': str(root), 'app': str(installed), 'bundle_id': state['bundle_id'],
              'installed_version': info['CFBundleVersion'], 'scenario': state['scenario'],
              'feed': state['feed'], 'archive_sha256': digest(root / 'served/PhraseLens-B.zip'),
              'installed_executable_sha256': digest(installed / 'Contents/MacOS/PhraseLens')}
    verification = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(installed)], capture_output=True)
    result['installed_signature_valid'] = verification.returncode == 0
    archive_check = subprocess.run([str(SIGN), '--verify', '-f', str(root / 'test-key.txt'),
                                    str(root / 'served/PhraseLens-B.zip'), state['signature']], capture_output=True)
    result['archive_signature_valid'] = archive_check.returncode == 0
    feed_check = subprocess.run([str(SIGN), '--verify', '-f', str(root / 'test-key.txt'),
                                 str(root / 'served/appcast.xml')], capture_output=True)
    result['feed_signature_valid'] = feed_check.returncode == 0
    print(json.dumps(result, indent=2))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('prepare').add_argument('--identity', default='Context Dictionary Local Development')
    for name in ['serve', 'status', 'scenario']:
        command = commands.add_parser(name)
        command.add_argument('directory')
        if name == 'scenario':
            command.add_argument('name', choices=['update', 'tampered', 'tampered-feed', 'no-update'])
    args = parser.parse_args()
    if args.command == 'prepare':
        prepare(args.identity)
    elif args.command == 'status':
        status(args.directory)
    elif args.command == 'scenario':
        scenario(args.directory, args.name)
    else:
        root, state = load(args.directory)
        handler = lambda *a, **kw: http.server.SimpleHTTPRequestHandler(*a, directory=str(root / 'served'), **kw)
        print(f"Serving {state['feed']}", flush=True)
        with http.server.ThreadingHTTPServer(('127.0.0.1', state['port']), handler) as server:
            server.serve_forever()


if __name__ == '__main__':
    main()
