#!/usr/bin/env python3
"""Stage an isolated Tizen package; the original application stays read-only."""
import argparse
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.parse import unquote, urljoin, urlparse
import xml.etree.ElementTree as ET


TOOL_REVISION = '22bcec9058fbe1e0943e6c6fda21792f24868e91'
FRAMEWORK_REVISION = 'abaf9c523780a608bd46686fd5e53740a07077f8'
PLUGINS = {
    'path_provider_tizen': '2.3.3',
    'flutter_secure_storage_tizen': '0.1.6',
    'package_info_plus_tizen': '1.2.0',
    'url_launcher_tizen': '2.1.7',
}
DEFINES = {'TVBRO_CLOUD_ENABLED': False, 'DISTRIBUTION_CHANNEL': 'development'}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=['prepare', 'create-native', 'verify-lock', 'configure-sqlite'])
parser.add_argument('--owner', type=Path, default=Path('/owner'))
parser.add_argument('--project', type=Path, required=True)
parser.add_argument('--yaml-module', type=Path, help='Existing PyYAML source directory, when not installed; never installs packages.')
parser.add_argument('--flutter-tizen', type=Path, help='Isolated pinned CLI, required only by create-native.')
parser.add_argument('--expected-owner-version', default='1.0.7+2008')
parser.add_argument('--sqlite-proof', type=Path, help='Required SDK API 6 system-library proof for configure-sqlite; never enables a hook by default.')
args = parser.parse_args()
if args.yaml_module:
    sys.path.insert(0, str(args.yaml_module.resolve()))
try:
    import yaml
except ImportError:
    parser.error('PyYAML is required: use an existing --yaml-module directory; no installation is performed.')


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    os.replace(temporary, path)


def mount(path):
    matches = []
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        left, right = line.split(' - ', 1)
        fields = left.split()
        point = Path(re.sub(r'\\([0-7]{3})', lambda m: chr(int(m[1], 8)), fields[4]))
        if path == point or point in path.parents:
            matches.append((len(str(point)), {'point': str(point), 'options': fields[5].split(','), 'filesystem': right.split()[0]}))
    if not matches:
        raise RuntimeError('Cannot establish mount provenance: ' + str(path))
    return max(matches, key=lambda item: item[0])[1]


def inside_owner(relative):
    relative = Path(relative)
    if relative.is_absolute() or '..' in relative.parts:
        raise RuntimeError('Owner-relative input required: ' + str(relative))
    path = (owner / relative).resolve(strict=True)
    if not path.is_relative_to(owner):
        raise RuntimeError('Input resolves outside the read-only owner: ' + str(relative))
    return path


def protected_hashes():
    files = [inside_owner('pubspec.yaml'), inside_owner('pubspec.lock'), inside_owner('tv/app/main.dart')]
    files.append(inside_owner('tv/tizen_player/pubspec.yaml'))
    files.extend(sorted((owner / 'tv/tizen_player/lib').rglob('*.dart')))
    files.extend(sorted((owner / 'lib').rglob('*.dart')))
    files.extend(inside_owner(key) for key in asset_keys)
    files.append(inside_owner(brand_icon_key))
    return {str(path.relative_to(owner)): sha(path) for path in sorted(set(files))}


def identity(package):
    return {key: package.get(key) for key in ['version', 'source', 'description']}


def rebased_path(value):
    relative = Path(value)
    path = relative.resolve(strict=True) if relative.is_absolute() else inside_owner(relative)
    if not path.is_relative_to(owner):
        raise RuntimeError('Owner path dependency is outside the read-only mount: ' + str(value))
    return path.as_posix()


def prepare():
    if project.exists() and any(project.iterdir()):
        raise RuntimeError('Use a new empty project directory; existing stages are preserved.')
    project.mkdir(parents=True, exist_ok=True)
    overrides = copy.deepcopy(spec.get('dependency_overrides', {}))
    for value in overrides.values():
        if isinstance(value, dict) and 'path' in value:
            value['path'] = rebased_path(value['path'])
    dependencies = {'flutter': {'sdk': 'flutter'}, 'iptvs': {'path': owner.as_posix()},
                    'tvbro_tizen_player': {'path': inside_owner('tv/tizen_player').as_posix()}, **PLUGINS}
    manifest = {'name': 'tvbro_tizen', 'description': 'Isolated Tizen packaging of the original TVBro application.',
                'publish_to': 'none', 'version': spec['version'], 'environment': spec['environment'],
                'dependencies': dependencies, 'flutter': spec.get('flutter', {})}
    if overrides:
        manifest['dependency_overrides'] = overrides
    # JSON is a YAML subset; metadata is generated without another emitter.
    write(project / 'pubspec.yaml', manifest)
    seed = copy.deepcopy(lock)
    for name, package in seed['packages'].items():
        package['dependency'] = 'direct main' if name in dependencies else 'transitive'
        if package['source'] == 'path':
            package['description']['path'] = rebased_path(package['description']['path'])
            package['description']['relative'] = False
    seed['packages']['iptvs'] = {'dependency': 'direct main', 'description': {'path': owner.as_posix(), 'relative': False},
                                 'source': 'path', 'version': spec['version']}
    write(project / 'pubspec.lock', seed)
    write(meta / 'owner-lock-identities.json', {name: identity(package) for name, package in seed['packages'].items() if name != 'iptvs'})
    assets = []
    for key in asset_keys:
        source = inside_owner(key)
        if not source.is_file():
            raise RuntimeError('This owner declares an unsupported non-file asset: ' + key)
        target = project / key
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        if sha(source) != sha(target):
            raise RuntimeError('Staged asset differs: ' + key)
        assets.append({'assetKey': key, 'source': source.as_posix(), 'staged': target.as_posix(), 'sha256': sha(source)})
    write(meta / 'asset-staging.json', assets)
    write(meta / 'build-defines.json', DEFINES)
    write(meta / 'runtime-dependencies.json', {
        'ownerDependencies': {name: {'constraint': value, 'locked': lock['packages'].get(name), 'runtimeQualifiedByStaging': False}
                              for name, value in spec['dependencies'].items()},
        'additionalTizenPlugins': PLUGINS,
        'mediaKit': 'Original Player models and application logic use the TV-only AVPlay PlatformPlayer adapter; no mpv initialization or desktop process on Tizen.',
        'database': 'Original Linux route selects databaseFactoryFfi; adding sqflite_tizen would not select it. No factory or sqlite hook is supplied.',
        'filePicker': 'Original dependency remains; no Tizen implementation is supplied.',
        'appLinks': {'locked': lock['packages'].get('app_links'), 'status': 'Transitive owner package; no Tizen implementation qualified by this stage.'},
        'urlLauncher': 'Original externalApplication launchUrl calls use the legacy launch path and require an installed URL handler; supportsLaunchMode metadata does not reject those calls.',
        'applicationRuntimeQualified': False,
    })
    return {'status': 'manifest_assets_and_lock_seed_prepared', 'nativeSkeletonCreated': False,
            'entrypoint': (owner / 'tv/app/main.dart').as_posix(), 'ownerVersion': spec['version'],
            'ownerSdkConstraint': spec['environment']['sdk'], 'iptvsPath': owner.as_posix(), 'additionalTizenPlugins': PLUGINS,
            'assetCount': len(assets), 'lockSeedPackageCount': len(seed['packages']), 'pubGetPerformed': False,
            'nativeBrandIcon': {'sourceKey': brand_icon_key, 'sourceSha256': sha(inside_owner(brand_icon_key))},
            'requiredBuildArguments': ['--target=' + (owner / 'tv/app/main.dart').as_posix(), '--dart-define-from-file=' + (meta / 'build-defines.json').as_posix()],
            'runtimeQualified': False}


def create_native():
    if not args.flutter_tizen:
        raise RuntimeError('--flutter-tizen is required for create-native.')
    cli = args.flutter_tizen.resolve(strict=True)
    revision = subprocess.check_output(['git', '-C', str(cli.parent.parent), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != TOOL_REVISION:
        raise RuntimeError('The isolated flutter-tizen checkout must be pinned to ' + TOOL_REVISION)
    cli_root = cli.parent.parent
    flutter_root = cli_root / 'flutter'
    configured_framework = (cli_root / 'bin/internal/flutter.version').read_text().strip()
    framework_revision = subprocess.check_output(['git', '-C', str(flutter_root), 'rev-parse', 'HEAD'], text=True).strip()
    if configured_framework != FRAMEWORK_REVISION or framework_revision != configured_framework:
        raise RuntimeError('CLI and isolated Flutter HEAD must already match the owner SDK pin; bootstrap resets are refused.')
    template_status = subprocess.check_output(['git', '--no-optional-locks', '-C', str(flutter_root), 'status',
                                               '--porcelain=v1', '--untracked-files=all', '--', 'packages/flutter_tools/templates'], text=True)
    if template_status.strip():
        raise RuntimeError('Refusing create: official CLI cleans the SDK template subtree, which has local changes:\n' + template_status)
    if (project / 'tizen').exists():
        raise RuntimeError('Refusing to overwrite an existing native Tizen skeleton.')
    retained = [project / 'pubspec.yaml', project / 'pubspec.lock', *(project / key for key in asset_keys)]
    retained_hashes = {str(path): sha(path) for path in retained}
    seed_lock = (project / 'pubspec.lock').read_bytes()
    generated_samples = [project / 'lib/main.dart', project / 'test/widget_test.dart']
    if any(path.exists() for path in generated_samples):
        raise RuntimeError('Refusing a stage that already has a Dart entrypoint or sample test.')
    command = [str(cli), '--no-version-check', '--suppress-analytics', 'create', '--platforms=tizen', '--tizen-language=csharp',
               '--template=app', '--app-type=ui', '--empty', '--no-pub', '--project-name=tvbro_tizen', '--org=org.tvbro', str(project)]
    with (meta / 'create-native.log').open('w', encoding='utf-8') as log:
        result = subprocess.run(command, cwd=project, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError('Pinned flutter-tizen create failed; see .tvbro/create-native.log.')
    # Flutter create emits its sample lock even with --no-pub. Restore only
    # this generated wrapper's owner-derived seed before ordinary pub get.
    template_lock_hash = sha(project / 'pubspec.lock')
    (project / 'pubspec.lock').write_bytes(seed_lock)
    if any(sha(Path(path)) != value for path, value in retained_hashes.items()):
        raise RuntimeError('Create changed the staged manifest, lock seed or original asset copies.')
    # Only newly generated sample files are removed; the original target is outside CWD.
    removed_samples = []
    for path in generated_samples:
        if path.exists():
            removed_samples.append({'path': path.as_posix(), 'sha256': sha(path)})
            path.unlink()
            if not any(path.parent.iterdir()):
                path.parent.rmdir()
    native_manifest = project / 'tizen/tizen-manifest.xml'
    tree = ET.parse(native_manifest)
    native_root = tree.getroot()
    namespace = native_root.tag.split('}')[0].lstrip('{')
    ET.register_namespace('', namespace)
    native_root.set('version', spec['version'].split('+')[0])
    if native_root.get('api-version') != '6.0':
        raise RuntimeError('Expected the pinned API 6.0 manifest template.')
    profiles = native_root.findall('{' + namespace + '}profile')
    applications = native_root.findall('{' + namespace + '}ui-application')
    if len(profiles) != 1 or len(applications) != 1:
        raise RuntimeError('Expected one profile and one UI application in the generated manifest.')
    profiles[0].set('name', 'tv')
    label = applications[0].find('{' + namespace + '}label')
    icon = applications[0].find('{' + namespace + '}icon')
    if label is None or icon is None or not icon.text:
        raise RuntimeError('The generated C# manifest has no application label/icon.')
    label.text = 'TVBro'
    icon_key = Path(icon.text)
    if icon_key.is_absolute() or '..' in icon_key.parts:
        raise RuntimeError('The generated native icon must stay inside its resource directory.')
    native_icon = (project / 'tizen/shared/res' / icon_key).resolve(strict=True)
    if not native_icon.is_relative_to(project / 'tizen') or not native_icon.is_file():
        raise RuntimeError('Unexpected generated native icon resource path.')
    brand_source = inside_owner(brand_icon_key)
    shutil.copyfile(brand_source, native_icon)
    if sha(brand_source) != sha(native_icon):
        raise RuntimeError('Native icon is not a byte-for-byte copy of the owner brand asset.')
    for privilege in ['http://tizen.org/privilege/internet', 'http://tizen.org/privilege/appmanager.launch']:
        if not any(element.get('name') == privilege for element in native_root.findall('{' + namespace + '}privilege')):
            ET.SubElement(native_root, '{' + namespace + '}privilege', {'name': privilege})
    tree.write(native_manifest, encoding='utf-8', xml_declaration=True)
    native_project = project / 'tizen/Runner.csproj'
    project_tree = ET.parse(native_project)
    frameworks = [element for element in project_tree.getroot().iter() if element.tag.rsplit('}', 1)[-1] == 'TargetFramework']
    if len(frameworks) != 1 or frameworks[0].text not in ['tizen80', 'tizen60']:
        raise RuntimeError('Unexpected generated C# target framework.')
    frameworks[0].text = 'tizen60'
    project_tree.write(native_project, encoding='utf-8', xml_declaration=True)
    native_files = [project / 'tizen/App.cs', native_project, native_manifest, native_icon]
    if not all(path.is_file() for path in native_files) or (project / 'lib/main.dart').exists():
        raise RuntimeError('The generated C# skeleton is incomplete or a duplicate Dart entrypoint remains.')
    return {'status': 'pinned_csharp_skeleton_created', 'command': command, 'toolRevision': revision, 'pubGetPerformed': False,
            'frameworkRevision': framework_revision, 'sdkTemplateStatusBeforeCreate': template_status,
            'templateLockSha256': template_lock_hash, 'ownerSeedLockRestoredSha256': sha(project / 'pubspec.lock'),
            'entrypoint': (owner / 'tv/app/main.dart').as_posix(), 'removedGeneratedSamples': removed_samples,
            'nativeFiles': {path.relative_to(project).as_posix(): sha(path) for path in native_files},
            'manifestVersion': spec['version'].split('+')[0], 'ownerBuildNumber': spec['version'].split('+')[1],
            'manifestProfile': 'tv', 'manifestApiVersion': '6.0', 'targetFramework': 'tizen60', 'applicationLabel': label.text,
            'nativeBrandIcon': {'sourceKey': brand_icon_key, 'manifestReference': icon.text, 'sourceSha256': sha(brand_source), 'stagedSha256': sha(native_icon)},
            'sourceReferences': ['https://developer.samsung.com/tizen/Smart-TV/Quickstarts/Creating-an-application.html',
                                 'https://developer.samsung.com/tizen/blog/en/2019/06/13/using-tizennetsdk-as-sdk-style']}


def verify_lock():
    expected = json.loads((meta / 'owner-lock-identities.json').read_text())
    resolved = yaml.safe_load((project / 'pubspec.lock').read_text())['packages']
    differences = {name: {'owner': expected[name], 'wrapper': identity(resolved[name])} for name in sorted(expected.keys() & resolved.keys())
                   if expected[name] != identity(resolved[name])}
    config_path = project / '.dart_tool/package_config.json'
    config = json.loads(config_path.read_text())
    iptvs = [package for package in config['packages'] if package['name'] == 'iptvs']
    resolved_owner = Path(unquote(urlparse(urljoin(config_path.as_uri(), iptvs[0]['rootUri'])).path)).resolve() if len(iptvs) == 1 else None
    correct_owner = resolved_owner == owner and iptvs[0].get('packageUri') == 'lib/' if iptvs else False
    staged_manifest = yaml.safe_load((project / 'pubspec.yaml').read_text())
    expected_overrides = copy.deepcopy(spec.get('dependency_overrides', {}))
    for value in expected_overrides.values():
        if isinstance(value, dict) and 'path' in value:
            value['path'] = rebased_path(value['path'])
    overrides_unchanged = staged_manifest.get('dependency_overrides', {}) == expected_overrides
    owner_contract_preserved = (staged_manifest.get('version') == spec['version']
                                and staged_manifest.get('environment') == spec['environment']
                                and staged_manifest.get('flutter') == spec.get('flutter', {}))
    plugin_pins_preserved = all(resolved.get(name, {}).get('version') == version
                               and staged_manifest.get('dependencies', {}).get(name) == version for name, version in PLUGINS.items())
    safe_defines = json.loads((meta / 'build-defines.json').read_text()) == DEFINES
    matching_generator = config.get('generatorVersion') == '3.13.5'
    assets = json.loads((meta / 'asset-staging.json').read_text())
    assets_unchanged = all(sha(project / asset['assetKey']) == asset['sha256'] == sha(inside_owner(asset['assetKey'])) for asset in assets)
    passed = not differences and all([correct_owner, overrides_unchanged, assets_unchanged, owner_contract_preserved,
                                     plugin_pins_preserved, safe_defines, matching_generator])
    result = {'status': 'owner_lock_and_paths_preserved' if passed else 'failed',
              'commonOwnerPackageDifferences': differences, 'removedOwnerPackages': sorted(expected.keys() - resolved.keys()),
              'addedWrapperPackages': sorted(resolved.keys() - expected.keys()), 'resolvedIptvsRoot': str(resolved_owner),
              'iptvsResolvesToReadOnlyOwner': correct_owner, 'onlyExistingOwnerOverrides': overrides_unchanged,
              'stagedAssetsUnchanged': assets_unchanged, 'ownerManifestContractPreserved': owner_contract_preserved,
              'exactTizenPluginPinsPreserved': plugin_pins_preserved, 'safeBuildDefinesPreserved': safe_defines,
              'packageConfigGeneratorVersion': config.get('generatorVersion'), 'matchingDartGenerator': matching_generator}
    write(meta / 'verify-lock.json', result)
    if result['status'] == 'failed':
        raise RuntimeError('Wrapper resolution changed owner package identities, overrides, assets or iptvs root; see verify-lock.json.')
    return result


def configure_sqlite():
    if not args.sqlite_proof:
        raise RuntimeError('configure-sqlite requires --sqlite-proof; the generated manifest was not changed.')
    proof_path = args.sqlite_proof.resolve(strict=True)
    proof_bytes = proof_path.read_bytes()
    proof = json.loads(proof_bytes)
    candidate, decision = proof.get('candidate', {}), proof.get('decision', {})
    expected = {'targetOS': 'linux', 'targetPath': '/usr/lib/libsqlite3.so.0', 'sdkApiVersion': '6.0',
                'elfClass': 32, 'machine': 40, 'flags': '0x5000200', 'soname': 'libsqlite3.so.0', 'sqliteVersion': '3.31.1'}
    if (proof.get('schemaVersion') != 1 or lock['packages'].get('sqlite3', {}).get('version') != '3.7.1'
            or 'ro' not in mount(proof_path)['options']
            or any(candidate.get(key) != value for key, value in expected.items())
            or decision.get('systemApiCandidate') is not True or decision.get('hardBlockerForNormalOpenQuery') is not False
            or decision.get('runtimeQualified') is not False or decision.get('ftsQualified') is not False):
        raise RuntimeError('The supplied proof does not establish the narrow unqualified SDK API 6 system candidate.')
    library = Path(candidate['sourcePath']).resolve(strict=True)
    sdk = Path(os.environ['TIZEN_SDK']).resolve(strict=True)
    provenance = proof['provenance']['sdkPackageLog']
    if (not library.is_relative_to(sdk / 'platforms/tizen-6.0') or sha(library) != candidate['sha256']
            or provenance.get('completed') is not True or sha(inside_owner(provenance['ownerRelativePath'])) != provenance['sha256']):
        raise RuntimeError('SDK library or completed package provenance differs from the supplied proof.')
    header = library.read_bytes()[:40]
    if header[:6] != b'\x7fELF\x01\x01' or int.from_bytes(header[18:20], 'little') != 40 or int.from_bytes(header[36:40], 'little') != 0x5000200:
        raise RuntimeError('The SDK library is not the expected little-endian ARM soft-float ELF.')
    manifest = yaml.safe_load((project / 'pubspec.yaml').read_text())
    defines = manifest.setdefault('hooks', {}).setdefault('user_defines', {})
    hook = {'source': {'linux': 'system'}, 'name': {'linux': candidate['targetPath']}}
    if defines.get('sqlite3') not in [None, hook]:
        raise RuntimeError('Refusing to overwrite a different generated SQLite hook.')
    defines['sqlite3'] = hook
    write(project / 'pubspec.yaml', manifest)
    return {'status': 'sdk_system_sqlite_candidate_configured', 'hook': hook, 'proofSha256': hashlib.sha256(proof_bytes).hexdigest(),
            'sdkLibrarySha256': candidate['sha256'], 'sdkPackageLogSha256': provenance['sha256'],
            'candidate': candidate,
            'systemApiCandidate': True, 'runtimeQualified': False, 'ftsQualified': False,
            'optionalApisNotQualified': ['sqlite3_db_status64', 'session/changeset'], 'libraryCopiedIntoTpk': False}


owner = args.owner.resolve(strict=True)
if args.project.is_symlink():
    raise SystemExit('The generated project must not be a symlink.')
project = args.project.resolve()
meta = project / '.tvbro'
if sys.platform != 'linux' or project.is_relative_to(owner) or project.is_symlink():
    raise SystemExit('Use a separate Linux ext4 project outside the original owner.')
owner_mount = mount(owner)
project_mount = mount(project if project.exists() else project.parent)
if 'ro' not in owner_mount['options'] or project_mount['filesystem'] != 'ext4' or 'rw' not in project_mount['options']:
    raise SystemExit('The owner must be mounted read-only and project storage must be writable ext4.')
prepared = None
if args.action == 'prepare':
    if project.exists() and any(project.iterdir()):
        raise SystemExit('Refusing a nonempty output; no files in that directory were changed.')
else:
    marker = meta / 'prepare.json'
    if not marker.is_file():
        raise SystemExit('This action requires this generator\'s successful prepare marker.')
    prepared = json.loads(marker.read_text())
    if (prepared.get('status') != 'manifest_assets_and_lock_seed_prepared' or prepared.get('owner') != owner.as_posix()
            or prepared.get('project') != project.as_posix()):
        raise SystemExit('Refusing a stage belonging to a different or failed preparation.')
spec = yaml.safe_load(inside_owner('pubspec.yaml').read_text(encoding='utf-8-sig'))
lock = yaml.safe_load(inside_owner('pubspec.lock').read_text(encoding='utf-8-sig'))
if spec['name'] != 'iptvs' or spec['version'] != args.expected_owner_version or spec['environment']['sdk'] != '^3.13.5':
    raise SystemExit('Unexpected owner name/version/SDK; preserve the owner contract and qualify a changed baseline separately.')
flutter = spec.get('flutter', {})
brand_icon_key = spec.get('flutter_launcher_icons', {}).get('image_path_android')
if brand_icon_key != 'assets/brand/tvbro-icon.png':
    raise SystemExit('Expected the existing owner Android/Windows TVBro brand icon configuration.')
asset_keys = list(dict.fromkeys([*flutter.get('assets', []), *(font['asset'] for family in flutter.get('fonts', []) for font in family['fonts'])]))
if any(not isinstance(key, str) for key in asset_keys):
    raise SystemExit('Only owner-declared file asset keys are supported by this narrow staging workflow.')
before = protected_hashes()
record = {'action': args.action, 'startedAtUtc': now(), 'owner': owner.as_posix(), 'project': project.as_posix(),
          'ownerMount': owner_mount, 'projectMount': project_mount, 'protectedInputHashesBefore': before,
          'generatorSha256': sha(Path(__file__)), 'yamlModule': str(Path(yaml.__file__).resolve())}
try:
    if prepared and any(before.get(key) != value for key, value in prepared['protectedInputHashesAfter'].items()):
        raise RuntimeError('Owner inputs changed since prepare; retain this stage and prepare a new baseline.')
    record.update({'prepare': prepare, 'create-native': create_native, 'verify-lock': verify_lock, 'configure-sqlite': configure_sqlite}[args.action]())
except BaseException as error:
    record.update(status='failed', error=str(error))
finally:
    after = protected_hashes()
    record.update(finishedAtUtc=now(), protectedInputHashesAfter=after,
                  protectedInputsChanged=sorted(key for key in before.keys() | after.keys() if before.get(key) != after.get(key)))
    if record['protectedInputsChanged']:
        record.update(status='failed', error='Read-only inputs changed during staging; concurrent owner edits require a new baseline.')
    if project.is_dir():
        write(meta / (args.action + '.json'), record)
    print(json.dumps({key: record.get(key) for key in ['action', 'status', 'ownerVersion', 'assetCount', 'protectedInputsChanged', 'error']}, ensure_ascii=False), flush=True)
sys.exit(1 if record.get('status') == 'failed' else 0)
