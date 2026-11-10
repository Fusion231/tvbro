'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');

const createPlatform = require('../platform.js');
const platforms = new Set();
test.afterEach(async()=>{const pending=[...platforms];platforms.clear();await Promise.all(pending.map(api=>api.query('sources.cancel')));});
const project = path.resolve(__dirname, '..');
const output = path.resolve(project, '../output/samsung-web');
const build = JSON.parse(fs.readFileSync(path.join(output, 'latest-build.json'), 'utf8'));
const payload = process.env.TVBRO_SAMSUNG_TEST_PAYLOAD || build.payload;

function loadModules() {
  const sandbox = {
    console,
    crypto: crypto.webcrypto,
    setTimeout,
    clearTimeout,
    TextEncoder,
    TextDecoder,
    URL,
    URLSearchParams,
    Blob,
    btoa,
    atob
  };
  sandbox.window = sandbox;
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  for (const file of ['polyfills.js', 'canonical-core.js', 'panel-validation.js']) {
    const bytes = fs.readFileSync(path.join(payload, file));
    if (!process.env.TVBRO_SAMSUNG_TEST_PAYLOAD) {
      assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), build.payloadHashes[file],
        'Staged module hash must match latest-build.json: ' + file);
    }
    vm.runInContext(bytes.toString('utf8'), sandbox, {filename:file});
  }
  return {core:sandbox.TVBroCanonical, validation:sandbox.TVBroPanelValidation};
}

const secureStoreModule = require('../platform/secure_store.js');
const userStateModule = require('../platform/user_state.js');
const transportModule = require('../platform/transport.js');
const cloudModule = require('../platform/cloud.js');
const libraryModule = require('../platform/library.js');
const avplayModule = require('../platform/avplay.js');

function xhrBoundary(route) {
  const sent = [];
  const waiters = [];
  class XMLHttpRequest {
    open(method, url, asynchronous) {
      this.method = method;
      this.url = url;
      this.asynchronous = asynchronous;
    }
    setRequestHeader(name, value) {
      this.headers = this.headers || {};
      this.headers[name] = value;
    }
    getAllResponseHeaders() { return ''; }
    send() {
      sent.push(this);
      for (const waiter of waiters.slice()) {
        if (waiter.predicate(this)) {
          waiters.splice(waiters.indexOf(waiter), 1);
          waiter.resolve(this);
        }
      }
      const response = route(this);
      if (response !== undefined) queueMicrotask(() => this.respond(response.body === undefined ? response : response.body,
        response.status == null ? 200 : response.status));
    }
    abort() {
      this.aborted = true;
      if (this.onabort) this.onabort();
    }
    respond(body, status = 200) {
      this.status = status;
      this.responseText = typeof body === 'string' ? body : JSON.stringify(body);
      if (this.responseType === 'arraybuffer') {
        const bytes = Buffer.from(this.responseText);
        this.response = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        Object.defineProperty(this, 'responseText', {get() { throw new Error('InvalidStateError: binary response'); }});
      }
      if (this.onload) this.onload();
    }
  }
  return {
    XMLHttpRequest,
    sent,
    whenSent(predicate) {
      const found = sent.find(predicate);
      if (found) return Promise.resolve(found);
      return new Promise(resolve => waiters.push({predicate, resolve}));
    }
  };
}

function keyManagerBoundary() {
  const data = new Map();
  const saves = [];
  return {
    data,
    saves,
    sdk: {
      getData(identifier) {
        if (!data.has(identifier.name)) {
          const error = new Error('Not found');
          error.name = 'NotFoundError';
          throw error;
        }
        return data.get(identifier.name);
      },
      getDataAliasList() { return Array.from(data.keys(), name => ({name, packageId:'TVBroWebTV'})); },
      saveData(alias, value, password, success, failure) {
        assert.equal(password, null);
        saves.push({alias, value});
        queueMicrotask(() => {
          if (data.has(alias)) {
            const error = new Error('KeyManager alias already exists'); error.name = 'UnknownError';
            failure(error); return;
          }
          data.set(alias, value);
          success();
        });
      },
      removeData(identifier) { data.delete(identifier.name); }
    }
  };
}

function playerBoundary(events) {
  const calls = {open:[], rect:[], stop:0};
  const listeners = [];
  let state = {
    phase:'idle', playing:false, buffering:false, position:0, duration:0,
    error:null, rate:1, aspect:'auto'
  };
  function publish() { listeners.slice().forEach(listener => listener(state)); }
  return {
    calls,
    sdk: {
      setRect(x, y, width, height) { calls.rect.push([x, y, width, height]); },
      open(url, options) {
        calls.open.push({url, options});
        state = {...state, phase:'playing', playing:true, buffering:false, error:null};
        publish();
        return Promise.resolve();
      },
      stop() {
        calls.stop++;
        if (events) events.push('stop');
        state = {...state, phase:'idle', playing:false, buffering:false};
        publish();
        return Promise.resolve();
      },
      getState() { return {...state}; },
      onState(listener) { listeners.push(listener); listener({...state}); return () => {}; },
      playPause() {
        state = {...state, playing:!state.playing};
        publish();
        return Promise.resolve();
      },
      seek(position) { state.position = position; publish(); return Promise.resolve(); },
      getTracks() { return []; },
      selectTrack() { return Promise.resolve(); },
      setSubtitlesEnabled() { return Promise.resolve(); },
      setSpeed(rate) { state.rate = rate; return Promise.resolve(); },
      setDisplayMode(mode) { state.aspect = mode; return Promise.resolve(); },
      getCapabilities() {
        return {tracks:false, playbackSpeeds:[], displayModes:[]};
      },
      setState(next) { state = {...state, ...next}; publish(); }
    }
  };
}

function harness(route, existingKeyManager) {
  const real = loadModules();
  const xhr = xhrBoundary(route || (() => undefined));
  const keyManager = existingKeyManager || keyManagerBoundary();
  const events = [];
  const player = playerBoundary(events);
  const documentListeners = {};
  const environment = {
    TVBroCanonical:real.core,
    TVBroPanelValidation:real.validation,
    TVBroSamsungSecureStore:secureStoreModule,
    TVBroSamsungUserState:userStateModule,
    TVBroSamsungTransport:transportModule,
    TVBroSamsungCloud:cloudModule,
    TVBroSamsungLibrary:libraryModule,
    TVBroSamsungAvplay:avplayModule,
    TVBroSamsungConfig:{enabled:false},
    XMLHttpRequest:xhr.XMLHttpRequest,
    Blob,
    btoa,
    URL,
    URLSearchParams,
    navigator:{userAgent:'SamsungTV fixture'},
    innerWidth:1280,
    innerHeight:720,
    document:{
      hidden:false,
      addEventListener(name, listener) { documentListeners[name] = listener; }
    },
    tizen:{
      keymanager:keyManager.sdk,
      tvinputdevice:{registerKey() {}},
      application:{getCurrentApplication() { return {appInfo:{packageId:'TVBroWebTV'}, exit() { events.push('exit'); }}; }}
    },
    localStorage:{
      getItem() { throw new Error('Samsung client must not use localStorage.'); },
      setItem() { throw new Error('Samsung client must not use localStorage.'); }
    }
  };
  const api = createPlatform(environment, {player:player.sdk,createSource:real.core.createSource,
    verifyPin:real.core.verifyPin,hashPin:real.core.hashPin});
  platforms.add(api);
  return {api, core:real.core, validation:real.validation, xhr, keyManager, player, events,
    document:environment.document, documentListeners,
    readPersistedUserState:() => secureStoreModule.create({environment}).readUserState()};
}

function m3uSource(url, label) {
  return {kind:'m3u', label:label || 'M3U contract', fields:{playlistUrl:url}, settings:{}};
}

function playlist(name, url) {
  return '#EXTM3U\n#EXTINF:-1 tvg-id="station" group-title="News",' + name + '\n' + url + '\n';
}

async function createProfile(api, name) {
  await api.query('bootstrap');
  const result = await api.query('profiles.create', {name});
  return result.profile;
}

test('KeyManager boundaries reject duplicate alias creation and enumerate actual package-owned metadata', async () => {
  const node = keyManagerBoundary();
  const sandbox = {setTimeout}; sandbox.window = sandbox; vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname,'browser_sdk_fixture.js'),'utf8'),sandbox);
  const browser = sandbox.tizen.keymanager;
  for (const sdk of [node.sdk, browser]) {
    const save = (alias, value) => new Promise((resolve,reject) => sdk.saveData(alias,value,null,resolve,reject));
    await save('fixture_alias','first');
    await assert.rejects(save('fixture_alias','second'),error => error.name === 'UnknownError');
    assert.equal(sdk.getData({name:'fixture_alias'}),'first');
    assert.deepEqual(JSON.parse(JSON.stringify(sdk.getDataAliasList())),[{name:'fixture_alias',packageId:'TVBroWebTV'}]);
    await save('fixture_alias_g1','next');
    assert.deepEqual(JSON.parse(JSON.stringify(sdk.getDataAliasList())),[
      {name:'fixture_alias',packageId:'TVBroWebTV'}, {name:'fixture_alias_g1',packageId:'TVBroWebTV'}
    ]);
  }
  assert.equal(sandbox.tizen.application.getCurrentApplication().appInfo.packageId,'TVBroWebTV');
});

test('fresh boot persists both migrations using create-only aliases and reopens without rewriting them', async () => {
  const kit = harness();
  await kit.api.query('bootstrap');
  assert.ok(kit.keyManager.saves.length >= 2,'Both existing boot migrations must reach the real SDK boundary.');
  assert.equal(new Set(kit.keyManager.saves.map(row => row.alias)).size,kit.keyManager.saves.length,
    'Boot must never upsert a KeyManager alias.');
  const persisted = kit.readPersistedUserState();
  assert.equal(persisted.samsung_sources_migrated_v1,'true');
  assert.equal(persisted.profile_picker_startup,'auto');
  const saves = kit.keyManager.saves.length;
  const reopened = harness(undefined,kit.keyManager);
  const bootstrap = await reopened.api.query('bootstrap');
  assert.equal(bootstrap.languageSelected,false);
  assert.equal(reopened.readPersistedUserState().profile_picker_startup,'auto');
  assert.equal(kit.keyManager.saves.length,saves,'Completed boot migrations must not repeat after reload.');
});

test('the UI facade exposes only real-library queries and drives canonical M3U playback', async () => {
  const stream = 'https://media.invalid/news.m3u8';
  const kit = harness(xhr => {
    assert.equal(xhr.url, 'https://playlist.invalid/channels.m3u');
    return playlist('News', stream);
  });
  assert.deepEqual(Object.keys(kit.api).sort(),
    ['exit','getState','onState','playPause','query','seek']);

  const profile = await createProfile(kit.api, 'Living room');
  assert.ok(profile.id);
  const sourceUrl = 'https://playlist.invalid/channels.m3u';
  const saved = (await kit.api.query('sources.add', {config:m3uSource(sourceUrl)}))[0];
  assert.match(saved.id, /^[0-9a-f-]{36}$/);

  const catalog = await kit.api.query('sources.load', {id:saved.id});
  assert.equal(catalog.channels[0].id, kit.core.stableM3uChannelId(stream));
  assert.equal(catalog.categories[0].title, 'News');
  assert.equal(kit.xhr.sent[0].url, sourceUrl);

  await kit.api.query('playback.play', {channel:catalog.channels[0], sourceId:saved.id});
  assert.deepEqual(kit.player.calls.open, [{url:stream, options:{headers:{},isLive:true,bufferPreset:'default'}}]);
  assert.deepEqual(kit.player.calls.rect, [[0,0,1280,720]]);
  assert.equal(kit.api.getState().currentItem.id, catalog.channels[0].id);
  assert.equal(kit.api.getState().isLive, true);
});

test('the public facade rejects protected and invalid requests with the library error codes', async () => {
  const kit = harness(() => undefined);
  await createProfile(kit.api, 'Default');
  const locked = (await kit.api.query('profiles.create', {name:'Guarded', pin:'1234'})).profile;
  await kit.api.query('profiles.create', {name:'Other'});

  await assert.rejects(
    kit.api.query('profiles.select', {id:locked.id, pin:'0000'}),
    error => error.code === 'pin_invalid'
  );
  await kit.api.query('profiles.select', {id:locked.id, pin:'1234'});

  await kit.api.query('parental.setPin', {newPin:'5678'});
  await assert.rejects(
    kit.api.query('parental.setPin', {newPin:'8765'}),
    error => error.code === 'pin_required'
  );
  await assert.rejects(
    kit.api.query('parental.setPin', {newPin:'8765', pin:'0000'}),
    error => error.code === 'pin_invalid'
  );

  await assert.rejects(
    kit.api.query('sources.add', {config:{
      kind:'m3u', label:'Invalid', fields:{playlistUrl:'javascript:secret-value'}, settings:{}
    }}),
    error => typeof error.message === 'string' && !error.message.includes('secret-value')
  );
  assert.deepEqual(await kit.api.query('sources.list'), []);
});

test('EPG failures cross the canonical binding and facade with safe causes instead of empty success', async t => {
  for (const fixture of [
    {name:'invalid XML', body:'<tv><programme>private-provider-token</tv>', code:'epg_invalid_data', marker:'[EPG:DATA]'},
    {name:'guide not found', body:'private-provider-token', status:404, code:'epg_http', marker:'[EPG:HTTP 404]', missing:true},
    {name:'inferred M3U guide not found', body:'private-provider-token', status:404, code:'epg_http', marker:'[EPG:HTTP 404]', missing:true, inferred:true},
    {name:'guide removed', body:'private-provider-token', status:410, code:'epg_http', marker:'[EPG:HTTP 410]', missing:true},
    {name:'HTTP refusal', body:'private-provider-token', status:403, code:'epg_http', marker:'[EPG:HTTP 403]'}
  ]) await t.test(fixture.name, async () => {
    const playlistUrl = fixture.inferred
      ? 'https://playlist.invalid/get.php?' + new URLSearchParams({username:'fixture-user',password:'fixture-pass'})
      : 'https://playlist.invalid/list.m3u';
    const kit = harness(xhr => xhr.url === playlistUrl
      ? playlist('Station','https://media.invalid/live.m3u8') : fixture);
    await createProfile(kit.api,'EPG errors');
    const config = m3uSource(playlistUrl);
    if (!fixture.inferred) config.fields.epgUrl = 'https://guide.invalid/private-provider-token.xml';
    const saved = (await kit.api.query('sources.add',{config}))[0];
    const catalog = await kit.api.query('sources.load',{id:saved.id});
    assert.equal(catalog.preparation.sections.epg.status,'failed','onboarding records the first guide failure without blocking channels');
    const from = new Date().toISOString(), to = new Date(Date.now()+7200000).toISOString();
    let retryAt;
    await assert.rejects(kit.api.query('guide',{channels:catalog.channels,from,to}), error => {
      assert.equal(error.code,fixture.status === 403 ? fixture.code : 'epg_retry_deferred');
      if (fixture.status !== 403) assert.equal(error.causeCode,fixture.code);
      if (fixture.status) assert.equal(error.status,fixture.status);
      const marker = fixture.status === 403 ? fixture.marker : fixture.status ? '[EPG:RETRY HTTP '+fixture.status+']' : '[EPG:RETRY DATA]';
      assert.ok(error.message.includes(marker),error.message);
      if (fixture.missing) {
        assert.match(error.message,/Nie znaleziono programu TV/);
        assert.match(error.message,/adres EPG/);
        assert.match(error.message,/kanały.*oglądać/i);
        assert.doesNotMatch(error.message,/odmówił/);
      }
      if (fixture.status === 403) assert.match(error.message,/Dostawca odmówił/);
      assert.ok(!/private-provider-token|guide\.invalid|https?:\/\//.test(error.message));
      if (fixture.status !== 403) { assert.ok(error.retryAt > Date.now());retryAt=error.retryAt; }
      return true;
    });
    if (fixture.status === 403) return;
    const readsBeforeRetry = kit.xhr.sent.length;
    await assert.rejects(kit.api.query('guide',{channels:catalog.channels,from,to}), error => {
      assert.equal(error.code,'epg_retry_deferred');
      assert.equal(error.causeCode,fixture.code);assert.equal(error.retryAt,retryAt);
      assert.ok(error.message.includes(fixture.status?'[EPG:RETRY HTTP '+fixture.status+']':'[EPG:RETRY DATA]'));
      if (fixture.missing) {
        assert.match(error.message,/Nie znaleziono programu TV/);
        assert.match(error.message,/adres EPG/);
        assert.doesNotMatch(error.message,/odmówił/);
      }
      assert.ok(!/private-provider-token|guide\.invalid|https?:\/\//.test(error.message));
      return true;
    });
    assert.equal(kit.xhr.sent.length,readsBeforeRetry,'Deferred EPG must not re-fetch the guide');
    if (fixture.inferred) {
      assert.equal(new URL(kit.xhr.sent[1].url).pathname,'/xmltv.php');
      assert.equal(kit.xhr.sent.length,2,'M3U must not automatically probe the Xtream API');
    }
    if (fixture.missing) {
      const reads = kit.xhr.sent.length;
      await kit.api.query('playback.play',{channel:catalog.channels[0],sourceId:saved.id});
      assert.equal(kit.player.calls.open[0].url,'https://media.invalid/live.m3u8');
      assert.equal(kit.xhr.sent.length,reads,'Playback must not retry a missing guide');
    }
  });

  await t.test('transport size limit retains its classification without provider text', async () => {
    const {core} = loadModules();
    const config = m3uSource('https://playlist.invalid/list.m3u');
    config.fields.epgUrl = 'https://guide.invalid/private-provider-token.xml';
    const engine = core.createSource(JSON.stringify(config), () => Promise.resolve(JSON.stringify({
      errorKind:'limit',error:'https://guide.invalid/private-provider-token.xml'
    })));
    try {
      const value = JSON.parse(await engine.invoke('epg',JSON.stringify({channels:[{id:'station',name:'Station',tvgId:'station'}]})));
      assert.equal(value.__tvbroEpgError,1);assert.equal(value.code,'epg_size_limit');assert.ok(value.retryAt>Date.now());
      assert.ok(!JSON.stringify(value).includes('private-provider-token'));
    } finally { await engine.dispose(); }
  });
});

test('a guide HTTP 403 permits the next request for the same source and channels', async () => {
  let guideRequests = 0;
  const kit = harness(xhr => xhr.url.endsWith('/list.m3u')
    ? playlist('Station','https://media.invalid/live.m3u8')
    : ++guideRequests === 1 ? {status:403,body:'Forbidden'} : {status:200,body:'<tv/>'});
  await createProfile(kit.api,'EPG retry');
  const config = m3uSource('https://playlist.invalid/list.m3u');
  config.fields.epgUrl = 'https://guide.invalid/guide.xml';
  const saved = (await kit.api.query('sources.add',{config}))[0];
  const catalog = await kit.api.query('sources.load',{id:saved.id});
  assert.equal(catalog.preparation.sections.epg.status,'failed');
  assert.equal(guideRequests,1,'onboarding makes the first guide attempt');
  const request = {channels:catalog.channels};
  assert.deepEqual((await kit.api.query('guide',request)).programmes,[]);
  assert.equal(guideRequests,2);
});

test('restoring a guide cache discards saved HTTP 403 failures and preserves other refusals', async () => {
  const {core} = loadModules();
  const config = {...m3uSource('https://playlist.invalid/list.m3u'),id:'guide-restore'};
  const source = core.createSource(JSON.stringify(config),() => Promise.reject(Error('Unexpected provider request')));
  const invoke = async (method,args) => JSON.parse(await source.invoke(method,JSON.stringify(args)));
  try {
    const snapshot = JSON.parse(await invoke('exportGuide',{scope:'profile'}));
    const forbidden = 'a'.repeat(64), unauthorized = 'b'.repeat(64), until = Date.now()+600000;
    snapshot.payload = JSON.stringify({entries:[],failures:{[forbidden]:until,[unauthorized]:until},
      failureReasons:{[forbidden]:{code:'epg_http',status:403},[unauthorized]:{code:'epg_http',status:401}}});
    snapshot.checksum = crypto.createHash('sha256').update(snapshot.payload).digest('hex');
    assert.equal(await invoke('importGuide',{scope:'profile',snapshot:JSON.stringify(snapshot)}),true);
    const restored = JSON.parse(JSON.parse(await invoke('exportGuide',{scope:'profile'})).payload);
    assert.equal(restored.failures[forbidden],undefined);
    assert.equal(restored.failureReasons[forbidden],undefined);
    assert.equal(restored.failures[unauthorized],until);
    assert.equal(restored.failureReasons[unauthorized].status,401);
  } finally { await source.dispose(); }
});

test('the real library aborts a stale source request and only the current source opens', async () => {
  const kit = harness(xhr => xhr.url.endsWith('/second.m3u')
    ? playlist('Second', 'https://media.invalid/second.m3u8')
    : undefined);
  await createProfile(kit.api, 'Source switch');
  const sources = await kit.api.query('sources.add', {
    config:m3uSource('https://playlist.invalid/first.m3u', 'First')
  });
  const second = (await kit.api.query('sources.add', {
    config:m3uSource('https://playlist.invalid/second.m3u', 'Second')
  }))[1];

  const firstLoad = kit.api.query('sources.load', {id:sources[0].id}).then(
    value => ({value}), error => ({error})
  );
  const firstRequest = await kit.xhr.whenSent(xhr => xhr.url.endsWith('/first.m3u'));
  const catalog = await kit.api.query('sources.load', {id:second.id});
  assert.equal(firstRequest.aborted, true);
  firstRequest.respond(playlist('First', 'https://media.invalid/first.m3u8'));
  await firstLoad;

  const oldId = kit.core.stableM3uChannelId('https://media.invalid/first.m3u8');
  await kit.api.query('playback.play', {
    channel:{id:oldId, name:'First'}, sourceId:second.id
  }).catch(() => {});
  assert.deepEqual(kit.player.calls.open, []);

  await kit.api.query('playback.play', {channel:catalog.channels[0], sourceId:second.id});
  assert.deepEqual(kit.player.calls.open.map(call => call.url), ['https://media.invalid/second.m3u8']);
});

test('playback.stop cancels a play request waiting for provider data before native open', async () => {
  const stream = 'https://media.invalid/pending.m3u8';
  const kit = harness(() => undefined);
  await createProfile(kit.api, 'Cancel playback');
  const source = (await kit.api.query('sources.add', {
    config:m3uSource('https://playlist.invalid/pending.m3u')
  }))[0];
  const opening = kit.api.query('playback.play', {
    channel:{id:kit.core.stableM3uChannelId(stream), name:'Pending'}, sourceId:source.id
  });
  const request = await kit.xhr.whenSent(xhr => xhr.url.endsWith('/pending.m3u'));
  await kit.api.query('playback.stop');
  request.respond(playlist('Pending', stream));

  const cancelled = await opening.then(value => ({value}), error => ({error:error.message, code:error.code}));
  assert.equal(cancelled.code, 'cancelled');
  assert.deepEqual(kit.player.calls.open, []);
});

test('visibility stop and exit flush actual-library resume state before exit', async () => {
  const kit = harness(() => undefined);
  await createProfile(kit.api, 'Resume');
  const source = (await kit.api.query('sources.add', {
    config:{kind:'demo', label:'Demo', fields:{}, settings:{}}
  }))[0];
  await kit.api.query('sources.load', {id:source.id});
  const categories = await kit.api.query('catalog.categories', {kind:'movie'});
  const movies = await kit.api.query('catalog.items', {
    kind:'movie', categoryId:categories[0].id, page:1
  });
  const item = movies.items[0];
  assert.ok(item && item.id);

  const stopsBeforePlayback = kit.player.calls.stop;
  await kit.api.query('playback.play', {item, sourceId:source.id});
  kit.player.sdk.setState({position:31, duration:120, playing:true});
  kit.document.hidden = true;
  kit.documentListeners.visibilitychange();
  await new Promise(resolve => setTimeout(resolve, 0));
  assert.equal(kit.player.calls.stop, stopsBeforePlayback + 1);

  const stateAfterHide = kit.readPersistedUserState();
  assert.ok(stateAfterHide.samsung_playback_positions_v1, JSON.stringify(stateAfterHide));
  const positionsAfterHide = JSON.parse(stateAfterHide.samsung_playback_positions_v1);
  assert.ok(Object.values(positionsAfterHide)[0][JSON.stringify([source.id, item.kind, item.id])].position >= 31);

  kit.document.hidden = false;
  await kit.api.query('playback.play', {item, sourceId:source.id});
  kit.player.sdk.setState({position:47, duration:120, playing:true});
  await kit.api.exit();
  assert.equal(kit.events[kit.events.length - 1], 'exit');
  assert.deepEqual(kit.events.slice(-2), ['stop', 'exit']);
  const stateAtExit = kit.readPersistedUserState();
  const positionsAtExit = JSON.parse(stateAtExit.samsung_playback_positions_v1);
  assert.ok(Object.values(positionsAtExit)[0][JSON.stringify([source.id, item.kind, item.id])].position >= 47);
});
