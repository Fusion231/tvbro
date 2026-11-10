'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const create = require('../platform/epg_files.js').create;

const key = 'a'.repeat(64);
const descriptor = {token:'epg_1000_0.bin', size:9, at:1000};

function harness(respond) {
  const calls = [], timers = new Map();
  let nextTimer = 0;
  const environment = {
    atob,
    setTimeout(callback, delay) { const id = ++nextTimer; timers.set(id, {callback, delay}); return id; },
    clearTimeout(id) { timers.delete(id); },
    webOS:{service:{request(uri, options) {
      const call = {uri, options, cancelled:false};
      const handle = {cancel() { call.cancelled = true; }};
      call.handle = handle; calls.push(call);
      if (respond) queueMicrotask(() => respond(call));
      return handle;
    }}}
  };
  return {api:create({environment}), calls, timers,
    runTimers() { for (const timer of [...timers.values()]) timer.callback(); }};
}

test('adapter reports unsupported when the webOS service bridge is absent', async () => {
  const api = create({environment:{atob}});
  assert.equal(api.available(), false);
  await assert.rejects(api.query({action:'lookup', key}), {name:'NotSupportedError'});
});

test('adapter delegates downloads and cache lookups through the app-prefixed Luna service', async () => {
  const bridge = harness(call => {
    if (call.options.method === 'download') call.options.onSuccess({returnValue:true, ...descriptor});
    else if (call.options.method === 'query') call.options.onSuccess({returnValue:true, ...descriptor});
  });
  assert.equal(bridge.api.available(), true);
  const entry = {};
  assert.deepEqual(await bridge.api.download({url:'https://provider.test/guide', headers:{'x-key':'value'}}, entry, key), descriptor);
  assert.equal(bridge.calls[0].uri, 'luna://online.tvbro.webos.epg/');
  assert.equal(bridge.calls[0].options.method, 'download');
  assert.equal(bridge.calls[0].options.subscribe, true);
  assert.equal(bridge.calls[0].options.parameters.url, 'https://provider.test/guide');
  assert.equal(entry.cancelNative, null);
  assert.deepEqual(await bridge.api.query({action:'lookup', key}), descriptor);
  assert.equal(bridge.calls[1].options.method, 'query');
});

test('adapter decodes bounded file reads and rejects requests above 64 KiB locally', async () => {
  const bytes = Buffer.from([0, 127, 128, 255, 9, 8, 7, 6, 5]);
  const bridge = harness(call => {
    if (call.options.method === 'query' && call.options.parameters.action === 'lookup') {
      call.options.onSuccess({returnValue:true, ...descriptor});
    } else if (call.options.method === 'query') {
      call.options.onSuccess({returnValue:true, bodyBase64:bytes.toString('base64'), eof:true});
    }
  });
  await bridge.api.query({action:'lookup', key});
  const result = await bridge.api.query({action:'read', token:descriptor.token, offset:0, count:65536});
  assert.deepEqual(Buffer.from(result.bodyBuffer), bytes);
  assert.equal(result.eof, true);
  await assert.rejects(bridge.api.query({action:'read', token:descriptor.token, offset:0, count:65537}), {name:'TypeError'});
  assert.equal(bridge.calls.length, 2);
});

test('a missing service response times out and cancels its Luna request', async () => {
  const bridge = harness(null);
  let outcome;
  const pending = bridge.api.query({action:'lookup', key}).catch(error => { outcome = error; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(bridge.calls.length, 1);
  bridge.runTimers();
  await pending;
  assert.equal(outcome.name, 'TimeoutError');
  assert.equal(bridge.calls[0].cancelled, true);
});

test('abort cancels outstanding RPCs, sends service abort, and consumes its failure', async () => {
  const bridge = harness(call => {
    if (call.options.method === 'abort') call.options.onSuccess({returnValue:true});
  });
  const pending = bridge.api.query({action:'lookup', key}).catch(error => error.name);
  await new Promise(resolve => setImmediate(resolve));
  await bridge.api.abort();
  assert.equal(await pending, 'AbortError');
  assert.equal(bridge.calls[0].cancelled, true);
  assert.equal(bridge.calls[1].options.method, 'abort');
});

test('service HTTP refusals preserve status and retry-after without provider details', async () => {
  const bridge = harness(call => call.options.onSuccess({returnValue:false, errorKind:'http', status:429,
    retryAfter:'30', errorText:'https://provider.test/?password=private'}));
  await assert.rejects(bridge.api.download({url:'https://provider.test/guide'}, {}, key), failure => {
    assert.equal(failure.name, 'NetworkError');
    assert.equal(failure.status, 429);
    assert.equal(failure.retryAfter, '30');
    assert.ok(!failure.message.includes('provider.test'));
    assert.ok(!failure.message.includes('private'));
    return true;
  });
});
