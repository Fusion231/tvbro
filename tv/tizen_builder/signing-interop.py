#!/usr/bin/env python3
"""Audit local profile passwords and the exact SDK BouncyCastle P12 loader."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path('/opt/tvbro-tizen-toolchain')
HOME = ROOT / 'home'
PRIVATE = HOME / 'private'
KEY = PRIVATE / 'TVBroLocalQualification.p12'
PASSWORD = PRIVATE / 'TVBroLocalQualification.password'
SDK = HOME / 'tizen-sdk'
assert Path('/.dockerenv').exists() and os.getuid() == 10000 and Path.home() == HOME
os.umask(0o077)
expected = PASSWORD.read_text().strip()
profile = next(p for p in ET.parse(HOME / 'tizen-sdk-data/profile/profiles.xml').getroot()
               if p.get('name') == 'TVBroLocalQualification')
author = next(p for p in profile if p.get('distributor') == '0')
stored = author.get('password', '')
lookup = subprocess.run([str(SDK / 'tools/certificate-encryptor/secret-tool'), 'lookup',
                         '--label=tizen-studio', 'keyfile', stored, 'tool', 'certificate-manager'],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
decoded = lookup.stdout.decode('utf-8', errors='replace').rstrip('\r\n')
report = {
    'savedPasswordLength': len(expected),
    'savedPasswordSha256': hashlib.sha256(expected.encode()).hexdigest(),
    'profilePasswordValueLength': len(stored),
    'profilePasswordIsFile': Path(stored).is_file() if stored else False,
    'profilePasswordLooksAbsolutePath': stored.startswith('/'),
    'profilePasswordHasPwdSuffix': stored.endswith('.pwd'),
    'profilePasswordEqualsSavedPassword': stored == expected,
    'secretToolExitCode': lookup.returncode,
    'secretToolRawOutputLength': len(lookup.stdout),
    'secretToolPasswordLength': len(decoded),
    'secretToolPasswordSha256': hashlib.sha256(decoded.encode()).hexdigest(),
    'secretToolPasswordMatchesSaved': decoded == expected,
    'secretToolOutputLooksError': bool(re.search(r'error|not found|fail|keyring', decoded, re.I)),
    'secretToolStderrSha256': hashlib.sha256(lookup.stderr).hexdigest(),
}
openssl = subprocess.run(['openssl', 'pkcs12', '-legacy', '-in', str(KEY),
                          '-passin', 'file:' + str(PASSWORD), '-info', '-noout'],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
report['opensslSavedPasswordExitCode'] = openssl.returncode

tool = PRIVATE / 'p12-interop'
tool.mkdir(mode=0o700, exist_ok=True)
assembly = HOME / '.nuget/packages/tizen.net.sdk/1.1.7/tools/netstandard1.6/BouncyCastle.Crypto.dll'
report['bouncyCastleDllSha256'] = hashlib.sha256(assembly.read_bytes()).hexdigest()
(tool / 'Interop.csproj').write_text('''<Project Sdk="Microsoft.NET.Sdk">
<PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework></PropertyGroup>
<ItemGroup><Reference Include="BouncyCastle.Crypto"><HintPath>''' + str(assembly) + '''</HintPath></Reference></ItemGroup>
</Project>\n''')
(tool / 'Program.cs').write_text('''using System;
using System.IO;
using Org.BouncyCastle.Pkcs;
try {
  using var input = File.OpenRead(args[0]);
  var store = new Pkcs12Store(input, File.ReadAllText(args[1]).TrimEnd('\\r','\\n').ToCharArray());
  int count = 0; foreach (string alias in store.Aliases) count++;
  Console.WriteLine("BouncyCastleAssembly=" + typeof(Pkcs12Store).Assembly.FullName);
  Console.WriteLine("PKCS12_LOAD_PASS aliases=" + count); return 0;
} catch (Exception error) {
  Console.WriteLine("PKCS12_LOAD_FAIL type=" + error.GetType().FullName); return 1;
}
''')
dotnet = str(ROOT / 'dotnet/dotnet')
build = subprocess.run([dotnet, 'build', str(tool / 'Interop.csproj'), '-o', str(tool / 'bin'),
                         '--ignore-failed-sources', '-v:q'],
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
(tool / 'build.log').write_bytes(build.stdout)
report['bouncyCastleProbeBuildExitCode'] = build.returncode
if build.returncode == 0:
    for label, value in [('saved', expected), ('sdkDecoded', decoded)]:
        candidate = tool / (label + '.password')
        candidate.write_text(value)
        candidate.chmod(0o600)
        check = subprocess.run([dotnet, str(tool / 'bin/Interop.dll'), str(KEY), str(candidate)],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        report[label + 'BouncyCastleExitCode'] = check.returncode
        report[label + 'BouncyCastleResult'] = check.stdout.decode().strip()
    distributor = next(p for p in profile if p.get('distributor') == '1')
    distributor_key = Path(distributor.get('key'))
    defaults = ET.parse(HOME / '.nuget/packages/tizen.net.sdk/1.1.7/build/Tizen.NET.Sdk.Common.targets')
    distributor_expected = next(p.text for p in defaults.getroot().iter()
                                if p.tag.endswith('TizenDefaultDistributorPass') and p.text)
    lookup = subprocess.run([str(SDK / 'tools/certificate-encryptor/secret-tool'), 'lookup',
                             '--label=tizen-studio', 'keyfile', distributor.get('password'),
                             'tool', 'certificate-manager'],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    distributor_decoded = lookup.stdout.decode().rstrip('\r\n')
    report['distributor'] = {
        'lookupExitCode': lookup.returncode,
        'savedLength': len(distributor_expected), 'decodedLength': len(distributor_decoded),
        'savedSha256': hashlib.sha256(distributor_expected.encode()).hexdigest(),
        'decodedSha256': hashlib.sha256(distributor_decoded.encode()).hexdigest(),
        'decodedMatchesSdkDefault': distributor_decoded == distributor_expected,
    }
    for label, value in [('saved', distributor_expected), ('sdkDecoded', distributor_decoded)]:
        candidate = tool / ('distributor-' + label + '.password')
        candidate.write_text(value)
        candidate.chmod(0o600)
        check = subprocess.run([dotnet, str(tool / 'bin/Interop.dll'), str(distributor_key), str(candidate)],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        report['distributor'][label + 'BouncyCastleExitCode'] = check.returncode
        report['distributor'][label + 'BouncyCastleResult'] = check.stdout.decode().strip()
report['timeUtc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
passed = (report.get('secretToolPasswordMatchesSaved') is True
          and report.get('secretToolExitCode') == 0
          and report.get('opensslSavedPasswordExitCode') == 0
          and report.get('savedBouncyCastleExitCode') == 0
          and report.get('sdkDecodedBouncyCastleExitCode') == 0
          and report.get('distributor', {}).get('decodedMatchesSdkDefault') is True
          and report.get('distributor', {}).get('lookupExitCode') == 0
          and report.get('distributor', {}).get('sdkDecodedBouncyCastleExitCode') == 0)
report['status'] = 'succeeded' if passed else 'failed'
evidence = Path('/evidence/signing-interop.json')
evidence.write_text(json.dumps(report, indent=2) + '\n')
evidence.with_name('signing-interop-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S') + '.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
raise SystemExit(0 if passed else 1)
