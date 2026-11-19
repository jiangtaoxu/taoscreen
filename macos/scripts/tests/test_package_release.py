import importlib.util
import os
import pathlib
import plistlib
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('release', pathlib.Path(__file__).resolve().parents[1] / 'package-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class VersionTests(unittest.TestCase):
    def test_release_without_destination_stops_before_network_access(self):
        with mock.patch.object(release, 'RELEASE_ORIGIN', ''), mock.patch.object(release, 'fetch') as fetch:
            with mock.patch('sys.argv', ['package-release.py', '--upload-only']):
                with self.assertRaisesRegex(SystemExit, 'TAOSCREEN_RELEASE_ORIGIN'):
                    release.main()
            fetch.assert_not_called()

    def test_auto_version_advances_online_and_skips_local_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            info = root / 'Info.plist'
            info.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '1.0.6'}))
            package = root / 'macos/1.0.9/TaoScreen-1.0.9-arm64.dmg'
            package.parent.mkdir(parents=True)
            package.write_bytes(b'existing')
            def fetch(url, probe=False):
                return b'{"version":"1.0.8"}' if 'taoscreen-macos-arm64.json' in url else None
            with mock.patch.object(release, 'output', root), mock.patch.object(release, 'fetch', side_effect=fetch):
                self.assertEqual(release.resolve_version(None, False, 'arm64', info), '1.0.10')

    def test_explicit_version_is_not_silently_changed(self):
        self.assertEqual(release.resolve_version('2.0.0', False, 'arm64', pathlib.Path('unused')), '2.0.0')

    def test_patch_overflow_stops(self):
        with self.assertRaises(SystemExit):
            release.next_version('1.0.9999')


class SparkleReleaseTests(unittest.TestCase):
    def setUp(self):
        import base64
        import hashlib
        import json
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.output = self.root / 'dist/releases'
        self.version, self.arch = '1.0.15', 'arm64'
        self.notes = '1. 简化更新入口\n\n2. 保留换行 <标签> & 文本'
        for name, value in [('RELEASE_ORIGIN', 'https://downloads.example.test'),
                            ('UPDATE_SERVER', 'https://desktop.example.test'),
                            ('BUNDLE_ID', 'org.example.taoscreen'), ('TEAM_ID', 'EXAMPLE123')]:
            patcher = mock.patch.object(release, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.signature = base64.b64encode(bytes(range(64))).decode()
        self.info = {'SUPublicEDKey': base64.b64encode(bytes(range(32))).decode(), 'LSMinimumSystemVersion': '14.0'}
        (self.root / 'Resources').mkdir()
        (self.root / 'Resources/Info.plist').write_bytes(plistlib.dumps(self.info))
        (self.root / '.release').mkdir()
        (self.root / '.release/update-public.plist').write_bytes(plistlib.dumps({'SUPublicEDKey': self.info['SUPublicEDKey']}))
        key_config = mock.patch.dict(os.environ, {'TAOSCREEN_UPDATE_PUBLIC_KEY_FILE': str(self.root / '.release/update-public.plist')})
        key_config.start()
        self.addCleanup(key_config.stop)
        directory = self.output / 'macos' / self.version
        directory.mkdir(parents=True)
        self.dmg = directory / release.package_name(self.version, self.arch)
        self.archive = self.dmg.with_suffix('.zip')
        self.dmg.write_bytes(b'legacy signed disk image')
        self.archive.write_bytes(b'Sparkle signed archive')
        self.manifest = dict(version=self.version, platform='macos', arch=self.arch,
                             url=f'{release.RELEASE_ORIGIN}/macos/{self.version}/{self.dmg.name}',
                             size=self.dmg.stat().st_size, sha256=hashlib.sha256(self.dmg.read_bytes()).hexdigest(), notes=self.notes)
        (self.output / 'taoscreen-macos-arm64.json').write_text(json.dumps(self.manifest))
        self.feed_path = self.output / 'taoscreen-appcast-arm64.xml'
        self.feed_path.write_bytes(release.appcast_data(self.version, self.arch, self.notes, self.archive.stat().st_size, self.signature))
        for name, value in [('root', self.root), ('output', self.output)]:
            patcher = mock.patch.object(release, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_appcast_preserves_notes_and_binds_archive_version_and_architecture(self):
        item = release.ET.fromstring(self.feed_path.read_bytes()).find('channel/item')
        self.assertEqual(item.findtext('title'), f'TaoScreen {self.version}')
        self.assertEqual(item.findtext('description'), self.notes)
        self.assertEqual(item.find('description').get(f'{{{release.SPARKLE_NS}}}format'), 'plain-text')
        with mock.patch.object(release, 'check_update_key'), mock.patch.object(release, 'sparkle_tool', return_value='sign_update'), mock.patch.object(release.subprocess, 'run') as run:
            release.verify_appcast(self.feed_path.read_bytes(), self.version, self.arch, self.archive, self.info)
            self.assertEqual(run.call_args.args[0], ['sign_update', '--account', release.UPDATE_KEY_ACCOUNT, '--verify', str(self.archive), self.signature])
            for version, arch in [('1.0.16', self.arch), (self.version, 'x86_64')]:
                with self.assertRaises(SystemExit):
                    release.verify_appcast(self.feed_path.read_bytes(), version, arch, self.archive, self.info)
            self.archive.write_bytes(b'truncated')
            with self.assertRaises(SystemExit):
                release.verify_appcast(self.feed_path.read_bytes(), self.version, self.arch, self.archive, self.info)

    def test_signature_failure_stops_before_any_upload(self):
        import subprocess
        with mock.patch.object(release, 'check_update_key'), mock.patch.object(release, 'sparkle_tool', return_value='sign_update'), \
             mock.patch.object(release.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'sign_update')), \
             mock.patch.object(release, 'wrangler') as upload:
            with self.assertRaises(subprocess.CalledProcessError):
                release.upload(self.version, self.arch)
            upload.assert_not_called()

    def test_uploads_both_packages_before_activating_either_feed(self):
        objects, uploaded = {}, []
        def fetch(url, probe=False):
            if url.startswith(release.UPDATE_SERVER):
                return release.json.dumps({'release': self.manifest}).encode()
            return objects.get(url.removeprefix(release.RELEASE_ORIGIN + '/'))
        def wrangler(*args, **kwargs):
            key = args[3].removeprefix(release.R2_BUCKET + '/')
            objects[key] = pathlib.Path(args[args.index('--file') + 1]).read_bytes()
            uploaded.append(key)
        with mock.patch.object(release, 'check_update_key'), mock.patch.object(release, 'sparkle_tool', return_value='sign_update'), \
             mock.patch.object(release.subprocess, 'run'), mock.patch.object(release, 'fetch', side_effect=fetch), \
             mock.patch.object(release, 'wrangler', side_effect=wrangler):
            release.upload(self.version, self.arch)
            self.assertEqual(uploaded, [f'macos/{self.version}/{self.archive.name}', f'macos/{self.version}/{self.dmg.name}',
                                        'taoscreen-appcast-arm64.xml', 'taoscreen-macos-arm64.json'])
            uploaded.clear()
            release.upload(self.version, self.arch)
            self.assertEqual(uploaded, ['taoscreen-appcast-arm64.xml', 'taoscreen-macos-arm64.json'], '重试时复用公开校验一致的包')

    def test_package_conflict_and_incomplete_release_never_switch_feeds(self):
        with mock.patch.object(release, 'check_update_key'), mock.patch.object(release, 'sparkle_tool', return_value='sign_update'), \
             mock.patch.object(release.subprocess, 'run'), mock.patch.object(release, 'fetch', return_value=b'other package'), \
             mock.patch.object(release, 'wrangler') as upload:
            with self.assertRaises(SystemExit):
                release.upload(self.version, self.arch)
            upload.assert_not_called()
            self.archive.unlink()
            with self.assertRaises(SystemExit):
                release.upload(self.version, self.arch)
            upload.assert_not_called()

    def test_failed_public_download_never_switches_feeds(self):
        original_wait = release.wait_until
        uploaded = []
        def wrangler(*args, **kwargs):
            uploaded.append(args[3])
        def wait(check, failure):
            original_wait(check, failure, attempts=1)
        with mock.patch.object(release, 'check_update_key'), mock.patch.object(release, 'sparkle_tool', return_value='sign_update'), \
             mock.patch.object(release.subprocess, 'run'), mock.patch.object(release, 'fetch', return_value=None), \
             mock.patch.object(release, 'wrangler', side_effect=wrangler), mock.patch.object(release, 'wait_until', side_effect=wait):
            with self.assertRaises(SystemExit):
                release.upload(self.version, self.arch)
        self.assertEqual(uploaded, [f'{release.R2_BUCKET}/macos/{self.version}/{self.archive.name}'])

    def test_wrong_update_key_is_rejected_without_rotation(self):
        with mock.patch.object(release, 'public_key', return_value='wrong'), mock.patch.object(release.subprocess, 'run') as run:
            with self.assertRaises(SystemExit):
                release.init_update_key(self.root / 'Resources/Info.plist')
            run.assert_not_called()
            self.assertEqual(release.plistlib.loads((self.root / 'Resources/Info.plist').read_bytes()), self.info)

    def test_release_passes_configured_identity_and_update_settings_to_builder(self):
        info = self.root / 'Resources/Info.plist'
        source = {'CFBundleShortVersionString': '1.0.14', 'SUFeedURL': '$(TAOSCREEN_UPDATE_FEED_URL)',
                  'SUPublicEDKey': '$(TAOSCREEN_UPDATE_PUBLIC_KEY)'}
        info.write_bytes(plistlib.dumps(source))
        with mock.patch.object(release.subprocess, 'run', side_effect=InterruptedError) as build:
            with self.assertRaises(InterruptedError):
                release.build(self.version, self.notes, self.arch, info)
        env = build.call_args.kwargs['env']
        self.assertEqual(env['TAOSCREEN_BUNDLE_ID'], 'org.example.taoscreen')
        self.assertEqual(env['TAOSCREEN_DEFAULT_SERVER_URL'], release.UPDATE_SERVER)
        self.assertEqual(env['TAOSCREEN_UPDATE_FEED_URL'], f'{release.RELEASE_ORIGIN}/taoscreen-appcast-{self.arch}.xml')
        self.assertEqual(env['TAOSCREEN_UPDATE_PUBLIC_KEY'], self.info['SUPublicEDKey'])
        self.assertEqual(plistlib.loads(info.read_bytes())['SUFeedURL'], source['SUFeedURL'])

    def test_version_checks_both_channels_after_partial_publication(self):
        info = self.root / 'Resources/Info.plist'
        info.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '1.0.14'}))
        feed = release.appcast_data('1.0.20', self.arch, self.notes, 1, self.signature)
        def fetch(url, probe=False):
            if url.endswith('taoscreen-appcast-arm64.xml'):
                return feed
            if url.endswith('taoscreen-macos-arm64.json'):
                return b'{"version":"1.0.15"}'
            return None
        with mock.patch.object(release, 'fetch', side_effect=fetch):
            self.assertEqual(release.resolve_version(None, False, self.arch, info), '1.0.21')
            with mock.patch.object(release.shutil, 'which', return_value='/wrangler'), \
                 mock.patch.object(release, 'wrangler', return_value=mock.Mock(returncode=0)):
                with self.assertRaises(SystemExit):
                    release.check_upload_ready('1.0.16', self.arch, fresh=False)


if __name__ == '__main__':
    unittest.main()
