import pathlib
import subprocess
import tempfile
import unittest
import zipfile

import export_client_source as source


class ClientSourceTest(unittest.TestCase):
    def test_export_handles_windows_command_length_and_filters_private_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            repo, output = root / 'repo', root / 'export'
            code = repo / 'clients/player/lib'
            code.mkdir(parents=True)
            (repo / 'clients/player/pubspec.yaml').write_bytes(b'name: test_app\n')
            (repo / 'backend').mkdir()
            (repo / 'backend/server.mjs').write_text('private server')
            for number in range(400):
                (code / (str(number) + '_' + 'source' * 15 + '.dart')).write_bytes(b'application source\n')
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            subprocess.run(['git', '-C', str(repo), 'config', 'core.autocrlf', 'false'], check=True)
            subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Source export test',
                            '-c', 'user.email=test@example.invalid', '-c', 'core.hooksPath=' + str(root/'no-hooks'),
                            'commit', '-qm', 'fixture'], check=True)
            subprocess.run(['git', '-C', str(repo), 'config', 'core.autocrlf', 'true'], check=True)
            source.export_git(repo, 'HEAD', output)
            self.assertEqual(len(list((output/'clients/player/lib').glob('*.dart'))), 400)
            self.assertEqual((output/'clients/player/pubspec.yaml').read_bytes(), b'name: test_app\n')
            self.assertFalse((output/'backend').exists())

    def test_only_application_inputs_are_public(self):
        for path in ['backend/server.mjs', 'backend/.env', 'panel/src/main.js',
                     'panel/public/downloads/tvbro-source.zip', 'docs/coolify.md',
                     'clients/player/android/key.properties', 'clients/player/android/release.jks',
                     'clients/player/test/secret_keys_parity_test.dart',
                     'clients/player/test/linux_packaging_test.dart', 'clients/player/test/msix_packaging_test.dart',
                     'clients/player/build/app.apk', '../clients/player/lib/main.dart']:
            with self.subTest(path=path):
                self.assertFalse(source.is_client_source(path))
        for path in ['clients/player/lib/main.dart', 'clients/player/pubspec.yaml',
                     'clients/player/android/app/debug.keystore',
                     'clients/player/packages/iptvs_ios_player/ios/Classes/Player.swift',
                     'clients/tv/samsung_web/ui/app.js', 'panel/src/crypto.js',
                     'panel/src/pin.js', 'panel/src/validate.js', 'LICENSE',
                     'lib/main.dart', 'android/app/src/main/AndroidManifest.xml', 'pubspec.yaml']:
            with self.subTest(path=path):
                self.assertTrue(source.is_client_source(path))

    def test_archive_retains_version_and_exact_client_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            original = pathlib.Path(directory) / 'original.zip'
            output = pathlib.Path(directory) / 'client.zip'
            with zipfile.ZipFile(original, 'w') as archive:
                archive.writestr('tvbro-1.0.7/lib/main.dart', b'original release source')
                archive.writestr('tvbro-1.0.7/backend/server.mjs', b'private backend')
                archive.writestr('tvbro-1.0.7/panel/src/main.js', b'private panel')
                archive.writestr('tvbro-1.0.7/panel/src/crypto.js', b'client protocol')
            source.filter_zip(original, output)
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(set(archive.namelist()), {
                    'tvbro-1.0.7/lib/main.dart', 'tvbro-1.0.7/panel/src/crypto.js',
                    'tvbro-1.0.7/panel/package.json'})
                self.assertEqual(archive.read('tvbro-1.0.7/lib/main.dart'), b'original release source')
                self.assertEqual(archive.read('tvbro-1.0.7/panel/package.json'), source.PANEL_PACKAGE)


if __name__ == '__main__':
    unittest.main()
