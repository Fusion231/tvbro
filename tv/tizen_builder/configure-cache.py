#!/usr/bin/env python3
"""Stage the qualified custom ARM artifacts in an isolated, ARM-only CLI cache."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import urllib.request
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('--root', type=Path, required=True)
parser.add_argument('--engine', type=Path, required=True)
parser.add_argument('--evidence', type=Path, required=True)
parser.add_argument('--verify-only', action='store_true')
args = parser.parse_args()
tool = args.root / 'flutter-tizen'
cache = tool / 'flutter/bin/cache'
engine_cache = cache / 'artifacts/engine'
custom = args.engine / 'artifacts/custom-tizen-arm-release'

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

builder = json.loads((args.engine / '.tvbro-engine-builder.json').read_text())
assert builder['engineRevision'] == 'a0e550d2b728d26d86bdbd981b33c9e9de7a656b'
assert builder['dartRevision'] == '04bcd1036cdc799ac6564988f159ee454d42c822'
qualified = json.loads((args.engine / 'state/control.json').read_text())
assert qualified['status'] == 'succeeded'
for name in ['libflutter_engine.so', 'icudtl.dat', 'gen_snapshot']:
    assert digest(custom / name) == qualified['artifactHashes'][name], name
compiler_version = subprocess.run([str(custom / 'gen_snapshot'), '--version'], stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True, check=True).stdout.strip()
assert re.search(r'Dart SDK version: 3\.13\.5\b', compiler_version), compiler_version

target = engine_cache / 'tizen-arm-release'
records = {}
if not args.verify_only:
    source = tool / 'lib/tizen_cache.dart'
    text = source.read_text()
    method = r'  @override\n  List<List<String>> getBinaryDirs\(\) \{.*?\n  \}'
    start = text.index('class TizenEngineArtifacts ')
    boundary = text.index('class TizenEmbedderArtifacts ')
    prefix, engine_class, embedder_class = text[:start], text[start:boundary], text[boundary:]
    engine_method = "  @override\n  List<List<String>> getBinaryDirs() {\n    // CUSTOM SDK: only the qualified ARM release configuration is available.\n    return <List<String>>[\n      <String>['tizen-arm-release', 'tizen-arm-release.zip'],\n      <String>['tizen-arm-release/linux-x64', 'tizen-arm-release_linux-x64.zip'],\n    ];\n  }"
    embedder_method = "  @override\n  List<List<String>> getBinaryDirs() {\n    // CUSTOM SDK: only the existing TV ARM API 6.0 target is staged.\n    return <List<String>>[\n      <String>['tizen-common', 'tizen-common.zip'],\n      <String>['tizen-arm/6.0', 'tizen-6.0-arm.zip'],\n    ];\n  }"
    engine_class, count1 = re.subn(method, lambda _: engine_method, engine_class, count=1, flags=re.S)
    embedder_class, count2 = re.subn(method, lambda _: embedder_method, embedder_class, count=1, flags=re.S)
    assert count1 == count2 == 1
    source.write_text(prefix + engine_class + embedder_class)
    for name, destination in {'libflutter_engine.so': target / 'libflutter_engine.so',
                              'icudtl.dat': target / 'icudtl.dat',
                              'gen_snapshot': target / 'linux-x64/gen_snapshot'}.items():
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(custom / name, destination)
    assets = [('tizen-common.zip', 'tizen-common', '4bd9db092431c37f53f50d6b2648c11e635bf1d5b488dba40c43d4ed4863789a'),
              ('tizen-6.0-arm.zip', 'tizen-arm/6.0', '8ec5f36a8625277cf00bcc8fa479cf32b781585031369ef118934fd00e1c1810')]
    for name, folder, expected in assets:
        archive = args.root / 'downloads' / name
        if not archive.exists():
            with urllib.request.urlopen('https://github.com/flutter-tizen/embedder/releases/download/cccce06/' + name) as response, archive.open('wb') as out:
                shutil.copyfileobj(response, out)
        assert digest(archive) == expected, name
        destination = engine_cache / folder
        destination.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive) as z:
            for item in z.infolist():
                assert not item.is_dir() or not item.filename.startswith('/')
                assert '..' not in Path(item.filename).parts and not item.filename.startswith('/')
            z.extractall(destination)
    (cache / 'tizen-engine.stamp').write_text('a0e550d2b728d26d86bdbd981b33c9e9de7a656b\n')
    (cache / 'tizen-embedder.stamp').write_text('cccce063cdb6783ed2a72ebc772adecc25808697\n')

for name, destination in {'libflutter_engine.so': target / 'libflutter_engine.so',
                          'icudtl.dat': target / 'icudtl.dat',
                          'gen_snapshot': target / 'linux-x64/gen_snapshot'}.items():
    assert digest(custom / name) == digest(destination), name
    records[name] = {'source': str(custom / name), 'cachePath': str(destination), 'sha256': digest(destination)}
manifest = {'kind': 'CUSTOM_ARM_RELEASE_SDK', 'officialEngineBinary': False,
            'baseEngineRevision': 'a0e550d2b728d26d86bdbd981b33c9e9de7a656b',
            'dartRevision': '04bcd1036cdc799ac6564988f159ee454d42c822',
            'frameworkRevision': 'abaf9c523780a608bd46686fd5e53740a07077f8',
            'compilerVersion': compiler_version,
            'supportedConfiguration': 'ARM release, TV API 6.0 only', 'artifacts': records}
(args.evidence / 'custom-cache.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
