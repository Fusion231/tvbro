#!/usr/bin/env python3
"""Create a real SDK signing profile for local TPK qualification only."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import stat
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path('/opt/tvbro-tizen-toolchain')
HOME = ROOT / 'home'
PRIVATE = HOME / 'private'
NAME = 'TVBroLocalQualification'
KEY = PRIVATE / (NAME + '.p12')
PASSWORD = PRIVATE / (NAME + '.password')
SDK = HOME / 'tizen-sdk'
CLI = SDK / 'tools/ide/bin/tizen'
PROFILES = HOME / 'tizen-sdk-data/profile/profiles.xml'
EVIDENCE = Path('/evidence')

assert Path('/.dockerenv').exists() and os.getuid() == 10000
assert Path.home() == HOME and os.environ['TIZEN_SDK'] == str(SDK)
assert not PRIVATE.is_symlink()
os.umask(0o077)
PRIVATE.mkdir(mode=0o700, exist_ok=True)
PRIVATE.chmod(0o700)
for path in [KEY, PASSWORD]:
    assert not path.is_symlink(), path
if KEY.exists() and not PASSWORD.exists():
    raise RuntimeError('Existing author key has no saved password; refusing to replace it.')
if not PASSWORD.exists():
    with PASSWORD.open('x') as out:
        out.write(secrets.token_urlsafe(48) + '\n')
PASSWORD.chmod(0o600)
password = PASSWORD.read_text().strip()
assert len(password) >= 48
redactions = [password]

# SDK secret-tool uses a real Secret Service. Keep its bus and encrypted
# keyring private and persistent across separate docker exec invocations.
assert os.environ['DBUS_SESSION_BUS_ADDRESS'] == 'unix:path=' + str(PRIVATE / 'dbus-session.sock')
for keyring_dir in ['runtime', 'keyring-data', 'keyring-control']:
    (PRIVATE / keyring_dir).mkdir(mode=0o700, exist_ok=True)
bus_probe = subprocess.run(['dbus-send', '--session', '--print-reply',
                            '--dest=org.freedesktop.DBus', '/org/freedesktop/DBus',
                            'org.freedesktop.DBus.ListNames'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if bus_probe.returncode:
    socket_path = PRIVATE / 'dbus-session.sock'
    if socket_path.is_socket():
        socket_path.unlink()
    subprocess.run(['dbus-daemon', '--session', '--fork',
                    '--address=' + os.environ['DBUS_SESSION_BUS_ADDRESS']], check=True)
master_file = PRIVATE / 'secret-service.password'
if not master_file.exists():
    with master_file.open('x') as out:
        out.write(secrets.token_urlsafe(48) + '\n')
master_file.chmod(0o600)
keyring = subprocess.run([str(ROOT / 'compat-keyring/usr/bin/gnome-keyring-daemon'),
                          '--daemonize', '--unlock', '--components=secrets',
                          '--control-directory=' + str(PRIVATE / 'keyring-control')],
                         input=master_file.read_bytes(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if keyring.returncode:
    raise RuntimeError('Private Secret Service failed; exit=' + str(keyring.returncode)
                       + ', stderrSha256=' + hashlib.sha256(keyring.stderr).hexdigest())

stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S')
log_path = EVIDENCE / (stamp + '-local-signing.log')
print('Local signing qualification started; sanitized log: ' + str(log_path), flush=True)
with log_path.open('x') as log:
    def run(command, input_data=None):
        def redact(value):
            for secret in redactions:
                value = value.replace(secret, '[REDACTED]')
            return value
        shown = [redact(arg) for arg in command]
        log.write('$ ' + shlex.join(shown) + '\n')
        result = subprocess.run(command, cwd=PRIVATE, input=input_data,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for output in [result.stdout, result.stderr]:
            log.write(redact(output.decode('utf-8', errors='replace')))
        log.write('\nexitCode=' + str(result.returncode) + '\n')
        log.flush()
        if result.returncode:
            raise RuntimeError('SDK signing command failed; see sanitized log ' + str(log_path))
        return result.stdout

    if not KEY.exists():
        run([str(CLI), 'certificate', '--alias', NAME, '--password', password,
             '--filename', NAME, '--', str(PRIVATE)])
    assert KEY.is_file(), 'Official certificate command did not create the expected P12.'
    KEY.chmod(0o600)

    # Read the public certificate only. The private key never leaves its P12.
    # SDK's real PKCS#12 uses RC2-40-CBC; OpenSSL 3 needs its legacy provider.
    public_pem = run(['openssl', 'pkcs12', '-legacy', '-in', str(KEY), '-passin',
                      'file:' + str(PASSWORD), '-clcerts', '-nokeys'])
    certificate_info = run(['openssl', 'x509', '-noout', '-fingerprint', '-sha256',
                            '-subject', '-issuer', '-dates'], public_pem).decode().strip()

    existing = []
    if PROFILES.exists():
        existing = [p for p in ET.parse(PROFILES).getroot().iter('profile')
                    if p.get('name') == NAME]
    if not existing:
        run([str(CLI), 'security-profiles', 'add', '--name', NAME, '--author',
             str(KEY), '--password', password, '--force'])
    profile = [p for p in ET.parse(PROFILES).getroot().iter('profile')
               if p.get('name') == NAME]
    assert len(profile) == 1
    authors = [p for p in profile[0].iter('profileitem') if p.get('distributor') == '0']
    assert len(authors) == 1 and authors[0].get('key') == str(KEY), authors
    password_reference = Path(authors[0].get('password', ''))
    assert password_reference == KEY.with_suffix('.pwd')
    secret_tool = str(SDK / 'tools/certificate-encryptor/secret-tool')
    lookup_command = [secret_tool, 'lookup', '--label=tizen-studio', 'keyfile',
                      str(password_reference), 'tool', 'certificate-manager']
    lookup = subprocess.run(lookup_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if lookup.returncode or lookup.stdout.decode().rstrip('\r\n') != password:
        run([secret_tool, 'store', '--label=tizen-studio', 'keyfile',
             str(password_reference), 'tool', 'certificate-manager', '--password', password])
        lookup = subprocess.run(lookup_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    password_matches = lookup.returncode == 0 and lookup.stdout.decode().rstrip('\r\n') == password
    log.write('SDK password lookup matches saved password: ' + str(password_matches) + '\n')
    assert password_matches, 'SDK password store did not return the real author password.'
    # Legacy CLI also ignored the failed store for its standard distributor.
    defaults = ET.parse(HOME / '.nuget/packages/tizen.net.sdk/1.1.7/build/Tizen.NET.Sdk.Common.targets')
    distributor_password = next(p.text for p in defaults.getroot().iter()
                                if p.tag.endswith('TizenDefaultDistributorPass') and p.text)
    assert '$(' not in distributor_password
    redactions.append(distributor_password)
    distributors = [p for p in profile[0].iter('profileitem') if p.get('distributor') == '1']
    assert len(distributors) == 1
    distributor = distributors[0]
    assert Path(distributor.get('key', '')) == SDK / 'tools/certificate-generator/certificates/distributor/tizen-distributor-signer.p12'
    distributor_lookup = [secret_tool, 'lookup', '--label=tizen-studio', 'keyfile',
                          distributor.get('password', ''), 'tool', 'certificate-manager']
    lookup = subprocess.run(distributor_lookup, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if lookup.returncode or lookup.stdout.decode().rstrip('\r\n') != distributor_password:
        run([secret_tool, 'store', '--label=tizen-studio', 'keyfile',
             distributor.get('password', ''), 'tool', 'certificate-manager',
             '--password', distributor_password])
        lookup = subprocess.run(distributor_lookup, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    distributor_matches = lookup.returncode == 0 and lookup.stdout.decode().rstrip('\r\n') == distributor_password
    log.write('SDK distributor lookup matches SDK default: ' + str(distributor_matches) + '\n')
    assert distributor_matches, 'SDK distributor password lookup did not match its default.'
    PROFILES.parent.chmod(0o700)
    PROFILES.chmod(0o600)
    assert stat.S_IMODE(KEY.stat().st_mode) == 0o600
    assert stat.S_IMODE(PASSWORD.stat().st_mode) == 0o600
    run([str(CLI), 'security-profiles', 'list'])

manifest = {
    'status': 'succeeded', 'qualificationOnly': True, 'profileName': NAME,
    'timeUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'authorCertificate': str(KEY), 'keyMode': '0600', 'privateDirectoryMode': '0700',
    'authorP12Sha256': hashlib.sha256(KEY.read_bytes()).hexdigest(),
    'publicCertificate': certificate_info,
    'profilesXml': str(PROFILES), 'log': str(log_path),
    'passwordLogged': False, 'deviceOrStoreCertificate': False,
    'secretService': 'private D-Bus with encrypted GNOME keyring',
    'sdkPasswordLookupMatchesSaved': password_matches,
    'sdkDistributorLookupMatchesDefault': distributor_matches,
}
(EVIDENCE / 'local-signing-profile.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('Local signing qualification succeeded: --security-profile ' + NAME)
