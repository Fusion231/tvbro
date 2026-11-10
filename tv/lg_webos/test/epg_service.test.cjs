'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

let createStore;
try { createStore = require('../epg_service/store.js').create; }
catch (error) { if (error.code !== 'MODULE_NOT_FOUND') throw error; }

const key = 'a'.repeat(64);
const size = 2 * 1024 * 1024 + 17;

function byteAt(offset) { return offset % 251; }

function localServer(t, handler) {
  const server = http.createServer(handler);
  server.listen(0, '127.0.0.1');
  t.after(() => new Promise(resolve => {
    server.close(resolve);
    if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
  }));
  return new Promise(resolve => server.once('listening', () => resolve('http://127.0.0.1:' + server.address().port)));
}

function fixtureServer(t) {
  return localServer(t, (request, response) => {
    assert.equal(request.method, 'GET');
    assert.equal(request.url, '/guide?token=fixture');
    response.writeHead(200, {'content-length': String(size), 'content-encoding': 'gzip'});
    let offset = 0;
    function write() {
      while (offset < size) {
        const count = Math.min(8192, size - offset);
        const chunk = Buffer.allocUnsafe(count);
        for (let i = 0; i < count; i++) chunk[i] = byteAt(offset + i);
        offset += count;
        if (!response.write(chunk)) { response.once('drain', write); return; }
      }
      response.end();
    }
    write();
  });
}

function tempDirectory(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'tvbro-webos-epg-'));
  t.after(() => fs.rmSync(root, {recursive: true, force: true}));
  return path.join(root, 'online.tvbro.webos.epg');
}

function smallReply(status, headers, body) {
  return function (_request, response) {
    body = Buffer.from(body || 'ok');
    response.writeHead(status, Object.assign({'content-length':String(body.length)}, headers || {}));
    response.end(body);
  };
}

test('streams raw EPG to private disk and reopens a pending then committed generation', async t => {
  assert.equal(typeof createStore, 'function', 'the webOS disk EPG service store is implemented');
  const directory = tempDirectory(t);
  const baseUrl = await fixtureServer(t);
  const store = createStore({directory});
  const descriptor = await store.download({
    url: baseUrl + '/guide?token=fixture',
    headers: {'x-fixture': 'test'},
    maximumBodyBytes: 4 * 1024 * 1024,
    totalTimeoutMs: 10000,
    idleTimeoutMs: 3000
  }, key, 'request-1');

  assert.deepEqual(Object.keys(descriptor).sort(), ['at', 'size', 'token']);
  assert.equal(descriptor.size, size);
  assert.match(descriptor.token, /^epg_[A-Za-z0-9_]+\.bin$/);
  const reopenedPending = createStore({directory});
  const chunk = await reopenedPending.query({action: 'read', token: descriptor.token, offset: 65530, count: 65536});
  const chunkBytes = Buffer.from(chunk.bodyBase64, 'base64');
  assert.equal(chunkBytes.length, 65536);
  assert.equal(chunk.eof, false);
  for (let index = 0; index < chunkBytes.length; index++) {
    assert.equal(chunkBytes[index], byteAt(65530 + index));
  }
  await reopenedPending.query({action: 'commit', token: descriptor.token});
  await reopenedPending.query({action: 'release', token: descriptor.token});
  const reopenedCommitted = createStore({directory});
  assert.deepEqual(await reopenedCommitted.query({action: 'lookup', key}), descriptor);
  const tail = await reopenedCommitted.query({action: 'read', token: descriptor.token, offset: size - 3, count: 65536});
  assert.deepEqual(Array.from(Buffer.from(tail.bodyBase64, 'base64')), [byteAt(size - 3), byteAt(size - 2), byteAt(size - 1)]);
  assert.equal(tail.eof, true);
  await reopenedCommitted.query({action: 'release', token: descriptor.token});
});

test('missing disk reads reject with a not-found error', async t => {
  const store = createStore({directory:tempDirectory(t)});
  await assert.rejects(store.query({action:'read', token:'epg_0_0.bin', offset:0, count:1}),
    error => error.name === 'NotFoundError');
});

test('HTTP refusals preserve safe status and Retry-After while the old committed file survives', async t => {
  const directory = tempDirectory(t), keyA = 'c'.repeat(64), keyB = 'd'.repeat(64);
  const okUrl = await localServer(t, smallReply(200, {}, 'old'));
  const failureUrl = await localServer(t, (_request, response) => {
    response.writeHead(429, {'retry-after':'45'}); response.end('provider response with password=fixture');
  });
  const store = createStore({directory});
  const old = await store.download({url:okUrl + '/guide', maximumBodyBytes:1000}, keyA, 'first');
  await store.query({action:'commit', token:old.token});
  await store.query({action:'release', token:old.token});
  const failure = await store.download({url:failureUrl + '/feed?password=fixture'}, keyB, 'second').then(
    () => null, error => error);
  assert.equal(failure.kind, 'http'); assert.equal(failure.status, 429); assert.equal(failure.retryAfter, '45');
  assert.ok(!failure.message.includes('fixture')); assert.ok(!failure.message.includes('http://'));
  assert.deepEqual(await store.query({action:'lookup', key:keyA}), old);
  assert.equal(fs.existsSync(path.join(directory, old.token)), true);
  assert.deepEqual(fs.readdirSync(directory).filter(name => name.endsWith('.part')), []);
});

test('cross-origin redirects do not forward credentials, provider headers, or URL userinfo', async t => {
  let received;
  const destination = await localServer(t, (request, response) => {
    received = request.headers;
    smallReply(200, {}, 'ok')(request, response);
  });
  const redirect = await localServer(t, (_request, response) => {
    response.writeHead(302, {location:destination + '/finish'}); response.end();
  });
  const directory = tempDirectory(t), store = createStore({directory});
  const headers = {Authorization:'Bearer fixture', Cookie:'session=fixture', 'X-Api-Key':'fixture',
    'X-Provider-Private':'fixture', Referer:'https://source.test/path', 'User-Agent':'TVBro fixture', Accept:'application/xml'};
  const descriptor = await store.download({url:redirect.replace('http://', 'http://user:password@') + '/start',
    headers:headers, maximumBodyBytes:1000}, key, 'redirect');
  assert.ok(received); assert.equal(received['user-agent'], 'TVBro fixture');
  assert.equal(received.accept, 'application/xml');
  for (const name of ['authorization', 'cookie', 'x-api-key', 'x-provider-private', 'referer']) assert.equal(received[name], undefined, name);
  assert.deepEqual(await store.query({action:'read', token:descriptor.token, offset:0, count:2}),
    {bodyBase64:Buffer.from('ok').toString('base64'), eof:true});
  const marker = fs.readFileSync(path.join(directory, descriptor.token + '.pending'), 'utf8');
  assert.ok(!marker.includes('provider.test')); assert.ok(!marker.includes('password'));
});

test('redirect loops and non-HTTP redirect protocols fail without leaving a file', async t => {
  let redirects = 0;
  const loop = await localServer(t, (_request, response) => {
    redirects++; response.writeHead(302, {location:'/loop'}); response.end();
  });
  const foreign = await localServer(t, (_request, response) => {
    response.writeHead(302, {location:'file:///etc/passwd'}); response.end();
  });
  const directory = tempDirectory(t), store = createStore({directory});
  const capped = await store.download({url:loop + '/start'}, key, 'loop').then(() => null, error => error);
  assert.equal(capped.name, 'NetworkError'); assert.equal(redirects, 6);
  const protocol = await store.download({url:foreign + '/start'}, 'e'.repeat(64), 'protocol').then(() => null, error => error);
  assert.equal(protocol.name, 'NetworkError');
  assert.deepEqual(fs.readdirSync(directory), []);
});

test('advertised and streamed size limits fail safely and remove partial files', async t => {
  const advertised = await localServer(t, (request, response) => {
    response.writeHead(200, {'content-length':'1000'}); response.end();
  });
  const streamed = await localServer(t, (request, response) => {
    response.writeHead(200, {'transfer-encoding':'chunked'}); response.end(Buffer.alloc(1000, 1));
  });
  const absolute = await localServer(t, (_request, response) => {
    response.writeHead(200, {'content-length':String(512 * 1024 * 1024 + 1)}); response.end();
  });
  const directory = tempDirectory(t), store = createStore({directory});
  for (const url of [advertised, streamed]) {
    const failure = await store.download({url:url + '/guide', maximumBodyBytes:100}, key, 'limit-' + url).then(
      () => null, error => error);
    assert.equal(failure.name, 'QuotaExceededError');
    assert.deepEqual(fs.readdirSync(directory), []);
  }
  const absoluteFailure = await store.download({url:absolute + '/guide', maximumBodyBytes:1024 * 1024 * 1024},
    '0'.repeat(64), 'absolute-limit').then(() => null, error => error);
  assert.equal(absoluteFailure.name, 'QuotaExceededError');
  assert.deepEqual(fs.readdirSync(directory), []);
});

test('idle and total deadlines stop stalled HTTP transfers', async t => {
  const stalled = await localServer(t, () => {});
  const progressing = await localServer(t, (_request, response) => {
    response.writeHead(200, {'transfer-encoding':'chunked'});
    const timer = setInterval(() => response.write('x'), 15);
    response.on('close', () => clearInterval(timer));
  });
  const store = createStore({directory:tempDirectory(t)});
  const idle = await store.download({url:stalled + '/idle', totalTimeoutMs:1000, idleTimeoutMs:40}, key, 'idle')
    .then(() => null, error => error);
  const total = await store.download({url:progressing + '/total', totalTimeoutMs:100, idleTimeoutMs:70},
    'f'.repeat(64), 'total').then(() => null, error => error);
  assert.equal(idle.name, 'TimeoutError'); assert.equal(total.name, 'TimeoutError');
});

test('write-open failures are redacted and clean only the owned token path', async t => {
  let requestSeen;
  const sawRequest = new Promise(resolve => { requestSeen = resolve; });
  let delayedResponse;
  const base = await localServer(t, (_request, response) => { delayedResponse = response; requestSeen(); });
  const directory = tempDirectory(t), store = createStore({directory, now:() => 1000});
  const pending = store.download({url:base + '/guide?password=fixture'}, key, 'write-failure').then(
    () => null, error => error);
  await sawRequest;
  fs.writeFileSync(path.join(directory, 'epg_1000_0.bin.part'), 'occupied');
  delayedResponse.writeHead(200, {'content-length':'1'}); delayedResponse.end('x');
  const failure = await pending;
  assert.equal(failure.name, 'IOError'); assert.ok(!failure.message.includes('fixture'));
  assert.deepEqual(fs.readdirSync(directory), []);
});

test('committed cache lookup and leases survive store restart until every reader releases', async t => {
  let tick = 1000;
  const directory = tempDirectory(t), server = await localServer(t, smallReply(200, {}, 'guide'));
  const now = () => tick++;
  const firstStore = createStore({directory, now});
  const keyA = '1'.repeat(64), old = await firstStore.download({url:server + '/0'}, keyA, '0');
  await firstStore.query({action:'commit', token:old.token});
  let latest;
  for (let index = 1; index < 10; index++) {
    const key = index.toString(16).repeat(64);
    const descriptor = await firstStore.download({url:server + '/' + index}, key, String(index));
    latest = descriptor;
    await firstStore.query({action:'commit', token:descriptor.token});
    if (index !== 9) await firstStore.query({action:'release', token:descriptor.token});
  }
  assert.equal(fs.readdirSync(directory).filter(name => /^epg_[A-Za-z0-9_]+\.bin$/.test(name)).length, 9,
    'the two leased generations remain available during the replacement');
  assert.equal(fs.existsSync(path.join(directory, old.token)), true);
  const restarted = createStore({directory, now});
  assert.deepEqual(await restarted.query({action:'lookup', key:keyA}), old);
  assert.deepEqual(await restarted.query({action:'read', token:old.token, offset:0, count:16}),
    {bodyBase64:Buffer.from('guide').toString('base64'), eof:true});
  await restarted.query({action:'release', token:old.token});
  assert.equal(fs.existsSync(path.join(directory, old.token)), true);
  await restarted.query({action:'release', token:old.token});
  assert.equal(fs.existsSync(path.join(directory, old.token)), false);
  assert.equal(fs.existsSync(path.join(directory, latest.token)), true);
  assert.equal(fs.readdirSync(directory).filter(name => /^epg_[A-Za-z0-9_]+\.bin$/.test(name)).length, 8);
});
