'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const {createRequire} = require('node:module');
const {start, serviceId, appId, storeDirectory} = require('../epg_service/service.js');
const acorn = createRequire(path.resolve(__dirname, '../../samsung_web/package.json'))('acorn');

function serviceFixture(store, metadataHttp) {
  const methods = Object.create(null);
  function Service(id) { this.id = id; }
  Service.prototype.register = function (name, request, cancel) {
    methods[name] = {request, cancel};
    return methods[name];
  };
  const instance = start(Service, store, metadataHttp);
  return {methods, instance};
}

function message(sender, payload = {}, extra = {}) {
  return Object.assign({sender, payload, uniqueToken:'request-1', isSubscription:false,
    responses:[], respond(value) { this.responses.push(value); }}, extra);
}

async function turn() { await new Promise(resolve => setImmediate(resolve)); }

test('the packaged service registers its methods when the webOS launcher requires its entry point', () => {
  const directory = path.resolve(__dirname, '../epg_service');
  const main = JSON.parse(fs.readFileSync(path.join(directory, 'package.json'), 'utf8')).main;
  const methods = [], loaded = {exports:{}};
  function Service(id) { assert.equal(id, serviceId); }
  Service.prototype.register = function (name) { methods.push(name); };
  function serviceRequire(name) {
    if (name === 'webos-service') return Service;
    return require(path.resolve(directory, name));
  }
  serviceRequire.main = {filename:'bootstrap-node.js'};
  const entry = vm.runInThisContext('(function(require,module,exports){\n' +
    fs.readFileSync(path.join(directory, main), 'utf8') + '\n})', {filename:main});
  entry(serviceRequire, loaded, loaded.exports);
  if (loaded.exports.run) loaded.exports.run(serviceId);
  assert.deepEqual(methods.sort(), ['abort', 'available', 'download', 'query', 'requestMetadata']);
});

test('service registration uses the app-prefixed identity and the jailed service directory', () => {
  const fixture = serviceFixture({available:() => true});
  assert.equal(serviceId, 'online.tvbro.webos.epg');
  assert.equal(appId, 'online.tvbro.webos');
  assert.equal(storeDirectory, '/media/internal/online.tvbro.webos.epg');
  assert.equal(fixture.instance.id, serviceId);
  assert.deepEqual(Object.keys(fixture.methods).sort(), ['abort', 'available', 'download', 'query', 'requestMetadata']);
});

test('service and adapter sources parse at the webOS Node 0.12 ES5 syntax floor', () => {
  for (const relative of ['../epg_service/service.js', '../epg_service/store.js', '../epg_service/metadata_http.js', '../platform/epg_files.js']) {
    acorn.parse(fs.readFileSync(path.resolve(__dirname, relative), 'utf8'), {ecmaVersion:5});
  }
});

test('the metadata method is app-bound, subscribed, cancellable, and keeps provider data out of errors', async () => {
  let reject;
  let cancelled = 0;
  const service = serviceFixture({available:() => true, query:() => Promise.resolve(null), abort:() => Promise.resolve()}, {
    request() { return {promise:new Promise((resolve, failure) => { reject = failure; }), cancel() { cancelled++; }}; }
  });
  const foreign = message('another.app', {}, {isSubscription:true, uniqueToken:'meta-foreign'});
  service.methods.requestMetadata.request(foreign);
  assert.deepEqual(foreign.responses, [{returnValue:false, errorKind:'invalid'}]);
  assert.equal(reject, undefined);

  const pending = message(appId, {url:'https://api.themoviedb.org/3/movie/1', method:'GET'},
    {isSubscription:true, uniqueToken:'meta-1'});
  service.methods.requestMetadata.request(pending);
  assert.equal(typeof reject, 'function');
  service.methods.requestMetadata.cancel(message(appId, {}, {uniqueToken:'meta-1'}));
  assert.equal(cancelled, 1);
  reject(Object.assign(new Error('credential https://provider.invalid/?api_key=private'), {kind:'network'}));
  await turn();
  assert.deepEqual(pending.responses, [], 'a cancelled provider request has no late service reply');
});

test('service rejects missing and foreign app senders before exposing any file operation', async () => {
  const calls = [];
  const fixture = serviceFixture({available:() => { calls.push('available'); return true; },
    download:() => { calls.push('download'); return Promise.resolve({token:'epg_1_0.bin', size:1, at:1}); },
    query:() => { calls.push('query'); return Promise.resolve(null); },
    abort:() => { calls.push('abort'); return Promise.resolve(); }, cancel() { calls.push('cancel'); }});
  for (const sender of [undefined, 'online.tvbro.webos.other', 'another.app']) {
    const response = message(sender);
    fixture.methods.query.request(response);
    assert.deepEqual(response.responses, [{returnValue:false, errorKind:'invalid'}]);
    const stopped = message(sender);
    fixture.methods.abort.request(stopped);
    assert.deepEqual(stopped.responses, [{returnValue:false, errorKind:'invalid'}]);
  }
  assert.deepEqual(calls, []);
});

test('authorized service calls preserve the flat metadata and bounded read response contract', async () => {
  const fixture = serviceFixture({available:() => true,
    download:() => Promise.resolve({token:'epg_1000_0.bin', size:8, at:1000}),
    query:args => args.action === 'read' ? Promise.resolve({bodyBase64:'AQID', eof:false}) : Promise.resolve(null),
    abort:() => Promise.resolve()});
  const downloaded = message(appId, {key:'a'.repeat(64)}, {isSubscription:true});
  fixture.methods.download.request(downloaded);
  await turn();
  assert.deepEqual(downloaded.responses, [{returnValue:true, token:'epg_1000_0.bin', size:8, at:1000}]);
  const read = message(appId, {action:'read', token:'epg_1000_0.bin', offset:0, count:3});
  fixture.methods.query.request(read);
  await turn();
  assert.deepEqual(read.responses, [{returnValue:true, bodyBase64:'AQID', eof:false}]);
});

test('canceling a subscribed download stops its store job and suppresses a late response', async () => {
  let reject;
  const calls = [];
  const fixture = serviceFixture({available:() => true,
    download:() => new Promise((resolve, failure) => { reject = failure; }),
    query:() => Promise.resolve(null), abort:() => Promise.resolve(),
    cancel(id) { calls.push(id); }});
  const pending = message(appId, {key:'b'.repeat(64)}, {uniqueToken:'download-7', isSubscription:true});
  fixture.methods.download.request(pending);
  fixture.methods.download.cancel(message(appId, {}, {uniqueToken:'download-7'}));
  reject(Object.assign(new Error('provider secret'), {kind:'cancelled'}));
  await turn();
  assert.deepEqual(calls, ['download-7']);
  assert.deepEqual(pending.responses, []);
});
