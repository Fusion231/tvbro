#!/usr/bin/env bash
# Run only inside the pinned Linux container described in README.md.
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse
import ast
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import sys


IMAGE = 'ghcr.io/flutter-tizen/build-engine@sha256:cc6e431ffd60bdbe6bb20b2178c1dc4897a408f6c51728d3b59b5a9394bbe797'
ENGINE_URL = 'https://github.com/flutter-tizen/flutter.git'
ENGINE = 'a0e550d2b728d26d86bdbd981b33c9e9de7a656b'
DART = '04bcd1036cdc799ac6564988f159ee454d42c822'
DEPOT_URL = 'https://chromium.googlesource.com/chromium/tools/depot_tools.git'
KERNEL_SHA = '04c80cfa32a25830bf653c80af186ae82bae56371dcc95e3770c44febe42164f'
PHASES = ['packages', 'depot', 'checkout', 'configure', 'sync', 'sysroot', 'workarounds', 'gn', 'build', 'control']
parser = argparse.ArgumentParser(description='Build a CUSTOM Tizen ARM release engine and qualify the existing application kernel.')
parser.add_argument('--jobs', type=int, default=8)
parser.add_argument('--min-free-gib', type=int, default=80, help='Operational free-space floor, not an estimate of the build size.')
parser.add_argument('--retry-phase', action='append', choices=PHASES, default=[], help='Explicitly retry a failed/interrupted phase; never retries automatically.')
parser.add_argument('--stop-after', choices=PHASES, default='control')
args = parser.parse_args()
if not 1 <= args.jobs <= 32:
    parser.error('--jobs must be between 1 and 32')
if args.min_free_gib < 1:
    parser.error('--min-free-gib must be positive')

work = Path('/work')
source = work / 'flutter'
depot = work / 'depot_tools'
state = work / 'state'
out = source / 'engine/src/out/tizen_arm_release'
artifacts = work / 'artifacts/custom-tizen-arm-release'
kernel = Path('/control/app.dill')
control_evidence = Path('/control/evidence.json')
run_id = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
run_dir = work / 'evidence/runs' / run_id
current = None
phase_record = None
log = None
evidence = {'kind': 'CUSTOM_TIZEN_SDK', 'status': 'incomplete', 'runtimeExecution': False,
            'pluginLinking': False, 'tpkPackaging': False, 'physicalTvTesting': False}


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + '.tmp-' + str(os.getpid()))
    temporary.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')
    os.replace(temporary, path)


def event(status, **fields):
    value = {'timeUtc': now(), 'phase': current, 'status': status, **fields}
    print(json.dumps(value), flush=True)
    with (run_dir / 'events.jsonl').open('a', encoding='utf-8') as handle:
        handle.write(json.dumps(value) + '\n')


def command(argv, cwd=work, capture=False, required=True):
    argv = [str(value) for value in argv]
    item = {'argv': argv, 'cwd': str(cwd), 'startedUtc': now()}
    phase_record['commands'].append(item)
    write_json(state / (current + '.json'), phase_record)
    log.write('\n' + json.dumps(item) + '\n')
    log.flush()
    result = subprocess.run(argv, cwd=cwd, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE if capture else log,
                            stderr=subprocess.STDOUT, text=True, check=False)
    item.update(exitCode=result.returncode, finishedUtc=now())
    if capture:
        log.write(result.stdout)
        log.flush()
    write_json(state / (current + '.json'), phase_record)
    if required and result.returncode:
        raise RuntimeError('Command exited {}: {}'.format(result.returncode, argv[0]))
    return result.stdout.strip() if capture else result.returncode


def mount(path):
    matches = []
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        left, right = line.split(' - ', 1)
        fields = left.split()
        point = Path(re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), fields[4]))
        if path == point or point in path.parents:
            matches.append((len(str(point)), fields[5].split(','), right.split()[0], str(point)))
    if not matches:
        raise RuntimeError('Cannot establish mount provenance for ' + str(path))
    return max(matches)


def check_control():
    for path in [kernel, control_evidence]:
        if not path.is_file() or 'ro' not in mount(path.resolve())[1]:
            raise RuntimeError(str(path) + ' must be a file on a read-only mount')
    previous = json.loads(control_evidence.read_text(encoding='utf-8-sig'))
    if (previous.get('status') != 'application_arm_control_compiled_only'
            or previous.get('entryPoint') != 'Application'
            or previous.get('protectedInputsChanged') != []
            or previous.get('ownerGraph', {}).get('importedOriginalDartCount') != 145
            or previous.get('kernelSha256') != KERNEL_SHA or sha(kernel) != KERNEL_SHA):
        raise RuntimeError('Control does not match the stable original Application-mode qualification')
    header = kernel.read_bytes()[:18]
    if header[:8] != bytes.fromhex('90abcdef0000008a') or header[8:18] != DART[:10].encode():
        raise RuntimeError('Unexpected unmodified control kernel header')
    return {'kernelSha256': KERNEL_SHA, 'evidenceSha256': sha(control_evidence),
            'previousStatus': previous['status'], 'originalDartFiles': 145,
            'sourceHashes': previous['sourceHashes']}


def git_repo(path, url, revision):
    if not path.exists():
        path.mkdir()
    if not (path / '.git').exists():
        if any(path.iterdir()):
            raise RuntimeError('Refusing to initialize a nonempty directory: ' + str(path))
        command(['git', 'init', str(path)])
        command(['git', 'remote', 'add', 'origin', url], path)
    if command(['git', 'remote', 'get-url', 'origin'], path, capture=True) != url:
        raise RuntimeError('Unexpected Git remote in ' + str(path))
    command(['git', 'fetch', '--depth=1', 'origin', revision], path)
    command(['git', 'checkout', '--detach', revision], path)


def check_source():
    if command(['git', 'rev-parse', 'HEAD'], source, capture=True) != ENGINE:
        raise RuntimeError('Engine checkout moved from its pinned revision')
    tree = ast.parse((source / 'DEPS').read_text())
    variables = next(ast.literal_eval(node.value) for node in tree.body
                     if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'vars' for t in node.targets))
    # gclient preserves expression variables as the string 'False' and its
    # EvaluateCondition recursively parses that string to the boolean False.
    if variables['dart_revision'] != DART or any(variables[name] is not False and variables[name] != 'False' for name in
            ['download_dart_sdk', 'download_android_deps', 'download_fuchsia_deps']):
        raise RuntimeError('DEPS no longer matches the isolated Dart roll and disabled SDK downloads')
    dart_path = source / 'engine/src/flutter/third_party/dart'
    if command(['git', 'rev-parse', 'HEAD'], dart_path, capture=True) != DART:
        raise RuntimeError('Synchronized Dart source does not match the requested revision')
    modified = command(['git', 'diff', '--name-only'], source, capture=True).splitlines()
    if set(modified) - {'DEPS', 'engine/src/build/config/compiler/BUILD.gn'}:
        raise RuntimeError('Unexpected tracked source modifications: ' + repr(modified))


def packages():
    command(['apt-get', 'update'])
    command(['apt-get', 'install', '-y', 'ninja-build', 'unzip', 'patch'])


def depot_phase():
    pin = state / 'depot_revision.txt'
    if not pin.exists():
        revision = command(['git', 'ls-remote', DEPOT_URL, 'HEAD'], capture=True).split()[0]
        if not re.fullmatch('[0-9a-f]{40}', revision):
            raise RuntimeError('Invalid depot_tools revision')
        pin.write_text(revision + '\n')
    git_repo(depot, DEPOT_URL, pin.read_text().strip())


def configure():
    config = source / '.gclient'
    if not config.exists():
        command(['gclient', 'config', '--unmanaged', 'https://github.com/flutter-tizen/flutter'], source)
    text = config.read_text()
    config_tree = ast.parse(text)
    solutions = next(ast.literal_eval(node.value) for node in config_tree.body
                     if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'solutions' for t in node.targets))
    if (len(solutions) != 1 or solutions[0]['name'] not in ['flutter', '.']
            or solutions[0]['url'] != 'https://github.com/flutter-tizen/flutter'
            or solutions[0]['managed'] is not False):
        raise RuntimeError('Unexpected existing .gclient solution')
    if solutions[0]['name'] == 'flutter':
        # The pinned upstream CI performs this same single-quoted replacement.
        if text.count("'flutter'") != 1:
            raise RuntimeError('Unexpected generated .gclient solution quoting')
        config.write_text(text.replace("'flutter'", "'.'"))
    command(['gclient', 'setdep', '--var=dart_revision=' + DART,
             '--var=download_dart_sdk=False', '--var=download_android_deps=False',
             '--var=download_fuchsia_deps=False', '--deps-file=DEPS'], source)


def workarounds():
    check_source()
    relative = 'engine/src/build/config/compiler/BUILD.gn'
    original = command(['git', 'show', ENGINE + ':' + relative], source, capture=True) + '\n'
    linker = '    ldflags += [ "-Wl,--undefined-version" ]\n'
    if original.count(linker) != 1 or original.count('Wno-nontrivial-memcall') != 2:
        raise RuntimeError('Upstream compiler workaround counts changed')
    patched = original.replace(linker, '').replace('Wno-nontrivial-memcall', 'Wno-nontrivial-memaccess')
    target = source / relative
    if target.read_text() not in [original, patched]:
        raise RuntimeError('Compiler config has edits beyond the two upstream CI workarounds')
    target.write_text(patched)
    (run_dir / 'source.diff').write_text(command(['git', 'diff', '--', 'DEPS', relative], source, capture=True) + '\n')


def gn():
    check_source()
    command([source / 'engine/src/flutter/tools/gn', '--target-os', 'linux', '--linux-cpu', 'arm',
             '--runtime-mode', 'release', '--no-goma', '--no-lto',
             '--target-toolchain', '/tizen_tools/toolchains', '--target-sysroot', '/work/sysroot/arm',
             '--target-triple', 'arm-linux-gnueabi', '--enable-fontconfig',
             '--disable-desktop-embeddings', '--target-dir', 'tizen_arm_release'], source)
    shutil.copyfile(out / 'args.gn', run_dir / 'args.gn')
    versions = {}
    for name, argv in {'git': ['git', '--version'], 'ninja': ['/usr/bin/ninja', '--version'],
                       'tizenClang': ['/tizen_tools/toolchains/bin/clang', '--version'],
                       'gn': [source / 'engine/src/flutter/third_party/gn/gn', '--version'],
                       'installedPackages': ['dpkg-query', '-W']}.items():
        versions[name] = command(argv, capture=True)
    versions.update(python=sys.version, depotToolsRevision=(state / 'depot_revision.txt').read_text().strip())
    write_json(work / 'evidence/tool-versions.json', versions)


def elf(path, machine, elf_class):
    with path.open('rb') as handle:
        header = handle.read(20)
    if header[:4] != b'\x7fELF' or header[4] != elf_class or header[5] != 1 or struct.unpack('<H', header[18:20])[0] != machine:
        raise RuntimeError('Unexpected ELF architecture: ' + str(path))
    return {'path': str(path), 'sha256': sha(path), 'bytes': path.stat().st_size,
            'elfMachine': machine, 'elfClass': elf_class}


def control():
    check_source()
    check_control()
    artifacts.mkdir(parents=True, exist_ok=True)
    for name, origin in {'libflutter_engine.so': out / 'libflutter_engine.so',
                         'icudtl.dat': source / 'engine/src/flutter/third_party/icu/flutter/icudtl.dat',
                         'gen_snapshot': out / 'clang_x64/gen_snapshot'}.items():
        shutil.copy2(origin, artifacts / name)
    elf(artifacts / 'libflutter_engine.so', 40, 1)
    elf(artifacts / 'gen_snapshot', 62, 2)
    version = command([artifacts / 'gen_snapshot', '--version'], capture=True)
    if not re.search(r'Dart SDK version: 3\.13\.5\b', version):
        raise RuntimeError('Built compiler is not Dart 3.13.5')
    command([artifacts / 'gen_snapshot', '--deterministic', '--snapshot_kind=app-aot-elf',
             '--elf=' + str(artifacts / 'application-tizen-arm.so'), '--strip',
             '--no-sim-use-hardfp', '--no-use-integer-division', kernel])
    phase_record['genSnapshotOptions'] = phase_record['commands'][-1]['argv'][1:-1]
    elf(artifacts / 'application-tizen-arm.so', 40, 1)
    phase_record['compilerVersion'] = version
    phase_record['artifactHashes'] = {p.name: sha(p) for p in artifacts.iterdir() if p.is_file()}
    shutil.copyfile(control_evidence, run_dir / 'original-application-evidence.json')
    check_control()


try:
    if os.environ.get('TVBRO_BUILDER_IMAGE') != IMAGE:
        raise RuntimeError('TVBRO_BUILDER_IMAGE must name the exact pinned container image')
    image_id = os.environ.get('TVBRO_CONTAINER_IMAGE_ID', '')
    if not re.fullmatch('sha256:[0-9a-f]{64}', image_id):
        raise RuntimeError('Pass the host-inspected TVBRO_CONTAINER_IMAGE_ID for provenance')
    if platform.machine() != 'x86_64' or not Path('/.dockerenv').exists():
        raise RuntimeError('Expected an x86_64 Docker container')
    if (not work.is_dir() or work.is_symlink() or mount(work)[2:] != ('ext4', '/work')
            or 'rw' not in mount(work)[1]):
        raise RuntimeError('/work must be a separate persistent Linux ext4 mount')
    free_bytes = shutil.disk_usage(work).free
    if free_bytes < args.min_free_gib * 1024 ** 3:
        raise RuntimeError('/work has {:.1f} GiB free; the requested operational floor is {} GiB'.format(
            free_bytes / 1024 ** 3, args.min_free_gib))
    control_info = check_control()
    config_path = work / '.tvbro-engine-builder.json'
    config = {'schemaVersion': 1, 'engineRevision': ENGINE, 'dartRevision': DART,
              'imageReference': IMAGE, 'imageId': image_id, 'controlKernelSha256': KERNEL_SHA}
    if config_path.exists():
        if json.loads(config_path.read_text()) != config:
            raise RuntimeError('Existing builder workspace belongs to different pins; use a new empty /work')
    else:
        if any(work.iterdir()):
            raise RuntimeError('Refusing to adopt a nonempty unmanaged /work')
        write_json(config_path, config)
    state.mkdir(exist_ok=True)
    lock = (state / 'lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    run_dir.mkdir(parents=True)
    os.environ.update(PATH=str(depot) + ':' + os.environ['PATH'], DEPOT_TOOLS_UPDATE='0',
                      DEPOT_TOOLS_METRICS='0', DEBIAN_FRONTEND='noninteractive')
    evidence.update(startedUtc=now(), runId=run_id, pins=config, control=control_info,
                    host={'uname': list(platform.uname()), 'cpuCount': os.cpu_count()}, jobs=args.jobs,
                    diskPreflight={'freeBytes': free_bytes, 'minimumFreeGiB': args.min_free_gib,
                                   'floorIsBuildSizeEstimate': False},
                    scriptSha256=sha(Path(os.environ.get('TVBRO_BUILDER_SCRIPT', '/builder/build.sh'))))
    actions = {'packages': packages, 'depot': depot_phase,
               'checkout': lambda: git_repo(source, ENGINE_URL, ENGINE), 'configure': configure,
               'sync': lambda: command(['gclient', 'sync', '-v', '--no-history', '--shallow'], source),
               'sysroot': lambda: command([source / 'engine/src/flutter/ci/tizen/generate_sysroot.py',
                                           '--out', '/work/sysroot', '--api-version', '6.0'], source),
               'workarounds': workarounds, 'gn': gn,
               'build': lambda: command(['/usr/bin/ninja', '-j' + str(args.jobs), '-C', out,
                                         'flutter_engine_library', 'clang_x64/gen_snapshot'], source),
               'control': control}
    for current in PHASES[:PHASES.index(args.stop_after) + 1]:
        record_path = state / (current + '.json')
        previous = json.loads(record_path.read_text()) if record_path.exists() else None
        container_packages_missing = current == 'packages' and any(
            not os.access('/usr/bin/' + tool, os.X_OK) for tool in ['ninja', 'unzip', 'patch'])
        reprovision_container = previous and previous['status'] == 'succeeded' and container_packages_missing
        if previous and previous['status'] == 'succeeded' and not reprovision_container:
            if current in args.retry_phase:
                raise RuntimeError('A successful phase is immutable; use a new workspace to rebuild it: ' + current)
            event('skipped_completed', record=str(record_path))
            continue
        if previous and not reprovision_container and current not in args.retry_phase:
            raise RuntimeError('Phase {} previously {}; explicit --retry-phase {} is required'.format(current, previous['status'], current))
        phase_record = {'phase': current, 'status': 'running', 'startedUtc': now(), 'runId': run_id,
                        'attempt': 1 + (previous.get('attempt', 0) if previous else 0), 'commands': [],
                        'log': str(run_dir / (current + '.log'))}
        if reprovision_container:
            phase_record['reason'] = 'Missing prerequisites in a fresh container; persistent sources are retained'
        write_json(record_path, phase_record)
        event('started', log=phase_record['log'])
        with Path(phase_record['log']).open('w', encoding='utf-8', buffering=1) as log:
            actions[current]()
        phase_record.update(status='succeeded', finishedUtc=now())
        write_json(record_path, phase_record)
        event('succeeded')
        phase_record = None
    if args.stop_after == 'control':
        control_info = check_control()
        saved = json.loads((state / 'control.json').read_text())
        saved_options = saved.get('genSnapshotOptions')
        if saved_options is None:
            saved_commands = [item['argv'] for item in saved.get('commands', [])
                              if '--snapshot_kind=app-aot-elf' in item.get('argv', [])]
            saved_options = saved_commands[-1][1:-1] if saved_commands else None
        if any(sha(artifacts / name) != value for name, value in saved['artifactHashes'].items()):
            raise RuntimeError('Completed custom artifacts changed since qualification')
        evidence['artifacts'] = {name: elf(artifacts / name, machine, kind) for name, machine, kind in
                                 [('libflutter_engine.so', 40, 1), ('gen_snapshot', 62, 2), ('application-tizen-arm.so', 40, 1)]}
        evidence['artifacts']['icudtl.dat'] = {'path': str(artifacts / 'icudtl.dat'), 'sha256': sha(artifacts / 'icudtl.dat')}
        evidence.update(status='custom_tizen_engine_and_application_aot_built', nativeEngineBuild=True,
                        applicationAotCompiled=True, compilerVersion=saved['compilerVersion'],
                        genSnapshotOptions=saved_options)
    else:
        evidence.update(status='stopped_after_requested_phase', stoppedAfter=args.stop_after)
except BaseException as error:
    evidence.update(status='failed', failedPhase=current, error=str(error))
    if phase_record and phase_record.get('status') == 'running':
        phase_record.update(status='failed', finishedUtc=now(), error=str(error))
        write_json(state / (current + '.json'), phase_record)
    print('Builder stopped: ' + str(error), file=sys.stderr, flush=True)
finally:
    if run_dir.is_dir():
        evidence.update(finishedUtc=now(), phases={name: json.loads((state / (name + '.json')).read_text())
                        for name in PHASES if (state / (name + '.json')).is_file()})
        write_json(run_dir / 'evidence.json', evidence)
        write_json(work / 'evidence/terminal.json', {'status': evidence['status'], 'runId': run_id,
                   'failedPhase': evidence.get('failedPhase'), 'evidence': str(run_dir / 'evidence.json')})
        event(evidence['status'], evidence=str(run_dir / 'evidence.json'))
sys.exit(1 if evidence['status'] == 'failed' else 0)
PY
