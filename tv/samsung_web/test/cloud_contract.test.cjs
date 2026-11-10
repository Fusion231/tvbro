'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {webcrypto} = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const babel = require('@babel/core');
const presetEnv = require('@babel/preset-env');
const createCloud = require('../platform/cloud.js').create;
const createSecureStore = require('../platform/secure_store.js').create;
const createUserState = require('../platform/user_state.js').create;
const extractPanelCrypto = require('../tools/extract_cloud_crypto.cjs');

const cryptoFixtures = JSON.parse(fs.readFileSync(path.join(__dirname, '../../../test/fixtures/crypto_vectors.json'), 'utf8'));
const project = path.resolve(__dirname, '..');
const output = path.resolve(project, '../output/samsung-web');
const build = JSON.parse(fs.readFileSync(path.join(output, 'latest-build.json'), 'utf8'));
const payload = process.env.TVBRO_SAMSUNG_TEST_PAYLOAD || build.payload;

function canonicalCore() {
  const sandbox = {console, crypto:webcrypto, setTimeout, clearTimeout, TextEncoder, TextDecoder};
  sandbox.window = sandbox;
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(payload, 'canonical-core.js'), 'utf8'), sandbox,
    {filename:'canonical-core.js'});
  return sandbox.TVBroCanonical;
}

const core = canonicalCore();

const deviceId = '7f4fc8ed-5ec6-4601-9e9a-2d3396547771';
const profileId = 'f1d7e5d2-1e02-4e4c-8d29-11b4f11a0502';
const sourceId = '90a03a25-9dbf-43c2-a0ab-66737e7f4301';

function keyManagerState(initial = {}) {
  const records = new Map(Object.keys(initial).length ? [['tvbro_user_state_v1', JSON.stringify(initial)]] : []);
  const keymanager = {
    getData({name}) {
      if (!records.has(name)) throw Object.assign(new Error('not found'), {name:'NotFoundError'});
      return records.get(name);
    },
    getDataAliasList() { return [...records.keys()].map(name => ({name, packageId:'TVBroWebTV'})); },
    saveData(name, rawData, password, success, failure) {
      assert.equal(password, null);
      queueMicrotask(() => {
        if (records.has(name)) return failure(Object.assign(new Error('alias already exists'), {name:'UnknownError'}));
        records.set(name, rawData);
        success();
      });
    },
    removeData({name}) {
      if (!records.delete(name)) throw Object.assign(new Error('not found'), {name:'NotFoundError'});
    }
  };
  const tizen = {keymanager, package:{getPackageInfo() { return {id:'TVBroWebTV'}; }}};
  const reload = () => createUserState({store:createSecureStore({tizen})});
  return Object.assign(reload(), {reload});
}

function fixture(route, options = {}) {
  const state = options.state || keyManagerState();
  const calls = [];
  class XMLHttpRequest {
    open(method, url, async) {
      this.method = method;
      this.url = url;
      assert.equal(async, true);
    }
    setRequestHeader(name, value) {
      this.headers = this.headers || {};
      this.headers[name.toLowerCase()] = value;
    }
    getResponseHeader(name) { return this.responseHeaders && this.responseHeaders[name.toLowerCase()] || null; }
    send(rawBody) {
      let body = null;
      if (rawBody) body = JSON.parse(rawBody);
      const call = {method:this.method, url:this.url, body, headers:this.headers || {}};
      calls.push(call);
      const response = route(call) || {status:404, body:{code:'PGRST202'}};
      this.responseHeaders = response.headers || {};
      queueMicrotask(() => {
        this.status = response.status == null ? 200 : response.status;
        this.responseText = this.status === 204 || response.body == null ? '' : JSON.stringify(response.body);
        if (this.onload) this.onload();
      });
    }
  }
  const api = createCloud({
    core,
    config:options.config || {apiUrl:'https://api.tvbro.test', panelUrl:'https://panel.tvbro.test/', anonKey:'public-fixture'},
    userState:state,
    XMLHttpRequest,
    crypto:options.crypto || webcrypto,
    now:options.now,
    cryptoProtocol:options.cryptoProtocol
  });
  return {api, state, calls};
}

function extractedCryptoProtocol() {
  const outputDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tvbro-cloud-protocol-'));
  const previous = global.TVBroPanelCrypto;
  try {
    delete global.TVBroPanelCrypto;
    const result = extractPanelCrypto(babel, presetEnv, path.resolve(__dirname, '..'), outputDir);
    require(result.path);
    return global.TVBroPanelCrypto;
  } finally {
    if (previous === undefined) delete global.TVBroPanelCrypto;
    else global.TVBroPanelCrypto = previous;
    fs.rmSync(outputDir, {recursive:true, force:true});
  }
}

function authenticatedState(extra = {}) {
  return keyManagerState({
    supabase_session:JSON.stringify({
      access_token:'access-fixture', refresh_token:'refresh-fixture', expires_at:4102444800,
      user:{id:deviceId}
    }),
    ...extra
  });
}

test('supporter API coalesces bursts, caches sequential reads and expires grants and failures', async () => {
  let now=Date.now(), fail=false;
  const kit=fixture(()=>fail ? {status:503,body:{message:'unavailable'}} : {body:{supported:true,valid_until:'2099-01-01T00:00:00Z'}},
    {state:authenticatedState(),now:()=>now});
  await Promise.all(Array.from({length:50},()=>kit.api.query('supporter.status')));
  for(let i=0;i<50;i++) await kit.api.query('supporter.status');
  assert.equal(kit.calls.length,1);
  const changed=await kit.api.query('supporter.status');changed.supported=false;
  assert.equal((await kit.api.query('supporter.status')).supported,true);
  now+=60000;fail=true;
  for(let i=0;i<20;i++) await assert.rejects(kit.api.query('supporter.status'));
  assert.equal(kit.calls.length,2);
  now+=15000;fail=false;
  assert.equal((await kit.api.query('supporter.status')).supported,true);
  assert.equal(kit.calls.length,3);
  now-=1;
  await kit.api.query('supporter.status');
  assert.equal(kit.calls.length,4,'clock rollback must expire the cache');
  await kit.api.query('unpair');
  const afterUnpair=kit.calls.length;
  await kit.api.query('supporter.status');
  assert.equal(kit.calls.length,afterUnpair+1);
});

test('pairing status coalesces automatic and manual checks and respects canonical Retry-After', async () => {
  let now=Date.now();
  const kit=fixture(()=>({status:429,headers:{'retry-after':'120'},body:{message:'slow down'}}),{state:authenticatedState(),now:()=>now});
  const results=await Promise.allSettled(Array.from({length:30},()=>kit.api.query('pairing.status',{code:'ABCD2345'})));
  assert.equal(kit.calls.length,1);
  assert.ok(results.every(row=>row.status==='rejected'&&row.reason.retryAt===now+120000));
  now+=119999;await assert.rejects(kit.api.query('pairing.status',{code:'ABCD2345'}));assert.equal(kit.calls.length,1);
  now++;await assert.rejects(kit.api.query('pairing.status',{code:'ABCD2345'}));assert.equal(kit.calls.length,2);
});

test('failed code renewal shares backoff instead of retrying on every UI tick', async () => {
  let now=Date.now();
  const kit=fixture(()=>({status:503,body:{message:'unavailable'}}),{state:authenticatedState(),now:()=>now});
  for(let i=0;i<20;i++)await assert.rejects(kit.api.query('pairing.start'));
  assert.equal(kit.calls.length,1);
  now+=5000;await assert.rejects(kit.api.query('pairing.start'));assert.equal(kit.calls.length,2);
  now+=5000;await assert.rejects(kit.api.query('pairing.start'));assert.equal(kit.calls.length,2,'second failure doubles the retry delay');
});

test('concurrent cloud status reads share HTTP without caching pairing or profile locks',async()=>{
  const kit=fixture(deviceRow,{state:authenticatedState()});
  await Promise.all(Array.from({length:50},()=>kit.api.query('status')));
  assert.equal(kit.calls.length,1);
  await kit.api.query('status');
  assert.equal(kit.calls.length,2,'subsequent status checks must see revocation');
});

function deviceRow(call) {
  if (call.method === 'GET' && call.url.includes('/rest/v1/devices?')) {
    return {body:[{device_uid:deviceId, owner:'owner-uuid', label:'TV', active_profile_id:profileId}]};
  }
}

test('status and pairing.get never create an anonymous account on the boot path', async () => {
  const kit = fixture(() => undefined);
  assert.equal(kit.api.configured, true);
  assert.deepEqual(await kit.api.query('status'), {
    configured:true, hasSession:false, paired:false, deviceId:null, profileId:null, e2eeSupported:false
  });
  assert.equal(await kit.api.query('pairing.get').then(value => value.hasSession), false);
  assert.deepEqual(await kit.api.query('supporter.status'), {
    status:'free', supported:false, device_limit:0, valid_until:null,
    activated_devices:[], selected_devices:[], billing_ready:false
  });
  assert.equal(kit.calls.length, 0);
});

test('placeholder API and panel configuration disables the cloud adapter', async () => {
  const kit = fixture(() => { throw new Error('network must not start'); }, {
    config:{apiUrl:'https://abc.com', panelUrl:'https://panel.tvbro.test', anonKey:'public-fixture'}
  });
  assert.equal(kit.api.configured, false);
  assert.match((await kit.api.status()).error, /placeholder/);
  await assert.rejects(kit.api.query('pairing.start'), {name:'ConfigurationError'});
  assert.equal(kit.calls.length, 0);
});

test('provider relay requires explicit build opt-in and creates an anonymous session only on request', async () => {
  const disabled = fixture(() => { throw new Error('relay must remain disabled'); });
  assert.equal(disabled.api.relayConfigured, false);
  await assert.rejects(disabled.api.relayProvider({workload:'stalker-json', url:'https://provider.test/portal.php'}),
    {name:'CloudCapabilityError'});
  assert.equal(disabled.calls.length, 0);

  const dto = {
    workload:'stalker-json', url:'https://provider.test/portal.php?type=stb&action=get_profile',
    headers:{Cookie:'mac=fixture', 'User-Agent':'TVBro fixture'}, maximumDecodedBytes:8192
  };
  const kit = fixture(call => {
    if (call.url.endsWith('/auth/v1/signup')) return {body:{
      access_token:'relay-access', refresh_token:'relay-refresh', expires_in:3600, user:{id:deviceId}
    }};
    if (call.url.endsWith('/tv/provider-request')) return {body:{
      status:200, body:'{"js":{"token":"metadata-only"}}', headers:{'content-type':'application/json'},
      url:dto.url, decoded:true
    }};
  }, {config:{apiUrl:'https://api.tvbro.test', panelUrl:'https://panel.tvbro.test', anonKey:'public-fixture', providerRelay:true}});
  assert.equal(kit.api.relayConfigured, true);
  assert.deepEqual(await kit.api.status().then(value => value.hasSession), false);
  assert.equal(kit.calls.length, 0);
  const result = JSON.parse(await kit.api.relayProvider(dto));
  assert.deepEqual(result, {
    status:200, body:'{"js":{"token":"metadata-only"}}', headers:{'content-type':'application/json'},
    url:dto.url, decoded:true
  });
  assert.equal(kit.calls.length, 2);
  assert.ok(kit.calls[0].url.endsWith('/auth/v1/signup'));
  const relay = kit.calls[1];
  assert.equal(relay.method, 'POST');
  assert.ok(relay.url.endsWith('/tv/provider-request'));
  assert.equal(relay.headers.authorization, 'Bearer relay-access');
  assert.deepEqual(relay.body, {
    workload:dto.workload, url:dto.url,
    headers:{cookie:'mac=fixture', 'user-agent':'TVBro fixture'}, maximumDecodedBytes:8192
  });
  assert.equal(JSON.stringify(relay.body).includes('relay-access'), false);
});

test('provider relay rejects non-Stalker and malformed DTOs before creating a session', async () => {
  const kit = fixture(() => { throw new Error('invalid relay DTO reached the network'); }, {
    config:{apiUrl:'https://api.tvbro.test', panelUrl:'https://panel.tvbro.test', anonKey:'public-fixture', providerRelay:true}
  });
  await assert.rejects(kit.api.relayProvider({workload:'provider-json', url:'https://provider.test/portal.php'}),
    {name:'ValidationError'});
  await assert.rejects(kit.api.relayProvider({workload:'stalker-json', method:'POST', url:'https://provider.test/portal.php'}),
    {name:'ValidationError'});
  await assert.rejects(kit.api.relayProvider({workload:'stalker-json', url:'http://user:secret@provider.test/portal.php'}),
    {name:'ValidationError'});
  await assert.rejects(kit.api.relayProvider({workload:'stalker-json', url:'https://provider.test/movie.mp4'}),
    {name:'ValidationError'});
  assert.equal(kit.api.hasSession(), false);
  assert.equal(kit.calls.length, 0);
});

test('provider relay exposes only a bounded server error code, never response details', async () => {
  const kit = fixture(call => {
    if (call.url.endsWith('/auth/v1/signup')) return {body:{
      access_token:'relay-access', refresh_token:'relay-refresh', expires_in:3600, user:{id:deviceId}
    }};
    if (call.url.endsWith('/tv/provider-request')) return {
      status:404, body:{error:'provider_relay_disabled', details:'https://provider.test/portal.php?token=do-not-echo'}
    };
  }, {config:{apiUrl:'https://api.tvbro.test', panelUrl:'https://panel.tvbro.test', anonKey:'public-fixture', providerRelay:true}});
  await assert.rejects(kit.api.relayProvider({workload:'stalker-json', url:'https://provider.test/portal.php'}), failure => {
    assert.equal(failure.code, 'provider_relay_disabled');
    assert.equal(failure.message.includes('provider.test'), false);
    assert.equal(failure.message.includes('do-not-echo'), false);
    return true;
  });
});

test('pairing.start creates and stores an anonymous session only after the explicit action', async () => {
  const kit = fixture(call => {
    if (call.url.endsWith('/auth/v1/signup')) return {body:{
      access_token:'new-access', refresh_token:'new-refresh', expires_in:3600,
      user:{id:deviceId}
    }};
    if (call.url.endsWith('/rest/v1/rpc/request_pairing')) return {body:[{
      code:'ABCD2345', expires_at:'2030-01-01T00:10:00Z'
    }]};
  });
  assert.equal(kit.api.hasSession(), false);
  const pairing = await kit.api.query('pairing.start', {label:'Living room', language:'pl'});
  assert.equal(pairing.code, 'ABCD2345');
  assert.equal(pairing.panelLink, 'https://panel.tvbro.test/?code=ABCD2345&lang=pl');
  assert.equal(kit.calls.length, 2);
  assert.equal(kit.calls[0].method, 'POST');
  assert.equal(kit.calls[0].url.endsWith('/auth/v1/signup'), true);
  assert.deepEqual(kit.calls[0].body, {data:{}});
  assert.deepEqual(kit.calls[1].body, {p_label:'Living room', p_language:'pl'});
  assert.equal(kit.calls[1].headers.authorization, 'Bearer new-access');
  assert.equal(JSON.parse(kit.state.get('supabase_session')).user.id, deviceId);
  assert.equal(kit.state.reload().get('supabase_session'), kit.state.get('supabase_session'));
});

test('pairing status and profile list use the existing device session without signup', async () => {
  const kit = fixture(call => {
    if (call.url.endsWith('/rest/v1/rpc/pairing_status')) return {body:true};
    if (deviceRow(call)) return deviceRow(call);
    if (call.url.includes('/rest/v1/profiles?')) return {body:[{
      id:profileId, name:'Home', position:0, updated_at:'2026-01-01T00:00:00Z', pin:null
    }]};
  }, {state:authenticatedState()});
  assert.equal(await kit.api.query('pairing.status', {code:'ABCD2345'}), true);
  const profiles = await kit.api.query('profiles.list');
  assert.equal(profiles.length, 1);
  assert.equal(profiles[0].id, profileId);
  assert.equal(kit.calls.some(call => call.url.endsWith('/auth/v1/signup')), false);
  assert.equal(kit.calls.every(call => call.headers.authorization === 'Bearer access-fixture'), true);
});

test('supporter.status reads only the server-issued supporter RPC and never creates a session', async () => {
  const kit = fixture(call => {
    if (call.url.endsWith('/rest/v1/rpc/get_supporter_status')) return {body:{
      status:'active', supported:true, device_limit:3, valid_until:'2030-01-01T00:00:00Z',
      activated_devices:[deviceId], selected_devices:[deviceId], billing_ready:false
    }};
  }, {state:authenticatedState()});
  const value = await kit.api.query('supporter.status');
  assert.equal(value.supported, true);
  assert.equal(value.device_limit, 3);
  assert.equal(kit.calls.length, 1);
  assert.deepEqual(kit.calls[0].body, {});
  assert.equal(kit.calls[0].url.endsWith('/rest/v1/rpc/get_supporter_status'), true);
});

test('profiles.select persists only after the owner-scoped server RPC succeeds', async () => {
  const kit = fixture(call => {
    if (deviceRow(call)) return deviceRow(call);
    if (call.url.endsWith('/rest/v1/rpc/set_device_profile')) return {status:204};
  }, {state:authenticatedState()});
  assert.deepEqual(await kit.api.query('profiles.select', {profileId}), {profileId});
  assert.equal(kit.state.get('cloud_profile_id'), profileId);
  const rpc = kit.calls.find(call => call.url.endsWith('/rest/v1/rpc/set_device_profile'));
  assert.deepEqual(rpc.body, {p_profile_id:profileId});
});

test('pull joins format-0 secret RPC data, fills missing credentials locally and returns profile snapshot', async () => {
  const kit = fixture(call => {
    if (deviceRow(call)) return deviceRow(call);
    if (call.url.endsWith('/rest/v1/rpc/set_device_profile')) return {status:204};
    if (call.url.endsWith('/rest/v1/rpc/get_crypto_state')) return {body:{enabled:false, ck_version:0}};
    if (call.url.endsWith('/rest/v1/rpc/get_secrets')) return {body:{
      sources:{[sourceId]:{format:0, payload:{username:'cloud-user', password:'cloud-pass', playlistUrl:'https://provider.test/list.m3u'}}},
      metadata:{format:0, payload:{tmdbApiKey:'cloud-tmdb'}}
    }};
    if (call.url.includes('/rest/v1/profiles?')) return {body:[{
      id:profileId, name:'Home', position:0, updated_at:'2026-01-01T00:00:00Z', pin:'pin-hash',
      favorites:[{source_id:sourceId, kind:'live', item_id:'station-1'}]
    }]};
    if (call.url.includes('/rest/v1/sources?')) return {body:[{
      id:sourceId, kind:'m3u', label:'News', position:0,
      fields:{host:'https://provider.test', username:'must-not-win', userAgent:'must-not-win'},
      settings:{streamExtension:'m3u8'}
    }]};
    if (call.url.includes('/rest/v1/metadata_configs?')) return {body:[{
      config:{provider:'tmdb', autoEnrich:true, tmdbApiKey:'must-not-win'}
    }]};
  }, {state:authenticatedState()});
  const snapshot = await kit.api.query('pull', {
    profileId,
    localSources:[{id:sourceId, fields:{epgUrl:'https://local.test/guide.xml', username:'local-user'}}],
    localMetadata:{tvdbApiKey:'local-tvdb'}
  });
  assert.equal(snapshot.profile.name, 'Home');
  assert.equal(snapshot.profile.pin, 'pin-hash');
  assert.deepEqual({...snapshot.sources[0].fields}, {
    host:'https://provider.test', username:'cloud-user', password:'cloud-pass',
    playlistUrl:'https://provider.test/list.m3u', epgUrl:'https://local.test/guide.xml'
  });
  assert.deepEqual(snapshot.metadata, {provider:'tmdb', autoEnrich:true, tmdbApiKey:'cloud-tmdb', tvdbApiKey:'local-tvdb'});
  assert.deepEqual(snapshot.favorites, [{source_id:sourceId, kind:'live', item_id:'station-1'}]);
  assert.deepEqual(snapshot.managedSourceIds, [sourceId]);
  assert.equal(kit.state.get('cloud_profile_id'), profileId);
  assert.equal(kit.state.get('cloud_source_ids'), sourceId);
});

test('push sends only broad fields to source/config rows and isolates format-0 credentials', async () => {
  const kit = fixture(call => {
    if (deviceRow(call)) return deviceRow(call);
    if (call.url.endsWith('/rest/v1/rpc/set_device_profile')) return {status:204};
    if (call.url.endsWith('/rest/v1/rpc/get_crypto_state')) return {body:{enabled:false, ck_version:0}};
    if (call.url.endsWith('/rest/v1/rpc/get_secrets')) return {body:{sources:{}, metadata:null}};
    if (call.url.includes('/rest/v1/rpc/push_')) return {status:204};
  }, {state:authenticatedState()});
  const result = await kit.api.query('push', {
    profileId,
    sources:[{id:sourceId, kind:'m3u', label:'News', fields:{host:'https://provider.test', playlistUrl:'https://provider.test/list?token=secret', userAgent:'agent-fixture'}, settings:{}, position:0}],
    metadata:{provider:'tmdb', tmdbApiKey:'metadata-fixture'},
    favorites:[
      {sourceId, channel:{id:'station-1', name:'Station'}},
      {sourceId, item:{id:'movie-1', kind:'movie', title:'Film'}}
    ]
  });
  assert.deepEqual(result, {profileId, sourceCount:1, favoritesSynced:true, e2ee:'off'});
  const sourceCall = kit.calls.find(call => call.url.endsWith('/rest/v1/rpc/push_sources'));
  assert.deepEqual(sourceCall.body.p_sources, [{
    id:sourceId, kind:'m3u', label:'News', fields:{host:'https://provider.test'}, settings:{}, position:0,
    secret:{format:0, payload:{playlistUrl:'https://provider.test/list?token=secret', userAgent:'agent-fixture'}}
  }]);
  const metadataCall = kit.calls.find(call => call.url.endsWith('/rest/v1/rpc/push_metadata'));
  assert.deepEqual(metadataCall.body, {
    p_config:{provider:'tmdb'}, p_profile_id:profileId,
    p_secret:{format:0, payload:{tmdbApiKey:'metadata-fixture'}}
  });
  assert.deepEqual(kit.calls.find(call => call.url.endsWith('/rest/v1/rpc/push_favorites')).body.p_favorites,
    [
      {source_id:sourceId, kind:'live', item_id:'station-1'},
      {source_id:sourceId, kind:'movie', item_id:'movie-1'}
    ]);
  assert.equal(kit.state.get('cloud_source_ids'), sourceId);
});

test('pull exposes canonical playback position rows and tolerates a pre-position-sync server', async () => {
  const position = {
    source_id:sourceId, kind:'episode', item_id:'episode-1', position_ms:120000,
    duration_ms:1800000, updated_at:1790000000000, removed:false
  };
  const kit = fixture(call => {
    if (deviceRow(call)) return deviceRow(call);
    if (call.url.endsWith('/rest/v1/rpc/set_device_profile')) return {status:204};
    if (call.url.endsWith('/rest/v1/rpc/get_crypto_state')) return {body:{enabled:false, ck_version:0}};
    if (call.url.endsWith('/rest/v1/rpc/get_secrets')) return {body:{sources:{}, metadata:null}};
    if (call.url.endsWith('/rest/v1/rpc/get_playback_positions')) return {body:[position]};
    if (call.url.includes('/rest/v1/profiles?')) return {body:[{id:profileId, name:'Home', favorites:[]}]};
    if (call.url.includes('/rest/v1/sources?')) return {body:[]};
    if (call.url.includes('/rest/v1/metadata_configs?')) return {body:[]};
  }, {state:authenticatedState()});
  const result = await kit.api.query('pull', {profileId});
  assert.deepEqual(result.playbackPositions, [position]);
  assert.equal(result.playbackPositionsAvailable, true);

  const oldServer = fixture(call => {
    if (deviceRow(call)) return deviceRow(call);
    if (call.url.endsWith('/rest/v1/rpc/set_device_profile')) return {status:204};
    if (call.url.endsWith('/rest/v1/rpc/get_crypto_state')) return {body:{enabled:false, ck_version:0}};
    if (call.url.endsWith('/rest/v1/rpc/get_secrets')) return {body:{sources:{}, metadata:null}};
    if (call.url.includes('/rest/v1/profiles?')) return {body:[{id:profileId, name:'Home', favorites:[]}]};
    if (call.url.includes('/rest/v1/sources?')) return {body:[]};
    if (call.url.includes('/rest/v1/metadata_configs?')) return {body:[]};
  }, {state:authenticatedState()});
  const legacy = await oldServer.api.query('pull', {profileId});
  assert.deepEqual(legacy.playbackPositions, []);
  assert.equal(legacy.playbackPositionsAvailable, false);
});

test('push emits exact SQL playback deltas while retaining source and favorite cloud contracts', async () => {
  const position = {
    source_id:sourceId, kind:'movie', item_id:'movie-1', position_ms:240000,
    duration_ms:7200000, updated_at:1790000000100, removed:false
  };
  const kit = fixture(call => {
    if (deviceRow(call)) return deviceRow(call);
    if (call.url.endsWith('/rest/v1/rpc/set_device_profile')) return {status:204};
    if (call.url.endsWith('/rest/v1/rpc/get_crypto_state')) return {body:{enabled:false, ck_version:0}};
    if (call.url.endsWith('/rest/v1/rpc/get_secrets')) return {body:{sources:{}, metadata:null}};
    if (call.url.endsWith('/rest/v1/rpc/push_sources') ||
        call.url.endsWith('/rest/v1/rpc/push_metadata') ||
        call.url.endsWith('/rest/v1/rpc/push_favorites') ||
        call.url.endsWith('/rest/v1/rpc/push_playback_positions')) return {status:204};
  }, {state:authenticatedState()});
  const result = await kit.api.query('push', {
    profileId, sources:[], metadata:{}, favorites:[], playbackPositions:[position]
  });
  assert.equal(result.playbackPositionsSynced, true);
  assert.equal(result.playbackPositionCount, 1);
  assert.deepEqual(kit.calls.find(call => call.url.endsWith('/rest/v1/rpc/push_playback_positions')).body,
    {p_profile_id:profileId, p_changes:[position]});
});

test('playback deltas use server pages and an account/profile cursor, and sources exceed one REST page', async () => {
  const positions = Array.from({length:201}, (_, i) => ({source_id:sourceId, kind:'movie', item_id:String(i),
    position_ms:60000, duration_ms:600000, updated_at:100, removed:false}));
  const sources = Array.from({length:1001}, (_, i) => ({id:'90a03a25-9dbf-43c2-a0ab-' + String(i).padStart(12,'0'),
    kind:'m3u', label:'Source', fields:{}, settings:{}, position:i}));
  const kit = fixture(call => {
    if (deviceRow(call)) return deviceRow(call);
    if (call.url.endsWith('/set_device_profile')) return {status:204};
    if (call.url.endsWith('/get_crypto_state')) return {body:{enabled:false}};
    if (call.url.endsWith('/get_secrets')) return {body:{sources:{},metadata:null}};
    if (call.url.includes('/rest/v1/profiles?')) return {body:[{id:profileId,name:'Home',favorites:[]}]};
    if (call.url.includes('/rest/v1/metadata_configs?')) return {body:[]};
    if (call.url.includes('/rest/v1/sources?')) {
      const url = new URL(call.url), offset = Number(url.searchParams.get('offset'));
      return {body:sources.slice(offset,offset+250)};
    }
    if (call.url.endsWith('/get_playback_delta')) {
      const after=Number(call.body.p_after), rows=positions.slice(after,after+call.body.p_limit);
      return {body:{positions:rows,next_cursor:String(after+rows.length),has_more:after+rows.length<positions.length}};
    }
  }, {state:authenticatedState()});
  const first = await kit.api.query('pull',{profileId});
  assert.equal(first.sources.length,1001);
  assert.equal(first.playbackPositions.length,201);
  assert.equal(first.playbackSync.cursor,'201');
  const second = await kit.api.query('pull',{profileId,playbackSync:first.playbackSync});
  assert.deepEqual(second.playbackPositions,[]);
  assert.equal(second.playbackSync.cursor,'201');
  const rebuilt = await kit.api.query('pull',{profileId,playbackSync:{scope:'another account',cursor:'201'}});
  assert.equal(rebuilt.playbackPositions.length,201);
});

test('long Unicode playback ids are uploaded below the SQL byte budget', async () => {
  const positions = Array.from({length:150}, (_, i) => ({source_id:sourceId,kind:'movie',item_id:'ą'.repeat(4000)+i,
    position_ms:60000,duration_ms:600000,updated_at:100,removed:false}));
  const kit = fixture(call => {
    if (deviceRow(call)) return deviceRow(call);
    if (call.url.endsWith('/set_device_profile')) return {status:204};
    if (call.url.endsWith('/get_crypto_state')) return {body:{enabled:false}};
    if (call.url.endsWith('/get_secrets')) return {body:{sources:{},metadata:null}};
    if (/\/push_/.test(call.url)) return {status:204};
  }, {state:authenticatedState()});
  await kit.api.query('push',{profileId,sources:[],metadata:{},favorites:[],playbackPositions:positions});
  const batches = kit.calls.filter(call=>call.url.endsWith('/push_playback_positions'));
  assert.ok(batches.length>1);
  assert.ok(batches.every(call=>Buffer.byteLength(JSON.stringify(call.body.p_changes))<900000));
});

test('playback position DTO validation rejects unsupported kinds and malformed tombstones before sync', async () => {
  const kit = fixture(() => { throw new Error('invalid playback position reached the network'); }, {
    state:authenticatedState()
  });
  await assert.rejects(kit.api.query('push', {
    profileId, sources:[], metadata:{}, favorites:[],
    playbackPositions:[{
      source_id:sourceId, kind:'live', item_id:'channel-1', position_ms:0,
      duration_ms:0, updated_at:1790000000100, removed:false
    }]
  }), {name:'ProtocolError'});
  await assert.rejects(kit.api.query('push', {
    profileId, sources:[], metadata:{}, favorites:[],
    playbackPositions:[{
      source_id:sourceId, kind:'movie', item_id:'movie-1', position_ms:0,
      duration_ms:0, updated_at:1790000000100, removed:'false'
    }]
  }), {name:'ProtocolError'});
  assert.equal(kit.calls.length, 0);
});

test('E2EE-enabled profiles fail closed and persist the sticky mark before any pull or push', async () => {
  const kit = fixture(call => {
    if (deviceRow(call)) return deviceRow(call);
    if (call.url.endsWith('/rest/v1/rpc/set_device_profile')) return {status:204};
    if (call.url.endsWith('/rest/v1/rpc/get_crypto_state')) return {body:{enabled:true, ck_version:3}};
  }, {state:authenticatedState()});
  await assert.rejects(kit.api.query('pull', {profileId}), {name:'CryptoLockedError'});
  assert.deepEqual(JSON.parse(kit.state.get('cloud_e2ee_marks'))[profileId], {seen:true, ckv:0});
  assert.equal(kit.calls.some(call => call.url.includes('/rest/v1/sources?')), false);
  assert.equal(kit.calls.some(call => call.url.endsWith('/rest/v1/rpc/push_sources')), false);
});

test('an encrypted profile locks before reading secrets when the extracted panel protocol is missing', async () => {
  const wrapped = cryptoFixtures.deviceWrap[0];
  const state = authenticatedState({
    supabase_session:JSON.stringify({access_token:'access-fixture', refresh_token:'refresh-fixture', expires_at:4102444800,
      user:{id:wrapped.deviceUid}}),
    cloud_device_priv_key:Buffer.from(wrapped.devicePrivateKey_hex, 'hex').toString('base64'),
    cloud_device_pub_key:Buffer.from(wrapped.devicePublicKey_hex, 'hex').toString('base64')
  });
  const kit = fixture(call => {
    if (call.method === 'GET' && call.url.includes('/rest/v1/devices?')) return {body:[{
      device_uid:wrapped.deviceUid, owner:'owner-fixture', label:'Samsung', active_profile_id:wrapped.profileId
    }]};
    if (call.url.endsWith('/rest/v1/rpc/set_device_profile')) return {status:204};
    if (call.url.endsWith('/rest/v1/rpc/get_crypto_state')) return {body:{enabled:true, ck_version:wrapped.ckVersion}};
    if (call.url.endsWith('/rest/v1/rpc/set_device_public_key')) return {status:204};
    if (call.url.endsWith('/rest/v1/rpc/get_device_ck')) return {body:{ck_version:wrapped.ckVersion, wrapped_ck:wrapped.envelope}};
  }, {state});
  await assert.rejects(kit.api.query('pull', {profileId:wrapped.profileId}), {name:'CryptoUnsupportedError'});
  assert.equal(kit.calls.some(call => call.url.endsWith('/rest/v1/rpc/get_secrets')), false);
  assert.equal(kit.calls.some(call => call.url.includes('/rest/v1/sources?')), false);
});

test('WebCrypto unwraps the shared device-wrap and secret-envelope vectors before returning E2EE sources', async () => {
  const wrapped = cryptoFixtures.deviceWrap[0];
  const secret = cryptoFixtures.secretEnvelope[0];
  const panelCrypto = await import('../../../panel/src/crypto.js');
  const extractedProtocol = extractedCryptoProtocol();
  const deviceWrap = await panelCrypto.encodeDeviceWrap({
    contentKey:Buffer.from(secret.contentKey_hex, 'hex'), ckVersion:secret.ckVersion,
    ephemeralPrivateKey:Buffer.from(wrapped.ephemeralPrivateKey_hex, 'hex'),
    devicePublicKey:Buffer.from(wrapped.devicePublicKey_hex, 'hex'),
    iv:Buffer.from('303132333435363738393a3b', 'hex'),
    aad:panelCrypto.deviceWrapAad(wrapped.profileId, wrapped.deviceUid, secret.ckVersion)
  });
  const state = authenticatedState({
    supabase_session:JSON.stringify({access_token:'access-fixture', refresh_token:'refresh-fixture', expires_at:4102444800,
      user:{id:wrapped.deviceUid}}),
    cloud_device_priv_key:Buffer.from(wrapped.devicePrivateKey_hex, 'hex').toString('base64'),
    cloud_device_pub_key:Buffer.from(wrapped.devicePublicKey_hex, 'hex').toString('base64')
  });
  const kit = fixture(call => {
    if (call.method === 'GET' && call.url.includes('/rest/v1/devices?')) return {body:[{
      device_uid:wrapped.deviceUid, owner:'owner-fixture', label:'Samsung', active_profile_id:wrapped.profileId
    }]};
    if (call.url.endsWith('/rest/v1/rpc/set_device_profile')) return {status:204};
    if (call.url.endsWith('/rest/v1/rpc/get_crypto_state')) return {body:{enabled:true, ck_version:wrapped.ckVersion}};
    if (call.url.endsWith('/rest/v1/rpc/set_device_public_key')) return {status:204};
    if (call.url.endsWith('/rest/v1/rpc/get_device_ck')) return {body:{ck_version:wrapped.ckVersion, wrapped_ck:deviceWrap}};
    if (call.url.endsWith('/rest/v1/rpc/get_secrets')) return {body:{
      sources:{[secret.sourceId]:{format:1, payload:secret.envelope}}, metadata:null
    }};
    if (call.url.includes('/rest/v1/profiles?')) return {body:[{
      id:wrapped.profileId, name:'Encrypted home', position:0, favorites:[]
    }]};
    if (call.url.includes('/rest/v1/sources?')) return {body:[{
      id:secret.sourceId, kind:'xtream', label:'Encrypted source', position:0,
      fields:{host:'https://provider.test'}, settings:{}
    }]};
    if (call.url.includes('/rest/v1/metadata_configs?')) return {body:[]};
  }, {state, cryptoProtocol:extractedProtocol});
  const snapshot = await kit.api.query('pull', {profileId:wrapped.profileId});
  assert.equal(snapshot.e2ee, 'enabled');
  assert.deepEqual({...snapshot.sources[0].fields}, {
    host:'https://provider.test', password:secret.secret.password, username:secret.secret.username
  });
  const publicKeyCall = kit.calls.find(call => call.url.endsWith('/rest/v1/rpc/set_device_public_key'));
  assert.equal(publicKeyCall.body.p_public_key, Buffer.from(wrapped.devicePublicKey_hex, 'hex').toString('base64'));
  assert.deepEqual(JSON.parse(state.get('cloud_e2ee_marks'))[wrapped.profileId], {seen:true, ckv:wrapped.ckVersion});
  assert.deepEqual(state.reload().read(), state.read(), 'session, device keys and sticky E2EE mark survive CREATE-ONLY writes and reload');
});

test('E2EE push encrypts source and metadata secrets in the panel wire format', async () => {
  const wrapped = cryptoFixtures.deviceWrap[0];
  const secret = cryptoFixtures.secretEnvelope[0];
  const panelCrypto = await import('../../../panel/src/crypto.js');
  const extractedProtocol = extractedCryptoProtocol();
  const deviceWrap = await panelCrypto.encodeDeviceWrap({
    contentKey:Buffer.from(secret.contentKey_hex, 'hex'), ckVersion:secret.ckVersion,
    ephemeralPrivateKey:Buffer.from(wrapped.ephemeralPrivateKey_hex, 'hex'),
    devicePublicKey:Buffer.from(wrapped.devicePublicKey_hex, 'hex'),
    iv:Buffer.from('303132333435363738393a3b', 'hex'),
    aad:panelCrypto.deviceWrapAad(wrapped.profileId, wrapped.deviceUid, secret.ckVersion)
  });
  const state = authenticatedState({
    supabase_session:JSON.stringify({access_token:'access-fixture', refresh_token:'refresh-fixture', expires_at:4102444800,
      user:{id:wrapped.deviceUid}}),
    cloud_device_priv_key:Buffer.from(wrapped.devicePrivateKey_hex, 'hex').toString('base64'),
    cloud_device_pub_key:Buffer.from(wrapped.devicePublicKey_hex, 'hex').toString('base64')
  });
  const kit = fixture(call => {
    if (call.method === 'GET' && call.url.includes('/rest/v1/devices?')) return {body:[{
      device_uid:wrapped.deviceUid, owner:'owner-fixture', label:'Samsung', active_profile_id:wrapped.profileId
    }]};
    if (call.url.endsWith('/rest/v1/rpc/set_device_profile')) return {status:204};
    if (call.url.endsWith('/rest/v1/rpc/get_crypto_state')) return {body:{enabled:true, ck_version:wrapped.ckVersion}};
    if (call.url.endsWith('/rest/v1/rpc/set_device_public_key')) return {status:204};
    if (call.url.endsWith('/rest/v1/rpc/get_device_ck')) return {body:{ck_version:wrapped.ckVersion, wrapped_ck:deviceWrap}};
    if (call.url.endsWith('/rest/v1/rpc/get_secrets')) return {body:{
      sources:{[secret.sourceId]:{format:1, payload:secret.envelope}}, metadata:null
    }};
    if (call.url.endsWith('/rest/v1/rpc/push_sources') ||
        call.url.endsWith('/rest/v1/rpc/push_metadata') ||
        call.url.endsWith('/rest/v1/rpc/push_favorites')) return {status:204};
  }, {state, cryptoProtocol:extractedProtocol});
  const result = await kit.api.query('push', {
    profileId:wrapped.profileId,
    sources:[{id:secret.sourceId, kind:'xtream', label:'Encrypted source', position:0,
      fields:{host:'https://provider.test', username:'alice', password:'secret-password'}, settings:{}}],
    metadata:{provider:'tmdb', autoEnrich:true, tmdbApiKey:'secret-api-key'}, favorites:[]
  });
  const sourceCall = kit.calls.find(call => call.url.endsWith('/rest/v1/rpc/push_sources'));
  const metadataCall = kit.calls.find(call => call.url.endsWith('/rest/v1/rpc/push_metadata'));
  assert.deepEqual(sourceCall.body.p_sources[0].fields, {host:'https://provider.test'});
  assert.equal(sourceCall.body.p_sources[0].secret.format, 1);
  assert.equal(JSON.stringify(sourceCall.body.p_sources[0].fields).includes('secret-password'), false);
  assert.deepEqual(await panelCrypto.decryptSecretEnvelope({
    envelope:sourceCall.body.p_sources[0].secret.payload,
    contentKey:Buffer.from(secret.contentKey_hex, 'hex'), ckVersion:secret.ckVersion,
    aad:panelCrypto.sourceSecretAad(wrapped.profileId, secret.sourceId, secret.ckVersion)
  }), {password:'secret-password', username:'alice'});
  assert.deepEqual(metadataCall.body.p_config, {provider:'tmdb', autoEnrich:true});
  assert.equal(metadataCall.body.p_secret.format, 1);
  assert.deepEqual(await panelCrypto.decryptSecretEnvelope({
    envelope:metadataCall.body.p_secret.payload,
    contentKey:Buffer.from(secret.contentKey_hex, 'hex'), ckVersion:secret.ckVersion,
    aad:panelCrypto.metadataSecretAad(wrapped.profileId, secret.ckVersion)
  }), {tmdbApiKey:'secret-api-key'});
  assert.deepEqual(result, {profileId:wrapped.profileId, sourceCount:1, favoritesSynced:true, e2ee:'enabled'});
});

test('encrypted secret envelope under an off status locks the profile and blocks plaintext retry', async () => {
  const kit = fixture(call => {
    if (deviceRow(call)) return deviceRow(call);
    if (call.url.endsWith('/rest/v1/rpc/set_device_profile')) return {status:204};
    if (call.url.endsWith('/rest/v1/rpc/get_crypto_state')) return {body:{enabled:false, ck_version:0}};
    if (call.url.endsWith('/rest/v1/rpc/get_secrets')) return {body:{
      sources:{[sourceId]:{format:1, payload:{v:1, alg:'A256GCM'}}}, metadata:null
    }};
    if (call.url.includes('/rest/v1/profiles?')) return {body:[{id:profileId, name:'Encrypted', favorites:[]}]};
    if (call.url.includes('/rest/v1/sources?')) return {body:[{id:sourceId, kind:'m3u', label:'News', fields:{}, settings:{}}]};
    if (call.url.includes('/rest/v1/metadata_configs?')) return {body:[]};
  }, {state:authenticatedState()});
  await assert.rejects(kit.api.query('pull', {profileId}), {name:'CryptoLockedError'});
  assert.equal(JSON.parse(kit.state.get('cloud_e2ee_marks'))[profileId].seen, true);
  await assert.rejects(kit.api.query('push', {profileId, sources:[], metadata:{}, favorites:[]}), {name:'CryptoLockedError'});
  assert.equal(kit.calls.some(call => call.url.endsWith('/rest/v1/rpc/push_sources')), false);
});

test('unpair removes only this device link and cloud bookkeeping while retaining the secure session', async () => {
  const state = authenticatedState({cloud_profile_id:profileId, cloud_source_ids:sourceId,
    cloud_e2ee_marks:JSON.stringify({[profileId]:{seen:true, ckv:2}})});
  const kit = fixture(call => {
    if (call.method === 'DELETE') return {status:204};
  }, {state});
  const result = await kit.api.query('unpair');
  assert.deepEqual(result.removedSourceIds, [sourceId]);
  assert.equal(kit.calls.length, 2);
  assert.ok(kit.calls.every(call => call.url.includes('device_uid=eq.' + deviceId)));
  assert.ok(kit.calls.some(call => call.url.includes('/rest/v1/devices?')));
  assert.ok(kit.calls.some(call => call.url.includes('/rest/v1/pairings?')));
  assert.equal(state.get('supabase_session') != null, true);
  assert.equal(state.get('cloud_profile_id'), null);
  assert.equal(state.get('cloud_source_ids'), null);
  assert.equal(state.get('cloud_e2ee_marks'), null);
  assert.deepEqual(state.reload().read(), state.read(), 'unpairing must remain committed after a fresh KeyManager read');
});

test('server error details are not echoed into cloud errors', async () => {
  const kit = fixture(call => {
    if (deviceRow(call)) return deviceRow(call);
    if (call.url.endsWith('/rest/v1/rpc/set_device_profile')) return {status:204};
    if (call.url.endsWith('/rest/v1/rpc/get_crypto_state')) return {body:{enabled:false}};
    if (call.url.endsWith('/rest/v1/rpc/get_secrets')) return {body:{sources:{}, metadata:null}};
    if (call.url.endsWith('/rest/v1/rpc/push_sources')) return {status:400, body:{message:'echoed-secret-token'}};
  }, {state:authenticatedState()});
  await assert.rejects(kit.api.query('push', {profileId, sources:[], metadata:{}, favorites:[]}), failure => {
    assert.match(failure.message, /HTTP 400/);
    assert.equal(failure.message.includes('echoed-secret-token'), false);
    return true;
  });
});

test('automatic cloud deltas emit only canonical row and preference path merge RPCs',async()=>{
  const kit=fixture(call=>{
    if(deviceRow(call))return deviceRow(call);
    if(call.url.endsWith('/rpc/push_favorites_delta')||call.url.endsWith('/rpc/push_source_settings_delta'))return {status:204};
  },{state:authenticatedState()});
  await kit.api.query('push.delta',{profileId,favorites:[{sourceId,kind:'live',itemId:'one',add:true},{sourceId,kind:'movie',itemId:'two',add:false}],
    settings:[{sourceId,path:['channelOrganization','names','one'],value:'My name'},{sourceId,path:['hiddenCategories','movie'],value:['adult']}]});
  const favorite=kit.calls.find(call=>call.url.endsWith('/rpc/push_favorites_delta'));
  assert.deepEqual(favorite.body,{p_profile_id:profileId,p_added:[{source_id:sourceId,kind:'live',item_id:'one'}],p_removed:[{source_id:sourceId,kind:'movie',item_id:'two'}]});
  const settings=kit.calls.find(call=>call.url.endsWith('/rpc/push_source_settings_delta'));
  assert.deepEqual(settings.body,{p_profile_id:profileId,p_changes:[{source_id:sourceId,changes:{channelOrganization:{names:{one:'My name'}},hiddenCategories:{movie:['adult']}}}]});
  assert.equal(kit.calls.some(call=>/\/rpc\/(push_sources|push_metadata|push_favorites)$/.test(call.url)),false);
  const before=kit.calls.length;
  await assert.rejects(kit.api.query('push.delta',{profileId,settings:[{sourceId,path:['password'],value:'forbidden'}]}),{name:'ValidationError'});
  await assert.rejects(kit.api.query('push.delta',{profileId,settings:[{sourceId,path:['channelOrganization','__proto__','bad'],value:'forbidden'}]}),{name:'ValidationError'});
  assert.equal(kit.calls.length,before);
});
