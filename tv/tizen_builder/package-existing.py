#!/usr/bin/env python3
"""Sign an existing generated TPK payload with an installed SDK profile.

SDK 10 stores .pwd keyring references, while SDK 1.1.7 expects decoded passwords.
Use the real SDK Sign task with secrets in its private process environment.
Never rebuild Dart/native inputs or export certificates/passwords.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

TOOLS = Path('/opt/tvbro-tizen-toolchain')
SIGNATURES = {'author-signature.xml', 'signature1.xml', 'signature2.xml'}


def snapshot(root):
    files = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise RuntimeError('Generated payload must not contain symlinks.')
        if path.is_file() and path.relative_to(root).as_posix() not in SIGNATURES:
            files[path.relative_to(root).as_posix()] = {
                'size': path.stat().st_size,
                'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            }
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--profile', required=True)
    args = parser.parse_args()
    if sys.platform != 'linux' or os.getuid() != 10000 or not Path('/.dockerenv').exists():
        raise RuntimeError('Run as tvbro-sdk in the isolated Linux container.')
    source, output = args.source.resolve(strict=True), args.output.resolve()
    if (not source.is_relative_to(TOOLS / 'work') or source.name != 'tpkroot'
            or not output.is_relative_to(TOOLS / 'qualification')
            or output == TOOLS / 'qualification' or output.exists()):
        raise RuntimeError('Use a generated work/*/tpkroot and a new qualification child directory.')
    payload = snapshot(source)
    if not payload or 'tizen-manifest.xml' not in payload:
        raise RuntimeError('Generated payload is incomplete.')
    profiles = ET.parse(TOOLS / 'home/tizen-sdk-data/profile/profiles.xml')
    matches = [p for p in profiles.getroot().iter('profile') if p.get('name') == args.profile]
    if len(matches) != 1:
        raise RuntimeError('The requested SDK signing profile is not installed.')
    items = {p.get('distributor'): p for p in matches[0].iter('profileitem')}
    env, secrets = os.environ.copy(), []
    secret_tool = TOOLS / 'home/tizen-sdk/tools/certificate-encryptor/secret-tool'
    for role, prefix in [('0', 'AUTHOR'), ('1', 'DIST'), ('2', 'DIST2')]:
        item = items.get(role)
        key = item.get('key', '') if item is not None else ''
        if not key and role == '2':
            env['TVBRO_DIST2_PATH'] = env['TVBRO_DIST2_PASS'] = ''
            continue
        reference = item.get('password', '') if item is not None else ''
        if not Path(key).is_absolute() or not Path(key).is_file() or not reference.endswith('.pwd'):
            raise RuntimeError('The selected SDK profile needs certificates and private keyring references.')
        lookup = subprocess.run([str(secret_tool), 'lookup', '--label=tizen-studio', 'keyfile',
                                 reference, 'tool', 'certificate-manager'], capture_output=True)
        value = lookup.stdout.decode().rstrip('\r\n')
        if lookup.returncode or not value or '\n' in value or '\r' in value or re.search(r'\b(ERROR|FATAL)\b', value):
            raise RuntimeError('SDK secret lookup failed; unlock its Secret Service in this active WSL session.')
        env['TVBRO_' + prefix + '_PATH'], env['TVBRO_' + prefix + '_PASS'] = key, value
        secrets.append(value)
    manifest = ET.parse(source / 'tizen-manifest.xml').getroot()
    name, version = manifest.get('package', ''), manifest.get('version', '')
    if not re.fullmatch(r'[A-Za-z0-9_.]+', name) or not re.fullmatch(r'[0-9.]+', version):
        raise RuntimeError('Unexpected native package identity.')
    output.mkdir(parents=True, exist_ok=False)
    copied = output / 'tpkroot'
    shutil.copytree(source, copied, ignore=shutil.ignore_patterns(*SIGNATURES))
    if snapshot(copied) != payload:
        raise RuntimeError('Generated payload copy differs.')
    package = output / (name + '-' + version + '.tpk')
    task = TOOLS / 'home/.nuget/packages/tizen.net.sdk/1.1.7/tools/netstandard1.6/Tizen.NET.Build.Tasks.dll'
    env.update(TVBRO_TASKS_ASSEMBLY=str(task), TVBRO_PACKAGE_ROOT=str(copied),
               TVBRO_SIGNED_TPK=str(package), MSBUILDDISABLENODEREUSE='1',
               MSBUILDLOGTASKINPUTS='0', DOTNET_CLI_USE_MSBUILD_SERVER='0')
    result = subprocess.run(['dotnet', 'msbuild', str(Path(__file__).with_name('PackageExisting.proj')),
                             '-t:PackageExisting', '-nologo', '-nr:false', '-verbosity:quiet'],
                            cwd=output, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log = result.stdout.decode(errors='replace')
    for value in secrets:
        log = log.replace(value, '[REDACTED]')
    (output / 'sign.log').write_text(log)
    if result.returncode or not package.is_file():
        raise RuntimeError('SDK signing failed; inspect the sanitized sign.log.')
    with zipfile.ZipFile(package) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise RuntimeError('The signed archive contains duplicate paths.')
        actual = {p.filename: {'size': p.file_size, 'sha256': hashlib.sha256(archive.read(p)).hexdigest()}
                  for p in archive.infolist() if not p.is_dir() and p.filename not in SIGNATURES}
        signatures = sorted(SIGNATURES.intersection(names))
    if actual != payload or snapshot(source) != payload or snapshot(copied) != payload:
        raise RuntimeError('The signed payload differs from the original compiled inputs.')
    if not {'author-signature.xml', 'signature1.xml'}.issubset(signatures):
        raise RuntimeError('The signed package lacks author/distributor signatures.')
    proof = {'status': 'sdk_signed_payload_unchanged', 'profile': args.profile,
             'source': str(source), 'package': str(package), 'payloadFiles': len(payload),
             'size': package.stat().st_size, 'sha256': hashlib.sha256(package.read_bytes()).hexdigest(),
             'payload': payload, 'signatureFiles': signatures, 'runtimeExecution': False}
    (output / 'proof.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps({key: value for key, value in proof.items() if key != 'payload'}))


if __name__ == '__main__':
    main()
