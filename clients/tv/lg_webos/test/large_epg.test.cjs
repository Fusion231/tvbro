'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const vm = require('node:vm');
const {pipeline} = require('node:stream/promises');
const zlib = require('node:zlib');
const {createRequire} = require('node:module');
const createEpgFiles = require('../platform/epg_files.js').create;
const epgService = require('../epg_service/service.js');
const createStore = require('../epg_service/store.js').create;
const sharedRequire = createRequire(path.resolve(__dirname, '../../samsung_web/package.json'));
const coreFile = path.resolve(__dirname, '../../output/samsung-web/core/core.js');
const gzipFile = path.resolve(__dirname, '../../samsung_web/platform/streaming_gzip.js');
const MiB = 1024 * 1024;
const keyPattern = /^[a-f0-9]{64}$/;
const configBase = {id:'disk-guide', kind:'m3u', fields:{playlistUrl:'https://fixture.test/list'}};
const channelArgs = {channels:[{id:'target', name:'Target', extra:{tvgId:'target'}}],
  _tvEpgDisk:true, _tvEpgScope:'large-guide-test-profile'};
const selectedProgramme = '<programme channel="target" start="20261107100000 +0000" stop="20261107110000 +0000"><title>Selected programme</title></programme>';

function temporaryDirectory(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'tvbro-lg-large-epg-'));
  t.after(() => {
    assert.ok(fs.realpathSync(directory).startsWith(fs.realpathSync(os.tmpdir()) + path.sep));
    assert.ok(path.basename(directory).startsWith('tvbro-lg-large-epg-'));
    fs.rmSync(directory, {recursive:true, force:true});
  });
  return directory;
}

function writeLargeGuide(directory) {
  const file = path.join(directory, 'guide.xml');
  const fd = fs.openSync(file, 'w');
  const noise = Buffer.from(('<programme channel="other" start="20261107100000 +0000" stop="20261107110000 +0000"><title>' +
    'x'.repeat(300) + '</title></programme>').repeat(512));
  try {
    fs.writeSync(fd, '<tv><channel id="target"><display-name>Target</display-name></channel>' + selectedProgramme);
    for (let size = 0; size < 40 * MiB; size += noise.length) fs.writeSync(fd, noise);
    fs.writeSync(fd, '</tv>');
  } finally { fs.closeSync(fd); }
  assert.ok(fs.statSync(file).size > 32 * MiB);
  return file;
}

async function gzipGuide(file) {
  const compressed = file + '.gz';
  await pipeline(fs.createReadStream(file), zlib.createGzip(), fs.createWriteStream(compressed));
  assert.ok(fs.statSync(compressed).size < 32 * MiB);
  return compressed;
}

function closeServer(server) {
  return server.listening ? new Promise((resolve) => server.close(resolve)) : Promise.resolve();
}

function startService(directory) {
  const handlers = Object.create(null);
  const calls = {reads:0, maximumRead:0};
  let requestId = 0;
  function FakeService(id) {
    assert.equal(id, epgService.serviceId);
    this.register = function (method, handler, cancel) {
      handlers[method] = {handler, cancel};
      return handlers[method];
    };
  }
  epgService.start(FakeService, createStore({directory}));
  const environment = {
    atob: (value) => Buffer.from(value, 'base64').toString('binary'),
    webOS: {service: {request(uri, options) {
      assert.equal(uri, 'luna://online.tvbro.webos.epg/');
      const registration = handlers[options.method];
      assert.ok(registration, 'service method must be registered');
      const parameters = options.parameters || {};
      if (options.method === 'query' && parameters.action === 'read') {
        calls.reads++;
        calls.maximumRead = Math.max(calls.maximumRead, parameters.count);
      }
      const message = {payload:parameters, sender:epgService.appId,
        isSubscription:options.subscribe === true,
        uniqueToken:options.subscribe ? 'integration-' + (++requestId) : undefined,
        respond(response) {
          if (response && response.returnValue === true) options.onSuccess(response);
          else options.onFailure(response || {returnValue:false, errorKind:'storage'});
        }};
      Promise.resolve().then(() => registration.handler(message)).catch(() => {
        options.onFailure({returnValue:false, errorKind:'storage'});
      });
      return {cancel() { if (registration.cancel) registration.cancel(message); }};
    }}}
  };
  return {environment, adapter:createEpgFiles({environment}), calls};
}

function createCore(config, adapter, networkState) {
  const sandbox = {console, setTimeout, clearTimeout, TextEncoder, TextDecoder,
    btoa, atob, pako:sharedRequire('pako')};
  sandbox.self = sandbox.window = sandbox;
  vm.createContext(sandbox);
  if (fs.existsSync(gzipFile)) vm.runInContext(fs.readFileSync(gzipFile, 'utf8'), sandbox);
  vm.runInContext(fs.readFileSync(coreFile, 'utf8'), sandbox, {filename:'canonical-core.js'});
  const source = sandbox.TVBroCanonical.createSource(JSON.stringify(config), async (raw) => {
    const request = JSON.parse(raw);
    if (request.epgFile) {
      networkState.events.push('file:' + request.epgFile.action);
      const result = await adapter.query(request.epgFile);
      if (result && result.bodyBuffer) {
        assert.ok(result.bodyBuffer.byteLength <= 65536);
        return JSON.stringify({bodyBase64:Buffer.from(result.bodyBuffer).toString('base64'), eof:result.eof});
      }
      return JSON.stringify(result);
    }
    if (request.workload === 'epg') {
      networkState.events.push('download:start');
      assert.equal(request.maximumBodyBytes, 512 * MiB);
      assert.equal(request.maximumDecodedBytes, 4096 * MiB);
      assert.match(request.epgDiskKey, keyPattern);
      networkState.request = {totalTimeoutMs:request.totalTimeoutMs,
        maximumBodyBytes:request.maximumBodyBytes, maximumDecodedBytes:request.maximumDecodedBytes};
      networkState.diskKey = request.epgDiskKey;
      let file;
      try { file = await adapter.download(request, {}, request.epgDiskKey); }
      catch (error) { networkState.error = {name:error.name, message:error.message, status:error.status}; throw error; }
      assert.deepEqual(Object.keys(file).sort(), ['at', 'size', 'token']);
      networkState.fileReceipts.push(file);
      networkState.downloadCalls++;
      networkState.events.push('download:complete');
      return JSON.stringify({status:200, headers:{}, url:request.url, decoded:true, bodyFile:file});
    }
    return JSON.stringify({status:200, headers:{}, url:request.url, body:''});
  });
  return {source, invoke:async () => JSON.parse(await source.invoke('epg', JSON.stringify(channelArgs)))};
}

async function runGuideCase(t, gzip) {
  const directory = temporaryDirectory(t);
  const plainFile = writeLargeGuide(directory);
  const servedFile = gzip ? await gzipGuide(plainFile) : plainFile;
  const serverState = {requests:0};
  const server = http.createServer((request, response) => {
    serverState.requests++;
    response.writeHead(200, {'content-type':gzip ? 'application/gzip' : 'application/xml', 'connection':'close'});
    fs.createReadStream(servedFile).pipe(response);
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const url = 'http://127.0.0.1:' + server.address().port + '/guide.xml';
  const config = {...configBase, fields:{...configBase.fields, epgUrl:url}};
  const serviceDirectory = path.join(directory, 'service-data');
  fs.mkdirSync(serviceDirectory);
  const calls = {diskKey:null, downloadCalls:0, fileReceipts:[], events:[]};
  let active = startService(serviceDirectory);
  const adapters = [active.adapter];
  try {
  assert.equal(active.adapter.available(), true);
  const first = createCore(config, active.adapter, calls);
  try {
    const programmes = await first.invoke();
    assert.ok(Array.isArray(programmes), JSON.stringify({programmes, events:calls.events, http:serverState.requests,
      error:calls.error, request:calls.request}));
    assert.equal(programmes.length, 1);
    assert.equal(programmes[0].channelId, 'target');
    assert.equal(programmes[0].title, 'Selected programme');
    assert.ok(active.calls.reads > 0);
    assert.equal(active.calls.maximumRead, 65536);
    assert.equal(calls.downloadCalls, 1);
    assert.equal(serverState.requests, 1);
    assert.equal(calls.fileReceipts[0].size, fs.statSync(servedFile).size);
    const committed = await active.adapter.query({action:'lookup', key:calls.diskKey});
    assert.ok(committed && committed.token === calls.fileReceipts[0].token);
    assert.equal(committed.size, fs.statSync(servedFile).size);
  } finally { await first.source.dispose(); }

  await closeServer(server);
  active = startService(serviceDirectory);
  adapters.push(active.adapter);
  const cold = createCore(config, active.adapter, calls);
  try {
    const programmes = await cold.invoke();
    assert.equal(programmes.length, 1);
    assert.equal(programmes[0].channelId, 'target');
    assert.equal(programmes[0].title, 'Selected programme');
    assert.equal(serverState.requests, 1, 'committed EPG bytes reopen from the new service while HTTP is offline');
    assert.equal(calls.downloadCalls, 1, 'offline cache lookup avoids a service download request');
    assert.ok(active.calls.reads > 0);
    assert.equal(active.calls.maximumRead, 65536);
  } finally { await cold.source.dispose(); }
  } finally {
    await Promise.all(adapters.map((adapter) => adapter.abort()));
    await closeServer(server);
  }
}

test('LG service and adapter stream a plain XMLTV file larger than 32 MiB through the canonical parser', async (t) => {
  await runGuideCase(t, false);
});

test('LG service and adapter stream a gzip guide expanding beyond 32 MiB through the canonical parser', async (t) => {
  await runGuideCase(t, true);
});
