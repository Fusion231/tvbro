'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const createAdapters = require('../platform.js').create;
const sharedSource = fs.readFileSync(path.resolve(__dirname, '../../samsung_web/platform.js'), 'utf8');

function boundary() {
  const calls = [], state = {}, events = {};
  let resolveStorage, rejectStorage, libraryOptions;
  const initialized = new Promise((resolve, reject) => { resolveStorage = resolve; rejectStorage = reject; });
  const store = { initialize: () => initialized };
  const env = {
    Promise,
    document: { hidden: false, addEventListener(name, handler) { events[name] = handler; } },
    TVBroWebOSSecureStore: { create(options) { assert.equal(options.environment, env); return store; } },
    TVBroWebOSCatalogStore: { create(options) { assert.equal(options.secureStore, store); return {}; } },
    TVBroWebOSBackupFiles: { create: () => ({ capabilities: () => ({ import: false, export: false }) }) },
    TVBroWebOSMemoryPolicy: {}, TVBroCanonical: {}, TVBroPanelValidation: { friendlyError: e => e.message },
    TVBroSamsungUserState: { create(options) { assert.equal(options.store, store); calls.push('read-storage'); return {}; } },
    TVBroSamsungTransport: { create: () => ({ checkStream: () => Promise.resolve() }) },
    TVBroSamsungSourceWorker: { create: () => ({ createSource() {}, verifyPin() {}, hashPin() {} }) },
    TVBroTitanPlayer: { create: () => ({ onState() {}, getState: () => state, stop: () => Promise.resolve() }) },
    TVBroSamsungCloud: { create(options) { assert.equal(options.deviceLabel, 'Titan OS TV'); return {}; } },
    TVBroSamsungLibrary: { create(options) {
      libraryOptions=options;
      calls.push('library');
      assert.equal(options.canImportBackup, false);
      assert.equal(options.canExportBackup, false);
      return {
        getState: () => state,
        stopPlayback: () => { calls.push('stopPlayback'); return Promise.resolve(); },
        query: name => { calls.push(name); return Promise.resolve(); }
      };
    } }
  };
  env.window = env;
  return { env, store, calls, events, resolveStorage, rejectStorage, libraryOptions:() => libraryOptions };
}

function start(b) {
  b.env.TVBroPlatformAdapters = createAdapters(b.env);
  vm.runInNewContext(sharedSource, b.env);
  return b.env.TVBroPlatformReady;
}

test('Titan waits for protected storage before starting the unchanged shared library', async () => {
  const b = boundary(), ready = start(b);
  await Promise.resolve();
  assert.deepEqual(b.calls, []);
  b.resolveStorage();
  const platform = await ready;
  assert.equal(platform, b.env.TVBroSamsungPlatform);
  assert.deepEqual(b.calls, ['read-storage', 'library']);
  assert.equal(b.env.TVBroSamsungMemoryPolicy, b.env.TVBroWebOSMemoryPolicy);
  assert.equal(b.env.TVBroPlatformAdapters.playerModule, b.env.TVBroTitanPlayer);
  assert.equal(b.env.TVBroPlatformAdapters.confirmExit, true);
  assert.equal(b.env.TVBroPlatformAdapters.openTrailer, undefined);
  assert.equal(b.libraryOptions().requiresHttpsProvider,true,'only hosted Titan requires an HTTPS provider route');
});

test('failed persistent storage never creates an empty profile or starts the library', async () => {
  const b = boundary(), ready = start(b);
  b.rejectStorage(new Error('persistent key unavailable'));
  await assert.rejects(ready, /persistent key unavailable/);
  assert.equal(b.env.TVBroSamsungPlatform, undefined);
  assert.deepEqual(b.calls, []);
});

test('Philips and JVC Back and Titan Play/Pause reach existing Samsung UI actions', async () => {
  const b = boundary(), adapters = createAdapters(b.env);
  b.resolveStorage(); await adapters.ready;
  assert.equal(adapters.normalizeKey(8), 10009);
  assert.equal(adapters.normalizeKey(461), 10009);
  assert.equal(adapters.normalizeKey(179), 10252);
  for (const code of [13, 37, 38, 39, 40, 415, 413, 19, 412, 417, 33, 34, 48, 57, 403, 406]) {
    assert.equal(adapters.normalizeKey(code), code);
  }
});

test('confirmed exit flushes shared state and stops playback before the native Titan exit', async () => {
  const b = boundary();
  b.env.SmartTvA_API = { exit() { assert.equal(this, b.env.SmartTvA_API); b.calls.push('titan.exit'); } };
  b.env.close = () => assert.fail('native Titan exit is available');
  const ready = start(b); b.resolveStorage();
  const platform = await ready;
  await platform.exit();
  assert.deepEqual(b.calls.slice(-3), ['cache.flush', 'playback.stop', 'titan.exit']);
});

test('documented close fallback requires a confirmed closed window and never invokes other TV APIs', async () => {
  const b = boundary(), adapters = createAdapters(b.env);
  b.resolveStorage(); await adapters.ready;
  b.env.tizen = { application: { getCurrentApplication: () => assert.fail('no Tizen exit') } };
  b.env.webOS = { platformBack: () => assert.fail('no LG exit') };
  assert.throws(() => adapters.exit(), {name: 'NotSupportedError'});
  b.env.close = () => b.calls.push('ignored-close');
  assert.throws(() => adapters.exit(), {name: 'NotSupportedError'});
  b.env.close = () => { b.env.closed = true; };
  assert.doesNotThrow(() => adapters.exit());
});

test('native Titan exit errors stay observable rather than falling back to a successful no-op', async () => {
  const b = boundary(), adapters = createAdapters(b.env);
  b.resolveStorage(); await adapters.ready;
  b.env.SmartTvA_API = { exit() { throw new Error('exit denied'); } };
  b.env.close = () => assert.fail('do not hide native failure');
  assert.throws(() => adapters.exit(), /exit denied/);
});

test('backgrounding reuses the shared cache flush and playback stop lifecycle', async () => {
  const b = boundary(), ready = start(b);
  b.resolveStorage(); await ready;
  b.env.document.hidden = true;
  b.events.visibilitychange();
  await Promise.resolve(); await Promise.resolve();
  assert.deepEqual(b.calls.slice(2), ['cache.flush', 'stopPlayback', 'settings.get']);
});
