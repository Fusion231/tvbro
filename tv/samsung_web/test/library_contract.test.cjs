'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const libraryModule = require('../platform/library.js');
const libraries = new Set();
function createLibrary(options) { const api=libraryModule.create(options);libraries.add(api);return api; }
test.afterEach(async()=>{const pending=[...libraries];libraries.clear();await Promise.all(pending.map(api=>api.dispose()));});
const createStore = require('../platform/secure_store.js').create;
const createUserState = require('../platform/user_state.js').create;
const createCloud = require('../platform/cloud.js').create;
const createCatalogStore = require('../platform/catalog_store.js').create;
const project = path.resolve(__dirname, '..');
const output = path.resolve(project, '../output/samsung-web');
const rawCore = path.join(output, 'core/core.js');
const build = JSON.parse(fs.readFileSync(path.join(output, 'latest-build.json'), 'utf8'));
function deferred() { let resolve, reject; const promise = new Promise((a,b)=>{resolve=a;reject=b;}); return {promise,resolve,reject}; }
function modules(now) {
  const sandbox = {console, crypto:crypto.webcrypto, setTimeout, clearTimeout, TextEncoder, TextDecoder};
  sandbox.window = sandbox; sandbox.self = sandbox;
  if(now)sandbox.Date=class extends Date { constructor(...args){super(...(args.length?args:[now()]));} static now(){return now();} };
  vm.createContext(sandbox);
  const rawHash = crypto.createHash('sha256').update(fs.readFileSync(rawCore)).digest('hex');
  const packaged = build.inputHashes['tv/output/samsung-web/core/core.js'] === rawHash;
  for (const file of ['polyfills.js', 'panel-validation.js']) vm.runInContext(fs.readFileSync(path.join(build.payload,file),'utf8'),sandbox,{filename:file});
  vm.runInContext(fs.readFileSync(packaged ? path.join(build.payload,'canonical-core.js') : rawCore,'utf8'),sandbox,{filename:'actual-canonical-core.js'});
  return {core:sandbox.TVBroCanonical,validation:sandbox.TVBroPanelValidation};
}
function deviceStorage() {
  const records=new Map(); let fail=false, failWrite=null, delayed=null;
  return {records, failNext(){fail=true;}, failWhen(predicate){failWrite=predicate;}, deferNext(){delayed={started:deferred(),done:deferred()};return delayed;},
    sdk:{getData(id){if(!records.has(id.name)){const error=Error('Not found');error.name='NotFoundError';throw error;}return records.get(id.name);},
      getDataAliasList(){return [...records.keys()].map(name=>({name,packageId:'TVBroWebTV'}));},
      saveData(alias,value,password,success,failure){
        assert.equal(password,null);
        const hold=delayed; delayed=null;
        function finish(){if(fail||(failWrite&&failWrite(alias,value))){fail=false;failWrite=null;const error=Error('Device write failed');error.name='UnknownError';failure(error);}else if(records.has(alias)){const error=Error('Alias already exists');error.name='UnknownError';failure(error);}else{records.set(alias,value);success();}}
        if(hold){hold.started.resolve();hold.done.promise.then(finish);}else queueMicrotask(finish);
      },removeData(id){if(!records.delete(id.name)){const error=Error('Not found');error.name='NotFoundError';throw error;}}}};
}
function persistedUserState(kit){return createStore({tizen:kit.options.tizen}).readUserState();}
let nextHarness=0;
function harness(route,now) {
  const real=modules(now), device=deviceStorage(), tizen={keymanager:device.sdk,package:{getPackageInfo(){return {id:'TVBroWebTV'};}}}, store=createStore({tizen});
  const userState=createUserState({store});
  const calls={requests:[],open:[],stop:0,rect:[],seek:[],abort:0,events:[]};
  let state={playing:false,buffering:false,position:0,duration:0,isLive:true};
  let supported=false;
  const suffix=++nextHarness;
  const player={setRect(...rect){calls.rect.push(rect);},seek(position){calls.seek.push(position);state.position=position;return Promise.resolve();},
    getCapabilities(){return {playbackRates:[1,2]};},getTracks(){return {audio:[],subtitles:[]};},
    selectTrack(){},setSubtitlesEnabled(){},setSpeed(){},setDisplayMode(){}};
  const transport={capabilities(){return {cookies:true,userAgent:true};},abort(){calls.abort++;},
    async request(text){const request=JSON.parse(text);calls.requests.push(request);calls.events.push('http:'+new URL(request.url).host);
      const result=await route(new URL(request.url),request);
      return JSON.stringify({status:200,body:typeof result==='string'?result:JSON.stringify(result),url:request.url,headers:{},decoded:true});}};
  const options={...real,tizen,userState,player,transport,sourceStore:store,
    cloud:{hasSession(){return supported;},status(){return {configured:true};},query(action){assert.equal(action,'supporter.status');return Promise.resolve({supported:true,valid_until:'2099-01-01T00:00:00Z'});}},
    getState(){return {...state};},
    stop(){calls.stop++;calls.events.push('stop');state.playing=false;return Promise.resolve();},
    openStream(stream,rect){calls.open.push({stream,rect});calls.events.push('open:'+stream.url);
      state={...state,playing:true,isLive:stream.isLive,position:0,duration:stream.isLive?0:100};return Promise.resolve();},
    onError(error){throw error;}};
  const api=createLibrary(options);
  return {...real,api,calls,device,store,userState,options,suffix,
    progress(position,duration){state.position=position;state.duration=duration;},supporter(value){supported=value;}};
}
function chunkedCatalogStore(store) {
  const batches=new Map();let generation=0;store.batchWriteOptions=[];
  store.readBatch=async key=>{
    const saved=batches.get(key);
    return saved?{manifest:JSON.parse(JSON.stringify(saved.manifest)),token:saved.token,count:saved.parts.length}:null;
  };
  store.readBatchPart=async(key,token,index)=>{
    const saved=batches.get(key);
    if(!saved||saved.token!==token||!Number.isInteger(index)||index<0||index>=saved.parts.length)throw Error('Batch part unavailable');
    return saved.parts[index];
  };
  store.writeBatch=async(key,manifest,readPart,writeOptions)=>{
    store.batchWriteOptions.push(writeOptions);
    const saved=JSON.parse(JSON.stringify(manifest)),parts=[];
    try {
      for(const descriptor of saved.parts) {
        const value=await readPart(descriptor);
        if(!value||typeof value.raw!=='string'||typeof value.checksum!=='string')return false;
        descriptor.bytes=Buffer.byteLength(value.raw);descriptor.checksum=value.checksum;parts[descriptor.index]=value.raw;
      }
      if(store.write&&await store.write(key,JSON.stringify(saved),'catalog',writeOptions)===false)return false;
    } catch(_) { return false; }
    batches.set(key,{manifest:saved,parts,token:String(++generation)+'-0'});return true;
  };
  store.discardBatch=async(key,token)=>{
    const saved=batches.get(key);if(!saved||saved.token!==token)return false;batches.delete(key);
    if(store.discard)await store.discard(key,token);return true;
  };
  if(store.remove) {const remove=store.remove.bind(store);store.remove=async key=>{batches.delete(key);return remove(key);};}
  return store;
}
function catalogFileSystem() {
  const files=new Map();let rejected=null;
  function notFound(){const error=Error('Missing fixture file');error.name='NotFoundError';throw error;}
  function fileFor(name) {
    const file={name,isDirectory:false,raw:'',get fileSize(){return Buffer.byteLength(this.raw);},
      openStream(mode,success) {
        if(mode==='w')file.raw='';
        let position=0;
        const bytes=()=>new TextEncoder().encode(file.raw);
        queueMicrotask(()=>success({get bytesAvailable(){return bytes().length-position;},
          get eof(){return position>=bytes().length;},
          readBytes(count){const value=bytes().slice(position,position+count);position+=value.length;return Array.from(value);},
          writeBytes(value){if(rejected&&rejected(name))throw Error('Fixture disk refused the write');file.raw+=new TextDecoder().decode(new Uint8Array(value));},close(){}}));
      }};
    files.set(name,file);return file;
  }
  const directory={isDirectory:true,fullPath:'wgt-private/tvbro_catalog_v1',
    resolve(name){return files.get(name)||notFound();},createFile(name){return fileFor(name);},
    createDirectory(){return directory;},listFiles(success){queueMicrotask(()=>success([...files.values()]));},
    deleteFile(fullPath,success){files.delete(fullPath.split('/').pop());queueMicrotask(success);}};
  const root={resolve(name){if(name==='tvbro_catalog_v1')return directory;return notFound();},createDirectory(){return directory;}};
  const environment={Blob,TextEncoder,TextDecoder,setTimeout,tizen:{filesystem:{resolve(path,success){assert.equal(path,'wgt-private');queueMicrotask(()=>success(root));}}}};
  return {environment,files,fail(predicate){rejected=predicate;},restart(){return createCatalogStore({environment});}};
}
function m3u(host,name='Fixture') { return '#EXTM3U\n#EXTINF:-1 group-title="News",'+name+'\nhttps://streams.fixture/'+host+'.m3u8\n'; }
function m3uConfig(id,host) {return {id,kind:'m3u',label:id,fields:{playlistUrl:'https://'+host+'/list.m3u'},settings:{}};}
async function coreInvoke(engine,method,args={}) { return JSON.parse(await engine.invoke(method,JSON.stringify(args))); }
function keyedSnapshot(raw,key) {const envelope=JSON.parse(raw);envelope.key=key;envelope.checksum=crypto.createHash('sha256').update(envelope.payload).digest('hex');return JSON.stringify(envelope);}
async function seedLegacySnapshots(kit,config,scope,records) {
  const engine=kit.core.createSource(JSON.stringify(config),async text=>{
    const request=JSON.parse(text),body=request.url.indexOf('/guide')>=0
      ? '<tv><channel id="legacy-guide"><display-name>Legacy channel</display-name></channel><programme channel="legacy-guide" start="20000101100000 +0000" stop="20990101100000 +0000"><title>Cached legacy guide</title></programme></tv>'
      : '#EXTM3U\n#EXTINF:-1 tvg-id="legacy-guide" group-title="News",Legacy channel\nhttps://streams.fixture/legacy.m3u8\n';
    return JSON.stringify({status:200,body,url:request.url,headers:{},decoded:true});
  });
  try {
    await coreInvoke(engine,'categories');const channels=await coreInvoke(engine,'channels');
    if(config.fields.epgUrl) await coreInvoke(engine,'epg',{channels});
    const normalizedKey=await coreInvoke(engine,'cacheKey',{scope}),legacyKey=await coreInvoke(engine,'legacyCacheKey',{scope});
    const guideKey=await coreInvoke(engine,'guideCacheKey',{scope}),legacyGuideKey=await coreInvoke(engine,'legacyGuideCacheKey',{scope});
    records.set(legacyKey,{raw:keyedSnapshot(await coreInvoke(engine,'exportCatalog',{scope}),legacyKey),token:'legacy-catalog'});
    records.set(legacyGuideKey,{raw:keyedSnapshot(await coreInvoke(engine,'exportGuide',{scope}),legacyGuideKey),token:'legacy-guide'});
    return {normalizedKey,legacyKey,guideKey,legacyGuideKey};
  } finally { await engine.dispose(); }
}
function catalogStoreFor(records,failWrite) {
  const writeOptionsSeen=[],protectionLeases=[];
  return {writeOptionsSeen,protectionLeases,protectKeys(keys){const lease={keys:[...keys],released:false};protectionLeases.push(lease);return()=>{lease.released=true;};},
    async read(key){return records.has(key)?Object.assign({},records.get(key)):null;},
    async write(key,raw,kind,writeOptions){if(writeOptions)writeOptionsSeen.push({key,kind,writeOptions});if(failWrite&&failWrite(key))return false;records.set(key,{raw,token:'normalized'});return true;},
    async remove(key){records.delete(key);return true;},async discard(key,token){const saved=records.get(key);if(saved&&saved.token===token)records.delete(key);return true;}};
}
async function profile(kit,name,pin) {await kit.api.query('bootstrap');return (await kit.api.query('profiles.create',{name,pin})).profile;}
async function source(kit,config){await kit.api.query('sources.add',{config});return config;}
async function rejectsCode(promise,code){await assert.rejects(promise,error=>error.code===code);}

test('language selection uses the global app_language key without a session and preserves it after reload or failed changes',async()=>{
  const kit=harness(()=>{throw Error('Language selection must not contact a provider');});
  const cloud=await attachCloud(kit,{authenticated:false});
  const initial=await kit.api.query('language.get');
  assert.equal(initial.languageCode,'en');assert.equal(initial.languageSelected,false);
  assert.ok(initial.languages.some(language=>language.code==='pl'));
  const before=localProfileState(kit),selected=await kit.api.query('language.set',{code:'pl'});
  assert.equal(selected.languageCode,'pl');assert.equal(selected.languageSelected,true);
  assert.equal(kit.userState.get('app_language'),'pl');assert.deepEqual(localProfileState(kit),before);
  const coldStore=createStore({tizen:kit.options.tizen});
  const cold=createLibrary({...kit.options,sourceStore:coldStore,userState:createUserState({store:coldStore})}),reloaded=await cold.query('bootstrap');
  assert.equal((await cold.query('language.get')).languageCode,'pl');assert.equal(reloaded.languageSelected,true);
  assert.equal(reloaded.profile,null);assert.equal(kit.userState.get('supabase_session'),null);
  const committed=kit.userState.read();
  await rejectsCode(cold.query('language.set',{code:'invalid-language'}),'language_unsupported');
  assert.deepEqual(kit.userState.read(),committed);
  kit.device.failNext();await assert.rejects(cold.query('language.set',{code:'en'}),{name:'UnknownError'});
  assert.deepEqual(kit.userState.read(),committed);
  assert.equal(persistedUserState(kit).app_language,'pl');
  assert.deepEqual(cloud.calls,[]);assert.equal(kit.calls.requests.length,0);
});

test('profiles use real PIN functions and persisted KeyManager state without cross-profile data',async()=>{
  const kit=harness(url=>m3u(url.host));
  const first=await profile(kit,'One','1234');
  await source(kit,m3uConfig('first','first-profiles.fixture'));
  await kit.api.query('favorites.toggle',{sourceId:'first',channel:{id:'channel-one',name:'One'}});
  const second=(await kit.api.query('profiles.create',{name:'Two'})).profile;
  assert.deepEqual(await kit.api.query('sources.list'),[]);
  assert.deepEqual((await kit.api.query('favorites.list')).items,[]);
  await rejectsCode(kit.api.query('profiles.select',{id:first.id}),'pin_required');
  await rejectsCode(kit.api.query('profiles.select',{id:first.id,pin:'4321'}),'pin_invalid');
  await kit.api.query('profiles.select',{id:first.id,pin:'1234'});
  assert.equal((await kit.api.query('sources.list'))[0].id,'first');
  assert.equal((await kit.api.query('favorites.list')).items.length,1);
  const coldStore=createStore({tizen:kit.options.tizen});
  const cold=createLibrary({...kit.options,sourceStore:coldStore,userState:createUserState({store:coldStore})});
  const boot=await cold.query('bootstrap');
  assert.equal(boot.profile.locked,true);assert.deepEqual(boot.sources,[]);
  assert.notEqual(JSON.parse(persistedUserState(kit).local_profiles_v1).find(row=>row.id===first.id).pin,'1234');
  await kit.api.query('profiles.select',{id:second.id});
  assert.deepEqual((await kit.api.query('favorites.list')).items,[]);
});

test('startup picker migrates the active legacy preference atomically and applies one global mode across profiles and reloads',async()=>{
  const kit=harness(()=>{throw Error('Startup settings must not contact a provider');});
  const first=await profile(kit,'Locked startup','1234'),second=(await kit.api.query('profiles.create',{name:'Second startup'})).profile;
  assert.equal((await kit.api.query('bootstrap')).showProfilePicker,true);
  await kit.userState.update(state=>{
    delete state.profile_picker_startup;
    state.samsung_settings_v1=JSON.stringify({[first.id]:{profilePickerStartup:'always'},[second.id]:{profilePickerStartup:'off'}});
  });
  const beforeMigration=kit.userState.read(),cold=createLibrary(kit.options);
  kit.device.failNext();await assert.rejects(cold.query('bootstrap'),{name:'UnknownError'});
  assert.deepEqual(kit.userState.read(),beforeMigration);
  assert.equal(persistedUserState(kit).profile_picker_startup,undefined);
  const migrated=await cold.query('bootstrap');
  assert.equal(migrated.settings.profilePickerStartup,'off');assert.equal(migrated.showProfilePicker,false);
  assert.equal(kit.userState.get('profile_picker_startup'),'off');
  const buckets=JSON.parse(kit.userState.get('samsung_settings_v1'));
  assert.deepEqual(buckets[first.id],{profilePickerStartup:'always'});assert.deepEqual(buckets[second.id],{});
  const locked=await cold.query('profiles.select',{id:first.id,source:'local',pin:'1234'});
  assert.equal(locked.settings.profilePickerStartup,'off');assert.equal(locked.showProfilePicker,true);
  const reloaded=await createLibrary(kit.options).query('bootstrap');
  assert.equal(reloaded.profile.locked,true);assert.equal(reloaded.settings.profilePickerStartup,'off');assert.equal(reloaded.showProfilePicker,true);
  await cold.query('profiles.select',{id:second.id,source:'local'});
  assert.equal((await cold.query('settings.get')).settings.profilePickerStartup,'off');
  await cold.query('settings.set',{settings:{profilePickerStartup:'auto'}});
  assert.equal(kit.userState.get('profile_picker_startup'),'auto');
  const automatic=await createLibrary(kit.options).query('bootstrap');
  assert.equal(automatic.showProfilePicker,true);assert.equal(automatic.settings.profilePickerStartup,'auto');
  const committed=kit.userState.read();kit.device.failNext();
  await assert.rejects(cold.query('settings.set',{settings:{profilePickerStartup:'always',
    parental:{version:1,verifier:null,lockSettings:false,channels:[],categories:[]}}}),{name:'UnknownError'});
  assert.deepEqual(kit.userState.read(),committed);
  assert.equal(persistedUserState(kit).profile_picker_startup,'auto');
  assert.equal((await cold.query('parental.get')).lockSettings,true);assert.equal(kit.calls.requests.length,0);
});

test('source CRUD commits atomically and retains original snapshot after a real storage rejection',async()=>{
  const kit=harness(url=>m3u(url.host));await profile(kit,'Storage');
  const config=m3uConfig('source','source-storage.fixture');await source(kit,config);
  kit.device.failNext();
  await assert.rejects(kit.api.query('sources.update',{config:{...config,label:'Uncommitted'}}));
  assert.equal((await kit.api.query('sources.list'))[0].label,'source');
  await kit.api.query('sources.update',{config:{...config,label:'Committed'}});
  assert.equal((await kit.api.query('sources.list'))[0].label,'Committed');
  await kit.api.query('sources.remove',{id:'source'});
  assert.deepEqual(await kit.api.query('sources.list'),[]);
});

test('hosted Titan rejects HTTP source endpoints before requests and resolved HTTP streams before player open',async()=>{
  const kit=harness(()=> '#EXTM3U\n#EXTINF:-1 group-title="News",Fixture\nhttp://streams.fixture/live.m3u8\n');
  await kit.api.dispose();kit.options.requiresHttpsProvider=true;kit.api=createLibrary(kit.options);
  await profile(kit,'Hosted Titan');
  const configs=[
    {id:'http-m3u',kind:'m3u',label:'HTTP M3U',fields:{playlistUrl:'http://provider.fixture/list.m3u'},settings:{}},
    {id:'http-xtream',kind:'xtream',label:'HTTP Xtream',fields:{host:'http://provider.fixture',username:'user',password:'password'},settings:{}},
    {id:'bare-xtream',kind:'xtream',label:'Bare Xtream',fields:{host:'provider.fixture',username:'user',password:'password'},settings:{}}
  ];
  for(const config of configs) {
    await source(kit,config);
    await assert.rejects(kit.api.query('sources.load',{id:config.id}),error=>{
      assert.equal(error.code,'hosted_http_blocked');assert.match(error.message,/needs HTTPS/i);return true;
    });
  }
  assert.equal(kit.calls.requests.length,0,'unsupported source endpoints fail before transport calls');

  const secure=m3uConfig('https-with-http-stream','secure-provider.fixture');await source(kit,secure);
  const loaded=await kit.api.query('sources.load',{id:secure.id});
  await assert.rejects(kit.api.query('playback.play',{channel:loaded.channels[0]}),error=>{
    assert.equal(error.code,'hosted_http_blocked');assert.match(error.message,/needs HTTPS/i);return true;
  });
  assert.equal(kit.calls.open.length,0,'a resolved HTTP media locator never reaches the player');
});

test('native shared web library keeps HTTP source behavior when HTTPS is not required',async()=>{
  const kit=harness(()=> '#EXTM3U\n#EXTINF:-1 group-title="News",Fixture\nhttps://streams.fixture/live.m3u8\n');
  await profile(kit,'Native TV');
  const config={id:'native-http',kind:'m3u',label:'Native HTTP',fields:{playlistUrl:'http://provider.fixture/list.m3u'},settings:{}};
  await source(kit,config);
  assert.equal((await kit.api.query('sources.load',{id:config.id})).channels.length,1);
  assert.ok(kit.calls.requests.length>0);
});

test('typed worker replies support source load and label-only rename without parsing cache keys twice',async()=>{
  const kit=harness(()=>m3u('typed-worker','Typed worker channel'));
  await kit.api.dispose();
  kit.options.catalogStore=chunkedCatalogStore(catalogStoreFor(new Map()));
  kit.options.createSource=(...args)=>{
    const engine=kit.core.createSource(...args);
    const invoke=(method,input)=>engine.invoke(method,input).then(JSON.parse);
    return {invoke,dispose:()=>engine.dispose(),
      restoreCatalog:(scope,snapshot)=>invoke('importCatalog',JSON.stringify({scope,snapshot})),
      restoreGuide:(scope,snapshot)=>invoke('importGuide',JSON.stringify({scope,snapshot}))};
  };
  kit.api=createLibrary(kit.options);
  await profile(kit,'Typed worker');const config=m3uConfig('typed-worker','typed-worker.fixture');await source(kit,config);
  assert.equal((await kit.api.query('sources.load',{id:config.id})).channels[0].name,'Typed worker channel');
  await kit.api.query('sources.update',{config:{...config,label:'Typed worker renamed'}});
  assert.equal((await kit.api.query('sources.list'))[0].label,'Typed worker renamed');
  assert.equal((await kit.api.query('sources.load',{id:config.id})).channels[0].name,'Typed worker channel');
});

test('inactive label-only rename migrates exact legacy catalog and guide keys before commit',async()=>{
  const kit=harness(()=>{throw Error('A warm legacy snapshot must not request the provider.');});
  const owner=await profile(kit,'Legacy cache owner'),config=m3uConfig('legacy-inactive','legacy-inactive.fixture');
  await source(kit,config);
  const records=new Map(),keys=await seedLegacySnapshots(kit,config,owner.id,records);
  await kit.api.dispose();const durableStore=chunkedCatalogStore(catalogStoreFor(records));kit.options.catalogStore=durableStore;kit.api=createLibrary(kit.options);
  const renamed={...config,label:'Renamed while inactive'};
  await kit.api.query('sources.update',{config:renamed});
  assert.equal(records.has(keys.normalizedKey),true,'catalog is rekeyed before the source label changes');
  assert.equal(records.has(keys.guideKey),true,'guide snapshot is rekeyed before the source label changes');
  const migrationKeys=[keys.normalizedKey,keys.guideKey,keys.legacyKey,keys.legacyGuideKey];
  assert.deepEqual(durableStore.batchWriteOptions[0],{preserveKeys:migrationKeys},
    'the batch writer protects both destination keys and both exact legacy snapshots');
  assert.deepEqual(durableStore.writeOptionsSeen[0].writeOptions,{preserveKeys:migrationKeys},
    'the guide write protects the same four exact keys until migration commits');
  assert.deepEqual(durableStore.protectionLeases[0].keys,migrationKeys);
  assert.equal(durableStore.protectionLeases[0].released,true,'legacy key protection ends after migration commits');
  assert.equal(records.has(keys.legacyKey),false);assert.equal(records.has(keys.legacyGuideKey),false);
  assert.equal((await kit.api.query('sources.list'))[0].label,renamed.label);
  assert.equal((await kit.api.query('sources.load',{id:config.id})).channels[0].name,'Legacy channel');
  assert.equal(kit.calls.requests.length,0);
  await kit.api.dispose();kit.api=createLibrary(kit.options);
  assert.equal((await kit.api.query('sources.list'))[0].label,renamed.label,'the renamed label remains durable across restart');
  assert.equal((await kit.api.query('sources.load',{id:config.id})).channels[0].name,'Legacy channel');
  assert.equal(kit.calls.requests.length,0,'restart restores the migrated catalog without a provider request');
});

test('failed legacy cache migration leaves the old label and cache usable after restart',async()=>{
  const kit=harness(()=>{throw Error('A failed cache migration must not fall back to the provider.');});
  const owner=await profile(kit,'Failed cache migration'),config=m3uConfig('legacy-write-failure','legacy-write-failure.fixture');
  await source(kit,config);
  const records=new Map(),keys=await seedLegacySnapshots(kit,config,owner.id,records);
  await kit.api.dispose();kit.options.catalogStore=catalogStoreFor(records,key=>key===keys.normalizedKey);kit.api=createLibrary(kit.options);
  await assert.rejects(kit.api.query('sources.update',{config:{...config,label:'Must not commit'}}),error=>error.code==='cache_migration_failed');
  assert.equal((await kit.api.query('sources.list'))[0].label,config.label);
  assert.equal(kit.options.catalogStore.protectionLeases[0].released,true,'legacy protection is released after a failed migration attempt');
  assert.equal(records.has(keys.legacyKey),true);assert.equal(records.has(keys.legacyGuideKey),true);
  assert.equal(kit.calls.requests.length,0);
  await kit.api.dispose();kit.options.catalogStore=catalogStoreFor(records);kit.api=createLibrary(kit.options);
  assert.equal((await kit.api.query('sources.load',{id:config.id})).channels[0].name,'Legacy channel');
  assert.equal(kit.calls.requests.length,0,'the unchanged old config still resolves the old cache after restart');
});

test('ordinary source load serves exact legacy catalog and guide while real rekey writes are refused across restarts',async()=>{
  const kit=harness(()=>{throw Error('A valid legacy cache must not request the provider.');});
  const owner=await profile(kit,'Legacy cache quota'),base=m3uConfig('legacy-quota','legacy-quota.fixture'),
    config={...base,fields:{...base.fields,epgUrl:'https://legacy-quota.fixture/guide'}};
  await source(kit,config);
  const records=new Map(),keys=await seedLegacySnapshots(kit,config,owner.id,records),fs=catalogFileSystem();
  let store=fs.restart();
  assert.equal(await store.write(keys.legacyKey,records.get(keys.legacyKey).raw,'catalog'),true);
  assert.equal(await store.write(keys.legacyGuideKey,records.get(keys.legacyGuideKey).raw,'guide'),true);
  fs.fail(name=>name.startsWith(keys.normalizedKey+'.')||name.startsWith(keys.guideKey+'.'));
  await kit.api.dispose();kit.options.catalogStore=store;kit.api=createLibrary(kit.options);
  for(let restart=0;restart<2;restart++) {
    if(restart){await kit.api.dispose();store=fs.restart();kit.options.catalogStore=store;kit.api=createLibrary(kit.options);}
    const loaded=await kit.api.query('sources.load',{id:config.id});
    assert.equal(loaded.channels[0].name,'Legacy channel');
    const guide=await kit.api.query('guide',{channels:loaded.channels});
    assert.ok(guide.programmes.some(row=>row.title==='Cached legacy guide'));
    assert.equal(kit.calls.requests.length,0,'neither catalog nor guide rekey refusal contacts the provider');
    assert.equal((await store.read(keys.legacyKey)).raw,records.get(keys.legacyKey).raw);
    assert.equal((await store.read(keys.legacyGuideKey)).raw,records.get(keys.legacyGuideKey).raw);
  }
});

test('corrupt legacy snapshot reaches the bounded source fetch path after migration refusal',async()=>{
  const kit=harness(url=>m3u(url.host));
  const owner=await profile(kit,'Corrupt legacy cache'),config=m3uConfig('corrupt-legacy','corrupt-legacy.fixture');
  await source(kit,config);
  const records=new Map(),keys=await seedLegacySnapshots(kit,config,owner.id,records),fs=catalogFileSystem();
  let store=fs.restart();
  assert.equal(await store.write(keys.legacyKey,'invalid catalog snapshot','catalog'),true);
  assert.equal(await store.write(keys.legacyGuideKey,records.get(keys.legacyGuideKey).raw,'guide'),true);
  fs.fail(name=>name.startsWith(keys.normalizedKey+'.')||name.startsWith(keys.guideKey+'.'));
  await kit.api.dispose();kit.options.catalogStore=store;kit.api=createLibrary(kit.options);
  const loaded=await kit.api.query('sources.load',{id:config.id});
  assert.equal(loaded.channels.length,1);
  assert.equal(kit.calls.requests.length,1,'only the fixture playlist is fetched after bounded legacy cache rejection');
  assert.equal(kit.calls.requests[0].url,config.fields.playlistUrl);
});

test('M3U preview/fullscreen reuses one physical player and source changes stop it',async()=>{
  const kit=harness(url=>m3u(url.host));await profile(kit,'Live');
  await source(kit,m3uConfig('a','source-a-live.fixture'));await source(kit,m3uConfig('b','source-b-live.fixture'));
  const loaded=await kit.api.query('sources.load',{id:'a'}), channel=loaded.channels[0];
  await kit.api.query('playback.preview',{channel,rect:{x:800,y:20,width:400,height:225}});
  await kit.api.query('playback.play',{channel,rect:{x:0,y:0,width:1280,height:720}});
  assert.equal(kit.calls.open.length,1);assert.equal(kit.calls.rect.length,1);
  const before=kit.calls.events.length;
  await kit.api.query('sources.load',{id:'b'});
  const events=kit.calls.events.slice(before);
  assert.ok(events.indexOf('stop')<events.indexOf('http:source-b-live.fixture'));
  assert.equal(kit.api.getState().playing,false);
});

function xtreamRoute(url) {
  const action=url.searchParams.get('action');
  if(url.pathname==='/xmltv.php')return '<tv><channel id="guide"><display-name>Live</display-name></channel><programme channel="guide" start="20000101100000 +0000" stop="20000101103000 +0000"><title>Past</title></programme></tv>';
  if(!action)return {user_info:{auth:1,status:'Active',exp_date:'4102444800'}};
  if(action==='get_live_categories')return [{category_id:'news',category_name:'News'}];
  if(action==='get_live_streams')return [{stream_id:11,name:'Live',category_id:'news',epg_channel_id:'guide',tv_archive:1,tv_archive_duration:7}];
  if(action==='get_vod_categories')return [{category_id:'movies',category_name:'Movies'}];
  if(action==='get_series_categories')return [{category_id:'series',category_name:'Series'}];
  if(action==='get_vod_streams')return [{stream_id:500,name:'Film',category_id:'movies',container_extension:'mp4'}];
  if(action==='get_series')return [{series_id:900,name:'Series',category_id:'series'}];
  if(action==='get_vod_info')return {info:{plot:'Actual Source detail'}};
  if(action==='get_series_info')return {info:{},seasons:[{season_number:1,name:'Season 1'}],episodes:{'1':[{id:901,title:'Pilot',episode_num:1}]}};
  throw Error('Unexpected fixture action '+action);
}
async function vodHarness(now) {
  const kit=harness(xtreamRoute,now);if(now)kit.options.now=now;await profile(kit,'VOD');
  await source(kit,{id:'vod',kind:'xtream',label:'VOD',fields:{host:'https://vod-'+kit.suffix+'.fixture',username:'fixture-user',password:'fixture-pass'},settings:{}});
  const loaded=await kit.api.query('sources.load',{id:'vod'});
  const movie=(await kit.api.query('catalog.items',{kind:'movie',categoryId:'movies',page:1})).items[0];
  return {...kit,loaded,movie};
}

test('EPG deferred reads preserve the original safe cause and deadline across windows and cold runtimes',async()=>{
  let offset=0;const base=Date.now(),clock=()=>Date.now()+offset;
  const kit=harness(url=>url.pathname==='/xmltv.php'?'<tv><programme>private-guide-token</tv>':xtreamRoute(url),clock);
  const snapshots=new Map();kit.options.now=clock;
  kit.options.catalogStore=chunkedCatalogStore({async read(key){return snapshots.has(key)?{raw:snapshots.get(key),token:'saved'}:null;},
    async write(key,raw){snapshots.set(key,raw);return true;},async remove(key){snapshots.delete(key);}});
  async function restart(){await kit.api.dispose();Object.assign(kit.options,modules(clock));kit.api=createLibrary(kit.options);}
  await restart();await profile(kit,'Guide failure deadline');
  await source(kit,{id:'retry-deadline',kind:'xtream',label:'Retry',fields:{host:'https://retry-deadline.fixture',username:'user',password:'pass'},settings:{}});
  const loaded=await kit.api.query('sources.load',{id:'retry-deadline'});
  const window={channels:loaded.channels,from:new Date(base).toISOString(),to:new Date(base+7200000).toISOString()};
  let deadline;
  await assert.rejects(kit.api.query('guide',window),error=>{
    assert.equal(error.code,'epg_retry_deferred');assert.equal(error.causeCode,'epg_invalid_data');
    assert.ok(error.retryAt>=base+15*60*1000&&error.retryAt<=clock()+15*60*1000);deadline=error.retryAt;return true;
  });
  const requests=kit.calls.requests.length;offset+=5*60*1000;
  await assert.rejects(kit.api.query('guide',{...window,to:new Date(base+10800000).toISOString()}),error=>{
    assert.equal(error.code,'epg_retry_deferred');assert.equal(error.causeCode,'epg_invalid_data');assert.equal(error.retryAt,deadline);return true;
  });
  assert.equal(kit.calls.requests.length,requests,'Changing windows must not retry a failed provider');
  await kit.api.query('cache.flush');await restart();await kit.api.query('sources.load',{id:'retry-deadline'});
  const before=kit.calls.requests.length;offset+=5*60*1000;
  await assert.rejects(kit.api.query('guide',{...window,to:new Date(base+14400000).toISOString()}),error=>{
    assert.equal(error.code,'epg_retry_deferred');assert.equal(error.causeCode,'epg_invalid_data');assert.ok(error.retryAt>clock()&&error.retryAt<=deadline,'Restoring a feed deadline must never postpone the original failure deadline');return true;
  });
  assert.equal(kit.calls.requests.length,before,'A cold runtime must respect the same original deadline');
  for(let index=0;index<10;index++) {
    await kit.api.query('cache.flush');await restart();await kit.api.query('sources.load',{id:'retry-deadline'});offset+=1000;
    await assert.rejects(kit.api.query('guide',{...window,to:new Date(base+(5+index)*3600000).toISOString()}),error=>{
      assert.equal(error.code,'epg_retry_deferred');assert.equal(error.causeCode,'epg_invalid_data');assert.ok(error.retryAt>clock()&&error.retryAt<=deadline);return true;
    });
    assert.equal(kit.calls.requests.length,before,'Read-window eviction must retain the shared failed-feed guard');
  }
  offset=15*60*1000+1;
  await assert.rejects(kit.api.query('guide',{...window,to:new Date(base+18000000).toISOString()}),error=>error.code==='epg_invalid_data');
  assert.equal(kit.calls.requests.length,before+1,'The original deadline permits exactly one new guide attempt');
});

test('cold Samsung runtimes restore metadata and EPG offline, including different guide windows and failed-refresh backoff',async()=>{
  let offline=false,offset=0;const clock=()=>Date.now()+offset;
  const kit=harness(url=>{if(offline)throw Error('provider offline');return xtreamRoute(url);},clock);
  const snapshots=new Map(),writes=[],events=[],legacyExports=[];let failWrite=false,metadataRefreshes=0,partExports=0;
  kit.options.catalogStore=chunkedCatalogStore({async mark(key,kind){events.push({method:'mark',key,kind});return snapshots.has(key);},
    async read(key){events.push({method:'read',key});return snapshots.has(key)?{raw:snapshots.get(key),token:'generation'}:null;},
    async write(key,raw,kind){events.push({method:'write',key,kind});if(failWrite)throw Error('disk full');snapshots.set(key,raw);writes.push({key,kind});return true;},
    async discard(key){snapshots.delete(key);},async remove(key){snapshots.delete(key);}});
  kit.options.now=clock;
  kit.options.createSource=(...args)=>{
    const engine=kit.options.core.createSource(...args);
    return {invoke(method,input){
      if(method==='exportCatalog')legacyExports.push(JSON.parse(input));
      if(method==='exportCatalogPart')partExports++;
      if(method==='metadata.refresh')metadataRefreshes++;
      return engine.invoke(method,input);
    },dispose(){return engine.dispose();}};
  };
  async function restart(){await kit.api.dispose();Object.assign(kit.options,modules(clock));kit.api=createLibrary(kit.options);}
  await restart();const firstProfile=await profile(kit,'Persistent guide');
  const config={id:'persist',kind:'xtream',label:'Persistent',fields:{host:'https://persistent-guide.fixture',username:'user',password:'pass'},settings:{}};
  await source(kit,config);
  const loaded=await kit.api.query('sources.load',{id:'persist'});
  await kit.api.query('cache.flush');
  assert.equal((await kit.api.query('sources.load',{id:'persist'})).cachePersisted,true);
  assert.ok(partExports>0,'durable full-cache persistence uses bounded catalog parts');
  assert.equal(legacyExports.length,0,'full-cache persistence must not export one whole catalog');
  const item=(await kit.api.query('catalog.items',{kind:'movie',categoryId:'movies',page:1})).items[0];
  const beforeManualRefresh={legacyExports:legacyExports.length,partExports};
  await kit.api.query('media.refresh',{item});
  assert.equal(metadataRefreshes,1,'a full-catalog details refresh uses the metadata flow');
  assert.equal(legacyExports.length,beforeManualRefresh.legacyExports,'a details refresh must not export prepared roots');
  assert.equal(partExports,beforeManualRefresh.partExports,'a details refresh must not persist prepared roots');
  await kit.api.query('media.details',{item});
  await kit.api.query('guide',{channels:loaded.channels});
  await kit.api.query('cache.flush');
  assert.equal(snapshots.size,2,'catalogue and raw guides have separate durable keys');
  assert.ok(writes.some(write=>write.kind==='catalog'),'the shared library labels primary snapshots for the platform cache');
  assert.ok(writes.some(write=>write.kind==='guide'),'derived guide snapshots use the optional cache priority');
  const catalogWrite=events.findIndex(event=>event.method==='write'&&event.kind==='catalog');
  const guideMark=events.findIndex(event=>event.method==='mark'&&event.kind==='guide');
  assert.ok(guideMark>=0&&guideMark<catalogWrite,'the source-scoped legacy guide key is classified before catalog persistence');
  const firstGuideKey=writes.find(write=>write.kind==='guide').key;

  await kit.api.query('profiles.create',{name:'Other profile'});
  await source(kit,config);
  const beforeOther=kit.calls.requests.length;
  assert.equal((await kit.api.query('sources.load',{id:'persist'})).channels.length,1);
  assert.ok(kit.calls.requests.length>beforeOther,'a second profile must not reuse the first profile cache');
  await kit.api.query('cache.flush');
  const catalogKeys=[...new Set(writes.filter(write=>write.kind==='catalog').map(write=>write.key))];
  assert.equal(catalogKeys.length,2,'the same provider config gets separate scoped catalog keys');
  const otherCatalogKey=catalogKeys.find(key=>key!==writes.find(write=>write.kind==='catalog').key);
  const otherGuideKey=writes.find(write=>write.kind==='guide'&&write.key!==firstGuideKey)?.key;
  assert.ok(otherCatalogKey);
  assert.ok(otherGuideKey,'the second profile stores its own EPG snapshot');
  await kit.api.query('profiles.select',{id:firstProfile.id});
  const beforeFirst=kit.calls.requests.length;
  assert.equal((await kit.api.query('sources.load',{id:'persist'})).channels.length,1);
  assert.equal(kit.calls.requests.length,beforeFirst,'the first profile still imports its own canonical snapshot');

  offline=true;await restart();let before=kit.calls.requests.length;
  const restored=await kit.api.query('sources.load',{id:'persist'});
  assert.equal(restored.channels.length,1);assert.equal(restored.cachePersisted,true);
  assert.equal((await kit.api.query('media.details',{item})).description,'Actual Source detail');
  const window={channels:restored.channels,from:'2000-01-01T09:00:00.000Z',to:'2000-01-01T12:00:00.000Z'};
  assert.equal((await kit.api.query('guide',window)).programmes.length,1);
  assert.equal(kit.calls.requests.length,before,'cold cache hits must not authenticate or download');
  offset+=7*60*60*1000;
  const changedWindow={...window,to:'2000-01-01T13:00:00.000Z'};
  assert.equal((await kit.api.query('guide',changedWindow)).programmes.length,1,'offline refresh retains old guide');
  assert.ok(kit.calls.requests.length>before);
  await restart();before=kit.calls.requests.length;
  await kit.api.query('sources.load',{id:'persist'});
  assert.equal((await kit.api.query('guide',{...window,to:'2000-01-01T14:00:00.000Z'})).programmes.length,1);
  assert.equal(kit.calls.requests.length,before,'restart must retain the guide failure backoff');
  offset+=16*60*1000;offline=false;
  await kit.api.query('guide',{...window,to:'2000-01-01T15:00:00.000Z'});
  assert.equal(kit.calls.requests.length,before+1,'retry occurs once after the backoff');
  failWrite=true;
  assert.equal((await kit.api.query('media.details',{item:{...item,id:'another'}})).description,'Actual Source detail');
  await kit.api.query('cache.flush');failWrite=false;
  await kit.api.query('sources.update',{config:{...config,fields:{...config.fields,password:'changed'}}});
  assert.equal(snapshots.size,2,'editing credentials removes the current profile cache without crossing owner scope');
  assert.ok(snapshots.has(otherCatalogKey));assert.ok(snapshots.has(otherGuideKey),'the other profile keeps its independent catalog and EPG caches');
});

for(const failRefresh of [false,true]) test('cold catalogue starts from cache and refreshes only after 24h without blocking navigation, failure='+failRefresh,async t=>{
  let offset=0,hold=false,refreshStateReads=0,refreshFinished=deferred();
  const clock=()=>Date.now()+offset,started=deferred(),download=deferred();
  function watchRefresh(){refreshStateReads=0;refreshFinished=deferred();return refreshFinished.promise;}
  function liveReads(){return kit.calls.requests.filter(request=>new URL(request.url).searchParams.get('action')==='get_live_streams').length;}
  const kit=harness(async url=>{
    if(hold&&url.searchParams.get('action')==='get_live_streams') {
      started.resolve();await download.promise;
      if(failRefresh)return '{';
      return [...xtreamRoute(url),{stream_id:12,name:'New channel',category_id:'news'}];
    }
    return xtreamRoute(url);
  },clock);
  const snapshots=new Map();kit.options.now=clock;
  kit.options.catalogStore=chunkedCatalogStore({async read(key){return snapshots.has(key)?{raw:snapshots.get(key),token:'saved'}:null;},
    async write(key,raw){snapshots.set(key,raw);return true;},async discard(key){snapshots.delete(key);}});
  kit.options.createSource=(...args)=>{
    const engine=kit.options.core.createSource(...args);
    return {invoke(method,input){
      const result=engine.invoke(method,input);
      if(hold&&method==='catalogState')return result.then(value=>{
        if(++refreshStateReads===2)refreshFinished.resolve();
        return value;
      });
      return result;
    },async dispose(){await engine.dispose();}};
  };
  async function restart(){await kit.api.dispose();Object.assign(kit.options,modules(clock));kit.api=createLibrary(kit.options);}
  try {
    await restart();await profile(kit,'Cached startup');
    await source(kit,{id:'startup',kind:'xtream',label:'Startup',fields:{host:'https://cached-startup-'+kit.suffix+'.fixture',username:'user',password:'pass'},settings:{}});
    await kit.api.query('sources.load',{id:'startup'});await kit.api.query('cache.flush');
    offset=23*60*60*1000;await restart();
    t.mock.timers.enable({apis:['setTimeout']});
    await kit.api.dispose();kit.api=createLibrary(kit.options);
    const before=liveReads();
    assert.equal((await kit.api.query('sources.load',{id:'startup'})).channels.length,1);
    t.mock.timers.tick(1);await new Promise(resolve=>setImmediate(resolve));
    assert.equal(liveReads(),before,'a fresh catalog must not refresh before 24h');
    t.mock.timers.reset();offset=25*60*60*1000;await restart();hold=true;
    t.mock.timers.enable({apis:['setTimeout']});
    await kit.api.dispose();kit.api=createLibrary(kit.options);
    assert.equal((await kit.api.query('sources.load',{id:'startup'})).channels.length,1,'stale channels return before the provider responds');
    const refreshDone=watchRefresh();
    t.mock.timers.tick(1);await started.promise;
    assert.equal((await kit.api.query('sources.load',{id:'startup'})).channels.length,1,'navigation remains available during refresh');
    download.resolve();await refreshDone;await kit.api.query('cache.flush');
    assert.equal((await kit.api.query('sources.catalog')).channels.length,failRefresh?1:2);
  } finally {download.resolve();await kit.api.dispose();t.mock.timers.reset();}
});

for(const failRefresh of [false,true]) test('a restart after 24h shows saved EPG while its replacement downloads, failure='+failRefresh,async()=>{
  let offset=0,hold=false;const clock=()=>Date.now()+offset,started=deferred(),download=deferred();
  const kit=harness(async url=>{
    if(url.pathname==='/xmltv.php'&&hold) {
      started.resolve();await download.promise;
      if(failRefresh)throw Error('provider offline');
      return xtreamRoute(url).replace('<title>Past</title>','<title>Updated</title>');
    }
    return xtreamRoute(url);
  },clock);
  const snapshots=new Map();kit.options.now=clock;
  kit.options.catalogStore=chunkedCatalogStore({async read(key){return snapshots.has(key)?{raw:snapshots.get(key),token:'saved'}:null;},
    async write(key,raw){snapshots.set(key,raw);return true;},async discard(key){snapshots.delete(key);}});
  async function restart(){await kit.api.dispose();Object.assign(kit.options,modules(clock));kit.api=createLibrary(kit.options);}
  try {
    await restart();await profile(kit,'Background guide');
    await source(kit,{id:'background',kind:'xtream',label:'Guide',fields:{host:'https://background-guide-'+kit.suffix+'.fixture',username:'user',password:'pass'},settings:{}});
    const first=await kit.api.query('sources.load',{id:'background'});
    await kit.api.query('guide',{channels:first.channels});await kit.api.query('cache.flush');
    offset=25*60*60*1000;hold=true;await restart();
    const loaded=await kit.api.query('sources.load',{id:'background'});
    const window={channels:loaded.channels,from:'2000-01-01T09:00:00.000Z',to:'2000-01-01T12:00:00.000Z'};
    const saved=await kit.api.query('guide',window);
    assert.equal(saved.programmes[0].title,'Past','old EPG must paint before the held network request completes');
    await started.promise;
    assert.equal(kit.api.getState().guideRevision,0);
    const scrolled=await kit.api.query('guide',{...window,from:'2000-01-01T09:30:00.000Z'});
    assert.equal(scrolled.programmes[0].title,'Past','another window must also show the saved guide during the same download');
    download.resolve();await kit.api.query('cache.flush');
    assert.equal((await kit.api.query('guide',window)).programmes[0].title,failRefresh?'Past':'Updated');
    assert.equal(kit.api.getState().guideRevision,1,'completion tells the UI to read the retained or replacement guide');
  } finally {download.resolve();await kit.api.dispose();}
});

for (const failed of [false,true]) test('daily catalogue refresh keeps playback and cached reads, then publishes only a complete replacement: failure='+failed,async t=>{
  let offset=0,refresh=false,refreshFailure=failed;
  const clock=()=>Date.now()+offset,started=deferred(),download=deferred(),detailsStarted=deferred(),detailsDownload=deferred(),retried=deferred();
  let publicationStarted=false,created=0,backgroundStateReads=0,backgroundFinished=deferred();const exportCalls=[],prepareCalls=[];
  function watchBackgroundRefresh(){backgroundStateReads=0;backgroundFinished=deferred();return backgroundFinished.promise;}
  const kit=harness(async url=>{
    if(refresh&&url.searchParams.get('action')==='get_vod_info'&&url.searchParams.get('vod_id')==='501') {
      detailsStarted.resolve();await detailsDownload.promise;
    }
    if(refresh&&url.searchParams.get('action')==='get_live_streams') {
      started.resolve();await download.promise;
      if(refreshFailure)return '{';
      return [...xtreamRoute(url),{stream_id:12,name:'New channel',category_id:'news'}];
    }
    return xtreamRoute(url);
  },clock);
  kit.options.now=clock;
  kit.options.onProgress=()=>{if(kit.api.getState().catalogRevision===1)retried.resolve();};
  kit.options.createSource=(...args)=>{
    created++;
    const engine=kit.core.createSource(...args);
    return {invoke(method,...input){
      if(refresh&&method==='importCatalog')publicationStarted=true;
      if(refresh&&method==='prepareCatalog')prepareCalls.push(JSON.parse(input[0]));
      if(method==='exportCatalog') {
        const call={refresh,args:JSON.parse(input[0]||'{}')};exportCalls.push(call);
      }
      const result=engine.invoke(method,...input);
      if(refresh&&method==='catalogState')return result.then(value=>{
        if(++backgroundStateReads===2)backgroundFinished.resolve();
        return value;
      });
      return result;
    },async dispose(){await engine.dispose();}};
  };
  await kit.api.dispose();kit.api=createLibrary(kit.options);
  await profile(kit,'Daily refresh');
  await source(kit,{id:'daily',kind:'xtream',label:'Daily',fields:{host:'https://daily-'+kit.suffix+'.fixture',username:'user',password:'pass'},settings:{}});
  t.mock.timers.enable({apis:['setTimeout']});
  await kit.api.dispose();kit.api=createLibrary(kit.options);
  const loaded=await kit.api.query('sources.load',{id:'daily'});
  const movie=(await kit.api.query('catalog.items',{kind:'movie',categoryId:'movies',page:1})).items[0];
  await kit.api.query('media.details',{item:movie});
  await kit.api.query('playback.play',{channel:loaded.channels[0]});
  const stops=kit.calls.stop,opens=kit.calls.open.length;
  // Re-arm with a due timestamp without waiting a day on real hardware.
  offset=25*60*60*1000;refresh=true;
  try {
    const engineCount=created,backgroundDone=watchBackgroundRefresh();
    const pendingDetails=kit.api.query('media.details',{item:{...movie,id:'501'}});
    await detailsStarted.promise;
    t.mock.timers.tick(24*60*60*1000);await started.promise;
    assert.equal((await kit.api.query('sources.catalog')).channels.length,1);
    assert.equal((await kit.api.query('media.details',{item:movie})).description,'Actual Source detail','background refresh must keep the warm catalogue readable');
    download.resolve();
    detailsDownload.resolve();
    assert.equal((await pendingDetails).description,'Actual Source detail','a daily commit must not cancel an active details read');
    await backgroundDone;
    assert.equal(created,engineCount,'a daily refresh keeps the source engine alive');
    assert.ok(prepareCalls.some(args=>args.kind==='live'),'a daily refresh prepares the canonical live catalog in place');
    assert.equal(exportCalls.some(call=>call.refresh),false,'in-place refresh does not export a replacement catalog');
    assert.equal(publicationStarted,false,'in-place refresh does not import a replacement catalog');
    const current=await kit.api.query('sources.catalog');
    assert.equal(current.channels.length,failed?1:2,'new channels reach the visible catalogue only after a successful refresh');
    assert.equal(kit.api.getState().catalogRevision,failed?0:1);
    assert.equal(kit.api.getState().playing,true);assert.equal(kit.calls.stop,stops);assert.equal(kit.calls.open.length,opens);
    if(failed) {
      await new Promise(resolve=>setImmediate(resolve));
      const engines=created,liveReads=kit.calls.requests.filter(request=>new URL(request.url).searchParams.get('action')==='get_live_streams').length;
      offset+=3599999;t.mock.timers.tick(3599999);await new Promise(resolve=>setImmediate(resolve));
      assert.equal(created,engines,'a failed catalogue gets a quiet one-hour deadline');
      refreshFailure=false;offset++;const retryDone=watchBackgroundRefresh();t.mock.timers.tick(1);
      await retryDone;
      assert.equal(created,engines,'retry reuses the same source engine');
      assert.equal(kit.calls.requests.filter(request=>new URL(request.url).searchParams.get('action')==='get_live_streams').length,liveReads+1,'automatic retry prepares the live catalog again');
      await retried.promise;assert.equal((await kit.api.query('sources.catalog')).channels.length,2);
    }
  } finally {download.resolve();detailsDownload.resolve();await kit.api.dispose();t.mock.timers.reset();}
});

test('switching sources flushes metadata before disposing the source worker',async()=>{
  const kit=await vodHarness(),saved=new Map();
  kit.options.catalogStore=chunkedCatalogStore({async read(key){return saved.has(key)?{raw:saved.get(key),token:'1'}:null;},
    async write(key,raw){saved.set(key,raw);return true;},async remove(key){saved.delete(key);},async discard(key){saved.delete(key);}});
  await kit.api.dispose();kit.api=createLibrary(kit.options);
  await kit.api.query('sources.load',{id:'vod'});
  await kit.api.query('media.details',{item:kit.movie});
  await kit.api.query('sources.cancel');
  Object.assign(kit.options,modules());kit.api=createLibrary(kit.options);
  const before=kit.calls.requests.length;
  await kit.api.query('sources.load',{id:'vod'});
  await kit.api.query('media.details',{item:kit.movie});
  assert.equal(kit.calls.requests.length,before);
});

test('warm Samsung navigation reuses provider metadata across sequential and concurrent reads',async()=>{
  const kit=await vodHarness();
  const categories={kind:'movie'},details={item:kit.movie};
  await kit.api.query('catalog.categories',categories);
  await kit.api.query('media.details',details);
  const before=kit.calls.requests.length;
  for(let i=0;i<20;i++) {
    await kit.api.query('catalog.categories',categories);
    await kit.api.query('media.details',details);
    await kit.api.query('catalog.items',{kind:'movie',categoryId:'movies',page:1});
  }
  await Promise.all(Array.from({length:40},()=>kit.api.query('media.details',details)));
  assert.equal(kit.calls.requests.length,before,'warm navigation must make zero provider requests');
  await kit.api.dispose();
});

test('legacy serialized metadata cache expires, detaches results and clears on source replacement',async t=>{
  let offset=0;const clock=()=>Date.now()+offset,kit=harness(xtreamRoute,clock);
  await profile(kit,'Legacy metadata cache');await source(kit,{id:'vod',kind:'xtream',label:'VOD',fields:{host:'https://vod-'+kit.suffix+'.fixture',username:'fixture-user',password:'fixture-pass'},settings:{}});
  const core=kit.core;let detailReads=0;
  // This isolates the wrapper's legacy serialized cache; canonical cache behavior is covered by the full-catalog fixtures.
  kit.options.createSource=(...args)=>{const engine=core.createSource(...args);return {dispose:()=>engine.dispose(),invoke(method,input){
    if(method==='mediaDetails')detailReads++;
    const result=engine.invoke(method,input);
    return method==='capabilities'?Promise.resolve(result).then(raw=>{const caps=typeof raw==='string'?JSON.parse(raw):raw;return JSON.stringify({...caps,fullCatalogCache:false});}):result;
  }};};
  kit.options.now=clock;await kit.api.dispose();t.mock.timers.enable({apis:['setTimeout']});kit.api=createLibrary(kit.options);
  try {
    await kit.api.query('sources.load',{id:'vod'});
    const item=(await kit.api.query('catalog.items',{kind:'movie',categoryId:'movies',page:1})).items[0],args={item};
    const details=await kit.api.query('media.details',args);details.description='modified by view';
    const before=detailReads;
    assert.equal((await kit.api.query('media.details',args)).description,'Actual Source detail');
    assert.equal(detailReads,before,'a warm result is detached without another provider read');
    const catalogAge=JSON.parse(core.providerCachePolicy()).catalogMaxAgeMs;
    offset+=catalogAge;await kit.api.query('media.details',args);
    assert.equal(detailReads,before+1,'the serialized entry expires at the catalog deadline');
    offset-=60000;await kit.api.query('media.details',args);
    assert.equal(detailReads,before+2,'a backwards clock does not reuse a future-dated entry');
    await kit.api.query('sources.cancel');await kit.api.query('sources.load',{id:'vod'});
    const switched=detailReads;
    await kit.api.query('media.details',args);
    assert.equal(detailReads,switched+1,'a replacement source does not reuse the old detail');
  } finally {await kit.api.dispose();t.mock.timers.reset();}
});

test('metadata cache bounds memory, evicts LRU entries and never retains failed reads',async()=>{
  const kit=harness(()=>{throw Error('Synthetic engine must not use HTTP');});
  await profile(kit,'Cache bounds');await source(kit,m3uConfig('bounded','bounded.fixture'));
  await kit.api.dispose();
  const calls=[];let fail=true;
  kit.options.createSource=()=>({dispose:()=>Promise.resolve(),async invoke(method,raw){
    calls.push(method);const args=JSON.parse(raw);
    if(method==='categories'||method==='channels')return '[]';
    if(method==='capabilities')return '{}';
    if(method!=='mediaDetails')return 'null';
    if(args.item.id==='failure'&&fail)throw Error('temporary failure');
    return JSON.stringify({...args.item,description:args.item.id==='large'?'x'.repeat(2*1024*1024):'details'});
  }});
  kit.api=createLibrary(kit.options);await kit.api.query('sources.load',{id:'bounded'});
  const read=id=>kit.api.query('media.details',{item:{id,kind:'movie'}});
  await read('old');for(let i=0;i<128;i++)await read('item-'+i);
  let before=calls.length;await read('old');assert.equal(calls.length,before+1);
  before=calls.length;await read('large');await read('large');assert.equal(calls.length,before+2);
  await assert.rejects(read('failure'));fail=false;await read('failure');
  before=calls.length;await read('failure');assert.equal(calls.length,before);
  await kit.api.dispose();
});

test('10k-channel Samsung catalog stays warm through repeated navigation and guide bursts',async(t)=>{
  const playlist='#EXTM3U\n'+Array.from({length:10000},(_,i)=>'#EXTINF:-1 tvg-id="ch'+i+'" group-title="Group '+(i%20)+'",Channel '+i+'\nhttps://streams.fixture/'+i+'.m3u8\n').join('');
  const kit=harness(url=>url.pathname==='/epg.xml'?'<tv></tv>':playlist);
  await profile(kit,'Large fixture');
  const config=m3uConfig('large','large-'+kit.suffix+'.fixture');config.fields.epgUrl='https://large-'+kit.suffix+'.fixture/epg.xml';
  await source(kit,config);
  const start=performance.now(),loaded=await kit.api.query('sources.load',{id:'large'});
  const coldMs=performance.now()-start;
  assert.equal(loaded.channels.length,10000);
  const guideReads=()=>kit.calls.requests.filter(request=>new URL(request.url).pathname==='/epg.xml').length;
  assert.equal(guideReads(),1,'cold preparation attempts EPG once before returning');
  const before=kit.calls.requests.length,warmStart=performance.now();
  for(let i=0;i<30;i++) assert.equal((await kit.api.query('sources.load',{id:'large'})).channels.length,10000);
  assert.equal(kit.calls.requests.length,before);
  const warmMs=performance.now()-warmStart;
  await Promise.all(Array.from({length:30},()=>kit.api.query('guide',{channels:loaded.channels.slice(0,20)})));
  const afterGuide=kit.calls.requests.length;
  for(let i=0;i<10;i++) await kit.api.query('guide',{channels:loaded.channels.slice(0,20)});
  assert.equal(afterGuide,before);assert.equal(kit.calls.requests.length,afterGuide);
  t.diagnostic(JSON.stringify({channels:10000,coldMs,warm30Ms:warmMs,warmProviderRequests:0,coldGuideRequests:guideReads()}));
  await kit.api.dispose();
});

test('object-returning worker bridge reuses metadata without sharing mutable results',async()=>{
  const kit=harness(()=>{throw Error('Synthetic worker boundary must not use HTTP');});
  await profile(kit,'Worker objects');await source(kit,m3uConfig('objects','objects.fixture'));
  let reads=0;
  kit.options.createSource=()=>({dispose:()=>Promise.resolve(),async invoke(method,args){
    if(method==='channels'||method==='categories')return [];
    if(method==='capabilities')return {};
    if(method==='mediaDetails'){reads++;return {...JSON.parse(args).item,description:'original'};}
    return null;
  }});
  await kit.api.dispose();kit.api=createLibrary(kit.options);
  await kit.api.query('sources.load',{id:'objects'});
  const args={item:{id:'film',kind:'movie'}};
  (await kit.api.query('media.details',args)).description='changed';
  for(let i=0;i<30;i++)assert.equal((await kit.api.query('media.details',args)).description,'original');
  assert.equal(reads,1);
});
test('actual Source factory drives VOD details, series/episodes, XMLTV and catch-up eligibility',async()=>{
  const kit=await vodHarness();
  assert.equal((await kit.api.query('catalog.categories',{kind:'movie'}))[0].title,'Movies');
  assert.equal((await kit.api.query('media.details',{item:kit.movie})).description,'Actual Source detail');
  const series=(await kit.api.query('catalog.items',{kind:'series',categoryId:'series'})).items[0];
  const season=(await kit.api.query('media.children',{item:series})).items[0];
  const episode=(await kit.api.query('media.children',{item:season})).items[0];
  assert.equal(episode.title,'Pilot');
  const guide=await kit.api.query('guide',{channels:kit.loaded.channels});
  assert.equal(guide.programmes[0].canCatchup,true);
  await kit.api.query('playback.play',{channel:kit.loaded.channels[0],programme:guide.programmes[0]});
  assert.equal(kit.calls.open.at(-1).stream.isLive,false);
  assert.match(kit.calls.open.at(-1).stream.url,/\/timeshift\//);
});

test('selecting A then the already playing B cancels the pending A identity',async()=>{
  const kit=await vodHarness(),b=kit.movie,a={...b,id:'501',title:'Other'};
  await kit.api.query('playback.play',{item:b});const before=kit.calls.open.length;
  const first=kit.api.query('playback.play',{item:a}),last=kit.api.query('playback.play',{item:b});
  await Promise.allSettled([first,last]);
  assert.equal(kit.calls.open.length,before);assert.match(kit.calls.open.at(-1).stream.url,/\/500\.mp4$/);
});

test('canonical episode context cannot repopulate children after catalogue invalidation',async()=>{
  const real=modules();
  const engine=real.core.createSource(JSON.stringify({id:'generation',kind:'xtream',label:'Generation',fields:{host:'https://episode-generation.fixture',username:'fixture',password:'fixture'},settings:{}}),async raw=>{
    const request=JSON.parse(raw);return JSON.stringify({status:200,body:JSON.stringify(xtreamRoute(new URL(request.url))),url:request.url,headers:{},decoded:true});
  });
  const call=(method,args={})=>engine.invoke(method,JSON.stringify(args)).then(JSON.parse);
  try{
    await call('connect');const roots=await call('mediaItems',{kind:'series'});
    const seasons=await call('mediaItems',{kind:'season',parent:roots[0]});
    const episode={id:'901',kind:'episode',parentId:seasons[0].id,title:'Pilot',seasonNumber:1,episodeNumber:1,extra:{id:901}};
    const pending=call('playbackEpisodes',{item:episode}),cancelled=assert.rejects(pending);
    await call('invalidate');await cancelled;
  }finally{await engine.dispose();}
});
test('manual series refresh invalidates unchanged roots and preserves old children on failure',async()=>{
  let updated=false,fail=false;
  const kit=harness(url=>{
    if(url.searchParams.get('action')==='get_series_info') {
      if(fail)return 'Malformed provider response';
      return {info:{},seasons:[{season_number:1}],episodes:{1:[{id:901,title:'Pilot',episode_num:1},...(updated?[{id:902,title:'New episode',episode_num:2}]:[])]}};
    }
    return xtreamRoute(url);
  });
  await profile(kit,'Refresh');await source(kit,{id:'series-refresh',kind:'xtream',label:'Series',fields:{host:'https://series-refresh-'+kit.suffix+'.fixture',username:'fixture',password:'fixture'},settings:{}});
  await kit.api.query('sources.load',{id:'series-refresh'});
  const root=(await kit.api.query('catalog.items',{kind:'series'})).items[0];
  let detail=await kit.api.query('media.details',{item:root});
  const oldDetail=detail;
  let season=(await kit.api.query('media.children',{item:detail})).items[0];
  const oldSeason=season;
  assert.equal((await kit.api.query('media.children',{item:season})).items.length,1);
  updated=true;detail=await kit.api.query('media.refresh',{item:root});
  assert.equal((await kit.api.query('media.children',{item:oldSeason})).items.length,2,'an old open season cannot restore its embedded pre-refresh episode tree');
  assert.equal((await kit.api.query('media.children',{item:oldDetail})).items.length,1,'an old open series uses the refreshed authoritative details');
  season=(await kit.api.query('media.children',{item:detail})).items[0];
  assert.equal((await kit.api.query('media.children',{item:season})).items.length,2);
  assert.equal((await kit.api.query('media.episodes',{item:(await kit.api.query('media.children',{item:season})).items[0]})).next.id,'902');
  fail=true;await assert.rejects(kit.api.query('media.refresh',{item:root}));
  assert.equal((await kit.api.query('media.children',{item:season})).items.length,2,'failed refresh keeps the last complete cached children');
});

test('favorites/history/resume use actual persistence and original supporter/position policies',async()=>{
  const kit=await vodHarness();
  await kit.api.query('favorites.toggle',{item:kit.movie});
  assert.equal((await kit.api.query('favorites.list')).items[0].item.id,kit.movie.id);
  await kit.api.query('playback.play',{item:kit.movie});
  kit.progress(42,100);await kit.api.query('playback.stop');
  const free=await kit.api.query('resume.get',{sourceId:'vod',item:kit.movie});
  assert.equal(free.position,42);assert.equal(free.allowed,false);
  const before=kit.calls.open.length;
  await rejectsCode(kit.api.query('playback.play',{item:kit.movie,resumeMode:'resume'}),'supporter_required');
  assert.equal(kit.calls.open.length,before);
  await kit.api.query('playback.play',{item:kit.movie,resumeMode:'start'});
  assert.equal(kit.calls.seek.length,0);
  await kit.api.query('playback.stop');kit.supporter(true);
  await kit.api.query('playback.play',{item:kit.movie,resumeMode:'resume'});
  assert.equal(kit.calls.seek.at(-1),42);
  kit.progress(96,100);await kit.api.query('playback.stop');
  assert.equal((await kit.api.query('resume.get',{sourceId:'vod',item:kit.movie})).position,0);
  assert.equal((await kit.api.query('history.list')).items.length,1);
});

test('ready playback and fullscreen reuse do not wait for history; stop flushes it',async()=>{
  const kit=await vodHarness(), channel=kit.loaded.channels[0];
  const held=kit.device.deferNext();
  try {
    const ready=kit.api.query('playback.preview',{channel});
    await held.started.promise;
    const state=await ready;
    assert.equal(state.playing,true);
    await kit.api.query('playback.play',{channel,rect:{x:0,y:0,width:1920,height:1080}});
    assert.equal(kit.calls.open.length,1);
    let stopped=false;
    const stopping=kit.api.query('playback.stop').then(()=>{stopped=true;});
    await new Promise(resolve=>setImmediate(resolve));
    assert.equal(stopped,false);
    held.done.resolve();await stopping;
    assert.equal((await kit.api.query('history.list')).items[0].channel.id,channel.id);
  } finally { held.done.resolve(); }
});

test('failed history persistence reports once without failing or reopening playback',async()=>{
  const kit=await vodHarness(), failures=[];
  kit.options.onError=error=>failures.push(error);
  kit.device.failNext();
  const state=await kit.api.query('playback.preview',{channel:kit.loaded.channels[0]});
  assert.equal(state.playing,true);
  await kit.api.query('history.list');
  assert.equal(failures.length,1);assert.equal(kit.calls.open.length,1);
});

test('parental category locks use original rules and refuse native open without the correct PIN',async()=>{
  const kit=await vodHarness(), verifier=await kit.core.hashPin('1234');
  const key=JSON.parse(kit.core.parentalRules('categoryKey',JSON.stringify({sourceId:'vod',kind:'movie',id:'movies'})));
  await kit.api.query('settings.set',{settings:{parental:{version:1,verifier,lockSettings:true,channels:[],categories:[key]}}});
  await rejectsCode(kit.api.query('playback.play',{item:kit.movie}),'pin_required');
  await rejectsCode(kit.api.query('playback.play',{item:kit.movie,pin:'4321'}),'pin_invalid');
  assert.equal(kit.calls.open.length,0);
  await kit.api.query('playback.play',{item:kit.movie,pin:'1234'});
  assert.equal(kit.calls.open.length,1);
  const other=(await kit.api.query('profiles.create',{name:'Other'})).profile;
  assert.equal(kit.api.getState().playing,false);
  assert.equal((await kit.api.query('bootstrap')).profile.id,other.id);
});

test('concurrent Source loads cannot publish late A over the selected B snapshot',async()=>{
  const hold=deferred();
  const kit=harness(url=>url.host==='race-a.fixture'?hold.promise:m3u(url.host));await profile(kit,'Races');
  await source(kit,m3uConfig('a','race-a.fixture'));await source(kit,m3uConfig('b','race-b.fixture'));
  const a=kit.api.query('sources.load',{id:'a'});const observed=a.then(value=>({value}),error=>({error}));
  const b=await kit.api.query('sources.load',{id:'b'});hold.resolve(m3u('race-a.fixture'));
  assert.equal(b.source.id,'b');assert.ok((await observed).error);
  const stored=JSON.parse(kit.userState.get('local_profiles_v1'));
  assert.equal(stored[0].snapshot.activeSourceId,'b');
});

test('temporary favorite Source cannot retry provider HTTP after its profile is switched',async()=>{
  const kit=harness(xtreamRoute), first=await profile(kit,'Favorite owner');
  await source(kit,{id:'temporary',kind:'xtream',label:'Temporary favorite',
    fields:{host:'https://temporary-favorite.fixture',username:'fixture-user',password:'fixture-pass'},settings:{}});
  await kit.userState.update(state=>{
    state.samsung_favorites_v1=JSON.stringify({[first.id]:[{sourceId:'temporary',
      item:{id:'500',kind:'movie',title:'Film',extra:{}},channel:null,unresolved:true}]});
  });
  const second=(await kit.api.query('profiles.create',{name:'Next owner'})).profile;
  await kit.api.query('profiles.select',{id:first.id});
  const started=deferred();let physical=0,afterSwitch=0,switched=false;
  kit.options.transport.request=async text=>{
    const request=JSON.parse(text);physical++;if(switched)afterSwitch++;
    if(physical===1){started.resolve();return JSON.stringify({status:503,body:'{}',url:request.url,headers:{},decoded:true});}
    return JSON.stringify({status:200,body:JSON.stringify(xtreamRoute(new URL(request.url))),url:request.url,headers:{},decoded:true});
  };
  const pending=kit.api.query('favorites.list');
  const observed=pending.then(value=>({value}),error=>({error}));
  await started.promise;
  await kit.api.query('profiles.select',{id:second.id});switched=true;
  assert.ok((await observed).error);
  assert.equal(physical,1);assert.equal(afterSwitch,0);
  assert.equal((await kit.api.query('bootstrap')).profile.id,second.id);
});

test('an older cross-source play cannot adopt a later request token or reopen after it',async()=>{
  const hold=deferred();
  const kit=harness(url=>url.host==='play-a.fixture'?hold.promise:m3u(url.host));await profile(kit,'Play races');
  await source(kit,m3uConfig('a','play-a.fixture'));await source(kit,m3uConfig('b','play-b.fixture'));
  const b=await kit.api.query('sources.load',{id:'b'});
  const channelA=JSON.parse(kit.core.parseM3u(m3u('play-a.fixture'))).channels[0];
  const old=kit.api.query('playback.play',{sourceId:'a',channel:channelA});const observed=old.then(value=>({value}),error=>({error}));
  await kit.api.query('playback.play',{sourceId:'b',channel:b.channels[0]});
  hold.resolve(m3u('play-a.fixture'));
  assert.ok((await observed).error);
  assert.equal(kit.calls.open.length,1);
  assert.match(kit.calls.open[0].stream.url,/play-b\.fixture/);
});

test('a new play intent survives a prior stop waiting for KeyManager progress persistence',async()=>{
  const kit=await vodHarness();await kit.api.query('playback.play',{item:kit.movie});kit.progress(42,100);
  const hold=kit.device.deferNext(), stop=kit.api.query('playback.stop');
  await hold.started.promise;
  const next=kit.api.query('playback.play',{item:{...kit.movie,id:'501',title:'Next'}});
  hold.done.resolve();await stop;await next;
  assert.equal(kit.api.getState().playing,true);assert.match(kit.calls.open.at(-1).stream.url,/501\.mp4$/);
});

test('profile switching invalidates pending playback authorization and leaves no old native owner',async()=>{
  const kit=await vodHarness();
  const first=(await kit.api.query('bootstrap')).profile;
  const second=(await kit.api.query('profiles.create',{name:'Second'})).profile;
  await kit.api.query('profiles.select',{id:first.id});await kit.api.query('sources.load',{id:'vod'});
  const verifier=await kit.core.hashPin('1234');
  await kit.api.query('settings.set',{settings:{parental:{version:1,verifier,lockSettings:false,channels:[],categories:[JSON.stringify(['vod','movie','movies'])]}}});
  const pending=kit.api.query('playback.play',{item:kit.movie,pin:'1234'});const observed=pending.then(value=>({value}),error=>({error}));
  await kit.api.query('profiles.select',{id:second.id});await observed;
  assert.equal((await kit.api.query('bootstrap')).profile.id,second.id);
  assert.equal(kit.api.getState().playing,false);
  assert.deepEqual(await kit.api.query('sources.list'),[]);
});

test('parental management uses canonical PIN/rules and damaged policies never unlock playback',async()=>{
  const kit=await vodHarness();
  assert.equal((await kit.api.query('parental.get')).enabled,false);
  await kit.api.query('parental.setPin',{newPin:'1234',lockSettings:false});
  await rejectsCode(kit.api.query('parental.toggle',{type:'category',sourceId:'vod',kind:'movie',id:'movies'}),'pin_required');
  await rejectsCode(kit.api.query('parental.toggle',{type:'category',sourceId:'vod',kind:'movie',id:'movies',pin:'4321'}),'pin_invalid');
  const locked=await kit.api.query('parental.toggle',{type:'category',sourceId:'vod',kind:'movie',id:'movies',pin:'1234'});
  assert.deepEqual(locked.categories,[JSON.stringify(['vod','movie','movies'])]);assert.equal(locked.enabled,true);
  assert.equal(Object.hasOwn(locked,'verifier'),false);
  await rejectsCode(kit.api.query('playback.play',{item:kit.movie}),'pin_required');
  const unlocked=await kit.api.query('parental.toggle',{type:'category',sourceId:'vod',kind:'movie',id:'movies',pin:'1234'});
  assert.deepEqual(unlocked.categories,[]);
  await rejectsCode(kit.api.query('parental.setPin',{newPin:'',pin:'4321'}),'pin_invalid');
  assert.equal((await kit.api.query('parental.setPin',{newPin:'',pin:'1234'})).enabled,false);
  await kit.userState.set('tvbro_parental_controls_v1','{"version":999}');
  await assert.rejects(kit.api.query('parental.get'));await assert.rejects(kit.api.query('playback.play',{item:kit.movie}));
  assert.equal(kit.calls.open.length,0);
});

const remoteProfile='f1d7e5d2-1e02-4e4c-8d29-11b4f11a0502';
const otherRemoteProfile='f1d7e5d2-1e02-4e4c-8d29-11b4f11a0503';
const remoteDevice='7f4fc8ed-5ec6-4601-9e9a-2d3396547771';
const remoteSource='90a03a25-9dbf-43c2-a0ab-66737e7f4301';
const staleSource='90a03a25-9dbf-43c2-a0ab-66737e7f4302';
const extraSource='90a03a25-9dbf-43c2-a0ab-66737e7f4303';
function cloudSource(id=remoteSource) {return {id,kind:'xtream',label:'Cloud fixture',fields:{host:'https://cloud-provider.fixture',username:'local-user',password:'local-pass',epgUrl:'https://private-guide.fixture/xml',epgUrls:'https://private-guide2.fixture/xml'},settings:{streamExtension:'m3u8'}};}
async function attachCloud(kit,options={}) {
  const model={profile:{id:remoteProfile,name:'Remote',position:0,pin:null,favorites:[]},sources:[],metadata:[],
    secrets:{sources:{},metadata:null},positions:[],supported:false,calls:[],profiles:null,now:Date.now(),
    paired:options.paired==null?options.authenticated!==false:options.paired,crypto:{enabled:false,ck_version:0},networkFailure:null,
    activeProfileId:Object.hasOwn(options,'activeProfileId')?options.activeProfileId:remoteProfile,rejectProfileId:null};
  class XMLHttpRequest {
    open(method,url,async){this.method=method;this.url=url;assert.equal(async,true);}
    setRequestHeader(name,value){(this.headers??={})[name.toLowerCase()]=value;}
    send(raw){
      const call={method:this.method,url:this.url,headers:this.headers||{},body:raw?JSON.parse(raw):null};model.calls.push(call);
      const url=new URL(this.url);let body,status=200;
      if(url.pathname===model.networkFailure){queueMicrotask(()=>this.onerror());return;}
      if(url.pathname==='/auth/v1/signup')body={access_token:'fixture-access',refresh_token:'fixture-refresh',expires_at:4102444800,user:{id:remoteDevice}};
      else if(url.pathname==='/rest/v1/devices'){
        if(call.method==='DELETE'){model.paired=false;status=204;}
        else body=model.paired?[{device_uid:remoteDevice,owner:'fixture-owner',label:'TV',active_profile_id:model.activeProfileId}]:[];
      }
      else if(url.pathname==='/rest/v1/pairings'&&call.method==='DELETE')status=204;
      else if(url.pathname==='/rest/v1/profiles'){
        body=model.profiles||[model.profile];
        const selected=url.searchParams.get('id');if(selected)body=body.filter(row=>'eq.'+row.id===selected);
      }
      else if(url.pathname==='/rest/v1/sources')body=model.sources;
      else if(url.pathname==='/rest/v1/metadata_configs')body=model.metadata;
      else if(url.pathname==='/rest/v1/rpc/get_crypto_state')body=model.crypto;
      else if(url.pathname==='/rest/v1/rpc/get_secrets')body=model.secrets;
      else if(url.pathname==='/rest/v1/rpc/get_playback_positions')body=model.positions;
      else if(url.pathname==='/rest/v1/rpc/get_playback_delta'){
        const after=Number(call.body.p_after), page=model.positions.slice(after,after+call.body.p_limit);
        body={positions:page,next_cursor:String(after+page.length),has_more:after+page.length<model.positions.length};
      }
      else if(url.pathname==='/rest/v1/rpc/get_supporter_status')body={status:model.supported?'active':'free',supported:model.supported,device_limit:2,valid_until:model.supported?'2099-01-01T00:00:00Z':null};
      else if(url.pathname==='/rest/v1/rpc/request_pairing')body={code:'246810',expires_at:'2099-01-01T00:00:00Z'};
      else if(url.pathname==='/rest/v1/rpc/pairing_status')body=model.paired;
      else if(url.pathname==='/rest/v1/rpc/set_device_profile'){
        if(call.body.p_profile_id===model.rejectProfileId){status=503;body={code:'fixture_rejection'};}
        else{model.activeProfileId=call.body.p_profile_id;status=204;}
      }
      else if(url.pathname==='/rest/v1/rpc/set_profile_pin'){
        const selected=(model.profiles||[model.profile]).find(row=>row.id===call.body.p_profile_id);
        if(selected)selected.pin=call.body.p_pin;status=204;
      }
      else if(url.pathname==='/rest/v1/rpc/push_favorites'){
        const selected=(model.profiles||[model.profile]).find(row=>row.id===call.body.p_profile_id);
        if(selected)selected.favorites=call.body.p_favorites;status=204;
      }
      else if(url.pathname.startsWith('/rest/v1/rpc/push_'))status=204;
      else throw Error('Unrecognized local cloud HTTP fixture '+url.pathname);
      queueMicrotask(()=>{this.status=status;this.responseText=status===204?'':JSON.stringify(body);this.onload();});
    }
  }
  if(options.authenticated!==false){
    await kit.userState.set('supabase_session',JSON.stringify({access_token:'fixture-access',refresh_token:'fixture-refresh',expires_at:4102444800,user:{id:remoteDevice}}));
    if(model.activeProfileId)await kit.userState.set('cloud_profile_id',model.activeProfileId);
  }
  const cloud=createCloud({core:kit.core,now:()=>model.now,config:{apiUrl:'https://api.fixture.test',panelUrl:'https://panel.fixture.test/',anonKey:'public-fixture'},
    userState:kit.userState,XMLHttpRequest,crypto:crypto.webcrypto});
  kit.options.cloud=cloud;kit.api=createLibrary(kit.options);kit.cloudModel=model;
  return model;
}
async function positionSnapshot(kit,item,position=42.5,updatedAt='2026-01-01T00:00:00.000Z') {
  const owner=(await kit.api.query('bootstrap')).profile,local=owner.source==='cloud'?'cloud:'+owner.id:owner.id;
  const key=JSON.stringify([remoteSource,item.kind,item.id]);
  await kit.userState.update(state=>{const all=JSON.parse(state.samsung_playback_positions_v1||'{}');
    all[local]={...(all[local]||{}),[key]:{sourceId:remoteSource,item,position,duration:100,updatedAt,removed:false}};
    state.samsung_playback_positions_v1=JSON.stringify(all);});
}
function localProfileState(kit) {
  const state=kit.userState.read();
  return Object.fromEntries(['local_profiles_v1','active_local_profile_id','samsung_favorites_v1',
    'samsung_playback_positions_v1','samsung_playback_sync_v1','samsung_history_v1','samsung_settings_v1','tvbro_parental_controls_v1']
    .map(key=>[key,state[key]??null]));
}

test('first-use cloud pairing creates a session only after the explicit pairing action and never creates a local profile',async()=>{
  const kit=harness(()=>{throw Error('Pairing must not contact a provider');});
  const cloud=await attachCloud(kit,{authenticated:false});
  const boot=await kit.api.query('bootstrap');
  assert.deepEqual(boot.profiles,[]);assert.equal(boot.profile,null);
  assert.equal((await kit.api.query('pairing.get')).hasSession,false);
  await rejectsCode(kit.api.query('pairing.download',{profileId:remoteProfile}),'cloud_profile_required');
  assert.equal(kit.userState.get('supabase_session'),null);assert.deepEqual(cloud.calls,[]);
  const before=localProfileState(kit), started=await kit.api.query('pairing.start');
  assert.equal(started.code,'246810');assert.equal(new URL(started.panelLink).hostname,'panel.fixture.test');
  assert.equal(cloud.calls.filter(call=>new URL(call.url).pathname==='/auth/v1/signup').length,1);
  assert.equal(cloud.calls.filter(call=>call.url.endsWith('/request_pairing')).length,1);
  assert.ok(kit.userState.get('supabase_session'));
  await assert.rejects(kit.api.query('pairing.profiles'),{name:'CloudStateError'});
  assert.deepEqual(localProfileState(kit),before);
  cloud.paired=true;
  assert.equal(await kit.api.query('pairing.status',{code:started.code}),true);
  assert.deepEqual(await kit.api.query('pairing.profiles'),[{id:remoteProfile,name:'Remote',pinSet:false}]);
  assert.deepEqual(localProfileState(kit),before);assert.equal(kit.calls.requests.length,0);
});

test('first-use cloud download requires an explicit profile and canonical PIN before committing its complete snapshot',async()=>{
  const kit=harness(xtreamRoute), cloud=await attachCloud(kit,{activeProfileId:null});
  cloud.profile.pin=await kit.core.hashPin('1234');
  cloud.profiles=[{id:extraSource,name:'Other remote',position:0,pin:null},cloud.profile];
  cloud.sources=[{id:remoteSource,kind:'xtream',label:'Remote source',
    fields:{host:'https://remote-onboarding.fixture',password:'ignored-broad-password'},settings:{streamExtension:'m3u8'}}];
  cloud.secrets={sources:{[remoteSource]:{format:0,payload:{username:'remote-user',password:'remote-password',epgUrls:'https://private-remote.fixture/xml'}}},
    metadata:{format:0,payload:{tmdbApiKey:'remote-metadata-key'}}};
  cloud.metadata=[{config:{provider:'tmdb',autoEnrich:true}}];
  cloud.profile.favorites=[{source_id:remoteSource,kind:'movie',item_id:'500'}];
  cloud.positions=[{source_id:remoteSource,kind:'movie',item_id:'500',position_ms:42500,duration_ms:100000,
    updated_at:Date.parse('2026-01-01T00:00:00Z'),removed:false}];
  const boot=await kit.api.query('bootstrap'), before=localProfileState(kit);
  assert.equal(boot.profile,null);assert.deepEqual(boot.profiles.map(row=>row.source),['cloud','cloud']);
  assert.equal(cloud.calls.every(call=>call.method==='GET'),true);
  const listed=await kit.api.query('pairing.profiles');
  assert.deepEqual(listed,[{id:extraSource,name:'Other remote',pinSet:false},{id:remoteProfile,name:'Remote',pinSet:true}]);
  assert.equal(JSON.stringify(listed).includes(cloud.profile.pin),false);
  await rejectsCode(kit.api.query('pairing.download'),'cloud_profile_required');
  await rejectsCode(kit.api.query('pairing.download',{profileId:staleSource}),'cloud_profile_required');
  await rejectsCode(kit.api.query('pairing.download',{profileId:remoteProfile}),'pin_required');
  await rejectsCode(kit.api.query('pairing.download',{profileId:remoteProfile,pin:'4321'}),'pin_invalid');
  assert.equal(cloud.calls.some(call=>call.url.endsWith('/set_device_profile')),false);
  assert.equal(cloud.calls.some(call=>new URL(call.url).pathname==='/rest/v1/sources'),false);
  assert.deepEqual(localProfileState(kit),before);
  const imported=await kit.api.query('pairing.download',{profileId:remoteProfile,pin:'1234'});
  const importedId=imported.profile.id;
  assert.equal(imported.onboardingReady,true);assert.equal(importedId,remoteProfile);assert.equal(imported.profile.source,'cloud');
  assert.equal(imported.activeProfileId,remoteProfile);assert.equal(imported.activeProfileSource,'cloud');
  assert.equal(kit.userState.get('local_profiles_v1'),before.local_profiles_v1);assert.equal(kit.userState.get('active_local_profile_id'),null);
  assert.equal(kit.userState.get('cloud_profile_id'),remoteProfile);
  assert.equal(imported.profile.name,'Remote');assert.equal(imported.profile.locked,false);
  assert.equal(imported.profiles.length,2);assert.equal(imported.sources.length,1);
  assert.deepEqual(imported.sources[0].fields,{host:'https://remote-onboarding.fixture',username:'remote-user',
    password:'remote-password',epgUrls:'https://private-remote.fixture/xml'});
  const stored=JSON.parse(kit.userState.get('cloud_profile_snapshots_v1'))[remoteProfile];
  assert.deepEqual(JSON.parse(kit.userState.get('cloud_profile_pins_v1'))[remoteProfile],{pin:cloud.profile.pin,name:'Remote'});
  assert.deepEqual(stored.managedIds,[remoteSource]);assert.equal(stored.activeSourceId,remoteSource);
  assert.deepEqual(stored.metadata,{provider:'tmdb',autoEnrich:true,tmdbApiKey:'remote-metadata-key'});
  const favorite=JSON.parse(kit.userState.get('samsung_favorites_v1'))['cloud:'+importedId][0];
  assert.equal(favorite.sourceId,remoteSource);assert.equal(favorite.item.id,'500');assert.equal(favorite.item.kind,'movie');
  const position=JSON.parse(kit.userState.get('samsung_playback_positions_v1'))['cloud:'+importedId][JSON.stringify([remoteSource,'movie','500'])];
  assert.equal(position.position,42.5);assert.equal(position.duration,100);assert.equal(position.removed,false);
  assert.equal(kit.calls.requests.length,0);
  assert.ok(cloud.calls.filter(call=>call.url.endsWith('/set_device_profile')).every(call=>call.body.p_profile_id===remoteProfile));
  assert.equal(JSON.stringify(cloud.calls).includes('"pin":"1234"'),false);
  assert.equal(JSON.parse(persistedUserState(kit).cloud_profile_pins_v1)[remoteProfile].pin,cloud.profile.pin);
  assert.notEqual(JSON.parse(persistedUserState(kit).cloud_profile_pins_v1)[remoteProfile].pin,'1234');
  const cold=createLibrary(kit.options), locked=await cold.query('bootstrap');
  assert.equal(locked.profile.locked,true);assert.deepEqual(locked.sources,[]);
  await rejectsCode(cold.query('profiles.select',{id:importedId,source:'cloud',pin:'4321'}),'pin_invalid');
  assert.equal((await cold.query('profiles.select',{id:importedId,source:'cloud',pin:'1234'})).sources[0].fields.password,'remote-password');
  const repeated=await kit.api.query('pairing.download',{profileId:remoteProfile,pin:'1234'});
  assert.equal(repeated.profile.id,remoteProfile);assert.equal(repeated.profiles.filter(row=>row.id===remoteProfile&&row.source==='cloud').length,1);
  assert.equal(kit.userState.get('local_profiles_v1'),before.local_profiles_v1);
  assert.deepEqual(Object.keys(JSON.parse(kit.userState.get('cloud_profile_snapshots_v1'))),[remoteProfile]);
});

test('failed first-use downloads leave local profile, active selection and all profile buckets uncommitted',async t=>{
  const failures=[
    {name:'provider snapshot network failure',prepare(kit,cloud){cloud.networkFailure='/rest/v1/sources';},expected:{name:'NetworkError'}},
    {name:'encrypted snapshot without an approved key',prepare(kit,cloud){cloud.crypto={enabled:true,ck_version:3};},expected:{name:'CryptoLockedError'}},
    {name:'malformed cloud source fields',prepare(kit,cloud){cloud.sources[0].fields.host={secret:'invalid-shape'};},expected:{name:'ProtocolError'}},
    {name:'empty remote profile',prepare(kit,cloud){cloud.sources=[];},code:'cloud_no_usable_sources'},
    {name:'source without its required secret',prepare(kit,cloud){delete cloud.secrets.sources[remoteSource].payload.password;},code:'cloud_no_usable_sources'},
    {name:'KeyManager rejects the atomic profile commit',prepare(kit){kit.device.failWhen((alias,raw)=>alias.startsWith('tvbro_user_state_v1_g')&&
      JSON.parse(raw).cloud_profile_snapshots_v1!=null);},expected:{name:'UnknownError'}}
  ];
  for(const failure of failures)await t.test(failure.name,async()=>{
    const kit=harness(()=>{throw Error('Download must not contact a provider');}),cloud=await attachCloud(kit,{activeProfileId:null});
    await kit.api.query('bootstrap');
    cloud.sources=[{id:remoteSource,kind:'xtream',label:'Remote',fields:{host:'https://failure-onboarding.fixture'},settings:{}}];
    cloud.secrets={sources:{[remoteSource]:{format:0,payload:{username:'remote-user',password:'remote-password'}}},metadata:null};
    const before=localProfileState(kit),cloudBefore=kit.userState.get('cloud_profile_snapshots_v1');failure.prepare(kit,cloud);
    const download=kit.api.query('pairing.download',{profileId:remoteProfile});
    if(failure.code)await rejectsCode(download,failure.code);else await assert.rejects(download,failure.expected);
    assert.deepEqual(localProfileState(kit),before);
    assert.equal(kit.userState.get('cloud_profile_snapshots_v1'),cloudBefore);assert.equal(kit.userState.get('cloud_profile_id'),null);
    const persisted=persistedUserState(kit);
    for(const [key,value]of Object.entries(before))assert.equal(persisted[key]??null,value,key);
    const boot=await kit.api.query('bootstrap');assert.equal(boot.profile,null);assert.equal(boot.profiles.length,1);
    assert.equal(kit.calls.requests.length,0);assert.equal(kit.calls.open.length,0);
  });
});

test('cloud onboarding imports a separate profile without borrowing source or metadata secrets from an existing profile',async()=>{
  const kit=harness(xtreamRoute), owner=await profile(kit,'Existing local');
  await source(kit,cloudSource());
  const item={id:'500',kind:'movie',title:'Local favorite',extra:{}};
  await kit.api.query('favorites.toggle',{sourceId:remoteSource,item});await positionSnapshot(kit,item,64);
  await kit.api.query('settings.set',{settings:{profilePickerStartup:'always'}});
  await kit.userState.update(state=>{const rows=JSON.parse(state.local_profiles_v1);
    rows[0].snapshot.metadata={provider:'tmdb',tmdbApiKey:'local-tmdb',tvdbApiKey:'local-tvdb'};state.local_profiles_v1=JSON.stringify(rows);});
  const original=JSON.parse(kit.userState.get('local_profiles_v1'))[0], before=localProfileState(kit);
  const cloud=await attachCloud(kit);
  cloud.sources=[{id:remoteSource,kind:'xtream',label:'Remote',fields:{host:'https://isolated-onboarding.fixture'},settings:{}}];
  cloud.secrets={sources:{[remoteSource]:{format:0,payload:{username:'remote-user'}}},metadata:{format:0,payload:{tmdbApiKey:'remote-tmdb'}}};
  cloud.metadata=[{config:{provider:'tmdb'}}];
  await rejectsCode(kit.api.query('pairing.download',{profileId:remoteProfile}),'cloud_no_usable_sources');
  assert.deepEqual(localProfileState(kit),before);
  cloud.secrets.sources[remoteSource].payload.password='remote-password';
  const imported=await kit.api.query('pairing.download',{profileId:remoteProfile});
  assert.equal(imported.profile.id,remoteProfile);assert.equal(imported.profile.source,'cloud');assert.equal(imported.profiles.length,2);
  assert.deepEqual(imported.sources[0].fields,{host:'https://isolated-onboarding.fixture',username:'remote-user',password:'remote-password'});
  const stored=JSON.parse(kit.userState.get('local_profiles_v1'));
  assert.deepEqual(stored.find(row=>row.id===owner.id),original);
  assert.equal(stored.length,1);
  assert.deepEqual(JSON.parse(kit.userState.get('cloud_profile_snapshots_v1'))[remoteProfile].metadata,{provider:'tmdb',tmdbApiKey:'remote-tmdb'});
  assert.deepEqual(imported.favorites,[]);assert.deepEqual(imported.history,[]);assert.deepEqual(imported.settings,{profilePickerStartup:'always'});
  await kit.api.query('profiles.select',{id:owner.id});
  assert.equal((await kit.api.query('sources.list'))[0].fields.password,'local-pass');
  assert.equal((await kit.api.query('sources.list'))[0].fields.epgUrls,'https://private-guide2.fixture/xml');
  assert.equal((await kit.api.query('favorites.list')).items[0].item.title,'Local favorite');
  assert.equal((await kit.api.query('resume.get',{sourceId:remoteSource,item})).position,64);
  assert.equal((await kit.api.query('settings.get')).settings.profilePickerStartup,'always');
});

test('same-ID local and cloud profiles keep separate snapshots and buckets across select, pull, push and unpair',async()=>{
  const kit=harness(xtreamRoute),owner=await profile(kit,'Local collision');
  await source(kit,cloudSource());
  const localItem={id:'500',kind:'movie',title:'Local favorite',extra:{}},cloudItem={id:'501',kind:'movie',title:'Cloud favorite',extra:{}};
  await kit.api.query('favorites.toggle',{sourceId:remoteSource,item:localItem});await positionSnapshot(kit,localItem,64);
  await kit.api.query('settings.set',{settings:{profilePickerStartup:'always'}});
  const localBytes=kit.userState.get('local_profiles_v1'),cloud=await attachCloud(kit,{activeProfileId:owner.id});
  cloud.profile.id=owner.id;cloud.profile.name='Cloud collision';cloud.profile.pin=await kit.core.hashPin('1234');
  cloud.sources=[{id:remoteSource,kind:'xtream',label:'Cloud source',fields:{host:'https://collision-cloud.fixture'},settings:{}}];
  cloud.secrets={sources:{[remoteSource]:{format:0,payload:{username:'cloud-user',password:'cloud-password'}}},metadata:null};
  const boot=await kit.api.query('bootstrap');
  assert.deepEqual(boot.profiles.map(row=>[row.id,row.source]),[[owner.id,'cloud'],[owner.id,'local']]);
  assert.equal(boot.activeProfileSource,'local');assert.equal(cloud.calls.every(call=>call.method==='GET'),true);
  await rejectsCode(kit.api.query('profiles.select',{id:owner.id}),'ambiguous_profile');
  assert.equal(cloud.calls.every(call=>call.method==='GET'),true);
  await kit.api.query('pairing.download',{profileId:owner.id,pin:'1234'});
  assert.equal(kit.userState.get('local_profiles_v1'),localBytes);assert.equal(kit.userState.get('active_local_profile_id'),null);
  await kit.api.query('sources.update',{config:{id:remoteSource,kind:'xtream',label:'Cloud edited',fields:{password:'cloud-edited-password'}}});
  await kit.api.query('settings.set',{settings:{profilePickerStartup:'off'}});
  await kit.api.query('favorites.toggle',{sourceId:remoteSource,item:cloudItem});await positionSnapshot(kit,cloudItem,42);
  const loaded=await kit.api.query('sources.load',{id:remoteSource});
  await kit.api.query('playback.play',{sourceId:remoteSource,channel:loaded.channels[0]});await kit.api.query('playback.stop');
  cloud.supported=true;await kit.api.query('pairing.push',{profileId:owner.id});
  const pushed=cloud.calls.filter(call=>call.url.endsWith('/push_sources')).at(-1).body.p_sources[0];
  assert.equal(pushed.secret.payload.password,'cloud-edited-password');
  assert.deepEqual(cloud.calls.filter(call=>call.url.endsWith('/push_playback_positions')).at(-1).body.p_changes.map(row=>row.item_id),['501']);
  const selections=cloud.calls.filter(call=>call.url.endsWith('/set_device_profile')).length;
  const local=await kit.api.query('profiles.select',{id:owner.id,source:'local'});
  assert.equal(local.activeProfileSource,'local');assert.equal(local.sources[0].fields.password,'local-pass');
  assert.equal(cloud.calls.filter(call=>call.url.endsWith('/set_device_profile')).length,selections);
  assert.equal((await kit.api.query('favorites.list')).items[0].item.id,'500');
  assert.equal((await kit.api.query('resume.get',{sourceId:remoteSource,item:localItem})).position,64);
  assert.equal((await kit.api.query('settings.get')).settings.profilePickerStartup,'off');
  assert.deepEqual((await kit.api.query('history.list')).items,[]);
  delete cloud.secrets.sources[remoteSource].payload.password;
  const selected=await kit.api.query('profiles.select',{id:owner.id,source:'cloud',pin:'1234'});
  assert.equal(selected.activeProfileSource,'cloud');assert.equal(selected.sources[0].fields.password,'cloud-edited-password');
  assert.equal(selected.settings.profilePickerStartup,'off');assert.equal(selected.history[0].channel.id,'11');
  assert.equal((await kit.api.query('favorites.list')).items[0].item.id,'501');
  assert.equal((await kit.api.query('resume.get',{sourceId:remoteSource,item:cloudItem})).position,42);
  const favorites=JSON.parse(kit.userState.get('samsung_favorites_v1'));
  assert.equal(favorites[owner.id][0].item.id,'500');assert.equal(favorites['cloud:'+owner.id][0].item.id,'501');
  const snapshot=kit.userState.get('cloud_profile_snapshots_v1'),mark=cloud.calls.length;
  await kit.api.query('pairing.unpair');
  const mutations=cloud.calls.slice(mark).filter(call=>call.method!=='GET');
  assert.equal(mutations.length,2);assert.equal(mutations.every(call=>call.method==='DELETE'&&call.url.includes('device_uid=eq.'+remoteDevice)),true);
  assert.equal(kit.userState.get('local_profiles_v1'),localBytes);assert.equal(kit.userState.get('cloud_profile_snapshots_v1'),snapshot);
  assert.equal(kit.userState.get('cloud_profile_pins_v1'),null);assert.ok(kit.userState.get('supabase_session'));
  const unpaired=await createLibrary(kit.options).query('bootstrap');
  assert.equal(unpaired.profile,null);assert.equal(unpaired.ownerless,true);
  assert.deepEqual(unpaired.profiles.map(row=>[row.id,row.source]),[[owner.id,'local']]);
  assert.equal((await kit.api.query('profiles.select',{id:owner.id,source:'local'})).sources[0].fields.password,'local-pass');
});

test('online cloud PIN refresh replaces the cached verifier and offline fallback never survives definitive unpairing',async()=>{
  const kit=harness(xtreamRoute),cloud=await attachCloud(kit,{activeProfileId:null});
  cloud.profile.pin=await kit.core.hashPin('1234');
  cloud.sources=[{id:remoteSource,kind:'xtream',label:'Cloud',fields:{host:'https://pin-refresh.fixture'},settings:{}}];
  cloud.secrets={sources:{[remoteSource]:{format:0,payload:{username:'remote-user',password:'remote-password'}}},metadata:null};
  await kit.api.query('pairing.download',{profileId:remoteProfile,pin:'1234'});
  const changed=await kit.core.hashPin('5678');cloud.profile.pin=changed;cloud.profile.name='Renamed remote';
  const refreshed=await kit.api.query('bootstrap');
  assert.equal(refreshed.profile.locked,true);assert.deepEqual(refreshed.sources,[]);
  assert.deepEqual(JSON.parse(kit.userState.get('cloud_profile_pins_v1')),{[remoteProfile]:{pin:changed,name:'Renamed remote'}});
  await rejectsCode(kit.api.query('profiles.select',{id:remoteProfile,source:'cloud',pin:'1234'}),'pin_invalid');
  cloud.networkFailure='/rest/v1/devices';
  const cold=createLibrary(kit.options),offline=await cold.query('bootstrap');
  assert.equal(offline.profile.id,remoteProfile);assert.equal(offline.profile.source,'cloud');assert.equal(offline.profile.locked,true);
  const mark=cloud.calls.length;
  await rejectsCode(cold.query('profiles.select',{id:remoteProfile,source:'cloud',pin:'1234'}),'pin_invalid');
  const unlocked=await cold.query('profiles.select',{id:remoteProfile,source:'cloud',pin:'5678'});
  assert.equal(unlocked.sources[0].fields.password,'remote-password');assert.equal(unlocked.profile.locked,false);
  assert.equal(cloud.calls.slice(mark).every(call=>call.method==='GET'&&new URL(call.url).pathname==='/rest/v1/devices'),true);
  cloud.networkFailure=null;cloud.paired=false;
  const definitivelyUnpaired=await cold.query('bootstrap');
  assert.equal(definitivelyUnpaired.profile,null);assert.deepEqual(definitivelyUnpaired.profiles,[]);
  cloud.paired=true;cloud.profile.pin=null;
  const pinRemoved=await cold.query('bootstrap');
  assert.equal(pinRemoved.profile.pinSet,false);assert.equal(pinRemoved.profile.locked,false);
  assert.deepEqual(JSON.parse(kit.userState.get('cloud_profile_pins_v1')),{});
  cloud.networkFailure='/rest/v1/devices';
  assert.equal((await createLibrary(kit.options).query('bootstrap')).profile,null);
});

test('cloud PIN changes send canonical verifiers to set_profile_pin and preserve a same-ID local PIN',async()=>{
  const kit=harness(xtreamRoute),owner=await profile(kit,'Local PIN','2468');
  const localBytes=kit.userState.get('local_profiles_v1'),cloud=await attachCloud(kit,{activeProfileId:owner.id});
  cloud.profile.id=owner.id;cloud.profile.pin=await kit.core.hashPin('1234');await kit.api.query('bootstrap');
  await rejectsCode(kit.api.query('profiles.pin',{id:owner.id,source:'cloud',currentPin:'4321',pin:'5678'}),'pin_invalid');
  assert.equal(cloud.calls.some(call=>call.url.endsWith('/set_profile_pin')),false);
  const changed=await kit.api.query('profiles.pin',{id:owner.id,source:'cloud',currentPin:'1234',pin:'5678'});
  const rpc=cloud.calls.find(call=>call.url.endsWith('/set_profile_pin'));
  assert.deepEqual(rpc.body,{p_profile_id:owner.id,p_pin:cloud.profile.pin});assert.notEqual(rpc.body.p_pin,'5678');
  assert.equal(await kit.core.verifyPin('5678',rpc.body.p_pin),true);assert.equal(await kit.core.verifyPin('1234',rpc.body.p_pin),false);
  assert.equal(changed.activeProfileSource,'local');assert.equal(kit.userState.get('local_profiles_v1'),localBytes);
  assert.deepEqual(JSON.parse(kit.userState.get('cloud_profile_pins_v1'))[owner.id],{pin:rpc.body.p_pin,name:'Remote'});
  await kit.api.query('profiles.pin',{id:owner.id,source:'cloud',currentPin:'5678',pin:''});
  assert.deepEqual(cloud.calls.filter(call=>call.url.endsWith('/set_profile_pin')).at(-1).body,{p_profile_id:owner.id,p_pin:null});
  assert.equal(kit.userState.get('local_profiles_v1'),localBytes);assert.deepEqual(JSON.parse(kit.userState.get('cloud_profile_pins_v1')),{});
  assert.equal(JSON.stringify(cloud.calls).includes('"p_pin":"5678"'),false);
});

test('cloud activation network and KeyManager failures restore the existing local owner and prior remote selection',async t=>{
  for(const failure of ['pull','selection','commit'])await t.test(failure,async()=>{
    const kit=harness(xtreamRoute),owner=await profile(kit,'Rollback owner');await source(kit,m3uConfig('local','rollback-local.fixture'));
    const cloud=await attachCloud(kit);
    cloud.profiles=[cloud.profile,{id:otherRemoteProfile,name:'Target',pin:null,favorites:[]}];
    cloud.sources=[{id:remoteSource,kind:'xtream',label:'Incoming target',fields:{host:'https://rollback-cloud.fixture'},settings:{}}];
    cloud.secrets={sources:{[remoteSource]:{format:0,payload:{username:'target-user',password:'target-password'}}},metadata:null};
    await kit.userState.set('cloud_profile_snapshots_v1',JSON.stringify({[remoteProfile]:{sources:[],managedIds:[]},[otherRemoteProfile]:{sources:[],managedIds:[]}}));
    await kit.userState.set('cloud_source_ids',staleSource);await kit.api.query('bootstrap');
    const before=localProfileState(kit),snapshots=kit.userState.get('cloud_profile_snapshots_v1'),mark=cloud.calls.length;
    if(failure==='pull')cloud.networkFailure='/rest/v1/sources';
    if(failure==='selection')cloud.rejectProfileId=otherRemoteProfile;
    let rejectedCommit=false;
    if(failure==='commit')kit.device.failWhen((alias,raw)=>{
      const state=alias.startsWith('tvbro_user_state_v1_g')?JSON.parse(raw):{};
      const target=JSON.parse(state.cloud_profile_snapshots_v1||'{}')[otherRemoteProfile];
      return rejectedCommit=!!(target&&target.sources.length&&target.sources[0].label==='Incoming target');
    });
    await assert.rejects(kit.api.query('pairing.download',{profileId:otherRemoteProfile}),{name:failure==='pull'?'NetworkError':failure==='selection'?'CloudError':'UnknownError'});
    assert.deepEqual(localProfileState(kit),before);assert.equal(kit.userState.get('cloud_profile_snapshots_v1'),snapshots);
    assert.equal(kit.userState.get('cloud_profile_id'),remoteProfile);assert.equal(kit.userState.get('cloud_source_ids'),staleSource);
    assert.equal(cloud.activeProfileId,remoteProfile);if(failure==='commit')assert.equal(rejectedCommit,true);
    const selections=cloud.calls.slice(mark).filter(call=>call.url.endsWith('/set_device_profile')).map(call=>call.body.p_profile_id);
    assert.deepEqual(selections,failure==='pull'?[]:[otherRemoteProfile,remoteProfile]);
    const boot=await kit.api.query('bootstrap');assert.equal(boot.profile.id,owner.id);assert.equal(boot.profile.source,'local');
    assert.equal(boot.sources[0].id,'local');assert.equal(kit.calls.requests.length,0);
  });
});

test('unpairing while a local profile is active keeps its selection and data',async()=>{
  const kit=harness(xtreamRoute),owner=await profile(kit,'Local unpair');await source(kit,m3uConfig('local','unpair-local.fixture'));
  const cloud=await attachCloud(kit),before=localProfileState(kit);await kit.api.query('bootstrap');
  await kit.api.query('pairing.unpair');
  assert.deepEqual(localProfileState(kit),before);
  const boot=await kit.api.query('bootstrap');assert.equal(boot.profile.id,owner.id);assert.equal(boot.profile.source,'local');
  assert.equal(boot.sources[0].id,'local');assert.equal(cloud.paired,false);
});

test('fresh Demo setup loads live, movies and series from the actual canonical Source without provider HTTP',async()=>{
  const kit=harness(()=>{throw Error('Built-in Demo must not fetch a provider');});
  const owner=await profile(kit,'Demo');
  const setup=await kit.api.query('sources.demo');
  assert.equal(setup.activeSourceId,'demo');assert.equal(setup.sources.length,1);
  assert.equal((await kit.api.query('sources.demo')).sources.length,1);
  const loaded=await kit.api.query('sources.load',{id:'demo'});
  assert.ok(loaded.channels.some(channel=>channel.id==='bbb'));assert.ok(loaded.categories.length>0);
  const categories=await kit.api.query('catalog.categories',{kind:'movie'});
  const movie=(await kit.api.query('catalog.items',{kind:'movie',categoryId:categories[0].id,page:1})).items[0];
  assert.equal(movie.title,'Big Buck Bunny');
  const series=(await kit.api.query('catalog.items',{kind:'series',categoryId:'demo-series',page:1})).items[0];
  const season=(await kit.api.query('media.children',{item:series})).items[0];
  const episode=(await kit.api.query('media.children',{item:season})).items[0];
  assert.equal(episode.title,'Big Buck Bunny');
  await kit.api.query('playback.play',{item:movie,sourceId:'demo'});
  assert.equal(kit.calls.open.length,1);assert.equal(kit.calls.open[0].stream.isLive,false);
  assert.equal(new URL(kit.calls.open[0].stream.url).hostname,'video.blender.org');
  assert.equal(kit.calls.requests.length,0);
  const cold=createLibrary(kit.options), boot=await cold.query('bootstrap');
  assert.equal(boot.profile.id,owner.id);assert.equal(boot.sources[0].kind,'demo');assert.equal(boot.activeSourceId,'demo');
  await profile(kit,'Existing source');await source(kit,m3uConfig('existing','existing-demo-guard.fixture'));
  const before=localProfileState(kit);
  await rejectsCode(kit.api.query('sources.demo'),'profile_not_empty');
  assert.deepEqual(localProfileState(kit),before);
});

test('actual cloud profiles are sanitized and profile PIN is verified locally before select RPC',async()=>{
  const kit=harness(xtreamRoute), cloud=await attachCloud(kit);await profile(kit,'Cloud PIN');
  cloud.profile.pin=await kit.core.hashPin('1234');
  const list=await kit.api.query('pairing.profiles');
  assert.deepEqual(list,[{id:remoteProfile,name:'Remote',pinSet:true}]);
  assert.equal(JSON.stringify(list).includes(cloud.profile.pin),false);
  await rejectsCode(kit.api.query('pairing.selectProfile',{profileId:remoteProfile}),'pin_required');
  await rejectsCode(kit.api.query('pairing.selectProfile',{profileId:remoteProfile,pin:'4321'}),'pin_invalid');
  assert.equal(cloud.calls.filter(call=>call.url.endsWith('/set_device_profile')).length,0);
  await kit.api.query('pairing.selectProfile',{profileId:remoteProfile,pin:'1234'});
  const rpc=cloud.calls.find(call=>call.url.endsWith('/set_device_profile'));
  assert.deepEqual(rpc.body,{p_profile_id:remoteProfile});
  assert.equal(JSON.stringify(cloud.calls).includes('"pin":"1234"'),false);
  assert.equal(kit.userState.get('cloud_profile_id'),remoteProfile);
});

test('actual cloud push preserves SQL favorite identities and emits supporter resume positions in milliseconds',async()=>{
  const kit=harness(xtreamRoute), cloud=await attachCloud(kit);await profile(kit,'Cloud push');
  await source(kit,cloudSource());
  const movie={id:'500',title:'Film',kind:'movie',categoryId:'movies',extra:{}};
  await kit.api.query('favorites.toggle',{sourceId:remoteSource,item:movie});
  await kit.api.query('favorites.toggle',{sourceId:remoteSource,channel:{id:'11',name:'Live'}});
  await positionSnapshot(kit,movie);cloud.supported=true;
  await kit.api.query('pairing.push',{profileId:remoteProfile});
  assert.deepEqual(cloud.calls.find(call=>call.url.endsWith('/push_favorites')).body.p_favorites,[
    {source_id:remoteSource,kind:'movie',item_id:'500'},{source_id:remoteSource,kind:'live',item_id:'11'}]);
  assert.deepEqual(cloud.calls.find(call=>call.url.endsWith('/push_playback_positions')).body.p_changes,[
    {source_id:remoteSource,kind:'movie',item_id:'500',position_ms:42500,duration_ms:100000,updated_at:Date.parse('2026-01-01T00:00:00Z'),removed:false}]);
  const payload=cloud.calls.find(call=>call.url.endsWith('/push_sources')).body.p_sources[0];
  assert.equal(payload.fields.password,undefined);assert.equal(payload.secret.payload.password,'local-pass');
  assert.equal(payload.secret.payload.epgUrls,'https://private-guide2.fixture/xml');
  const before=cloud.calls.length;cloud.supported=false;cloud.now+=60000;
  await kit.api.query('pairing.push',{profileId:remoteProfile});
  assert.equal(cloud.calls.slice(before).some(call=>call.url.endsWith('/push_playback_positions')),false);
});

test('actual cloud pull retains cached cloud secrets and extras while replacing previous managed rows',async()=>{
  const kit=harness(xtreamRoute), cloud=await attachCloud(kit);
  await kit.userState.set('cloud_profile_snapshots_v1',JSON.stringify({[remoteProfile]:{
    sources:[cloudSource(),cloudSource(staleSource),cloudSource(extraSource)],managedIds:[remoteSource,staleSource],
    metadata:{provider:'tmdb',tvdbApiKey:'local-tvdb'}}}));
  cloud.sources=[{id:remoteSource,kind:'xtream',label:'Remote updated',fields:{host:'https://new-provider.fixture'},settings:{}}];
  cloud.secrets={sources:{[remoteSource]:{format:0,payload:{username:'cloud-user'}}},metadata:{format:0,payload:{tmdbApiKey:'cloud-tmdb'}}};
  cloud.metadata=[{config:{provider:'tmdb',autoEnrich:true}}];
  await kit.api.query('pairing.pull',{profileId:remoteProfile});
  const sources=await kit.api.query('sources.list');assert.deepEqual(sources.map(s=>s.id),[remoteSource,extraSource]);
  assert.equal(sources[0].fields.username,'cloud-user');assert.equal(sources[0].fields.password,'local-pass');
  assert.equal(sources[0].fields.epgUrl,'https://private-guide.fixture/xml');assert.equal(sources[0].fields.epgUrls,'https://private-guide2.fixture/xml');
  const stored=JSON.parse(kit.userState.get('cloud_profile_snapshots_v1'))[remoteProfile];
  assert.deepEqual(stored.managedIds,[remoteSource]);assert.equal(stored.metadata.tvdbApiKey,'local-tvdb');assert.equal(stored.metadata.tmdbApiKey,'cloud-tmdb');
});

test('cloud live favorite placeholders remain channels through playback/history/stop and never create VOD positions',async()=>{
  const kit=harness(xtreamRoute), cloud=await attachCloud(kit);await profile(kit,'Cloud live');
  cloud.sources=[{id:remoteSource,kind:'xtream',label:'Cloud live',fields:{host:'https://cloud-live.fixture'},settings:{}}];
  cloud.secrets={sources:{[remoteSource]:{format:0,payload:{username:'fixture-user',password:'fixture-pass'}}},metadata:null};
  cloud.profile.favorites=[{source_id:remoteSource,kind:'live',item_id:'999'}];
  await kit.api.query('pairing.pull',{profileId:remoteProfile});
  const row=(await kit.api.query('favorites.list')).items[0];
  assert.equal(row.item,null);assert.equal(row.channel.id,'999');
  await kit.api.query('playback.play',{sourceId:remoteSource,channel:row.channel});
  await kit.api.query('playback.stop');
  const history=(await kit.api.query('history.list')).items[0];
  assert.equal(history.item,null);assert.equal(history.channel.id,'999');
  const positions=JSON.parse(kit.userState.get('samsung_playback_positions_v1')||'{}');
  for(const rows of Object.values(positions))assert.deepEqual(Object.keys(rows),[]);
});

test('cloud position LWW retains newer local state and carries newer tombstones through the next push',async()=>{
  const kit=harness(xtreamRoute), cloud=await attachCloud(kit);
  cloud.sources=[{id:remoteSource,kind:'xtream',label:'Cloud',fields:{host:'https://cloud-provider.fixture'},settings:{}}];
  cloud.secrets={sources:{[remoteSource]:{format:0,payload:{username:'local-user',password:'local-pass'}}},metadata:null};
  await kit.api.query('pairing.download',{profileId:remoteProfile});
  const item={id:'500',kind:'movie',title:'Film',extra:{}};await positionSnapshot(kit,item,42,'2026-01-01T00:00:00Z');
  cloud.sources=[{id:remoteSource,kind:'xtream',label:'Cloud',fields:{host:'https://cloud-provider.fixture'},settings:{}}];
  const base={source_id:remoteSource,kind:'movie',item_id:'500',position_ms:1000,duration_ms:100000,removed:false};
  cloud.positions=[{...base,updated_at:Date.parse('2025-01-01T00:00:00Z')}];
  await kit.api.query('pairing.pull',{profileId:remoteProfile});
  assert.equal((await kit.api.query('resume.get',{sourceId:remoteSource,item})).position,42);
  cloud.positions.push({...base,position_ms:0,duration_ms:0,removed:true,updated_at:Date.parse('2027-01-01T00:00:00Z')});
  await kit.api.query('pairing.pull',{profileId:remoteProfile});
  const pulled=JSON.parse(kit.userState.get('samsung_playback_positions_v1'))['cloud:'+remoteProfile][JSON.stringify([remoteSource,'movie','500'])];
  assert.equal(pulled.updatedAt,'2027-01-01T00:00:00.000Z');assert.equal(pulled.removed,true);
  assert.equal((await kit.api.query('resume.get',{sourceId:remoteSource,item})).position,0);
  cloud.supported=true;cloud.now+=60000;await kit.api.query('pairing.push',{profileId:remoteProfile});
  const tombstone=cloud.calls.filter(call=>call.url.endsWith('/push_playback_positions')).at(-1).body.p_changes[0];
  assert.equal(tombstone.removed,true);assert.equal(tombstone.updated_at,Date.parse('2027-01-01T00:00:00Z'));
  assert.equal(tombstone.position_ms,0);
});

test('native organization preferences preserve source credentials and bulk parental visibility',async()=>{
  const kit=harness(()=> '#EXTM3U\n#EXTINF:-1 group-title="News",Beta\nhttps://stream.fixture/b\n#EXTINF:-1 group-title="News",Alpha\nhttps://stream.fixture/a\n#EXTINF:-1 group-title="Adult",Locked\nhttps://stream.fixture/h\n');
  await profile(kit,'Organization');const config=m3uConfig('native-organization','native-organization.fixture');config.fields.userAgent='Keep original';await source(kit,config);
  const loaded=await kit.api.query('sources.load',{id:config.id}),alpha=loaded.channels.find(row=>row.name==='Alpha'),beta=loaded.channels.find(row=>row.name==='Beta'),locked=loaded.channels.find(row=>row.name==='Locked');
  const result=await kit.api.query('organization.set',{sourceId:config.id,organization:{names:{[alpha.id]:'Renamed'},hidden:[],order:[alpha.id,beta.id],groups:[{id:'tvbro.group.mine',name:'Mine',channels:[alpha.id]}]}});
  assert.equal(result.catalog.channels[0].name,'Renamed');assert.equal((await kit.api.query('sources.list'))[0].fields.userAgent,'Keep original');
  await kit.api.query('parental.setPin',{newPin:'1234'});await kit.api.query('parental.toggle',{pin:'1234',type:'category',id:locked.categoryId});
  const protectedCatalog=await kit.api.query('sources.catalog');assert.equal(protectedCatalog.channels.some(row=>row.id===locked.id),false);assert.equal(protectedCatalog.categories.some(row=>row.id===locked.categoryId),false);
  await kit.api.query('parental.unlock',{pin:'1234'});assert.equal((await kit.api.query('sources.catalog')).channels.length,3);
});
