'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const libraryModule = require('../platform/library.js');

const kinds = ['live', 'movie', 'series'];
const syncedAt = Date.now();

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return {promise, resolve, reject};
}

function copy(value) { return JSON.parse(JSON.stringify(value)); }

function virtualTimer() {
  const tasks=new Map();let next=0;
  return {setTimeout(callback,delay){const id=++next;tasks.set(id,{callback,delay});return id;},
    clearTimeout(id){tasks.delete(id);},
    delays(){return Array.from(tasks.values()).map(task=>task.delay).sort((a,b)=>a-b);},
    run(delay){const rows=Array.from(tasks.entries()).filter(([,task])=>task.delay===delay);rows.forEach(([id,task])=>{tasks.delete(id);task.callback();});return rows.length;}};
}

function harness(settings = {}) {
  const calls = [];
  const catalogStarted = deferred();
  const prepareStarted = deferred();
  const prepareStartedByKind = Object.fromEntries(kinds.map(kind => [kind, deferred()]));
  const postPrepareState = deferred();
  const epgStarted = deferred();
  const epgSecondStarted = deferred();
  const epgStateStarted = deferred();
  const epgStateSecondStarted = deferred();
  const sectionGates = Object.fromEntries(kinds.map(kind => [kind, deferred()]));
  const epgGate = deferred();
  const epgGates = settings.epgGates || [epgGate];
  const epgStateGates = settings.epgStateGates || [];
  let epgCallCount = 0,epgStateCallCount = 0;
  let completedPrepares = 0;
  const prepared = {kinds:Object.fromEntries(kinds.map(kind => [kind, {complete:false,count:0,syncedAt:null}]))};
  let userState = {};
  let api;
  let importingManifest = null;

  const core = {
    appLanguages: () => JSON.stringify([{code:'en',name:'English'}]),
    canCatchup: () => false,
    createSource() {
      return {
        invoke(method, raw) {
          const args = JSON.parse(raw || '{}');
          calls.push({method,args});
          if (method === 'capabilities') return Promise.resolve(JSON.stringify({
            fullCatalogCache:true,
            epg:settings.epgCapability || 'supported'
          }));
          if (method === 'connect') return Promise.resolve('null');
          if (method === 'categories') return Promise.resolve(JSON.stringify([{id:'tv',title:'TV'}]));
          if (method === 'channels') return Promise.resolve(JSON.stringify(settings.channels || [{id:'channel-1',name:'Channel 1',categoryId:'tv'}]));
          if (method === 'catalogState') {
            if (calls.some(call => call.method === 'prepareCatalog')) postPrepareState.resolve();
            return Promise.resolve(JSON.stringify(prepared));
          }
          if (method === 'epgState') {
            const index=epgStateCallCount++;
            epgStateStarted.resolve();
            if(index===1)epgStateSecondStarted.resolve();
            if(epgStateGates[index])return epgStateGates[index].promise.then(state=>JSON.stringify(state||{nextRefreshAt:null,retryAt:null}));
            const state = typeof settings.epgState === 'function' ? settings.epgState() : settings.epgState;
            return Promise.resolve(JSON.stringify(state || {nextRefreshAt:null,retryAt:null}));
          }
          if (method === 'prepareCatalog') {
            const count = calls.filter(call => call.method === 'prepareCatalog').length;
            if (count === 1) prepareStarted.resolve();
            prepareStartedByKind[args.kind].resolve();
            if (count === kinds.length) catalogStarted.resolve();
            return sectionGates[args.kind].promise.then(result => {
              const row=settings.incompleteKinds&&settings.incompleteKinds.includes(args.kind)
                ? {kind:args.kind,count:0,syncedAt:null,complete:false} : result;
              if (row.complete === true) prepared.kinds[args.kind] = {complete:true,count:row.count,syncedAt:row.syncedAt};
              completedPrepares++;
              return JSON.stringify(row);
            });
          }
          if (method === 'importCatalog') {
            prepared.kinds.live = {complete:true,count:1,syncedAt};
            if (settings.legacyMediaComplete) {
              prepared.kinds.movie = {complete:true,count:0,syncedAt};
              prepared.kinds.series = {complete:true,count:0,syncedAt};
            }
            return Promise.resolve(JSON.stringify({fromCache:true,categories:[{id:'tv',title:'TV'}],
              channels:[{id:'channel-1',name:'Channel 1',categoryId:'tv'}],syncedAt,refreshDue:false}));
          }
          if (method === 'mediaCategories') return Promise.resolve(JSON.stringify([{id:args.kind+'-cat',title:args.kind}]));
          if (method === 'mediaItemsPage') {
            const item = {id:args.kind+'-ready',kind:args.kind,title:args.kind+' item',categoryId:args.kind+'-cat'};
            return Promise.resolve(JSON.stringify({items:[item],page:1,totalPages:1}));
          }
          if (method === 'epgMapping.set') return Promise.resolve(JSON.stringify({available:true,revision:0}));
          if (method === 'epgCached') return Promise.resolve(JSON.stringify([]));
          if (method === 'beginCatalogExport') return Promise.resolve(JSON.stringify({schema:1,scopeKey:'fixture',generation:1,completeAt:syncedAt,kinds:prepared.kinds,
            parts:settings.batchStore ? [{index:0,key:'live:channels',kind:'live',section:'channels',offset:0,count:1},
              {index:1,key:'series:items',kind:'series',section:'items',offset:0,count:1}] : []}));
          if (method === 'exportCatalogPart') return Promise.resolve(JSON.stringify({raw:'fixture-part-'+args.index,checksum:String(args.index+1).padStart(64,'0')}));
          if (method === 'beginCatalogImport') {
            importingManifest = args.manifest;
            if (!importingManifest.parts.every(part => typeof part.checksum === 'string')) throw new Error('Catalog import manifest is missing checksums.');
            return Promise.resolve(JSON.stringify(true));
          }
          if (method === 'importCatalogPart') return Promise.resolve(JSON.stringify(true));
          if (method === 'commitCatalogImport') {
            prepared.kinds = copy(importingManifest.kinds);
            return Promise.resolve(JSON.stringify(prepared));
          }
          if (method === 'abortCatalogImport') return Promise.resolve(JSON.stringify(true));
          if (method === 'epg') {
            const index = epgCallCount++;
            epgStarted.resolve();
            if (index === 1) epgSecondStarted.resolve();
            return (epgGates[index] || epgGates[epgGates.length - 1]).promise.then(rows => JSON.stringify(rows));
          }
          if (method === 'guideRevision') return Promise.resolve(JSON.stringify(0));
          if (method === 'exportGuide') return Promise.resolve(JSON.stringify('{}'));
          if (method === 'cacheKey') return Promise.resolve(JSON.stringify('d'.repeat(64)));
          if (method === 'legacyCacheKey') return Promise.resolve(JSON.stringify('a'.repeat(64)));
          if (method === 'guideCacheKey') return Promise.resolve(JSON.stringify('b'.repeat(64)));
          if (method === 'legacyGuideCacheKey') return Promise.resolve(JSON.stringify('c'.repeat(64)));
          if (method === 'metadata.configure') return Promise.resolve(JSON.stringify(true));
          if (method === 'metadata.details') return Promise.resolve(JSON.stringify({id:args.item.id,kind:args.item.kind,title:'cached details'}));
          if (method === 'metadata.refresh') return Promise.resolve(JSON.stringify({id:args.item.id,kind:args.item.kind,title:'refreshed details'}));
          if (method === 'metadata.cacheKey') return Promise.resolve(JSON.stringify('c'.repeat(64)));
          if (method === 'metadata.export') return Promise.resolve(JSON.stringify('{}'));
          if (method === 'metadata.import') return Promise.resolve(JSON.stringify(true));
          if (method === 'subscriptionExpiry') return Promise.resolve(JSON.stringify({kind:'unknown',date:null}));
          if (method === 'dispose') return Promise.resolve();
          throw new Error('Unexpected canonical RPC: '+method);
        },
        dispose() { return Promise.resolve(); }
      };
    },
    hashPin: value => Promise.resolve(value),
    newSourceId: () => 'generated-source',
    parentalRules(operation, raw) {
      if (operation === 'protects') return 'false';
      if (operation === 'visibleIds') return 'null';
      if (operation === 'validate') return JSON.stringify(JSON.parse(raw).rules);
      return JSON.stringify('fixture-key');
    },
    profileNormalize: raw => raw,
    providerCachePolicy: () => JSON.stringify(settings.cachePolicy || {catalogMaxAgeMs:86400000,epgMaxAgeMs:21600000,epgRetryDelayMs:0}),
    resumeDecision: () => JSON.stringify({allowed:false,position:0}),
    resumeDecisionForKind: () => JSON.stringify({allowed:false,position:0}),
    showProfilePicker: () => false,
    supporterActive: () => false,
    verifyPin: () => Promise.resolve(true)
  };

  const storage = {
    read: () => copy(userState),
    get: key => Object.prototype.hasOwnProperty.call(userState,key) ? userState[key] : null,
    set(key,value) {
      if (value == null) delete userState[key]; else userState[key] = value;
      return Promise.resolve(copy(userState));
    },
    update(change) {
      const next = copy(userState);
      const returned = change(next);
      userState = returned === undefined ? next : copy(returned);
      return Promise.resolve(copy(userState));
    }
  };
  const player = {getCapabilities:() => ({}), stop:() => Promise.resolve()};
  const options = {
    core,
    sourceStore:{read:() => [],write:() => Promise.resolve()},
    userState:storage,
    validation:{validateSource:() => null},
    player,
    transport:{capabilities:() => ({cookies:true,userAgent:true}),abort() {},request() { throw new Error('Provider HTTP is outside this fixture.'); }},
    getState:() => ({playing:false,buffering:false}),
    stop:() => Promise.resolve(),
    openStream:() => Promise.resolve(),
    onError:error => { throw error; },
    onProgress:() => { if (api) calls.push({state:copy(api.getState())}); }
  };
  if (settings.now) options.now = settings.now;
  if (settings.timer) { options.setTimeout = settings.timer.setTimeout; options.clearTimeout = settings.timer.clearTimeout; }
  if (settings.catalogStore) options.catalogStore = settings.catalogStore;
  else if (settings.batchStore) options.catalogStore = {
    protectKeys(keys) { assert.equal(keys.length,4); return () => {}; },
    read:() => Promise.resolve(null),
    readBatch:key => Promise.resolve(settings.batchStore.current && settings.batchStore.current.key===key ? copy(settings.batchStore.current) : null),
    readBatchPart:(key,token,index) => Promise.resolve(settings.batchStore.current&&settings.batchStore.current.key===key&&
      settings.batchStore.current.token===token ? settings.batchStore.parts[index] : null),
    writeBatch:async function (key,manifest,readPart) {
      const saved = copy(manifest), parts = [];
      for (const descriptor of saved.parts) {
        const value = await readPart(descriptor);
        descriptor.checksum = value.checksum; descriptor.bytes = Buffer.byteLength(value.raw);
        parts[descriptor.index] = value.raw;
      }
      settings.batchStore.current = {key,manifest:saved,token:'1-0',count:parts.length};
      settings.batchStore.parts = parts; return true;
    },
    discardBatch:() => Promise.resolve(true),
    mark:() => Promise.resolve(true),
    write:() => Promise.resolve(true)
  };
  api = libraryModule.create(options);

  return {
    api,
    options,
    calls,
    prepared,
    catalogStarted:catalogStarted.promise,
    prepareStarted:prepareStarted.promise,
    prepareStartedByKind:Object.fromEntries(kinds.map(kind => [kind,prepareStartedByKind[kind].promise])),
    postPrepareState:postPrepareState.promise,
    epgStarted:epgStarted.promise,
    epgSecondStarted:epgSecondStarted.promise,
    epgStateStarted:epgStateStarted.promise,
    epgStateSecondStarted:epgStateSecondStarted.promise,
    get epgCallCount() { return epgCallCount; },
    sectionGates,
    epgGate,
    async seedSource() {
      await api.query('bootstrap');
      await api.query('profiles.create',{name:'Fixture'});
      await api.query('sources.add',{config:{
        id:'fixture-source',kind:'m3u',label:'Fixture',
        fields:{playlistUrl:'https://fixture.invalid/list.m3u'},settings:{}
      }});
    }
  };
}

function legacyBatchStore(raw) {
  const batches=new Map();
  return {protectKeys(keys){assert.equal(keys.length,4);return()=>{};},
    read(key){return Promise.resolve(key==='a'.repeat(64)?{raw,token:'legacy'}:null);},
    readBatch(key){const value=batches.get(key);return Promise.resolve(value?copy(value):null);},
    readBatchPart(key,token,index){const value=batches.get(key);return Promise.resolve(value&&value.token===token?value.parts[index]:null);},
    writeBatch:async function(key,manifest,readPart,writeOptions){
      if(writeOptions)assert.equal(writeOptions.preserveKeys.length,4);
      const saved=copy(manifest),parts=[];
      for(const descriptor of saved.parts){const part=await readPart(descriptor);parts[descriptor.index]=part.raw;}
      batches.set(key,{manifest:saved,parts,token:'normalized-1',count:parts.length});return true;
    },
    discardBatch(key,token){const value=batches.get(key);if(value&&value.token===token)batches.delete(key);return Promise.resolve(true);},
    mark(){return Promise.resolve(true);},remove(key){batches.delete(key);return Promise.resolve(true);}};
}

test('cold source load waits for independent catalog and EPG attempts, then keeps successful sections usable', async t => {
  const kit = harness();
  t.after(() => kit.api.dispose());
  await kit.seedSource();

  const finished = deferred();
  let loaded;
  const load = kit.api.query('sources.load',{id:'fixture-source'}).then(value => {
    loaded = value;
    finished.resolve();
    return value;
  });
  const first = await Promise.race([
    kit.catalogStarted.then(() => 'catalogs-started'),
    finished.promise.then(() => 'load-finished')
  ]);

  assert.equal(first,'catalogs-started','first use must start every full-catalog preparation before sources.load resolves');
  assert.equal(kit.api.getState().catalogPreparation.sections.live.status,'pending');
  assert.equal(kit.api.getState().catalogPreparation.sections.movie.status,'pending');
  assert.equal(kit.api.getState().catalogPreparation.sections.series.status,'pending');

  kit.sectionGates.live.resolve({kind:'live',count:1,syncedAt,complete:true});
  kit.sectionGates.movie.resolve({kind:'movie',count:1,syncedAt,complete:true});
  kit.sectionGates.series.reject(new Error('series endpoint unavailable'));
  const epg = await Promise.race([
    kit.epgStarted.then(() => 'epg-started'),
    finished.promise.then(() => 'load-finished')
  ]);
  assert.equal(epg,'epg-started','EPG must be attempted after or alongside catalog preparation');
  kit.epgGate.reject(Object.assign(new Error('private-guide.fixture could not be reached'),{name:'NetworkError'}));
  await load;

  assert.deepEqual(kit.calls.filter(call => call.method === 'prepareCatalog').map(call => call.args.kind).sort(),kinds);
  assert.equal(new Set(kit.calls.filter(call => call.method === 'prepareCatalog').map(call => call.args.refreshKey)).size,1,
    'all catalog kinds share one canonical refresh batch key');
  assert.equal(kit.calls.filter(call => call.method === 'epg').length,1);
  assert.equal(kit.calls.some(call=>call.state&&call.state.loadingStage==='catalog-persist'),true,
    'the final preparation stage is visible after the EPG attempt completes');
  assert.equal(loaded.channels.length,1);
  assert.equal(loaded.preparation.sections.live.status,'ready');
  assert.equal(loaded.preparation.sections.movie.status,'ready');
  assert.equal(loaded.preparation.sections.series.status,'failed');
  assert.equal(loaded.preparation.sections.epg.status,'failed');
  assert.equal(loaded.preparation.cacheState.kinds.movie.complete,true);
  assert.equal(loaded.preparation.cacheState.kinds.series.complete,false);
  assert.equal(loaded.preparation.warnings.some(warning => warning.kind === 'series'),true);
  assert.equal(loaded.preparation.warnings.some(warning => warning.kind === 'epg'),true);

  const moviePage = await kit.api.query('catalog.items',{kind:'movie',page:1});
  assert.equal(moviePage.items[0].id,'movie-ready','a prepared movie root remains available after another section fails');
});

test('a warm complete catalog opens before background EPG or refresh attempts finish', async t => {
  const kit = harness();
  t.after(() => kit.api.dispose());
  await kit.seedSource();
  kinds.forEach(kind => { kit.prepared.kinds[kind] = {complete:true,count:1,syncedAt}; });

  let result;
  const load = kit.api.query('sources.load',{id:'fixture-source'}).then(value => { result = value; return value; });
  const first = await Promise.race([
    load.then(() => 'load-finished'),
    new Promise(resolve => setTimeout(() => resolve('still-loading'),100))
  ]);

  assert.equal(first,'load-finished','fresh cached sections must paint without waiting for network work');
  assert.equal(result.channels.length,1);
  assert.equal(kit.calls.filter(call => call.method === 'catalogState').length,1,
    'the preparation decision comes from canonical catalog state');
  assert.deepEqual(kit.calls.filter(call => call.method === 'prepareCatalog').map(call => call.args.kind),[],
    'fresh sections should not trigger a provider refresh');
  if (kit.calls.some(call => call.method === 'epg')) kit.epgGate.reject(new Error('background guide failure'));
  await load;
});

test('a legacy live-only cache opens first and schedules missing roots in the background', async t => {
  const catalogStore = legacyBatchStore('legacy-live');
  const kit = harness({catalogStore});
  t.after(() => kit.api.dispose());
  await kit.seedSource();

  const loading = kit.api.query('sources.load',{id:'fixture-source'});
  const loaded = await Promise.race([
    loading,
    new Promise((_,reject) => setTimeout(() => reject(new Error('legacy live cache waited for missing VOD roots')),100))
  ]);
  assert.equal(loaded.channels.length,1);
  assert.equal(kit.calls.filter(call => call.method === 'importCatalog').length,1);
  await Promise.race([kit.prepareStarted,new Promise((_,reject) => setTimeout(() => reject(new Error('missing roots were not scheduled')),100))]);
  assert.equal(kit.calls.some(call => call.method === 'prepareCatalog' && call.args.kind !== 'live'),true);
});

test('a restored legacy M3U media hint satisfies roots without a provider refresh', async t => {
  const catalogStore = legacyBatchStore('legacy-m3u-with-media');
  const kit = harness({catalogStore,legacyMediaComplete:true});
  t.after(() => kit.api.dispose());
  await kit.seedSource();

  const loaded = await kit.api.query('sources.load',{id:'fixture-source'});
  assert.equal(loaded.channels.length,1);
  assert.deepEqual(kit.calls.filter(call => call.method === 'prepareCatalog').map(call => call.args.kind),[]);
  assert.equal(kit.prepared.kinds.movie.complete,true);
  assert.equal(kit.prepared.kinds.series.complete,true);
});

test('a checksummed chunk generation restores all sections offline in the next runtime', async t => {
  const batchStore={current:null,parts:[]},kit=harness({batchStore});
  t.after(()=>kit.api.dispose());
  await kit.seedSource();

  const loading=kit.api.query('sources.load',{id:'fixture-source'});
  await kit.catalogStarted;
  kit.sectionGates.live.resolve({kind:'live',count:1,syncedAt,complete:true});
  kit.sectionGates.movie.resolve({kind:'movie',count:1,syncedAt,complete:true});
  kit.sectionGates.series.resolve({kind:'series',count:1,syncedAt,complete:true});
  await kit.epgStarted;kit.epgGate.resolve([]);
  const first=await loading;
  assert.equal(first.cachePersisted,true);
  assert.ok(batchStore.current.manifest.parts.every(part=>typeof part.checksum==='string'&&part.checksum.length>0),
    'the exported chunk checksums are attached before encrypting the manifest');

  await kit.api.dispose();
  const start=kit.calls.length;kit.prepared.kinds=Object.fromEntries(kinds.map(kind=>[kind,{complete:false,count:0,syncedAt:null}]));
  const restarted=libraryModule.create(kit.options);t.after(()=>restarted.dispose());
  const restored=await restarted.query('sources.load',{id:'fixture-source'});
  const calls=kit.calls.slice(start);
  assert.equal(restored.channels.length,1);
  assert.equal(restored.preparation.cacheState.kinds.movie.complete,true);
  assert.equal(calls.filter(call=>call.method==='prepareCatalog').length,0,'restored complete roots open without another provider attempt');
  assert.equal(calls.filter(call=>call.method==='beginCatalogImport').length,1);
  assert.equal(calls.filter(call=>call.method==='importCatalogPart').length,2);
  assert.equal(calls.filter(call=>call.method==='commitCatalogImport').length,1);
});

test('warm refresh uses independent 24-hour catalog timestamps and rearms after the flight clears', async t => {
  const timer=virtualTimer(),clock=syncedAt,kit=harness({timer,now:()=>clock,epgCapability:'unsupported'});
  t.after(()=>kit.api.dispose());
  await kit.seedSource();
  kit.prepared.kinds.live={complete:true,count:1,syncedAt:clock};
  kit.prepared.kinds.movie={complete:true,count:2,syncedAt:clock-86400001};
  kit.prepared.kinds.series={complete:true,count:3,syncedAt:clock-43200000};

  const loaded=await kit.api.query('sources.load',{id:'fixture-source'});
  assert.equal(loaded.channels.length,1);
  assert.deepEqual(kit.calls.filter(call=>call.method==='prepareCatalog'),[],'warm cache is returned before scheduled refresh');
  assert.equal(timer.run(0),1);
  await kit.prepareStartedByKind.movie;
  assert.deepEqual(kit.calls.filter(call=>call.method==='prepareCatalog').map(call=>call.args.kind),['movie'],
    'only the section older than its own 24-hour deadline is refreshed');
  kit.sectionGates.movie.resolve({kind:'movie',count:2,syncedAt:clock,complete:true});
  await kit.postPrepareState;
  await new Promise(resolve=>setImmediate(resolve));
  assert.ok(timer.delays().includes(12*60*60*1000),
    'the next timer is armed after the active background flight is cleared, using the still-fresh series timestamp');
});

test('a failed catalog section retains its cache and schedules a one-hour retry', async t => {
  const timer=virtualTimer(),clock=syncedAt,kit=harness({timer,now:()=>clock,epgCapability:'unsupported'});
  t.after(()=>kit.api.dispose());
  await kit.seedSource();
  kit.prepared.kinds.live={complete:true,count:1,syncedAt:clock};
  kit.prepared.kinds.movie={complete:true,count:2,syncedAt:clock-86400001};
  kit.prepared.kinds.series={complete:true,count:3,syncedAt:clock};

  const loaded=await kit.api.query('sources.load',{id:'fixture-source'});
  assert.equal(loaded.channels.length,1);
  timer.run(0);
  await kit.prepareStartedByKind.movie;
  kit.sectionGates.movie.reject(new Error('catalog timeout'));
  await kit.postPrepareState;
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(kit.api.getState().catalogPreparation.sections.movie.status,'failed');
  assert.equal(kit.api.getState().catalogPreparation.sections.movie.count,2,
    'the previously prepared movie count remains available when refresh fails');
  assert.ok(timer.delays().includes(60*60*1000),'failed sections are retried after one hour');
  assert.equal((await kit.api.query('catalog.items',{kind:'movie',page:1})).items[0].id,'movie-ready');
});

test('an incomplete resolved catalog result is classified as a section failure with a bounded retry', async t => {
  const timer=virtualTimer(),clock=syncedAt,kit=harness({timer,now:()=>clock,epgCapability:'unsupported',incompleteKinds:['movie']});
  t.after(()=>kit.api.dispose());
  await kit.seedSource();
  kit.prepared.kinds.live={complete:true,count:1,syncedAt:clock};
  kit.prepared.kinds.movie={complete:true,count:2,syncedAt:clock-86400001};
  kit.prepared.kinds.series={complete:true,count:3,syncedAt:clock};

  const loaded=await kit.api.query('sources.load',{id:'fixture-source'});
  assert.equal(loaded.channels.length,1);
  timer.run(0);
  await kit.prepareStartedByKind.movie;
  kit.sectionGates.movie.resolve({kind:'movie',count:2,syncedAt:clock,complete:true});
  await kit.postPrepareState;
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(kit.api.getState().catalogPreparation.sections.movie.status,'failed');
  assert.equal(kit.api.getState().catalogPreparation.sections.movie.count,2);
  assert.ok(timer.delays().includes(60*60*1000),'an incomplete successful RPC cannot create a zero-delay refresh loop');
});

test('generic EPG unavailability remains retryable and recovers on the next background attempt', async t => {
  const timer=virtualTimer(),clock={value:syncedAt},firstGuide=deferred(),secondGuide=deferred();
  const kit=harness({timer,now:()=>clock.value,epgGates:[firstGuide,secondGuide],cachePolicy:{
    catalogMaxAgeMs:86400000,epgMaxAgeMs:21600000,epgRetryDelayMs:900000
  }});
  t.after(()=>kit.api.dispose());
  await kit.seedSource();
  kinds.forEach(kind=>{kit.prepared.kinds[kind]={complete:true,count:1,syncedAt:clock.value};});

  const loaded=await kit.api.query('sources.load',{id:'fixture-source'});
  assert.equal(loaded.channels.length,1);
  assert.equal(timer.run(0),1);
  await kit.epgStarted;
  firstGuide.reject(new Error('unclassified guide failure'));
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(kit.api.getState().catalogPreparation.sections.epg.status,'failed');
  assert.ok(timer.delays().includes(900000),'generic epg_unavailable errors receive a retry deadline');

  clock.value+=900000;
  assert.equal(timer.run(900000),1);
  const retried=await Promise.race([kit.epgSecondStarted.then(()=>true),new Promise(resolve=>setTimeout(()=>resolve(false),100))]);
  assert.equal(retried,true,'the EPG refresh timer starts a second provider attempt');
  secondGuide.resolve([]);
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(kit.epgCallCount,2);
  assert.equal(kit.api.getState().catalogPreparation.sections.epg.status,'empty');
});

test('EPG refresh deadline stays anchored to the canonical feed timestamp across guide reads', async t => {
  const timer=virtualTimer(),clock={value:syncedAt},sixHours=6*60*60*1000;
  const firstGuide=deferred(),secondGuide=deferred();
  const nextRefreshAt=clock.value-4*60*60*1000+sixHours;
  const kit=harness({timer,now:()=>clock.value,epgGates:[firstGuide,secondGuide],epgState:()=>({nextRefreshAt,retryAt:null}),cachePolicy:{
    catalogMaxAgeMs:86400000,epgMaxAgeMs:sixHours,epgRetryDelayMs:900000
  }});
  t.after(()=>kit.api.dispose());
  await kit.seedSource();
  kinds.forEach(kind=>{kit.prepared.kinds[kind]={complete:true,count:1,syncedAt:clock.value};});

  const loaded=await kit.api.query('sources.load',{id:'fixture-source'});
  assert.equal(loaded.channels.length,1);
  timer.run(0);
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(kit.epgCallCount,0,'a fresh canonical EPG cache is not refreshed during warm startup');
  assert.ok(timer.delays().includes(2*60*60*1000),'warm startup schedules from the canonical six-hour deadline');

  clock.value+=60*60*1000;
  const firstWindow={channels:loaded.channels,from:'2000-01-01T09:00:00.000Z',to:'2000-01-01T10:00:00.000Z'};
  const firstRead=kit.api.query('guide',firstWindow);
  await kit.epgStarted;firstGuide.resolve([]);await firstRead;
  await new Promise(resolve=>setImmediate(resolve));
  assert.ok(timer.delays().includes(60*60*1000),'a guide read cannot move the next refresh beyond the original feed deadline');

  clock.value+=30*60*1000;
  const secondRead=kit.api.query('guide',{...firstWindow,to:'2000-01-01T10:30:00.000Z'});
  await kit.epgSecondStarted;secondGuide.resolve([]);await secondRead;
  await new Promise(resolve=>setImmediate(resolve));
  assert.ok(timer.delays().includes(30*60*1000),'repeated guide reads keep reducing the remaining canonical age');
});

test('a cold EPG success leaves only one canonical refresh timer after nested result handlers', async t => {
  const timer=virtualTimer(),clock=syncedAt,guide=deferred(),stateOne=deferred(),stateTwo=deferred(),sixHours=6*60*60*1000;
  const nextRefreshAt=clock+sixHours;
  const kit=harness({timer,now:()=>clock,epgGates:[guide],epgStateGates:[stateOne,stateTwo]});
  t.after(()=>kit.api.dispose());
  await kit.seedSource();
  const loading=kit.api.query('sources.load',{id:'fixture-source'});
  await kit.catalogStarted;
  kinds.forEach(kind=>kit.sectionGates[kind].resolve({kind,count:1,syncedAt:clock,complete:true}));
  await kit.epgStarted;guide.resolve([]);await loading;
  await kit.epgStateStarted;await kit.epgStateSecondStarted;
  stateOne.resolve({nextRefreshAt,retryAt:null});stateTwo.resolve({nextRefreshAt,retryAt:null});
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(timer.delays().filter(delay=>delay===sixHours).length,1,
    'the guide success and preload result share one timer rather than scheduling duplicate refreshes');
});

test('full-catalog detail refresh uses metadata refresh without invalidating prepared roots', async t => {
  const kit=harness({epgCapability:'unsupported'});
  t.after(()=>kit.api.dispose());
  await kit.seedSource();
  kinds.forEach(kind=>{kit.prepared.kinds[kind]={complete:true,count:1,syncedAt};});
  await kit.api.query('sources.load',{id:'fixture-source'});

  const item={id:'movie-ready',kind:'movie',title:'Movie'};
  const refreshed=await kit.api.query('media.refresh',{item});
  assert.equal(refreshed.title,'refreshed details');
  assert.equal(kit.calls.some(call=>call.method==='metadata.refresh'),true);
  assert.equal(kit.calls.some(call=>call.method==='invalidate'||call.method==='exportCatalog'),false,
    'refreshing provider details must retain the prepared movie and series roots');
});

test('an empty first-use catalog cannot become a successful warm load on retry', async t => {
  const kit = harness({channels:[],epgCapability:'unavailable'});
  t.after(() => kit.api.dispose());
  await kit.seedSource();
  kinds.forEach(kind => kit.sectionGates[kind].resolve({kind,count:0,syncedAt:Date.now(),complete:true}));
  await assert.rejects(kit.api.query('sources.load',{id:'fixture-source'}), error => error.code === 'catalog_empty');
  await assert.rejects(kit.api.query('sources.load',{id:'fixture-source'}), error => error.code === 'catalog_empty');
});
