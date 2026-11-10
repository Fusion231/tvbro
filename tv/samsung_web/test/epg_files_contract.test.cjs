'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
let create;
try { create = require('../platform/epg_files.js').create; }
catch (error) { if (error.code !== 'MODULE_NOT_FOUND') throw error; }

const key = 'a'.repeat(64), otherKey = 'b'.repeat(64);
const MiB = 1024 * 1024;

// Only SDK callbacks/storage are synthetic; large payloads are virtual disk bytes.
function sdk() {
  const files = new Map(), jobs = new Map(), timers = new Map();
  const reads = [], deleted = [], cancelled = [], opened = new Set();
  let clock = 1000, nextTimer = 0, nextJob = 0, peakStreams = 0;
  let failMarker = false, failRename = false, holdOpen = false, holdResolve = false;
  const waitingOpen = [], waitingResolve = [];
  function missing() { const error = Error('Not found'); error.name = 'NotFoundError'; throw error; }
  function file(name, size = 0, bytes = null) {
    const value = {name, isDirectory: false, size, bytes,
      get fileSize() { return this.bytes ? this.bytes.length : this.size; },
      openStream(mode, ok) {
        function open() {
          let position = 0, closed = false;
          const stream = {
            get position() { return position; }, set position(value) { position = value; },
            get bytesAvailable() { return value.fileSize - position; },
            get eof() { return position >= value.fileSize; },
            readBytes(count) {
              assert.equal(closed, false); reads.push({name, count});
              const size = Math.min(count, value.fileSize - position);
              const result = value.bytes ? Array.from(value.bytes.subarray(position, position + size)) :
                Array.from({length: size}, (_, offset) => (position + offset) % 251);
              position += size; return result;
            },
            writeBytes(bytes) {
              assert.equal(closed, false);
              if (failMarker) throw Error('Disk full at private/path?password=secret');
              value.bytes = Buffer.concat([value.bytes || Buffer.alloc(0), Buffer.from(bytes)]);
            },
            close() { closed = true; opened.delete(stream); }
          };
          opened.add(stream); peakStreams = Math.max(peakStreams, opened.size); ok(stream);
        }
        if (holdOpen && mode === 'r' && name.endsWith('.bin')) waitingOpen.push(open);
        else queueMicrotask(open);
      }
    };
    files.set(name, value); return value;
  }
  const directory = {isDirectory: true, fullPath: 'wgt-private/tvbro_epg_v1',
    resolve(name) { assert.ok(!name.includes('/')); return files.get(name) || missing(); },
    listFiles(ok) { queueMicrotask(() => ok([...files.values()])); },
    createFile(name) { assert.equal(files.has(name), false); return file(name, 0, Buffer.alloc(0)); },
    deleteFile(path, ok) {
      assert.ok(path.startsWith('wgt-private/tvbro_epg_v1/'));
      const name = path.slice('wgt-private/tvbro_epg_v1/'.length);
      assert.ok(!name.includes('/')); deleted.push(name); files.delete(name); queueMicrotask(ok);
    },
    moveTo(from, to, overwrite, ok, fail) {
      assert.equal(overwrite, false);
      if (failRename) { queueMicrotask(() => fail(Error('Disk failure secret'))); return; }
      const name = from.split('/').pop(), target = to.split('/').pop();
      assert.ok(files.has(name)); assert.equal(files.has(target), false);
      const value = files.get(name); files.delete(name); value.name = target; files.set(target, value);
      queueMicrotask(ok);
    }
  };
  const environment = {Date: {now: () => clock},
    setTimeout(fn, ms) { const id = ++nextTimer; timers.set(id, {fn, at: clock + ms}); return id; },
    clearTimeout(id) { timers.delete(id); },
    tizen: {systeminfo: {getCapability() { return true; }},
      filesystem: {resolve(path, ok) { assert.equal(path, 'wgt-private');
        const finish = () => ok({resolve(name) { assert.equal(name, 'tvbro_epg_v1'); return directory; }});
        if (holdResolve) waitingResolve.push(finish); else queueMicrotask(finish);
      }},
      DownloadRequest: function (url, destination, fileName, networkType, httpHeader) {
        Object.assign(this, {url, destination, fileName, networkType, httpHeader});
      },
      download: {
        start(request, callbacks) {
          assert.equal(request.destination, 'wgt-private/tvbro_epg_v1');
          assert.ok(!request.fileName.includes('/')); const id = ++nextJob;
          jobs.set(id, {id, request, callbacks}); return id;
        },
        cancel(id) { cancelled.push(id); }
      }
    }
  };
  async function flush() { for (let i = 0; i < 30; i++) await Promise.resolve(); }
  return {environment, files, jobs, reads, deleted, cancelled, opened,
    get peakStreams() { return peakStreams; },
    restart() { assert.equal(typeof create, 'function', 'native EPG files factory is implemented'); return create({environment}); },
    async advance(ms) {
      const target = clock + ms;
      while (true) {
        const due = [...timers].filter(([, value]) => value.at <= target).sort((a,b) => a[1].at - b[1].at)[0];
        if (!due) break;
        clock = due[1].at; timers.delete(due[0]); due[1].fn(); await flush();
      }
      clock = target; await flush();
    },
    async started(store, size = 101, request = {}, cacheKey = key) {
      const entry = {}, promise = store.download(Object.assign({url: 'https://provider.test/feed?password=secret',
        headers: {'X-Test': 'test'}, maximumBodyBytes: 512 * MiB, totalTimeoutMs: 1000, idleTimeoutMs: 100}, request), entry, cacheKey);
      promise.catch(() => {}); await flush();
      const job = [...jobs.values()].at(-1); return {entry, promise, job, size};
    },
    complete(operation, callbackPath) {
      file(operation.job.request.fileName, operation.size);
      operation.job.callbacks.oncompleted(operation.job.id, callbackPath || 'wgt-private/tvbro_epg_v1/' + operation.job.request.fileName);
      return operation.promise;
    },
    virtual: file, flush,
    failMarker(value) { failMarker = value; }, failRename(value) { failRename = value; },
    holdReads(value) { holdOpen = value; },
    resumeReads() { waitingOpen.splice(0).forEach(fn => fn()); },
    holdResolve(value) { holdResolve = value; },
    resumeResolve() { waitingResolve.splice(0).forEach(fn => fn()); }
  };
}

test('availability requires native download and filesystem APIs and honors unsupported capability', () => {
  const fs = sdk(); assert.equal(fs.restart().available(), true);
  fs.environment.tizen.systeminfo.getCapability = () => false;
  assert.equal(fs.restart().available(), false);
  delete fs.environment.tizen.systeminfo; delete fs.environment.tizen.download;
  assert.equal(fs.restart().available(), false);
});

test('native body stays on disk and binary reads seek and never exceed 64 KiB', async () => {
  const fs = sdk(), store = fs.restart();
  const operation = await fs.started(store, 400 * MiB);
  assert.deepEqual(operation.job.request.httpHeader, {'X-Test': 'test'});
  const descriptor = await fs.complete(operation);
  assert.equal(descriptor.size, 400 * MiB); assert.equal(typeof descriptor.at, 'number');
  assert.ok(!descriptor.token.includes('/')); assert.equal(fs.reads.length, 0);
  assert.equal(await store.query({action: 'lookup', key}), null);
  const first = await store.query({action: 'read', token: descriptor.token, offset: 300 * MiB, count: 65536});
  assert.equal(first.bodyBuffer.byteLength, 65536); assert.equal(first.eof, false);
  assert.equal(new Uint8Array(first.bodyBuffer)[13], (300 * MiB + 13) % 251);
  const last = await store.query({action: 'read', token: descriptor.token, offset: descriptor.size - 7, count: 65536});
  assert.equal(last.bodyBuffer.byteLength, 7); assert.equal(last.eof, true);
  await assert.rejects(store.query({action: 'read', token: descriptor.token, offset: 0, count: 65537}), {name: 'TypeError'});
  assert.ok(fs.reads.every(read => read.count <= 65536)); assert.equal(fs.opened.size, 0);
  await store.abort();
});

test('commit survives restart and failed refresh/discard retain the old verified generation', async () => {
  const fs = sdk(), store = fs.restart();
  const first = await fs.complete(await fs.started(store, 123));
  await store.query({action: 'commit', token: first.token});
  await store.query({action: 'release', token: first.token});
  assert.deepEqual(await fs.restart().query({action: 'lookup', key}), first);
  const second = await fs.complete(await fs.started(store, 456));
  assert.deepEqual(await store.query({action: 'lookup', key}), first);
  await store.query({action: 'discard', token: second.token});
  assert.deepEqual(await fs.restart().query({action: 'lookup', key}), first);
  assert.equal(await store.query({action: 'discard', token: first.token}), false);
  assert.equal(await store.query({action: 'release', token: first.token}), true);
  const third = await fs.complete(await fs.started(store, 789));
  await store.query({action: 'commit', token: third.token});
  assert.deepEqual(await fs.restart().query({action: 'lookup', key}), third);
  assert.equal(fs.files.has(first.token), false);
});

test('marker write/rename failure and an unvalidated restart never publish a partial generation', async () => {
  const fs = sdk(), store = fs.restart();
  const first = await fs.complete(await fs.started(store, 123));
  await store.query({action: 'commit', token: first.token});
  for (const kind of ['write', 'rename']) {
    const next = await fs.complete(await fs.started(store, 321));
    if (kind === 'write') fs.failMarker(true); else fs.failRename(true);
    await assert.rejects(store.query({action: 'commit', token: next.token}), error => !error.message.includes('secret'));
    fs.failMarker(false); fs.failRename(false);
    assert.deepEqual(await fs.restart().query({action: 'lookup', key}), first);
  }
  const partial = await fs.complete(await fs.started(store, 456));
  fs.virtual('unrelated-file', 10);
  assert.deepEqual(await fs.restart().query({action: 'lookup', key}), first);
  assert.equal(fs.files.has(partial.token), false); assert.equal(fs.files.has('unrelated-file'), true);
});

test('tokens and SDK completion paths cannot access arbitrary files', async () => {
  const fs = sdk(), store = fs.restart();
  fs.virtual('unrelated-file', 500);
  for (const token of ['../unrelated-file', '/private/file', 'epg_1_0.bin/../file', 'epg_1_0.bin']) {
    for (const action of ['read', 'commit', 'discard', 'release']) {
      await assert.rejects(store.query({action, token, offset: 0, count: 10}));
    }
  }
  await assert.rejects(store.query({action: 'lookup', key: '../key'}), {name: 'TypeError'});
  const operation = await fs.started(store, 100);
  const descriptor = await fs.complete(operation, '/outside/unrelated-file');
  assert.equal(descriptor.size, 100);
  await assert.rejects(store.query({action: 'commit', token: descriptor.token, key: otherKey}), {name: 'TypeError'});
  await store.abort(); assert.equal(fs.files.has('unrelated-file'), true);
});

test('cancellation and abort cancel native IO, settle requests, and discard only uncommitted files', async () => {
  const fs = sdk(), store = fs.restart();
  const good = await fs.complete(await fs.started(store)); await store.query({action: 'commit', token: good.token});
  const pending = await fs.started(store);
  assert.equal(typeof pending.entry.cancelNative, 'function'); pending.entry.cancelNative();
  await assert.rejects(pending.promise, {name: 'AbortError'});
  assert.ok(fs.cancelled.includes(pending.job.id));
  // A late SDK completion is never a cache candidate and is deleted from the owned directory.
  fs.complete(pending).catch(() => {}); await fs.flush();
  assert.equal(fs.files.has(pending.job.request.fileName), false);
  const validating = await fs.complete(await fs.started(store));
  const downloading = await fs.started(store);
  await store.abort(); await assert.rejects(downloading.promise, {name: 'AbortError'});
  assert.equal(fs.files.has(validating.token), false);
  assert.deepEqual(await store.query({action: 'lookup', key}), good);
});

test('idle timeout observes real byte progress and total timeout never extends with progress', async () => {
  const fs = sdk(), store = fs.restart();
  const idle = await fs.started(store);
  await fs.advance(60); idle.job.callbacks.onprogress(idle.job.id, 10, 100);
  await fs.advance(60); idle.job.callbacks.onprogress(idle.job.id, 10, 100);
  await fs.advance(40); await assert.rejects(idle.promise, {name: 'TimeoutError'});
  const total = await fs.started(store, 100, {totalTimeoutMs: 250});
  for (let received = 10; received <= 30; received += 10) {
    await fs.advance(70); total.job.callbacks.onprogress(total.job.id, received, 100);
  }
  await fs.advance(40); await assert.rejects(total.promise, {name: 'TimeoutError'});
  assert.ok(fs.cancelled.includes(total.job.id));
});

test('advertised, received and completed body sizes enforce caller and absolute 512 MiB ceilings', async () => {
  for (const mode of ['advertised', 'received', 'completed', 'absolute']) {
    const fs = sdk(), store = fs.restart();
    const operation = await fs.started(store, mode === 'absolute' ? 513 * MiB : 101,
      {maximumBodyBytes: mode === 'absolute' ? 1024 * MiB : 100});
    if (mode === 'advertised') operation.job.callbacks.onprogress(operation.job.id, 0, 101);
    else if (mode === 'received') operation.job.callbacks.onprogress(operation.job.id, 101, 0);
    else fs.complete(operation).catch(() => {});
    await assert.rejects(operation.promise, {name: 'QuotaExceededError'});
    assert.equal(fs.files.has(operation.job.request.fileName), false);
  }
});

test('native failures expose only safe HTTP refusals, never URLs or credentials', async () => {
  for (const [message, status] of [['HTTP 401: https://x?password=secret', 401], ['HTTP status: 403 secret', 403],
    ['HTTP/1.1 429 secret', 429], ['https://server/401?password=secret', undefined],
    ['Download failed for https://server/HTTP401?password=secret', undefined], ['HTTP 500 secret', undefined]]) {
    const fs = sdk(), store = fs.restart(), operation = await fs.started(store);
    operation.job.callbacks.onfailed(operation.job.id, {name: 'UnknownError', message});
    await assert.rejects(operation.promise, error => {
      assert.equal(error.name, 'NetworkError'); assert.equal(error.status, status);
      assert.ok(!error.message.includes('secret')); assert.ok(!error.message.includes('https:')); return true;
    });
  }
});

test('cache prunes completed entries to eight and 768 MiB while preserving the newest committed key', async () => {
  const fs = sdk(), store = fs.restart();
  let newest;
  for (let i = 0; i < 10; i++) {
    const cacheKey = i.toString(16).repeat(64);
    newest = await fs.complete(await fs.started(store, 100 * MiB, {}, cacheKey));
    await store.query({action: 'commit', token: newest.token});
    await store.query({action: 'release', token: newest.token});
  }
  const retained = [...fs.files.values()].filter(file => file.name.endsWith('.bin'));
  assert.ok(retained.length <= 8); assert.ok(retained.reduce((sum, file) => sum + file.fileSize, 0) <= 768 * MiB);
  assert.deepEqual(await fs.restart().query({action: 'lookup', key: '9'.repeat(64)}), newest);
});

test('abort during a delayed native stream open closes the handle and fails the read', async () => {
  const fs = sdk(), store = fs.restart();
  const descriptor = await fs.complete(await fs.started(store));
  await store.query({action: 'commit', token: descriptor.token});
  fs.holdReads(true);
  const reading = store.query({action: 'read', token: descriptor.token, offset: 0, count: 10});
  let outcome; reading.catch(error => { outcome = error.name; }); await fs.flush();
  const stopping = store.abort(); await fs.flush();
  assert.equal(outcome, 'AbortError');
  fs.resumeReads();
  await assert.rejects(reading, {name: 'AbortError'}); await stopping;
  assert.equal(fs.opened.size, 0); assert.equal(fs.peakStreams, 1);
});

test('download deadline settles while the SDK filesystem resolver is unresponsive', async () => {
  const fs = sdk(), store = fs.restart(); fs.holdResolve(true);
  const entry = {}, promise = store.download({url: 'https://provider.test/epg', totalTimeoutMs: 50}, entry, key);
  let outcome; promise.catch(error => { outcome = error.name; }); await fs.flush();
  await fs.advance(50); assert.equal(outcome, 'TimeoutError');
  const stopping = store.abort(); fs.resumeResolve(); await stopping;
  assert.equal(fs.jobs.size, 0);
});

test('uncommitted generations are bounded and rejecting another download leaves existing tokens intact', async () => {
  const fs = sdk(), store = fs.restart(), pending = [];
  for (let i = 0; i < 8; i++) pending.push(await fs.complete(await fs.started(store, 100)));
  const overflow = store.download({url: 'https://provider.test/epg'}, {}, key);
  let outcome; overflow.catch(error => { outcome = error.name; }); await fs.flush();
  assert.equal(outcome, 'QuotaExceededError');
  for (const descriptor of pending) assert.equal(fs.files.has(descriptor.token), true);
  await store.abort();
  assert.equal([...fs.files.values()].filter(file => file.name.endsWith('.bin')).length, 0);
});

test('a refreshed guide preserves a leased old token until its concurrent reader releases it', async () => {
  const fs = sdk(), store = fs.restart();
  const old = await fs.complete(await fs.started(store, 101));
  await store.query({action: 'commit', token: old.token});
  await store.query({action: 'release', token: old.token});
  const reading = await store.query({action: 'lookup', key});
  const newer = await fs.complete(await fs.started(store, 202));
  await store.query({action: 'commit', token: newer.token});
  assert.equal(fs.files.has(old.token), true);
  const chunk = await store.query({action: 'read', token: reading.token, offset: 90, count: 20});
  assert.equal(chunk.bodyBuffer.byteLength, 11); assert.equal(chunk.eof, true);
  await store.query({action: 'release', token: reading.token});
  assert.equal(fs.files.has(old.token), false);
  assert.equal((await store.query({action: 'lookup', key})).token, newer.token);
  await store.abort();
});
