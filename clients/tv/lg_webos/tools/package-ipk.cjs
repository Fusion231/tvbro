'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const {spawnSync} = require('node:child_process');
const {repoRoot, tvRoot} = require('../../paths.cjs');
const {validateServiceSyntax} = require('./build.cjs');
const output = path.join(tvRoot, 'output/lg-webos');
const project = path.resolve(__dirname, '..');
const expectedServiceId = 'online.tvbro.webos.epg';
const hash = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const hashFile = (file) => hash(fs.readFileSync(file));

function files(root, base = root, result = {}) {
  for (const entry of fs.readdirSync(root, {withFileTypes:true})) {
    const absolute = path.join(root, entry.name);
    if (entry.isSymbolicLink()) throw new Error('Refuse symlinks in the webOS payload.');
    if (entry.isDirectory()) files(absolute, base, result);
    else if (entry.isFile()) result[path.relative(base, absolute).split(path.sep).join('/')] = hashFile(absolute);
    else throw new Error('Unexpected payload entry.');
  }
  return result;
}

function verifyBuild(manifestFile, expectedSha) {
  const raw = fs.readFileSync(manifestFile);
  if (expectedSha && hash(raw) !== expectedSha) throw new Error('Build manifest changed before packaging.');
  const build = JSON.parse(raw);
  if (build.status !== 'lg_webos_payload_staged' || !build.javascriptEs5Syntax || !build.legacyCssGate) {
    throw new Error('Require a staged LG webOS legacy payload.');
  }
  if (path.dirname(path.resolve(build.payload)) !== output || !path.basename(build.payload).startsWith('payload-')) {
    throw new Error('Payload must belong to the LG generated output directory.');
  }
  assert.deepEqual(files(build.payload), build.payloadHashes, 'Payload differs from its captured hashes.');
  if (build.serviceId !== expectedServiceId || typeof build.serviceDir !== 'string' ||
      path.resolve(build.serviceDir) !== path.join(project, 'epg_service') ||
      path.resolve(build.serviceDir) !== build.serviceDir) {
    throw new Error('Build manifest does not identify the qualified LG service source.');
  }
  if (fs.lstatSync(build.serviceDir).isSymbolicLink()) throw new Error('Refuse a symlinked LG service source.');
  const appInfo = JSON.parse(fs.readFileSync(path.join(build.payload, 'appinfo.json'), 'utf8'));
  verifyServiceMetadata(build.serviceDir, build.serviceId, appInfo);
  assert.deepEqual(files(build.serviceDir), build.serviceHashes, 'Service source differs from its captured hashes.');
  validateServiceSyntax(build.serviceDir, build.serviceHashes);
  for (const [relative, expected] of Object.entries(build.inputHashes)) {
    if (hashFile(path.resolve(repoRoot, relative)) !== expected) throw new Error('Build input changed: ' + relative);
  }
  if (hashFile(build.canonicalReuseProof) !== build.canonicalReuseProofSha256) throw new Error('Canonical proof changed.');
  const proof = JSON.parse(fs.readFileSync(build.canonicalReuseProof, 'utf8'));
  if (proof.status !== 'canonical_core_compiled' || proof.originalSourcesUnchanged !== true ||
      hashFile(path.join(path.dirname(build.canonicalReuseProof), 'core.js')) !== proof.jsSha256) {
    throw new Error('Canonical core differs from its reuse proof.');
  }
  return {build, manifestSha256:hash(raw)};
}

function verifyServiceMetadata(serviceDir, serviceId, appInfo) {
  if (!appInfo || appInfo.id !== 'online.tvbro.webos' || serviceId !== expectedServiceId ||
      serviceId.indexOf(appInfo.id + '.') !== 0) throw new Error('Invalid LG service ID.');
  const packageInfo = JSON.parse(fs.readFileSync(path.join(serviceDir, 'package.json'), 'utf8'));
  const servicesInfo = JSON.parse(fs.readFileSync(path.join(serviceDir, 'services.json'), 'utf8'));
  if (packageInfo.name !== serviceId || (servicesInfo.id && servicesInfo.id !== serviceId) ||
      !Array.isArray(servicesInfo.services) || servicesInfo.services.length !== 1 ||
      servicesInfo.services[0].name !== serviceId) throw new Error('LG service manifests have the wrong service ID.');
  const mainFile = typeof packageInfo.main === 'string' ? path.resolve(serviceDir, packageInfo.main) : '';
  if (!mainFile || !mainFile.startsWith(path.resolve(serviceDir) + path.sep) ||
      !fs.existsSync(mainFile) || !fs.statSync(mainFile).isFile()) {
    throw new Error('LG service package.json has an invalid main file.');
  }
}

function archiveMembers(bytes) {
  if (bytes.subarray(0, 8).toString() !== '!<arch>\n') throw new Error('LG package must be an ar IPK archive.');
  const result = {};
  let offset = 8;
  while (offset < bytes.length) {
    const header = bytes.subarray(offset, offset + 60);
    if (header.length !== 60 || header.subarray(58).toString() !== '`\n') throw new Error('Invalid IPK member header.');
    const name = header.subarray(0, 16).toString().trim().replace(/\/$/, '');
    const size = Number(header.subarray(48, 58).toString().trim());
    if (!Number.isSafeInteger(size) || size < 0 || offset + 60 + size > bytes.length || result[name]) throw new Error('Invalid IPK member size or duplicate.');
    result[name] = bytes.subarray(offset + 60, offset + 60 + size);
    offset += 60 + size + size % 2;
  }
  return result;
}

function tarFiles(bytes) {
  const result = {};
  for (let offset = 0; offset + 512 <= bytes.length;) {
    const header = bytes.subarray(offset, offset + 512);
    if (header.every((value) => value === 0)) break;
    const string = (start, length) => header.subarray(start, start + length).toString().replace(/\0.*$/, '');
    const prefix = string(345, 155);
    const name = ((prefix ? prefix + '/' : '') + string(0, 100)).replace(/^\.\//, '');
    const size = parseInt(string(124, 12).trim() || '0', 8);
    const type = string(156, 1);
    if (!Number.isSafeInteger(size) || size < 0 || offset + 512 + size > bytes.length) throw new Error('Invalid IPK tar length.');
    if (type === '' || type === '0') {
      if (result[name]) throw new Error('Duplicate package file: ' + name);
      result[name] = bytes.subarray(offset + 512, offset + 512 + size);
    } else if (type !== '5') throw new Error('Unexpected IPK tar entry type: ' + type);
    offset += 512 + Math.ceil(size / 512) * 512;
  }
  return result;
}

function verifyIpk(ipk, build) {
  const members = archiveMembers(fs.readFileSync(ipk));
  if (!members['debian-binary'] || members['debian-binary'].toString().trim() !== '2.0' || !members['control.tar.gz'] || !members['data.tar.gz']) {
    throw new Error('Incomplete LG IPK package.');
  }
  const info = JSON.parse(fs.readFileSync(path.join(build.payload, 'appinfo.json'), 'utf8'));
  if (info.id !== 'online.tvbro.webos' || build.serviceId !== expectedServiceId || !build.serviceHashes) {
    throw new Error('IPK build metadata does not identify the qualified LG service.');
  }
  const prefix = 'usr/palm/applications/' + info.id + '/';
  const servicePrefix = 'usr/palm/services/' + build.serviceId + '/';
  const packageInfoPath = 'usr/palm/packages/' + info.id + '/packageinfo.json';
  const content = tarFiles(zlib.gunzipSync(members['data.tar.gz']));
  const packaged = {}, packagedService = {};
  let packageInfo = null;
  for (const [name, bytes] of Object.entries(content)) {
    if (name.startsWith(prefix)) packaged[name.slice(prefix.length)] = hash(bytes);
    else if (name.startsWith(servicePrefix)) packagedService[name.slice(servicePrefix.length)] = hash(bytes);
    else if (name.startsWith('usr/palm/services/')) throw new Error('Unexpected service ID in package: ' + name);
    else if (name === packageInfoPath) packageInfo = JSON.parse(bytes.toString('utf8'));
    else throw new Error('Unexpected package file: ' + name);
  }
  assert.deepEqual(packaged, build.payloadHashes, 'Archived app files differ from the qualified payload.');
  assert.deepEqual(packagedService, build.serviceHashes, 'Archived service files differ from the qualified service source.');
  if (!packageInfo || packageInfo.id !== info.id || packageInfo.app !== info.id || !Array.isArray(packageInfo.services) ||
      packageInfo.services.length !== 1 || packageInfo.services[0] !== build.serviceId) {
    throw new Error('IPK package metadata does not register the qualified LG service.');
  }
  return {applicationId:info.id, version:info.version, packagedFiles:Object.keys(packaged).length,
    serviceId:build.serviceId, serviceFiles:Object.keys(packagedService).length};
}

function packageBuild(options = {}) {
  const manifestFile = path.join(output, 'latest-build.json');
  const baseline = verifyBuild(manifestFile, options.expectedManifestSha256);
  const cli = options.cli || process.env.TVBRO_WEBOS_PACKAGE_CLI || path.join(path.dirname(repoRoot),
    'evaluation/tooling/webos-cli/node_modules/@webos-tools/cli/bin/ares-package.js');
  if (!fs.existsSync(cli)) throw new Error('Set TVBRO_WEBOS_PACKAGE_CLI to the installed official ares-package.js.');
  const destination = path.join(output, 'package-' + new Date().toISOString().replace(/[-:.]/g, ''));
  fs.mkdirSync(destination, {recursive:true});
  const result = spawnSync(process.execPath, [cli, '--no-minify', '--outdir', destination,
    baseline.build.payload, baseline.build.serviceDir],
    {encoding:'utf8', timeout:120000, maxBuffer:4 * 1024 * 1024,
      env:{...process.env, APPDATA:path.join(output, 'packager-data')}});
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error('Official LG packager failed with exit ' + result.status);
  verifyBuild(manifestFile, baseline.manifestSha256);
  const packages = fs.readdirSync(destination).filter((name) => name.endsWith('.ipk'));
  if (packages.length !== 1) throw new Error('Expected one official LG IPK output.');
  const ipk = path.join(destination, packages[0]);
  const verified = verifyIpk(ipk, baseline.build);
  const evidence = {
    status:'lg_webos_ipk_packaged', ipk, ipkSha256:hashFile(ipk),
    buildManifest:manifestFile, buildManifestSha256:baseline.manifestSha256,
    packager:cli, packagerSha256:hashFile(cli), noMinify:true,
    payloadHashes:baseline.build.payloadHashes, serviceHashes:baseline.build.serviceHashes, ...verified,
    physicalTvTested:false, installedOnTv:false, storeCertified:false
  };
  fs.writeFileSync(path.join(output, 'latest-package.json'), JSON.stringify(evidence, null, 2) + '\n');
  console.log(JSON.stringify({status:evidence.status, ipk, ipkSha256:evidence.ipkSha256}));
  return evidence;
}

module.exports = {verifyBuild, verifyIpk, packageBuild};
if (require.main === module) {
  const args = process.argv.slice(2);
  if (args.length && (args.length !== 2 || args[0] !== '--expected-manifest-sha' || !/^[a-f0-9]{64}$/.test(args[1]))) {
    throw new Error('Usage: node tools/package-ipk.cjs [--expected-manifest-sha <sha256>]');
  }
  packageBuild({expectedManifestSha256:args[1]});
}
