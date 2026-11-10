'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {performance} = require('node:perf_hooks');
const createLibrary = require('../platform/library.js').create;
const createUserState = require('../platform/user_state.js').create;

function deferred() {
  let resolve, reject;
  const promise = new Promise((a,b) => { resolve = a; reject = b; });
  return {promise,resolve,reject};
}
const nextTurn = () => new Promise(resolve => setImmediate(resolve));

// Provider/SDK boundary doubles isolate library scheduling. Existing library
// contracts exercise these same public queries with the actual compiled core.
function fixture(options = {}) {
  const configs = ['a','b'].map(id => ({id,kind:'m3u',label:id,fields:{playlistUrl:'https://'+id+'.fixture/list.m3u'},settings:{}}));
  const channels = options.channels || [{id:'one',name:'One',extra:{}},{id:'two',name:'Two',extra:{}}];
  let state = {active_local_profile_id:'profile',local_profiles_v1:JSON.stringify([
    {id:'profile',name:'Profile',snapshot:{sources:configs,managedIds:[],activeSourceId:options.selected === null ? null : 'a'}}
  ])};
  const events = [], calls = [], saved = new Map();
  let stateGate = null, diskGate = null, reads = 0, catchupChecks = 0;
  const userState = createUserState({store:{
    readUserState:() => ({...state}),
    async writeUserState(next) { events.push('state-write'); if (stateGate) await stateGate.promise; state = {...next}; return {...state}; }
  }});
  const core = {providerCachePolicy:() => JSON.stringify({catalogMaxAgeMs:3600000,epgRetryDelayMs:900000}),
    canCatchup() { catchupChecks += 1; return false; }};
  function createSource(rawConfig) {
    const config = JSON.parse(rawConfig);
    let guideRevision = 0;
    return {async dispose() { events.push('dispose:'+config.id); }, async invoke(method,rawArgs) {
      calls.push(method); const args = JSON.parse(rawArgs);
      if (method === 'cacheKey') return JSON.stringify(config.id.repeat(64));
      if (method === 'guideCacheKey') return JSON.stringify((config.id === 'a' ? 'c' : 'd').repeat(64));
      if (method === 'capabilities') return {};
      if (method === 'categories') return [{id:'news',title:'News'}];
      if (method === 'channels') return channels;
      if (method === 'exportCatalog') { events.push('catalog-export:'+config.id); return JSON.stringify(options.refuseCatalog ? null : '{"catalogue":true}'); }
      if (method === 'exportGuide') { events.push('guide-export:'+config.id); return JSON.stringify(JSON.stringify({guideRevision})); }
      if (method === 'guideRevision') return guideRevision;
      if (method === 'epg') {
        reads += 1; guideRevision += 1;
        if (options.epg) return options.epg(args,reads);
        return args.channels.map(channel => ({channelId:channel.id,title:channel.name,
          start:args.from || '2026-10-26T10:00:00.000Z',stop:args.to || '2026-10-26T12:00:00.000Z'}));
      }
      return null;
    }};
  }
  const catalogStore = options.noDisk ? null : {
    async read(key) { return options.read ? options.read(key) : null; },
    async write(key,raw) {
      events.push('disk-start:'+key[0]); if (diskGate) await diskGate.promise;
      if (options.failDisk) throw Error('Disk unavailable');
      saved.set(key,raw); events.push('disk-end:'+key[0]); return true;
    }
  };
  const api = createLibrary({core,userState,createSource,catalogStore,player:{getCapabilities:() => ({})},
    transport:{abort() {},capabilities:() => ({})},
    getState:() => ({playing:false,position:0}),stop:() => Promise.resolve(),
    now:options.now || (() => Date.parse('2026-10-26T11:00:00.000Z'))});
  return {api,userState,channels,events,calls,saved,
    reads:() => reads,catchupChecks:() => catchupChecks,
    holdState() { stateGate = deferred(); return stateGate; },
    holdDisk() { diskGate = deferred(); return diskGate; }};
}

test('an oversized export keeps the previous disk snapshot and never invalidates a catalogue without rollback', async t => {
  const kit = fixture({refuseCatalog:true});
  t.after(() => kit.api.dispose());
  await kit.api.query('sources.load',{id:'a'});
  const key = 'a'.repeat(64), previous = '{"previous":true}';
  kit.saved.set(key,previous);
  await kit.api.query('cache.flush');
  assert.equal(kit.saved.get(key),previous);
  assert.equal(kit.events.includes('disk-start:a'),false);
  await assert.rejects(kit.api.query('media.refresh',{item:{id:'show',kind:'series'}}), error => error.code === 'cache_limit');
  assert.equal(kit.calls.includes('invalidate'),false,'an uncopiable catalogue must not lose its children on refresh');
  assert.equal((await kit.api.query('sources.load',{id:'a'})).channels.length,2);
});

test('ready channel/guide results precede disk persistence and flush drains both before disposal', async t => {
  const kit = fixture(), disk = kit.holdDisk();
  t.after(async () => { disk.resolve(); await kit.api.dispose(); });
  const loaded = await kit.api.query('sources.load',{id:'a'});
  assert.equal(loaded.channels.length,2);
  assert.equal(loaded.cachePersisted,undefined,'pending persistence must not display a cache failure');
  const guide = await kit.api.query('guide',{channels:loaded.channels});
  assert.equal(guide.programmes.length,2);
  assert.equal(kit.events.some(event => event.startsWith('disk-start:')),false,'paint gets a turn before snapshot exports');
  let flushed = false, secondFlushed = false;
  const flush = kit.api.query('cache.flush').then(() => { flushed = true; });
  const secondFlush = kit.api.query('cache.flush').then(() => { secondFlushed = true; });
  await nextTurn();
  assert.deepEqual(kit.events.filter(event => event.startsWith('disk-start:')).sort(),['disk-start:a','disk-start:c']);
  assert.equal(flushed,false);
  assert.equal(secondFlushed,false,'a concurrent flush must observe the same pending persistence');
  const another = await kit.api.query('guide',{channels:loaded.channels.slice(0,1)});
  assert.equal(another.programmes.length,1,'warm visible guide reads do not join pending disk writes');
  disk.resolve(); await Promise.all([flush,secondFlush]);
  assert.equal(kit.saved.size,2);
  assert.equal((await kit.api.query('sources.load',{id:'a'})).cachePersisted,true);
});

test('warm navigation avoids a queued KeyManager write while changed activation still waits for its atomic write', async t => {
  const kit = fixture({noDisk:true}), hold = kit.holdState();
  t.after(async () => { hold.resolve(); await kit.api.dispose(); });
  await kit.api.query('sources.load',{id:'a'});
  const setting = kit.userState.set('unrelated-preference','value'); await nextTurn();
  let warm, changed;
  const navigation = kit.api.query('sources.load',{id:'a'}).then(result => { warm = result; });
  await nextTurn(); assert.equal(warm.channels.length,2);
  const activation = kit.api.query('sources.load',{id:'b'}).then(result => { changed = result; });
  await nextTurn(); assert.equal(changed,undefined,'changing active source keeps the persisted activation gate');
  hold.resolve(); await Promise.all([setting,navigation,activation]);
  assert.equal(changed.source.id,'b');
  assert.equal(JSON.parse(kit.userState.get('local_profiles_v1'))[0].snapshot.activeSourceId,'b');
});

test('source release persists pending guide and catalogue before disposing the worker', async t => {
  const kit = fixture(), disk = kit.holdDisk();
  t.after(async () => { disk.resolve(); await kit.api.dispose(); });
  await kit.api.query('sources.load',{id:'a'});
  await kit.api.query('guide',{channels:kit.channels});
  let released = false;
  const release = kit.api.query('sources.cancel').then(() => { released = true; });
  await nextTurn(); assert.equal(released,false); assert.equal(kit.events.includes('dispose:a'),false);
  disk.resolve(); await release;
  assert.equal(kit.saved.size,2);
  assert.ok(kit.events.indexOf('dispose:a') > kit.events.indexOf('disk-end:c'));
});

test('covered time/channel windows reuse the loaded guide and caller edits do not poison cached programmes', async t => {
  const kit = fixture({noDisk:true}); t.after(() => kit.api.dispose());
  await kit.api.query('sources.load',{id:'a'});
  const broad = await kit.api.query('guide',{channels:kit.channels,from:'2026-10-26T10:00:00.000Z',to:'2026-10-26T12:00:00.000Z'});
  broad.programmes[0].title = 'Caller mutation'; broad.programmes[0].canCatchup = true;
  const narrow = await kit.api.query('guide',{channels:kit.channels.slice(0,1),from:'2026-10-26T10:30:00.000Z',to:'2026-10-26T11:30:00.000Z'});
  assert.equal(narrow.programmes.length,1); assert.equal(narrow.programmes[0].title,'One');
  assert.equal(narrow.programmes[0].canCatchup,false); assert.equal(kit.reads(),1);
  await kit.api.query('guide',{channels:kit.channels,from:'2026-10-26T09:30:00.000Z',to:'2026-10-26T12:00:00.000Z'});
  assert.equal(kit.reads(),2,'uncovered earlier programmes still invoke the source');
});

test('guide presentation serializes each channel once rather than once per programme', async t => {
  let channelSerializations = 0;
  const channel = {id:'one',name:'One',extra:{},toJSON() { channelSerializations += 1; return {id:this.id,name:this.name,extra:this.extra}; }};
  const programmes = Array.from({length:500},(_,index) => ({channelId:'one',title:'Programme '+index,
    start:'2026-10-26T10:00:00.000Z',stop:'2026-10-26T12:00:00.000Z'}));
  const kit = fixture({channels:[channel],noDisk:true,epg:() => programmes}); t.after(() => kit.api.dispose());
  await kit.api.query('sources.load',{id:'a'}); channelSerializations = 0;
  const started = performance.now(), result = await kit.api.query('guide',{channels:[channel]});
  assert.equal(result.programmes.length,500); assert.equal(kit.catchupChecks(),500);
  assert.equal(channelSerializations,2,'one source argument plus one reusable channel JSON string');
  t.diagnostic(JSON.stringify({programmes:500,channelSerializations,renderMs:performance.now()-started}));
});

test('a newer visible window skips superseded guide work that was waiting for cache restoration', async t => {
  const restoring = deferred(), started = deferred();
  const kit = fixture({read:key => {
    if (key[0] !== 'c') return null;
    started.resolve(); return restoring.promise;
  }});
  t.after(async () => { restoring.resolve(null); await kit.api.dispose(); });
  await kit.api.query('sources.load',{id:'a'});
  const stale = kit.api.query('guide',{channels:kit.channels.slice(0,1)});
  const rejected = assert.rejects(stale,error => error.code === 'cancelled');
  await started.promise;
  const current = kit.api.query('guide',{channels:kit.channels.slice(1)});
  await nextTurn(); restoring.resolve(null);
  assert.equal((await current).programmes[0].channelId,'two'); await rejected;
  assert.equal(kit.reads(),1,'stale rows must not add a provider operation');
});

test('guide failures retain their safe category before delayed persistence and disk failures stay nonfatal', async t => {
  const kit = fixture({failDisk:true,epg:() => Promise.reject(Object.assign(Error('private provider details'),{name:'NetworkError'}))});
  t.after(() => kit.api.dispose());
  await kit.api.query('sources.load',{id:'a'});
  await assert.rejects(kit.api.query('guide',{channels:kit.channels}),error => error.code === 'epg_network' && !error.message.includes('private'));
  assert.equal(kit.events.some(event => event.startsWith('disk-start:')),false);
  await kit.api.query('cache.flush');
  assert.equal((await kit.api.query('sources.load',{id:'a'})).channels.length,2);
  await assert.rejects(kit.api.query('guide',{channels:kit.channels.slice(0,1)}),error => error.code === 'epg_retry_deferred' && error.causeCode === 'epg_network');
  assert.equal(kit.reads(),1);
});

test('simultaneous flush callers and teardown all wait for the held catalogue/guide writes', async t => {
  const kit = fixture(), disk = kit.holdDisk();
  t.after(async () => { disk.resolve(); await kit.api.dispose(); });
  await kit.api.query('sources.load',{id:'a'}); await kit.api.query('guide',{channels:kit.channels});
  const settled = [];
  function observe(promise,label) {
    return promise.then(value => { settled.push(label); return value; },error => {
      settled.push(label); assert.equal(error.code,'cancelled');
    });
  }
  const first = observe(kit.api.query('cache.flush'),'first');
  const second = observe(kit.api.query('cache.flush'),'second');
  await nextTurn();
  const disposed = observe(kit.api.dispose(),'dispose'); await nextTurn();
  assert.deepEqual(settled,[]);
  assert.equal(kit.events.includes('dispose:a'),false);
  disk.resolve(); await Promise.all([first,second,disposed]);
  assert.deepEqual(settled.slice().sort(),['dispose','first','second']);
  assert.equal(kit.events.filter(event => event === 'catalog-export:a').length,1);
  assert.equal(kit.events.filter(event => event === 'guide-export:a').length,1);
  assert.ok(kit.events.indexOf('dispose:a') > kit.events.indexOf('disk-end:a'));
  assert.ok(kit.events.indexOf('dispose:a') > kit.events.indexOf('disk-end:c'));
});
