'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const crypto = require('node:crypto');
const transportModule = require('../platform/transport.js');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const build = JSON.parse(fs.readFileSync(path.resolve(__dirname,'../../output/samsung-web/latest-build.json'),'utf8'));

function createTransport(environment, options = {}) {
  const sandbox = {console,setTimeout,clearTimeout,TextEncoder,TextDecoder};
  sandbox.self=sandbox;sandbox.window=sandbox;
  vm.createContext(sandbox);
  for(const file of ['polyfills.js','canonical-core.js']) vm.runInContext(fs.readFileSync(path.join(build.payload,file),'utf8'),sandbox);
  const state = new Map();
  return transportModule.create(environment,{core:sandbox.TVBroCanonical,
    userState:{get:key=>state.get(key),set:(key,value)=>{state.set(key,value);return Promise.resolve();}},...options});
}

function environment(options = {}) {
  const state = {agents:[], xhrs:[]};
  const waiters = [];
  const agentWaiters = [];
  const websetting = options.noWebsetting ? null : {
    setUserAgentString(value, resolve, reject) {
      const call = {value, resolve, reject};
      state.agents.push(call);
      for (const waiter of agentWaiters.slice()) if (state.agents.length >= waiter.count) {
        agentWaiters.splice(agentWaiters.indexOf(waiter),1);waiter.resolve();
      }
      if (options.autoAgent) queueMicrotask(resolve);
    }
  };
  class XMLHttpRequest {
    constructor() {
      this.headers = {};
      this.aborts = 0;
      state.xhrs.push(this);
    }
    open(method, url, async) {
      this.openArgs = {method, url, async};
    }
    setRequestHeader(name, value) {
      this.headers[name.toLowerCase()] = value;
    }
    send(body) {
      this.sentBody = body;
      this.sent = true;
      for (const waiter of waiters.slice()) if (state.xhrs.filter(xhr=>xhr.sent).length >= waiter.count) {
        waiters.splice(waiters.indexOf(waiter),1);waiter.resolve();
      }
      if (options.autoResponse) queueMicrotask(() => this.respond(options.autoResponse(this)));
    }
    abort() {
      this.aborts += 1;
      if (this.onabort) this.onabort();
    }
    getAllResponseHeaders() {
      return 'Content-Type: application/json\r\nX-Cache: fixture\r\n'+(options.retryAfter ? 'Retry-After: '+options.retryAfter+'\r\n' : '')+
        Object.entries(this.responseHeaders || {}).map(([name,value]) => name+': '+value+'\r\n').join('');
    }
    getResponseHeader(name) {
      const key = Object.keys(this.responseHeaders || {}).find(key => key.toLowerCase() === name.toLowerCase());
      return key == null ? name.toLowerCase() === 'retry-after' ? options.retryAfter || null : null : this.responseHeaders[key];
    }
    beginHeaders(response = {}) {
      this.status = response.status == null ? 200 : response.status;
      this.responseURL = response.url || this.openArgs.url;
      this.responseHeaders = response.headers || {};
      this.readyState = 2;
      if (this.onreadystatechange) this.onreadystatechange();
    }
    respond(response = {}) {
      this.beginHeaders(response);
      if (this.aborts) return;
      this.bodyDelivered = true;
      this.responseText = response.body == null ? '{"ok":true}' : response.body;
      if (this.responseType === 'arraybuffer') {
        const bytes = Buffer.from(this.responseText);
        this.response = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        Object.defineProperty(this, 'responseText', {get() { throw new Error('InvalidStateError: binary response'); }});
      }
      this.responseURL = response.url || this.openArgs.url;
      if (this.onload) this.onload();
    }
  }
  return {
    state,
    agent(count) {
      if(state.agents.length >= count) return Promise.resolve();
      return new Promise(resolve=>agentWaiters.push({count,resolve}));
    },
    sent(count) {
      if(state.xhrs.filter(xhr=>xhr.sent).length >= count) return Promise.resolve();
      return new Promise(resolve=>waiters.push({count,resolve}));
    },
    value:{
      navigator:{userAgent:'Samsung SmartTV fixture'},
      tizen:websetting ? {websetting} : {},
      XMLHttpRequest,
      Blob,
      btoa: value => Buffer.from(value, 'binary').toString('base64')
    }
  };
}

function tick() {
  return new Promise(resolve => setImmediate(resolve));
}

test('native EPG inspects headers and downloads directly to disk without delivering an XHR body',async()=>{
  const env=environment({autoResponse:()=>({headers:{'Content-Length':String(40*1024*1024)}})}),downloads=[];
  const file={token:'epg_fixture_1.bin',size:40*1024*1024,at:Date.now()};
  const transport=createTransport(env.value,{epgFiles:{available:()=>true,download:async(request,entry,key)=>{downloads.push({request,key});return file;}}});
  const response=JSON.parse(await transport.request({url:'https://native-guide.test/guide',workload:'epg',epgDiskKey:'a'.repeat(64),maximumBodyBytes:512*1024*1024,maximumDecodedBytes:4096*1024*1024}));
  assert.deepEqual(response.bodyFile,file);assert.equal(downloads.length,1);
  assert.equal(env.state.xhrs[0].openArgs.method,'HEAD');assert.equal(env.state.xhrs[0].bodyDelivered,undefined);
  assert.equal(downloads[0].key,'a'.repeat(64));assert.equal(response.bodyBuffer,undefined);
});

test('a provider without HEAD support is inspected with a GET aborted at headers before native download',async()=>{
  const env=environment({autoResponse:xhr=>({status:xhr.openArgs.method==='HEAD'?405:200})});let downloads=0;
  const transport=createTransport(env.value,{epgFiles:{available:()=>true,download:async()=>{downloads++;return {token:'epg_fixture_1.bin',size:100,at:Date.now()};}}});
  const response=JSON.parse(await transport.request({url:'https://no-head-guide.test/guide',workload:'epg',epgDiskKey:'b'.repeat(64),maximumBodyBytes:512*1024*1024,maximumDecodedBytes:4096*1024*1024}));
  assert.equal(response.status,200);assert.deepEqual(env.state.xhrs.map(xhr=>xhr.openArgs.method),['HEAD','GET']);
  assert.ok(env.state.xhrs.every(xhr=>!xhr.bodyDelivered));assert.equal(downloads,1);
});

for(const status of [401,403,429])test('native EPG header refusal blocks download and retains provider status '+status,async()=>{
  const env=environment({autoResponse:()=>({status})});let downloads=0;
  const transport=createTransport(env.value,{epgFiles:{available:()=>true,download:async()=>{downloads++;throw Error('must not download');}}});
  const response=JSON.parse(await transport.request({url:'https://refused-native-'+status+'.test/guide',workload:'epg',epgDiskKey:'c'.repeat(64),maximumBodyBytes:512*1024*1024,maximumDecodedBytes:4096*1024*1024}));
  assert.equal(response.status,status);assert.equal(downloads,0);
});

test('disk chunk RPC bypasses network admission and transfers only its bounded buffer',async()=>{
  const env=environment(),bytes=new Uint8Array([1,2,3]);
  const transport=createTransport(env.value,{epgFiles:{available:()=>true,query:async args=>{assert.equal(args.count,3);return {bodyBuffer:bytes.buffer,eof:true};}}});
  const result=await transport.request({epgFile:{action:'read',token:'epg_fixture_1.bin',offset:0,count:3}},{binaryResponse:true});
  assert.deepEqual(new Uint8Array(result.bodyBuffer),bytes);assert.equal(env.state.xhrs.length,0);
});

test('native EPG service refusal retains Retry-After in the shared provider cooldown',async()=>{
  const saved=new Map(),userState={get:key=>saved.get(key),set:(key,value)=>{saved.set(key,value);return Promise.resolve();}};
  const env=environment({autoResponse:()=>({})});
  const failure=Object.assign(Error('private provider detail'),{status:429,retryAfter:'900'});
  const transport=createTransport(env.value,{userState,epgFiles:{available:()=>true,download:async()=>{throw failure;}}});
  const url='https://native-backoff.test/guide';
  const response=JSON.parse(await transport.request({url,workload:'epg',epgDiskKey:'d'.repeat(64),
    maximumBodyBytes:512*1024*1024,maximumDecodedBytes:4096*1024*1024}));
  assert.equal(response.status,429);
  assert.equal(response.headers['retry-after'],'900');
  assert.doesNotMatch(JSON.stringify(response),/private provider detail/);
  await tick();
  const key=crypto.createHash('sha256').update('native-backoff.test').digest('hex');
  assert.ok(JSON.parse(saved.get('provider_cooldowns_v1'))[key].until>=Date.now()+15*60*1000-5000);
});

for (const compressed of [false, true]) {
  test('EPG preserves XMLTV bytes, gzip=' + compressed, async () => {
    const xml = Buffer.from('<tv><channel id="pl"><display-name>Łódź</display-name></channel></tv>');
    const body = compressed ? require('node:zlib').gzipSync(xml) : xml;
    const env = environment({autoResponse: () => ({body})});
    const transport = createTransport(env.value);
    const response = JSON.parse(await transport.request({url:'https://guide.test/feed', workload:'epg', maximumDecodedBytes:1024}));
    assert.equal(response.status, 200);
    assert.equal(env.state.xhrs[0].responseType, 'arraybuffer');
    assert.deepEqual(Buffer.from(response.bodyBase64, 'base64'), body);
    assert.equal(response.decoded, true);
  });
}

test('0.1.31 binary EPG delivery avoids base64 on the UI thread', async () => {
  const body = require('node:zlib').gzipSync(Buffer.from('<tv/>'));
  const env = environment({autoResponse: () => ({body})});
  env.value.btoa = () => { throw Error('UI must not encode transferable guide bytes'); };
  const response = await createTransport(env.value).request({url:'https://guide.test/binary',workload:'epg',maximumDecodedBytes:1024}, {binaryResponse:true});
  assert.equal(response.status,200);
  assert.deepEqual(Buffer.from(response.bodyBuffer),body);
  assert.equal(response.bodyBase64,undefined);
});

test('binary EPG still enforces the response size limit', async () => {
  const env = environment({autoResponse: () => ({body:Buffer.alloc(1025)})});
  const transport = createTransport(env.value);
  const response = JSON.parse(await transport.request({url:'https://guide.test/large', workload:'epg', maximumDecodedBytes:1024}));
  assert.equal(response.errorKind, 'limit');
  assert.equal(response.bodyBase64, undefined);
});

test('an advertised oversized XMLTV aborts at headers without blocking a short guide request', async () => {
  const env = environment(), transport = createTransport(env.value);
  const pending = transport.request({url:'https://guide-size.test/xmltv.php',workload:'epg',maximumBodyBytes:33554432,maximumDecodedBytes:33554432});
  await env.sent(1);
  const xhr = env.state.xhrs[0];
  xhr.beginHeaders({headers:{'Content-Length':'33554433'}});
  assert.equal(JSON.parse(await pending).errorKind, 'limit');
  assert.equal(xhr.aborts, 1); assert.equal(xhr.bodyDelivered, undefined);
  const short = transport.request({url:'https://guide-size.test/player_api.php?action=get_short_epg',maximumDecodedBytes:1024});
  await env.sent(2); env.state.xhrs[1].respond({body:'{"epg_listings":[]}'});
  assert.equal(JSON.parse(await short).status, 200);
});

test('Content-Length uses the wire limit for compressed responses and the decoded limit only for identity', async () => {
  for (const [encoding,bodyLimit,decodedLimit,oversized] of [['gzip',2048,1024,false],['gzip',1024,2048,true],['identity',2048,1024,true]]) {
    const env = environment({autoResponse:() => ({headers:{'Content-Length':'1536','Content-Encoding':encoding},body:'<tv/>'})});
    const result = JSON.parse(await createTransport(env.value).request({url:'https://encoded-size.test/feed',workload:'epg',maximumBodyBytes:bodyLimit,maximumDecodedBytes:decodedLimit}));
    assert.equal(result.errorKind === 'limit', oversized);
    assert.equal(env.state.xhrs[0].aborts, oversized ? 1 : 0);
  }
});

test('missing, zero, chunked and invalid response lengths retain the actual body size check', async () => {
  for (const length of [undefined,'0','unknown','-1','1e9','1024, 1024']) {
    const headers = length == null ? {'Transfer-Encoding':'chunked'} : {'Content-Length':length};
    const env = environment({autoResponse:() => ({headers,body:'<tv/>'})});
    const result = JSON.parse(await createTransport(env.value).request({url:'https://unknown-size.test/feed',workload:'epg',maximumBodyBytes:16,maximumDecodedBytes:16}));
    assert.equal(result.status, 200); assert.equal(env.state.xhrs[0].aborts, 0);
  }
  const env = environment({autoResponse:() => ({body:Buffer.alloc(17)})});
  const result = JSON.parse(await createTransport(env.value).request({url:'https://unknown-size.test/feed',workload:'epg',maximumBodyBytes:16,maximumDecodedBytes:16}));
  assert.equal(result.errorKind, 'limit');
});

for (const status of [401,403,429]) test('oversized HTTP '+status+' retains its HTTP status and retry policy', async () => {
  const env = environment({autoResponse:() => ({status,headers:{'Content-Length':'33554433'}}),retryAfter:'600'});
  const transport = createTransport(env.value);
  const request = {url:'https://size-refusal-'+status+'.test/feed',workload:'epg',maximumBodyBytes:1024,maximumDecodedBytes:1024};
  const response = JSON.parse(await transport.request(request));
  assert.equal(response.status, status); assert.equal(response.errorKind, undefined);
  assert.equal(env.state.xhrs[0].aborts, 0);
  const repeated = JSON.parse(await transport.request(request));
  if (status === 403) {
    assert.equal(repeated.status, 403);
    assert.equal(repeated.errorKind, undefined);
    assert.equal(env.state.xhrs.length, 2);
  } else {
    assert.equal(repeated.errorKind, 'provider-blocked');
    assert.equal(env.state.xhrs.length, 1);
  }
});

function resolveAgent(state, index) {
  assert.ok(state.agents[index], 'expected a pending WebSetting call at index ' + index);
  state.agents[index].resolve();
}

function rejectAgent(state, index) {
  assert.ok(state.agents[index], 'expected a pending WebSetting call at index ' + index);
  state.agents[index].reject(new Error('WebSetting fixture failure'));
}

test('custom User-Agent uses a real GET XHR and never becomes a request header', async () => {
  const env = environment({autoAgent:true, autoResponse:() => ({body:'{"channels":2}'})});
  const transport = createTransport(env.value);
  const result = JSON.parse(await transport.request({
    workload:'stalker-json', url:'https://provider.test/portal.php?type=stb',
    headers:{'User-Agent':'TVBro custom', 'X-Trace':'fixture', Accept:'application/json'},
    maximumDecodedBytes:8192, totalTimeoutMs:60000, idleTimeoutMs:20000
  }));
  assert.equal(result.status, 200);
  assert.equal(result.body, '{"channels":2}');
  assert.equal(result.decoded, true);
  assert.equal(env.state.xhrs.length, 1);
  assert.deepEqual(env.state.xhrs[0].openArgs, {
    method:'GET', url:'https://provider.test/portal.php?type=stb', async:true
  });
  assert.equal(env.state.xhrs[0].sentBody, undefined);
  assert.equal(env.state.xhrs[0].headers.accept, 'application/json');
  assert.equal(env.state.xhrs[0].headers['x-trace'], 'fixture');
  assert.equal(Object.prototype.hasOwnProperty.call(env.state.xhrs[0].headers, 'user-agent'), false);
  assert.deepEqual(env.state.agents.map(call => call.value), ['TVBro custom', 'Samsung SmartTV fixture']);
});

test('serializes custom User-Agents and resets between physical requests', async () => {
  const env = environment();
  const transport = createTransport(env.value);
  const first = transport.request({url:'https://provider.test/one', headers:{'User-Agent':'Agent One'}});
  const second = transport.request({url:'https://provider.test/two', headers:{'User-Agent':'Agent Two'}});
  await tick();
  assert.deepEqual(env.state.agents.map(call => call.value), ['Agent One']);
  assert.equal(env.state.xhrs.length, 0);
  resolveAgent(env.state, 0);
  await env.sent(1);
  assert.equal(env.state.xhrs.length, 1);
  env.state.xhrs[0].respond({body:'{"n":1}'});
  await env.agent(2);
  assert.deepEqual(env.state.agents.map(call => call.value), ['Agent One', 'Samsung SmartTV fixture']);
  assert.equal(env.state.xhrs.length, 1);
  resolveAgent(env.state, 1);
  await env.agent(3);
  assert.deepEqual(env.state.agents.map(call => call.value), ['Agent One', 'Samsung SmartTV fixture', 'Agent Two']);
  assert.equal(env.state.xhrs.length, 1);
  resolveAgent(env.state, 2);
  await env.sent(2);
  assert.equal(env.state.xhrs.length, 2);
  env.state.xhrs[1].respond({body:'{"n":2}'});
  await env.agent(4);
  assert.deepEqual(env.state.agents.map(call => call.value), [
    'Agent One', 'Samsung SmartTV fixture', 'Agent Two', 'Samsung SmartTV fixture'
  ]);
  resolveAgent(env.state, 3);
  assert.equal(JSON.parse(await first).body, '{"n":1}');
  assert.equal(JSON.parse(await second).body, '{"n":2}');
  assert.equal(env.state.xhrs.every(xhr => !Object.prototype.hasOwnProperty.call(xhr.headers, 'user-agent')), true);
});

test('failed User-Agent reset is retried before the next GET', async () => {
  const env = environment();
  const transport = createTransport(env.value);
  const first = transport.request({url:'https://provider.test/first', headers:{'User-Agent':'Custom'}});
  await tick();
  resolveAgent(env.state, 0);
  await env.sent(1);
  env.state.xhrs[0].respond();
  await env.agent(2);
  assert.equal(env.state.agents[1].value, 'Samsung SmartTV fixture');
  rejectAgent(env.state, 1);
  const failed = JSON.parse(await first);
  assert.equal(failed.errorKind, 'capability');
  assert.equal(env.state.xhrs.length, 1);

  const second = transport.request({url:'https://provider.test/recovery'});
  await env.agent(3);
  assert.equal(env.state.agents[2].value, 'Samsung SmartTV fixture');
  assert.equal(env.state.xhrs.length, 1);
  resolveAgent(env.state, 2);
  await env.sent(2);
  assert.equal(env.state.xhrs.length, 2);
  env.state.xhrs[1].respond({body:'{"recovered":true}'});
  assert.match(await second, /recovered/);
  assert.equal(env.state.xhrs[1].openArgs.url, 'https://provider.test/recovery');
});

test('abort cancels the active XHR and queued GET without leaving the agent queue poisoned', async () => {
  const env = environment();
  const transport = createTransport(env.value);
  const first = transport.request({url:'https://provider.test/active', headers:{'User-Agent':'Custom'}});
  await tick();
  resolveAgent(env.state, 0);
  await env.sent(1);
  assert.equal(env.state.xhrs.length, 1);
  const queued = transport.request({url:'https://provider.test/queued'});
  transport.abort();
  assert.equal(env.state.xhrs[0].aborts, 1);
  await env.agent(2);
  assert.equal(env.state.agents[1].value, 'Samsung SmartTV fixture');
  resolveAgent(env.state, 1);
  const firstResult = JSON.parse(await first);
  const queuedResult = JSON.parse(await queued);
  assert.equal(firstResult.errorKind, 'cancelled');
  assert.equal(queuedResult.errorKind, 'cancelled');
  assert.match(queuedResult.error, /anulowano/i);
  assert.equal(env.state.xhrs.length, 1);

  const later = transport.request({url:'https://provider.test/after-abort'});
  await env.sent(2);
  assert.equal(env.state.xhrs.length, 2);
  env.state.xhrs[1].respond({body:'{"later":true}'});
  assert.match(await later, /later/);
  transport.abort();
  assert.equal(env.state.xhrs[1].aborts, 0);
});

test('cookies require an authorized Stalker relay; ordinary M3U and video never use it', async () => {
  let relayCalls = [];
  const relay = {
    relayConfigured:true,
    relayProvider(request) {
      relayCalls.push(request);
      return Promise.resolve('{"status":200,"body":"{}","headers":{},"url":"https://provider.test/portal.php","decoded":true}');
    }
  };
  const noOptIn = environment({noWebsetting:true});
  const direct = createTransport(noOptIn.value, {relay:{relayConfigured:false, relayProvider:relay.relayProvider}});
  const blocked = JSON.parse(await direct.request({
    workload:'stalker-json', url:'https://provider.test/portal.php', headers:{Cookie:'mac=fixture'}
  }));
  assert.equal(blocked.errorKind, 'capability');
  assert.equal(relayCalls.length, 0);
  assert.equal(direct.capabilities().cookies, false);

  const opted = createTransport(noOptIn.value, {relay});
  const relayed = JSON.parse(await opted.request({
    workload:'stalker-json', url:'https://provider.test/portal.php', headers:{Cookie:'mac=fixture'}
  }));
  assert.equal(relayed.status, 200);
  assert.equal(relayCalls.length, 1);
  assert.equal(relayCalls[0].workload, 'stalker-json');
  assert.equal(opted.capabilities().cookies, true);

  const m3u = JSON.parse(await opted.request({
    workload:'provider-json', url:'https://provider.test/playlist.m3u', headers:{Cookie:'mac=fixture'}
  }));
  const video = JSON.parse(await opted.request({
    workload:'video', url:'https://provider.test/movie.ts', headers:{Cookie:'mac=fixture'}
  }));
  assert.equal(m3u.errorKind, 'capability');
  assert.equal(video.errorKind, 'capability');
  assert.equal(relayCalls.length, 1);
});

test('a custom User-Agent may relay only for Stalker JSON when WebSetting is unavailable', async () => {
  const env = environment({noWebsetting:true});
  const calls = [];
  const transport = createTransport(env.value, {relay:{
    relayConfigured:true,
    relayProvider(request) { calls.push(request); return Promise.resolve('{"status":200,"body":"{}","headers":{},"url":"x","decoded":true}'); }
  }});
  const response = JSON.parse(await transport.request({
    workload:'stalker-json', url:'https://provider.test/load.php', headers:{'User-Agent':'Portal Agent'}
  }));
  assert.equal(response.status, 200);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].headers['User-Agent'], 'Portal Agent');
  const other = JSON.parse(await transport.request({
    workload:'provider-json', url:'https://provider.test/load.php', headers:{'User-Agent':'Portal Agent'}
  }));
  assert.equal(other.errorKind, 'capability');
  assert.equal(calls.length, 1);
  assert.equal(env.state.xhrs.length, 0);
});

for (const status of [401,429,503]) test('provider '+status+' stops a burst before physical HTTP and persists the cooldown',async()=>{
  const saved=new Map();
  const userState={get:key=>saved.get(key),set:(key,value)=>{saved.set(key,value);return Promise.resolve();}};
  const env=environment({autoResponse:()=>({status}),retryAfter:'600'});
  const transport=createTransport(env.value,{userState});
  const request={url:'https://cooldown-'+status+'.fixture/catalog',totalTimeoutMs:5000};
  assert.equal(JSON.parse(await transport.request(request)).status,status);
  const burst=await Promise.all(Array.from({length:30},()=>transport.request(request)));
  assert.ok(burst.every(raw=>JSON.parse(raw).errorKind==='provider-blocked'));
  assert.equal(env.state.xhrs.length,1);
  assert.ok(saved.get('provider_cooldowns_v1'));
  const restarted=createTransport(env.value,{userState});
  assert.equal(JSON.parse(await restarted.request(request)).errorKind,'provider-blocked');
  assert.equal(env.state.xhrs.length,1);
});
test('HTTP 403 allows another physical request and ignores an old cooldown after restart', async () => {
  const host = 'cooldown-403.fixture';
  const key = require('node:crypto').createHash('sha256').update(host).digest('hex');
  const saved = new Map([['provider_cooldowns_v1', JSON.stringify({
    [key]: {status:403,until:Date.now()+600000}
  })]]);
  const userState = {get:key=>saved.get(key),set:(key,value)=>{saved.set(key,value);return Promise.resolve();}};
  let requests = 0;
  const env = environment({autoResponse:()=>({status:++requests === 1 ? 403 : 200}),retryAfter:'600'});
  const transport = createTransport(env.value,{userState});
  const request = {url:'https://'+host+'/catalog',totalTimeoutMs:5000};
  assert.equal(JSON.parse(await transport.request(request)).status,403);
  assert.equal(JSON.parse(await transport.request(request)).status,200);
  const restarted = createTransport(env.value,{userState});
  assert.equal(JSON.parse(await restarted.request(request)).status,200);
  assert.equal(env.state.xhrs.length,3);
});

test('stream HTTP 403 does not block later streams', async () => {
  const env = environment({autoAgent:true});
  const transport = createTransport(env);
  await transport.checkStream('https://stream-refusal.test/live');
  transport.recordStreamRefusal('https://stream-refusal.test/live', 403);
  await transport.checkStream('https://stream-refusal.test/another');
  await transport.checkStream('https://another-provider.test/live');
  assert.equal(env.state.xhrs.length, 0);
});

test('hosted Titan blocks physical HTTP before XHR while HTTPS and the explicit Stalker relay remain available',async()=>{
  const message='This provider uses HTTP. This TV version needs HTTPS. Ask your provider for an HTTPS address or use TVBro on Android, Windows or Samsung.';
  const http=environment({autoResponse:()=>({status:200,body:'unexpected'})});
  const hosted=createTransport(http.value,{requiresHttpsProvider:true});
  const blocked=JSON.parse(await hosted.request({url:'http://provider.test/catalog'}));
  assert.equal(blocked.errorKind,'hosted-http-blocked');assert.equal(blocked.error,message);
  assert.equal(http.state.xhrs.length,0,'HTTP must be rejected before XHR is constructed or sent');

  const https=environment({autoResponse:()=>({status:200,body:'ok'})});
  const secure=createTransport(https.value,{requiresHttpsProvider:true});
  assert.equal(JSON.parse(await secure.request({url:'https://provider.test/catalog'})).status,200);
  assert.equal(https.state.xhrs.length,1);

  const relayed=environment(),calls=[];
  const relay=createTransport(relayed.value,{requiresHttpsProvider:true,relay:{relayConfigured:true,relayProvider(request){
    calls.push(request);return Promise.resolve(JSON.stringify({status:200,body:'{}',headers:{},url:request.url,decoded:true}));
  }}});
  assert.equal(JSON.parse(await relay.request({workload:'stalker-json',url:'http://portal.test/load.php',headers:{Cookie:'mac=fixture'}})).status,200);
  assert.equal(calls.length,1);assert.equal(relayed.state.xhrs.length,0);

  const native=environment({autoResponse:()=>({status:200,body:'ok'})});
  assert.equal(JSON.parse(await createTransport(native.value).request({url:'http://native.test/catalog'})).status,200);
  assert.equal(native.state.xhrs.length,1,'native Samsung/LG transport remains unchanged');
});
