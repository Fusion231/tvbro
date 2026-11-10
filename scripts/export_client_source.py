"""Export only the sources needed to build the public TVBro applications."""
import fnmatch
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tarfile
import zipfile

MANIFEST = json.loads(pathlib.Path(__file__).with_name('client-source.json').read_text(encoding='utf-8'))
PANEL_PACKAGE = b'{"private":true,"type":"module"}\n'
PLAYER_DIRECTORIES = {'android', 'ios', 'windows', 'macos', 'linux', 'web', 'lib', 'assets',
                      'packages', 'test', 'integration_test', 'test_driver'}
PLAYER_FILES = {'pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml', '.metadata', 'dart_define.example.json'}


def canonical_path(path):
    first = path.split('/')[0]
    if first in PLAYER_DIRECTORIES or path in PLAYER_FILES:
        return 'clients/player/' + path
    if first == 'tv':
        return 'clients/' + path
    return path


def is_client_source(path):
    if '\\' in path or pathlib.PurePosixPath(path).is_absolute() or '..' in path.split('/'):
        return False
    path = canonical_path(path)
    if path in MANIFEST['exceptions']:
        return True
    if any(fnmatch.fnmatchcase(path, pattern) for pattern in MANIFEST['exclude']):
        return False
    return path in MANIFEST['files'] or any(path.startswith(prefix) for prefix in MANIFEST['directories'])


def materialise_lfs(data, path, repo):
    if not data.startswith(b'version https://git-lfs.github.com/spec/v1\n'):
        return data
    match = re.search(rb'oid sha256:([a-f0-9]{64})\nsize ([0-9]+)', data)
    if match is None or repo is None:
        raise ValueError('An LFS source file must be materialised: ' + path)
    oid, size = match[1].decode(), int(match[2])
    common = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', '--path-format=absolute', '--git-common-dir'], text=True).strip()
    candidates = [pathlib.Path(repo) / path, pathlib.Path(common) / 'lfs/objects' / oid[:2] / oid[2:4] / oid]
    for candidate in candidates:
        if candidate.is_file() and candidate.stat().st_size == size:
            content = candidate.read_bytes()
            if hashlib.sha256(content).hexdigest() == oid:
                return content
    raise ValueError('Missing verified LFS object ' + oid + '; fetch this revision with git lfs first.')


def filter_zip(original, output, repo=None):
    original, output = pathlib.Path(original), pathlib.Path(output)
    if original.resolve() == output.resolve():
        raise ValueError('Use a separate output archive before replacing the original.')
    with zipfile.ZipFile(original) as archive, zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as result:
        roots = {item.filename.split('/')[0] for item in archive.infolist() if not item.is_dir()}
        if len(roots) != 1 or next(iter(roots)) in ('', '.', '..'):
            raise ValueError('Expected one source archive root directory.')
        root = roots.pop()
        has_helpers = False
        for item in archive.infolist():
            if item.is_dir():
                continue
            relative = item.filename.partition('/')[2]
            if not is_client_source(relative) or relative == 'panel/package.json':
                continue
            data = materialise_lfs(archive.read(item), relative, repo)
            result.writestr(item, data, compress_type=zipfile.ZIP_DEFLATED)
            has_helpers |= relative.startswith('panel/src/')
        if has_helpers:
            result.writestr(root + '/panel/package.json', PANEL_PACKAGE)


def export_git(repo, revision, destination):
    repo, destination = pathlib.Path(repo), pathlib.Path(destination)
    if destination.exists() and any(destination.iterdir()):
        raise ValueError('Export destination must be empty.')
    destination.mkdir(parents=True, exist_ok=True)
    names = subprocess.check_output(['git', '-C', str(repo), 'ls-tree', '-rz', '--name-only', revision]).decode('utf-8').split('\0')
    selected = [name for name in names if name and is_client_source(name)]
    if not any(name.endswith('pubspec.yaml') for name in selected):
        raise ValueError('No application manifest in selected revision.')
    executable = []
    command = ['git', '-c', 'core.autocrlf=false', '-C', str(repo), 'archive', '--format=tar', revision]
    with subprocess.Popen(command, stdout=subprocess.PIPE) as process:
        with tarfile.open(fileobj=process.stdout, mode='r|') as archive:
            for member in archive:
                if member.isdir():
                    continue
                if not is_client_source(member.name):
                    continue
                if not member.isfile():
                    raise ValueError('Unexpected source entry: ' + member.name)
                target = destination / member.name
                if not target.resolve().is_relative_to(destination.resolve()):
                    raise ValueError('Source path escapes export directory.')
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(materialise_lfs(archive.extractfile(member).read(), member.name, repo))
                target.chmod(member.mode)
                if member.mode & 0o111:
                    executable.append(member.name)
        if process.wait() != 0:
            raise RuntimeError('git archive failed.')
    if (destination / 'panel/src').is_dir():
        (destination / 'panel/package.json').write_bytes(PANEL_PACKAGE)
    readme = repo / 'scripts/client-README.md'
    if (destination / 'clients/player/pubspec.yaml').is_file() and readme.is_file():
        (destination / 'README.md').write_bytes(readme.read_bytes())
    if not ((destination / 'clients/player/pubspec.yaml').is_file() or (destination / 'pubspec.yaml').is_file()):
        raise ValueError('Application manifest missing after export.')
    return executable


if __name__ == '__main__':
    if len(sys.argv) not in (2, 3):
        sys.exit('Usage: python scripts/export_client_source.py OUTPUT_DIRECTORY [REVISION]')
    repository = pathlib.Path(__file__).resolve().parent.parent
    export_git(repository, sys.argv[2] if len(sys.argv) == 3 else 'HEAD', sys.argv[1])
