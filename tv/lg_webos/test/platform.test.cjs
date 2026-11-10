'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const createAdapters = require('../platform.js').create;
const createPlatform = require('../../samsung_web/platform.js');

function boundary() {
  const calls = [], state = {};
  let resolveStorage, rejectStorage, libraryOptions;
  const initialized = new Promise((resolve, reject) => { resolveStorage = resolve; rejectStorage = reject; });
  const store = { initialize: () => initialized };
  const env = {
    URL, setTimeout, clearTimeout, close: () => calls.push('close'),
    TVBroWebOSSecureStore: { create: () => store },
    TVBroWebOSCatalogStore: { create(options) { assert.equal(options.secureStore, store); return {}; } },
    TVBroWebOSBackupFiles: { create: () => ({ capabilities: () => ({ import: false, export: false }) }) },
    TVBroWebOSMemoryPolicy: {}, TVBroCanonical: {}, TVBroPanelValidation: { friendlyError: e => e.message },
    TVBroWebOSEpgFiles: { create: () => ({ available: () => false }) },
    TVBroSamsungUserState: { create(options) { assert.equal(options.store, store); calls.push('read-storage'); return {}; } },
    TVBroSamsungTransport: { create: () => ({ checkStream: () => Promise.resolve() }) },
    TVBroSamsungSourceWorker: { create: () => ({ createSource() {}, verifyPin() {}, hashPin() {} }) },
    TVBroLgWebosPlayer: { create: () => ({ onState() {}, getState: () => state, stop: () => Promise.resolve() }) },
    TVBroSamsungCloud: { create(options) { assert.equal(options.deviceLabel, 'LG TV'); return {}; } },
    TVBroSamsungLibrary: { create(options) { libraryOptions=options; calls.push('library'); assert.equal(options.canImportBackup, false);
      assert.equal(options.canExportBackup, false); return {getState: () => state,
        query: name => { calls.push(name); return Promise.resolve(); }}; } }
  };
  return { env, store, calls, resolveStorage, rejectStorage, get libraryOptions() { return libraryOptions; } };
}

test('webOS waits for protected hydration before shared library reads and keeps LG bindings', async () => {
  const b = boundary();
  b.env.window = b.env; b.env.Promise = Promise;
  b.env.TVBroPlatformAdapters = createAdapters(b.env);
  assert.equal(b.env.TVBroSamsungEpgFiles, b.env.TVBroWebOSEpgFiles);
  vm.runInNewContext(fs.readFileSync(path.resolve(__dirname, '../../samsung_web/platform.js'), 'utf8'), b.env);
  await Promise.resolve();
  assert.deepEqual(b.calls, []);
  b.resolveStorage();
  const platform = await b.env.TVBroPlatformReady;
  assert.equal(platform, b.env.TVBroSamsungPlatform);
  assert.deepEqual(b.calls, ['read-storage', 'library']);
  assert.equal(b.env.TVBroSamsungMemoryPolicy, b.env.TVBroWebOSMemoryPolicy);
  assert.equal(b.libraryOptions.requiresHttpsProvider,false);
  assert.equal(b.env.TVBroPlatformAdapters.normalizeKey(461), 10009);
  for (const code of [13, 37, 38, 39, 40, 415, 413, 19, 33, 34, 48, 8]) assert.equal(b.env.TVBroPlatformAdapters.normalizeKey(code), code);
  await platform.exit();
  assert.deepEqual(b.calls.slice(-3), ['cache.flush', 'playback.stop', 'close']);
});

test('failed storage initialization never creates a new empty profile/library', async () => {
  const b = boundary(); b.env.window = b.env; b.env.Promise = Promise;
  b.env.TVBroPlatformAdapters = createAdapters(b.env);
  vm.runInNewContext(fs.readFileSync(path.resolve(__dirname, '../../samsung_web/platform.js'), 'utf8'), b.env);
  b.rejectStorage(new Error('locked'));
  await assert.rejects(b.env.TVBroPlatformReady, /locked/);
  assert.equal(b.env.TVBroSamsungPlatform, undefined);
  assert.deepEqual(b.calls, []);
});

test('shared default Samsung creation still starts synchronously without LG readiness', () => {
  const b = boundary(); b.env.window = b.env;
  b.env.TVBroSamsungSecureStore = b.env.TVBroWebOSSecureStore;
  b.env.TVBroSamsungAvplay = b.env.TVBroLgWebosPlayer;
  b.env.TVBroSamsungCloud = null;
  vm.runInNewContext(fs.readFileSync(path.resolve(__dirname, '../../samsung_web/platform.js'), 'utf8'), b.env);
  assert.equal(typeof b.env.TVBroSamsungPlatform.query, 'function');
  assert.equal(b.env.TVBroPlatformReady, undefined);
  assert.deepEqual(b.calls, ['read-storage', 'library']);
});

test('LG Back uses system behavior; trailers validate URLs and bound failed service calls', async () => {
  const b = boundary(); let launch;
  b.env.webOS = {platform: {tv: true}, platformBack: () => b.calls.push('platformBack'),
    service: {request(uri, args) { launch = {uri, args}; args.onSuccess(); }} };
  const adapters = createAdapters(b.env); b.resolveStorage(); await adapters.ready;
  adapters.exit(); assert.equal(b.calls.pop(), 'platformBack');
  await adapters.openTrailer('https://www.youtube.com/watch?v=example');
  assert.equal(launch.uri, 'luna://com.webos.applicationManager');
  assert.equal(launch.args.parameters.id, 'com.webos.app.browser');
  assert.equal(launch.args.parameters.params.target, 'https://www.youtube.com/watch?v=example');
  for (const url of ['javascript:alert(1)', 'http://example.org/video', 'https://secret:password@example.org/video']) {
    await assert.rejects(adapters.openTrailer(url), {code: 'trailer_unavailable'});
  }
  b.env.webOS.service.request = (uri, args) => args.onFailure({errorText:'private details'});
  await assert.rejects(adapters.openTrailer('https://example.org/video'), {message:'Could not open the trailer or YouTube.'});
});

test('webOS unavailable native trailer launch is not advertised', async () => {
  const b = boundary(), adapters = createAdapters(b.env); b.resolveStorage(); await adapters.ready;
  assert.equal(adapters.openTrailer, undefined);
});
