'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const vm = require('node:vm');
const {createRequire} = require('node:module');
const test = require('node:test');
const {repoRoot:owner, tvRoot} = require('../../paths.cjs');
const {build, transformHtml, validateServiceSyntax} = require('../tools/build.cjs');
const {verifyBuild, verifyIpk} = require('../tools/package-ipk.cjs');
const sharedRequire = createRequire(path.resolve(__dirname, '../../samsung_web/package.json'));
const acorn = sharedRequire('acorn');
const hash = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const hashFile = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');

test('LG build uses current shared UI/core/protocol sources and LG platform bindings with ES5 output', () => {
  const result = build();
  assert.equal(result.status, 'lg_webos_payload_staged');
  assert.equal(result.physicalTvTested, false);
  assert.match(result.target, /Chromium M38/);
  const html = fs.readFileSync(path.join(result.payload, 'index.html'), 'utf8');
  assert.match(html, /<video id="native-player"[^>]*preload="none"/);
  assert.doesNotMatch(html, /application\/avplayer|\$WEBAPIS|platform\/avplay/);
  assert.ok(html.indexOf('src="polyfills.js"') < html.indexOf('src="webOSTV.js"'));
  assert.ok(html.indexOf('src="webos-bootstrap.js"') < html.indexOf('src="platform.js"'));
  assert.ok(html.indexOf('src="platform.js"') < html.indexOf('src="app.js"'));
  assert.equal(fs.existsSync(path.join(result.payload, 'config.xml')), false);
  assert.equal(fs.existsSync(path.join(result.payload, 'platform/avplay.js')), false);
  const info = JSON.parse(fs.readFileSync(path.join(result.payload, 'appinfo.json'), 'utf8'));
  assert.equal(info.id, 'online.tvbro.webos');
  assert.equal(info.version, '1.0.0');
  assert.equal(info.icon, 'icon.png');
  assert.equal(info.largeIcon, 'largeIcon.png');
  for (const [file, size] of [['icon.png', 80], ['largeIcon.png', 130]]) {
    const png = fs.readFileSync(path.join(result.payload, file));
    assert.equal(png.toString('hex', 0, 8), '89504e470d0a1a0a');
    assert.equal(png.readUInt32BE(16), size, file + ' width');
    assert.equal(png.readUInt32BE(20), size, file + ' height');
    const relative = 'clients/tv/lg_webos/assets/' + file;
    assert.equal(result.inputHashes[relative], hashFile(path.join(owner, relative)));
    assert.equal(result.payloadHashes[file], hashFile(path.join(result.payload, file)));
  }
  assert.equal(info.disableBackHistoryAPI, true);
  assert.equal(info.resolution, '1280x720');
  assert.equal(result.serviceId, 'online.tvbro.webos.epg');
  assert.equal(result.serviceDir, path.join(tvRoot, 'lg_webos/epg_service'));
  assert.ok(result.serviceHashes['package.json']);
  assert.ok(result.serviceHashes['services.json']);
  assert.ok(result.serviceHashes['metadata_http.js']);
  for (const relative of ['clients/player/pubspec.yaml', 'clients/player/pubspec.lock',
    'clients/player/lib/sources/source.dart', 'clients/tv/paths.cjs']) {
    assert.equal(result.inputHashes[relative], hashFile(path.join(owner, relative)), relative);
  }
  for (const [relative, expected] of Object.entries(result.serviceHashes)) {
    assert.equal(result.inputHashes['clients/tv/lg_webos/epg_service/' + relative], expected);
    if (relative.endsWith('.js')) acorn.parse(fs.readFileSync(path.join(result.serviceDir, relative), 'utf8'), {ecmaVersion:5});
  }
  for (const name of ['ui/index.html', 'ui/styles.css', 'ui/app.js', 'ui/viewport.js', 'platform.js',
    'platform/user_state.js', 'platform/transport.js', 'platform/source_worker.js', 'platform/organization.js',
    'platform/backup.js', 'platform/library.js', 'platform/cloud.js']) {
    const relative = 'clients/tv/samsung_web/' + name;
    assert.equal(result.inputHashes[relative], hashFile(path.join(owner, relative)), relative + ' must use current shared source');
  }
  for (const name of ['player', 'secure_store', 'memory_policy', 'catalog_store', 'backup_files', 'epg_files']) {
    assert.ok(result.inputHashes['clients/tv/lg_webos/platform/' + name + '.js']);
    assert.equal(result.inputHashes['clients/tv/samsung_web/platform/' + name + '.js'], undefined);
  }
  const lgEpgFile = 'clients/tv/lg_webos/platform/epg_files.js';
  assert.equal(result.inputHashes[lgEpgFile], hashFile(path.join(owner, lgEpgFile)));
  assert.match(fs.readFileSync(path.join(result.payload, 'platform/epg_files.js'), 'utf8'),
    /luna:\/\/online\.tvbro\.webos\.epg\//);
  for (const relative of ['panel/src/pin.js', 'panel/src/crypto.js', 'panel/src/validate.js']) assert.ok(result.inputHashes[relative]);
  assert.equal(hashFile(path.join(result.payload, 'styles.css')), hashFile(path.join(tvRoot, 'samsung_web/ui/styles.css')));
  assert.equal(hashFile(result.canonicalReuseProof), result.canonicalReuseProofSha256);
  for (const relative of ['clients/tv/samsung_web/core_builder/web_bindings.dart.txt',
    'clients/tv/samsung_web/core_builder/metadata_bindings.dart.txt']) {
    assert.equal(result.inputHashes[relative], hashFile(path.join(owner, relative)), relative + ' must match the compiled core proof');
  }
  for (const relative of Object.keys(result.payloadHashes).filter((file) => file.endsWith('.js'))) {
    acorn.parse(fs.readFileSync(path.join(result.payload, relative), 'utf8'), {ecmaVersion:5});
  }
  verifyBuild(path.join(path.dirname(result.payload), 'latest-build.json'));
});

test('staged runtime and worker use packaged polyfills when native built-ins are absent', async (t) => {
  const {payload} = JSON.parse(fs.readFileSync(path.join(tvRoot, 'output/lg-webos/latest-build.json'), 'utf8'));
  function context() {
    const environment = {console, setTimeout, clearTimeout, crypto: crypto.webcrypto};
    environment.self = environment;
    vm.createContext(environment);
    // Exercise fallback code in Node; this does not emulate a TV's engine or APIs.
    vm.runInContext('Promise=Map=Set=WeakMap=WeakSet=Reflect=URL=URLSearchParams=undefined;' +
      'delete Object.assign;delete Object.entries;delete Object.values;delete Array.from;' +
      'delete Array.prototype.find;delete Array.prototype.includes;' +
      'delete String.prototype.includes;delete String.prototype.startsWith;' +
      'delete String.prototype.endsWith;delete String.prototype.repeat;' +
      'delete Number.isFinite;delete Number.isInteger;delete Number.isSafeInteger;', environment);
    return environment;
  }
  function load(environment, relative) {
    vm.runInContext(fs.readFileSync(path.join(payload, relative), 'utf8'), environment,
      {filename:relative, timeout:10000});
  }
  const window = context();
  window.window = window;
  window.navigator = {userAgent:'Mozilla/5.0 (Web0S; Linux/SmartTV) Chrome/38.0.2125.122 WebAppManager'};
  let backCalls = 0;
  window.PalmSystem = {platformBack() { backCalls++; }};
  for (const file of ['polyfills.js', 'webOSTV.js', 'canonical-core.js', 'panel-validation.js']) load(window, file);
  assert.equal(window.webOS.platform.tv, true);
  window.webOS.platformBack();
  assert.equal(backCalls, 1);
  assert.equal(vm.runInContext('new URL("../movie.m3u8?u=test#abc","https://provider.test/live/a").href', window),
    'https://provider.test/movie.m3u8?u=test#abc');
  assert.equal(vm.runInContext('new URLSearchParams("x=a%20b&x=2").getAll("x").join(",")', window), 'a b,2');
  assert.equal(vm.runInContext('Object.assign({}, {value:7}).value', window), 7);
  const parsed = JSON.parse(window.TVBroCanonical.parseM3u('#EXTM3U\n#EXTINF:-1,One\nhttps://provider.test/one.m3u8\n'));
  assert.equal(parsed.channels.length, 1);
  const stream = JSON.parse(await window.TVBroCanonical.resolveXtream(
    '{"fields":{"host":"provider.test","username":"user name","password":"p&x"}}',
    '{"id":"9","name":"One","extra":{"streamId":"10"}}'));
  assert.equal(stream.url, 'http://provider.test/live/user%20name/p%26x/10.ts');

  const worker = context(), imports = [];
  let resolveReady, rejectReady;
  const ready = new Promise((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
  const timer = setTimeout(() => rejectReady(new Error('Staged source worker did not become ready.')), 10000);
  t.after(() => clearTimeout(timer));
  worker.importScripts = (...files) => {
    imports.push(...files);
    for (const file of files) load(worker, path.posix.join('platform', file));
  };
  worker.postMessage = (message) => {
    if (message.type === 'ready') resolveReady();
    else if (message.type === 'fatal') rejectReady(new Error(message.error.message));
  };
  load(worker, 'platform/source_worker.js');
  await ready;
  assert.deepEqual(imports, ['../polyfills.js', '../pako-inflate.js', 'streaming_gzip.js', '../canonical-core.js']);
  assert.equal(typeof worker.onmessage, 'function');
});

test('HTML generation rejects missing or duplicated platform bindings', () => {
  const original = fs.readFileSync(path.join(tvRoot, 'samsung_web/ui/index.html'), 'utf8');
  assert.throws(() => transformHtml(original.replace('application/avplayer', 'application/other')), /platform binding changed/);
  assert.throws(() => transformHtml(original + '<script src="platform.js"></script>'), /platform binding changed/);
});

test('LG service build rejects JavaScript newer than the webOS 4 Node runtime', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'tvbro-lg-service-syntax-'));
  t.after(() => fs.rmSync(directory, {recursive:true, force:true}));
  fs.writeFileSync(path.join(directory, 'service.js'), 'const unsupported = true;');
  assert.throws(() => validateServiceSyntax(directory), SyntaxError);
});

test('packaging integrity gate rejects extra payload files and changed build metadata', (t) => {
  const output = path.join(tvRoot, 'output/lg-webos');
  const original = JSON.parse(fs.readFileSync(path.join(output, 'latest-build.json'), 'utf8'));
  const payload = fs.mkdtempSync(path.join(output, 'payload-integrity-'));
  const metadata = path.join(output, path.basename(payload) + '.json');
  t.after(() => {fs.rmSync(payload, {recursive:true, force:true}); fs.rmSync(metadata, {force:true});});
  fs.cpSync(original.payload, payload, {recursive:true});
  const changed = {...original, payload};
  fs.writeFileSync(metadata, JSON.stringify(changed));
  verifyBuild(metadata);
  fs.writeFileSync(path.join(payload, 'unqualified.js'), 'window.unqualified=true;');
  assert.throws(() => verifyBuild(metadata), /Payload differs/);
  fs.rmSync(path.join(payload, 'unqualified.js'));
  changed.inputHashes['clients/tv/lg_webos/tools/build.cjs'] = '0'.repeat(64);
  fs.writeFileSync(metadata, JSON.stringify(changed));
  assert.throws(() => verifyBuild(metadata), /Build input changed/);
  assert.throws(() => verifyBuild(metadata, '0'.repeat(64)), /manifest changed/);
});

function tarArchive(files) {
  const blocks = [];
  for (const [name, value] of Object.entries(files)) {
    const data = Buffer.from(value), header = Buffer.alloc(512);
    header.write(name, 0, 100, 'utf8');
    header.write('0000644\0', 100, 8, 'ascii');
    header.write('0000000\0', 108, 8, 'ascii');
    header.write('0000000\0', 116, 8, 'ascii');
    header.write(data.length.toString(8).padStart(11, '0') + '\0', 124, 12, 'ascii');
    header.write('00000000000\0', 136, 12, 'ascii');
    header.fill(32, 148, 156);
    header.write('0', 156, 1, 'ascii');
    header.write('ustar\0', 257, 6, 'ascii');
    header.write('00', 263, 2, 'ascii');
    const checksum = header.reduce((sum, byte) => sum + byte, 0);
    header.write(checksum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'ascii');
    blocks.push(header, data);
    if (data.length % 512) blocks.push(Buffer.alloc(512 - data.length % 512));
  }
  blocks.push(Buffer.alloc(1024));
  return Buffer.concat(blocks);
}

function arArchive(members) {
  const blocks = [Buffer.from('!<arch>\n')];
  for (const [name, value] of Object.entries(members)) {
    const data = Buffer.from(value), header = Buffer.alloc(60, 32);
    header.write(name, 0, 16, 'ascii');
    header.write('0', 16, 12, 'ascii');
    header.write('0', 28, 6, 'ascii');
    header.write('0', 34, 6, 'ascii');
    header.write('100644', 40, 8, 'ascii');
    header.write(String(data.length).padEnd(10), 48, 10, 'ascii');
    header.write('`\n', 58, 2, 'ascii');
    blocks.push(header, data);
    if (data.length % 2) blocks.push(Buffer.from('\n'));
  }
  return Buffer.concat(blocks);
}

function ipkFixture(t, mutation) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'tvbro-lg-ipk-'));
  t.after(() => fs.rmSync(root, {recursive:true, force:true}));
  const payload = path.join(root, 'payload');
  fs.mkdirSync(payload);
  const appId = 'online.tvbro.webos', serviceId = appId + '.epg';
  const app = {
    'appinfo.json': Buffer.from(JSON.stringify({id:appId, version:'0.1.31'})),
    'index.html': Buffer.from('<html>TVBro</html>')
  };
  const service = {
    'package.json': Buffer.from(JSON.stringify({name:serviceId, main:'epg_service.js'})),
    'services.json': Buffer.from(JSON.stringify({services:[{name:serviceId, commands:[{name:'available', public:true}]}]})),
    'epg_service.js': Buffer.from('module.exports = true;')
  };
  for (const [name, data] of Object.entries(app)) fs.writeFileSync(path.join(payload, name), data);
  const servicePath = mutation === 'wrong-id' ? serviceId + '.other' : serviceId;
  const packagedService = {...service};
  if (mutation === 'changed') packagedService['epg_service.js'] = Buffer.from('module.exports = false;');
  if (mutation === 'extra') packagedService['unexpected.js'] = Buffer.from('extra');
  if (mutation === 'missing') delete packagedService['epg_service.js'];
  const content = {};
  for (const [name, data] of Object.entries(app)) content['usr/palm/applications/' + appId + '/' + name] = data;
  for (const [name, data] of Object.entries(packagedService)) content['usr/palm/services/' + servicePath + '/' + name] = data;
  content['usr/palm/packages/' + appId + '/packageinfo.json'] = Buffer.from(JSON.stringify({
    id:appId, app:appId, version:'1.0.0', services:[serviceId]
  }));
  const ipk = path.join(root, 'fixture.ipk');
  fs.writeFileSync(ipk, arArchive({
    'debian-binary':'2.0\n',
    'control.tar.gz':zlib.gzipSync(tarArchive({control:'Package: online.tvbro.webos\n'})),
    'data.tar.gz':zlib.gzipSync(tarArchive(content))
  }));
  const payloadHashes = Object.fromEntries(Object.entries(app).map(([name, data]) => [name, hash(data)]));
  const serviceHashes = Object.fromEntries(Object.entries(service).map(([name, data]) => [name, hash(data)]));
  return {ipk, build:{payload, payloadHashes, serviceId, serviceHashes}};
}

test('IPK verification accepts the exact captured web app and service files', (t) => {
  const fixture = ipkFixture(t);
  const result = verifyIpk(fixture.ipk, fixture.build);
  assert.equal(result.applicationId, 'online.tvbro.webos');
  assert.equal(result.serviceId, 'online.tvbro.webos.epg');
  assert.equal(result.serviceFiles, 3);
});

test('IPK verification rejects changed, extra, missing, or wrongly named service files', (t) => {
  for (const mutation of ['changed', 'extra', 'missing', 'wrong-id']) {
    const fixture = ipkFixture(t, mutation);
    assert.throws(() => verifyIpk(fixture.ipk, fixture.build),
      mutation === 'wrong-id' ? /Unexpected service ID/ : /Archived service files differ/, mutation);
  }
});
