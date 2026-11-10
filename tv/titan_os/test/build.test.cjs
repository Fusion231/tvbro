'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const vm = require('node:vm');
const {createRequire} = require('node:module');
const test = require('node:test');
const {build, transformHtml} = require('../tools/build.cjs');
const sharedRequire = createRequire(path.resolve(__dirname, '../../samsung_web/package.json'));
const acorn = sharedRequire('acorn');
const owner = path.resolve(__dirname, '../../..');
const hashFile = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');

test('Titan stages current Samsung UI/core with portable HTML5 bindings and no vendor SDK', () => {
  const result = build();
  assert.equal(result.status, 'titan_os_payload_staged');
  assert.equal(result.hostedHtml5, true);
  assert.equal(result.httpsRequired, true);
  assert.equal(result.physicalTvTested, false);
  assert.equal(result.storeCertified, false);
  assert.equal(result.titanPublished, false);
  const html = fs.readFileSync(path.join(result.payload, 'index.html'), 'utf8');
  assert.match(html, /<video id="native-player"[^>]*playsinline/);
  assert.doesNotMatch(html, /application\/avplayer|\$WEBAPIS|platform\/avplay|webOSTV\.js/);
  assert.ok(html.indexOf('src="platform/html5-player.js"') < html.indexOf('src="platform/player.js"'));
  assert.ok(html.indexOf('src="titan-bootstrap.js"') < html.indexOf('src="platform.js"'));
  assert.ok(html.indexOf('src="platform.js"') < html.indexOf('src="app.js"'));
  for (const relative of ['config.xml', 'appinfo.json', 'platform/avplay.js', 'webOSTV.js']) {
    assert.equal(fs.existsSync(path.join(result.payload, relative)), false, relative);
  }
  for (const name of ['ui/index.html', 'ui/styles.css', 'ui/app.js', 'ui/viewport.js', 'platform.js',
    'platform/user_state.js', 'platform/transport.js', 'platform/source_worker.js', 'platform/organization.js',
    'platform/backup.js', 'platform/library.js', 'platform/cloud.js']) {
    const relative = 'tv/samsung_web/' + name;
    assert.equal(result.inputHashes[relative], hashFile(path.join(owner, relative)), relative);
  }
  for (const name of ['player', 'secure_store', 'memory_policy', 'catalog_store', 'backup_files']) {
    assert.ok(result.inputHashes['tv/lg_webos/platform/' + name + '.js']);
  }
  for (const relative of ['panel/src/pin.js', 'panel/src/crypto.js', 'panel/src/validate.js']) assert.ok(result.inputHashes[relative]);
  assert.equal(hashFile(path.join(result.payload, 'styles.css')), hashFile(path.join(owner, 'tv/samsung_web/ui/styles.css')));
  assert.equal(hashFile(result.canonicalReuseProof), result.canonicalReuseProofSha256);
  for (const [relative, expected] of Object.entries(result.payloadHashes)) {
    assert.equal(hashFile(path.join(result.payload, relative)), expected, relative);
    if (relative.endsWith('.js')) acorn.parse(fs.readFileSync(path.join(result.payload, relative), 'utf8'), {ecmaVersion:5});
  }
  const hosting = JSON.parse(fs.readFileSync(path.join(result.payload, 'hosting.json'), 'utf8'));
  assert.equal(hosting.delivery, 'hosted-html5');
  assert.equal(hosting.entryPoint, 'index.html');
});

test('hosted canonical core and source worker use the same original parsers without a TV SDK', async (t) => {
  const {payload} = JSON.parse(fs.readFileSync(path.join(owner, 'tv/output/titan-os/latest-build.json'), 'utf8'));
  function context() {
    const environment = {console, setTimeout, clearTimeout, crypto:crypto.webcrypto};
    environment.self = environment;
    vm.createContext(environment);
    return environment;
  }
  function load(environment, relative) {
    vm.runInContext(fs.readFileSync(path.join(payload, relative), 'utf8'), environment, {filename:relative, timeout:10000});
  }
  const window = context();
  window.window = window;
  for (const relative of ['polyfills.js', 'canonical-core.js', 'panel-validation.js', 'platform/html5-player.js', 'platform/player.js']) load(window, relative);
  assert.equal(typeof window.TVBroTitanPlayer.create, 'function');
  const parsed = JSON.parse(window.TVBroCanonical.parseM3u('#EXTM3U\n#EXTINF:-1,One\nhttps://provider.test/one.m3u8\n'));
  assert.equal(parsed.channels.length, 1);
  const stream = JSON.parse(await window.TVBroCanonical.resolveXtream(
    '{"fields":{"host":"provider.test","username":"user name","password":"p&x"}}',
    '{"id":"9","name":"One","extra":{"streamId":"10"}}'));
  assert.equal(stream.url, 'http://provider.test/live/user%20name/p%26x/10.ts');
  const worker = context(), imports = [];
  let ready, failed;
  const completion = new Promise((resolve, reject) => { ready = resolve; failed = reject; });
  const timeout = setTimeout(() => failed(new Error('Staged source worker did not become ready.')), 10000);
  t.after(() => clearTimeout(timeout));
  worker.importScripts = (...files) => {
    imports.push(...files);
    for (const file of files) load(worker, path.posix.join('platform', file));
  };
  worker.postMessage = (message) => {
    if (message.type === 'ready') ready();
    else if (message.type === 'fatal') failed(new Error(message.error.message));
  };
  load(worker, 'platform/source_worker.js');
  await completion;
  assert.deepEqual(imports, ['../polyfills.js', '../pako-inflate.js', 'streaming_gzip.js', '../canonical-core.js']);
  assert.equal(typeof worker.onmessage, 'function');
});

test('Titan HTML binding fails when the shared source changes instead of packaging a mixed platform', () => {
  const html = fs.readFileSync(path.join(owner, 'tv/samsung_web/ui/index.html'), 'utf8');
  assert.throws(() => transformHtml(html.replace('application/avplayer', 'application/other')), /platform binding changed/);
  assert.throws(() => transformHtml(html + '<script src="platform.js"></script>'), /platform binding changed/);
});
