'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {webcrypto} = require('node:crypto');
const secureModule = require('../platform/secure_store.js');
const catalogModule = require('../platform/catalog_store.js');

// Only the browser storage boundary is simulated. WebCrypto, cloning and all
// application storage code are real. Failed transactions discard their writes.
function indexedDatabase() {
  const databases = new Map();
  let fault = null, yields = 0;
  function failure(name) { const value = Error(name); value.name = name; return value; }
  function shouldFail(stage, db, store, key, mode) {
    if (!fault || fault.stage !== stage || fault.db && fault.db !== db || fault.store && fault.store !== store || fault.key && fault.key !== key || fault.mode && fault.mode !== mode) return false;
    const value = fault; fault = null; throw failure(value.name || 'QuotaExceededError');
  }
  function connect(name, state) {
    return {
      createObjectStore(store) { state.stores.set(store, new Map()); },
      close() {},
      transaction(names, mode) {
        const queue = [], tx = {error:null}, staged = new Map();
        let started = false, finished = false, scheduled = false;
        function start() {
          started = true;
          for (const store of names) staged.set(store, structuredClone(state.stores.get(store)));
          schedule();
        }
        function finish(abort) {
          if (finished) return;
          finished = true;
          if (!abort && mode === 'readwrite') for (const [store, values] of staged) state.stores.set(store, values);
          if (abort) { if (tx.onabort) tx.onabort(); }
          else if (tx.oncomplete) tx.oncomplete();
          state.active = false;
          const next = state.pending.shift(); if (next) { state.active = true; setImmediate(next); }
        }
        function schedule() {
          if (!started || scheduled || finished) return;
          scheduled = true;
          setImmediate(() => {
            scheduled = false;
            if (finished) return;
            const item = queue.shift();
            try {
              if (!item) { shouldFail('commit', name, null, null, mode); finish(false); return; }
              shouldFail('request', name, item.store, item.key, mode);
              item.run(staged.get(item.store));
            } catch (error) { tx.error = error; finish(true); return; }
            schedule();
          });
        }
        function request(store, key, operation) {
          const result = {};
          queue.push({store,key,run(values) { operation(values, result); }}); schedule(); return result;
        }
        tx.abort = () => { tx.error = tx.error || failure('AbortError'); finish(true); };
        tx.objectStore = store => ({
          get(key) { return request(store,key,(values, result) => { result.result = structuredClone(values.get(key)); if (result.onsuccess) result.onsuccess(); }); },
          put(value, key) {
            shouldFail('clone', name, store, key); const copied = structuredClone(value);
            return request(store,key,(values,result) => { values.set(key, copied); result.result=key; if (result.onsuccess) result.onsuccess(); });
          },
          add(value, key) {
            shouldFail('clone', name, store, key); const copied = structuredClone(value);
            return request(store,key,(values,result) => { if (values.has(key)) throw failure('ConstraintError'); values.set(key,copied); result.result=key; if (result.onsuccess) result.onsuccess(); });
          },
          delete(key) { return request(store,key,values => { values.delete(key); }); },
          openCursor() {
            const result = {}; let keys, position = 0;
            function advance(values) {
              if (!keys) keys = [...values.keys()].sort();
              const key = keys[position++];
              result.result = key === undefined ? null : {key,value:structuredClone(values.get(key)),continue() { queue.push({store,key,run:advance}); schedule(); }};
              if (result.onsuccess) result.onsuccess();
            }
            queue.push({store,run:advance}); schedule(); return result;
          }
        });
        if (state.active) state.pending.push(start); else { state.active = true; setImmediate(start); }
        return tx;
      }
    };
  }
  const api = {
    open(name) {
      const request = {};
      setImmediate(() => {
        const fresh = !databases.has(name);
        if (fresh) databases.set(name, {stores:new Map(),active:false,pending:[]});
        request.result = connect(name,databases.get(name));
        if (fresh && request.onupgradeneeded) request.onupgradeneeded();
        if (request.onsuccess) request.onsuccess();
      });
      return request;
    }
  };
  const environment = {indexedDB:api,crypto:webcrypto,setTimeout(callback) { yields++; setImmediate(callback); }};
  return {
    environment,
    get yields() { return yields; },
    stores(name) { return databases.get(name).stores; },
    fail(value) { fault = value; },
    async restart() { const value = secureModule.create({environment}); await value.initialize(); return value; },
    catalog(secureStore) { return catalogModule.create({environment,secureStore}); }
  };
}
const protectedDB = 'tvbro_webos_protected_v1', cacheDB = 'tvbro_webos_catalog_v1';
const sources = [{id:'source-1',kind:'xtream',label:'Zażółć 📺',fields:{username:'alice',password:'secret-password',url:'https://host.example:443'},settings:{enabled:true}}];

test('protected source and user state survive restart without plaintext or exportable keys', async () => {
  const boundary = indexedDatabase(), store = secureModule.create({environment:boundary.environment});
  assert.throws(() => store.read(), {name:'InvalidStateError'});
  await store.initialize();
  await store.write(sources);
  const state = JSON.parse('{"profiles":"[1]","__proto__":"literal-key","pin":"1234"}');
  await store.writeUserState(state);
  const values = boundary.stores(protectedDB).get('values');
  assert.equal(values.get('key').extractable, false);
  await assert.rejects(webcrypto.subtle.exportKey('raw', values.get('key')), {name:'InvalidAccessException'});
  for (const name of ['sources','user']) {
    const sealed = values.get(name);
    assert.deepEqual(Object.keys(sealed).sort(), ['ciphertext','iv','version']);
    assert.equal(Buffer.from(sealed.ciphertext).includes(Buffer.from('secret-password')),false);
  }
  const restarted = await boundary.restart();
  assert.deepEqual(restarted.read(), sources);
  assert.deepEqual(restarted.readUserState(), state);
  const copy = restarted.read(); copy[0].fields.password='changed'; assert.equal(restarted.read()[0].fields.password,'secret-password');
  await restarted.remove(); await restarted.removeUserState();
  const empty = await boundary.restart(); assert.deepEqual(empty.read(),[]); assert.deepEqual(empty.readUserState(),{});
});

test('large UTF-16 values round-trip across encoder and decoder chunk boundaries', async () => {
  const boundary=indexedDatabase(), realSubtle=webcrypto.subtle;let encoded=null;
  boundary.environment.crypto={getRandomValues(bytes){return webcrypto.getRandomValues(bytes);},subtle:{
    generateKey(){return realSubtle.generateKey.apply(realSubtle,arguments);},
    encrypt(algorithm,key,bytes){encoded=new Uint8Array(bytes);return realSubtle.encrypt(algorithm,key,bytes);},
    decrypt(){return realSubtle.decrypt.apply(realSubtle,arguments);}
  }};
  const store=secureModule.create({environment:boundary.environment});await store.initialize();
  const raw='a'.repeat(65535)+'📺'+'b'.repeat(65537);
  const sealed=await store.encrypt(raw,'chunk-boundary');
  const expected=new Uint8Array(raw.length*2);
  for(let i=0;i<raw.length;i++){const code=raw.charCodeAt(i);expected[i*2]=code&255;expected[i*2+1]=code>>>8;}
  assert.deepEqual(encoded,expected,'WebCrypto must receive the same UTF-16LE bytes on every host endianness.');
  assert.equal(await store.decrypt(sealed,'chunk-boundary'),raw);
  assert.ok(boundary.yields>0);
});

test('quota and aborted commits never advance the in-memory snapshot or restart state', async () => {
  const boundary = indexedDatabase(), store = await boundary.restart();
  await store.write(sources); await store.writeUserState({profiles:'old'});
  boundary.fail({stage:'request',db:protectedDB,store:'values',key:'sources'});
  await assert.rejects(store.write([]),{name:'QuotaExceededError'});
  assert.deepEqual(store.read(),sources);
  boundary.fail({stage:'commit',db:protectedDB,name:'AbortError'});
  await assert.rejects(store.writeUserState({profiles:'torn'}),{name:'AbortError'});
  assert.deepEqual(store.readUserState(),{profiles:'old'});
  const restarted = await boundary.restart(); assert.deepEqual(restarted.read(),sources); assert.deepEqual(restarted.readUserState(),{profiles:'old'});
  await store.writeUserState({profiles:'new'}); assert.deepEqual((await boundary.restart()).readUserState(),{profiles:'new'});
});

test('missing WebCrypto or CryptoKey cloning fails closed without a localStorage fallback', async () => {
  const unavailable = secureModule.create({environment:{localStorage:{setItem() { assert.fail('No plaintext fallback'); }}}});
  await assert.rejects(unavailable.initialize(),{name:'NotSupportedError'});
  const boundary = indexedDatabase(); boundary.fail({stage:'clone',db:protectedDB,store:'values',key:'key',name:'DataCloneError'});
  const unsupported = secureModule.create({environment:boundary.environment});
  await assert.rejects(unsupported.initialize(),{name:'DataCloneError'});
  assert.throws(() => unsupported.readUserState(),{name:'InvalidStateError'});
  assert.equal(boundary.stores(protectedDB).get('values').size,0);
});

test('protected storage can retry initialization after a transient IndexedDB open failure', async () => {
  const boundary = indexedDatabase(), originalOpen = boundary.environment.indexedDB.open.bind(boundary.environment.indexedDB);
  let attempts = 0;
  boundary.environment.indexedDB.open = function (name) {
    attempts += 1;
    if (attempts > 1) return originalOpen(name);
    const request = {};
    setImmediate(() => { request.error = Error('temporary IndexedDB failure'); if (request.onerror) request.onerror(); });
    return request;
  };
  const store = secureModule.create({environment:boundary.environment});
  await assert.rejects(store.initialize(),/temporary IndexedDB failure/);
  await store.initialize();
  assert.equal(attempts,2);
  assert.deepEqual(store.read(),[]);
});

test('protected storage reopens and rehydrates after an IndexedDB version change', async () => {
  const boundary = indexedDatabase(), originalOpen = boundary.environment.indexedDB.open.bind(boundary.environment.indexedDB);
  let connection = null;
  boundary.environment.indexedDB.open = function (name) {
    const request = originalOpen(name);
    let onSuccess;
    Object.defineProperty(request,'onsuccess',{configurable:true,get() { return onSuccess; },set(callback) {
      onSuccess = function () { connection = request.result; return callback(); };
    }});
    return request;
  };
  const store = secureModule.create({environment:boundary.environment});
  await store.initialize();
  await store.write(sources);
  connection.onversionchange();
  assert.throws(() => store.read(),{name:'InvalidStateError'});
  await store.initialize();
  assert.deepEqual(store.read(),sources);
});

test('tampered ciphertext, cross-domain substitution and missing keys cannot silently erase state', async () => {
  const boundary = indexedDatabase(), store = await boundary.restart(); await store.write(sources); await store.writeUserState({pin:'1234'});
  const values = boundary.stores(protectedDB).get('values'), valid = structuredClone(values.get('sources'));
  new Uint8Array(values.get('sources').ciphertext)[0] ^= 1;
  await assert.rejects(boundary.restart(),{name:'OperationError'});
  values.set('sources',valid);
  const swapped = values.get('user'); values.set('user',valid);
  await assert.rejects(boundary.restart(),{name:'OperationError'});
  values.set('user',swapped); values.delete('key');
  await assert.rejects(boundary.restart(),{name:'SecurityError'});
  assert.ok(values.get('sources'));
});

test('queued secure writes snapshot arguments and preserve validation and literal keys', async () => {
  const boundary = indexedDatabase(), store = await boundary.restart(), input = structuredClone(sources);
  const write = store.write(input); input[0].fields.password='later'; await write;
  assert.deepEqual(store.read(),sources);
  await Promise.all([store.writeUserState({v:'1'}),store.writeUserState({v:'2'})]);
  assert.deepEqual((await boundary.restart()).readUserState(),{v:'2'});
  await assert.rejects(store.write([{...sources[0],fields:{bad:3}}]),{name:'TypeError'});
  const circular = structuredClone(sources); circular[0].settings.loop=circular;
  await assert.rejects(store.write(circular),{name:'TypeError'});
  await assert.rejects(store.writeUserState({v:2}),{name:'TypeError'});
});

test('encrypted catalog restores newest complete generation and recovers previous after corruption', async () => {
  const boundary = indexedDatabase(), secure = await boundary.restart(), store=boundary.catalog(secure), key='a'.repeat(64);
  const first='https://server/live/alice/secret-password/1.ts 📺';
  assert.equal(await store.write(key,first),true); assert.equal(await store.write(key,'newer'),true);
  let restarted=boundary.catalog(await boundary.restart());
  assert.equal((await restarted.read(key)).raw,'newer');
  const payloads=boundary.stores(cacheDB).get('payloads');
  const newest=(await restarted.read(key)).token, sealed=payloads.get(key+':'+newest);
  assert.equal(Buffer.from(sealed.ciphertext).includes(Buffer.from('secret-password')),false);
  new Uint8Array(sealed.ciphertext)[0]^=1;
  restarted=boundary.catalog(await boundary.restart());
  const restored=await restarted.read(key); assert.equal(restored.raw,first); assert.equal(boundary.stores(cacheDB).get('metadata').size,1);
  assert.equal(await restarted.discard(key,restored.token),true); assert.equal(await restarted.read(key),null);
});

test('catalog write transactions retain prior entries on quota failure and commit abort', async () => {
  const boundary=indexedDatabase(), secure=await boundary.restart(), store=boundary.catalog(secure), key='b'.repeat(64), other='c'.repeat(64);
  await store.write(key,'old'); await store.write(other,'other');
  boundary.fail({stage:'request',db:cacheDB,store:'payloads'});
  assert.equal(await store.write(key,'failed'),false);
  assert.equal((await store.read(key)).raw,'old');
  // Abort after both payload and index writes have succeeded: neither becomes
  // visible until the complete readwrite transaction commits.
  boundary.fail({stage:'commit',db:cacheDB,mode:'readwrite',name:'AbortError'});
  assert.equal(await store.write(key,'torn'),false);
  assert.equal((await boundary.catalog(await boundary.restart()).read(key)).raw,'old');
  assert.equal(await store.remove(key),true); assert.equal(await store.read(key),null); assert.equal((await store.read(other)).raw,'other');
  await assert.rejects(store.write('../invalid','value'),{name:'TypeError'});
  await assert.rejects(store.discard(other,'../unsafe'),{name:'TypeError'});
});

test('catalog bounds plaintext size, encrypted bytes and metadata count', async () => {
  const boundary=indexedDatabase(), secure=await boundary.restart(), store=boundary.catalog(secure);
  assert.equal(await store.write('e'.repeat(64),'x'.repeat(32*1024*1024+1)),false);
  assert.equal(await store.write('e'.repeat(64),'ą'.repeat(16*1024*1024+1)),false);
  for(let i=0;i<130;i++) assert.equal(await store.write(i.toString(16).padStart(64,'0'),'entry-'+i),true);
  const rows=[...boundary.stores(cacheDB).get('metadata').values()];
  assert.equal(rows.length,128); assert.ok(rows.reduce((sum,row)=>sum+row.bytes,0)<=64*1024*1024);
  assert.equal(await store.read('0'.repeat(64)),null);
  assert.equal((await store.read((129).toString(16).padStart(64,'0'))).raw,'entry-129');
});

test('catalogs with a safe UTF-8 upper bound skip the byte scan',async()=>{
  const boundary=indexedDatabase(),key='a'.repeat(64),raw='catalog-'+('x'.repeat(128*1024));
  const store=boundary.catalog({encrypt(){return Promise.resolve({ciphertext:new ArrayBuffer(16)});},decrypt(){return Promise.resolve('');}});
  const original=String.prototype.charCodeAt;let calls=0;
  try {
    String.prototype.charCodeAt=function(index){calls++;return original.call(this,index);};
    assert.equal(await store.write(key,raw),true);
    assert.equal(calls,0);
  } finally { String.prototype.charCodeAt=original; }
});

test('catalog refuses plaintext caching when protected storage is unavailable',async()=>{
  const boundary=indexedDatabase(), store=boundary.catalog(null), key='f'.repeat(64);
  assert.equal(await store.write(key,'https://host/username/password'),false);
  assert.equal(await store.read(key),null);
  assert.throws(()=>boundary.stores(cacheDB));
});

test('catalog evicts by actual encrypted byte size and rolls pruning back if commit fails',async()=>{
  const boundary=indexedDatabase(), secure=await boundary.restart(), store=boundary.catalog(secure);
  const keys=['1','2','3'].map(value=>value.repeat(64)), raw='x'.repeat(12*1024*1024);
  assert.equal(await store.write(keys[0],raw,'catalog'),true); assert.equal(await store.write(keys[1],raw,'catalog'),true);
  const before=[...boundary.stores(cacheDB).get('metadata').values()];
  assert.ok(before.reduce((sum,row)=>sum+row.bytes,0)>32*1024*1024);
  boundary.fail({stage:'commit',db:cacheDB,mode:'readwrite',name:'AbortError'});
  assert.equal(await store.write(keys[2],raw,'catalog'),false);
  assert.deepEqual([...boundary.stores(cacheDB).get('metadata').values()],before);
  assert.equal(await store.write(keys[2],raw,'catalog'),true);
  const after=[...boundary.stores(cacheDB).get('metadata').values()];
  assert.equal(after.length,2); assert.ok(after.reduce((sum,row)=>sum+row.bytes,0)<=64*1024*1024);
  assert.equal(await store.read(keys[0]),null); assert.equal((await store.read(keys[2])).raw.length,raw.length);
  assert.ok(boundary.yields>0,'Large cache encoding and decoding must yield to TV input/render tasks.');
});

test('saving an encrypted guide must not evict the saved channel catalog',async()=>{
  const boundary=indexedDatabase(),store=boundary.catalog(await boundary.restart());
  const channels='a'.repeat(64),guide='b'.repeat(64);
  const channelSnapshot='c'.repeat(20*1024*1024),guideSnapshot='g'.repeat(14*1024*1024);
  assert.equal(await store.write(channels,channelSnapshot,'catalog'),true);
  assert.equal(await store.write(guide,guideSnapshot,'guide'),false,
    'the encrypted payloads exceed the fixed shared limit, so the optional guide must be refused');
  assert.equal(await store.write(guide,'g'.repeat(11*1024*1024),'guide'),true,
    'a guide that fits beside the primary catalog may still be cached');
  const restarted=boundary.catalog(await boundary.restart());
  assert.equal((await restarted.read(channels))?.raw,channelSnapshot,
    'an optional guide snapshot must not replace primary catalog data to satisfy the shared encrypted-byte budget');
  assert.equal((await restarted.read(guide))?.raw,'g'.repeat(11*1024*1024));
  const rows=[...boundary.stores(cacheDB).get('metadata').values()];
  assert.equal(rows.length,2);
  assert.ok(rows.reduce((sum,row)=>sum+row.bytes,0)<=64*1024*1024);
});

test('chunked catalogs commit atomically and restore one encrypted part at a time',async()=>{
  const boundary=indexedDatabase(),secure=await boundary.restart(),store=boundary.catalog(secure),key='d'.repeat(64);
  const manifest={schema:1,scopeKey:'profile-source',generation:1,completeAt:Date.now(),
    kinds:{live:{complete:true,count:1,syncedAt:Date.now()},movie:{complete:true,count:0,syncedAt:Date.now()},series:{complete:true,count:2,syncedAt:Date.now()}},
    parts:[{index:0,key:'live:channels',kind:'live',section:'channels',offset:0,count:1,decodedBytes:33},
      {index:1,key:'series:items',kind:'series',section:'items',offset:0,count:2,decodedBytes:31}]};
  const values=['first chunk with private URL token','second chunk with series data'];
  const committedManifest=structuredClone(manifest);
  committedManifest.parts.forEach((part,index)=>{part.checksum=(index===0?'1':'2').repeat(64);part.bytes=Buffer.byteLength(values[index]);});
  assert.equal(await store.writeBatch(key,manifest,descriptor=>({raw:values[descriptor.index],checksum:(descriptor.index===0?'1':'2').repeat(64)})),true);

  const restarted=boundary.catalog(await boundary.restart()),saved=await restarted.readBatch(key);
  assert.deepEqual(saved.manifest,committedManifest);assert.equal(saved.count,2);
  assert.deepEqual(saved.manifest.parts.map(part=>part.bytes),values.map(value=>Buffer.byteLength(value)));
  assert.equal(await restarted.readBatchPart(key,saved.token,0),values[0]);
  assert.equal(await restarted.readBatchPart(key,saved.token,1),values[1]);
  const payloads=boundary.stores(cacheDB).get('payloads');
  for(const sealed of payloads.values()) assert.equal(Buffer.from(sealed.ciphertext).includes(Buffer.from('private URL token')),false);

  const replacement={...manifest,generation:2};
  assert.equal(await store.writeBatch(key,replacement,descriptor=>descriptor.index===0?'new first chunk':Promise.reject(Error('part unavailable'))),false);
  assert.deepEqual((await boundary.catalog(await boundary.restart()).readBatch(key)).manifest,committedManifest,
    'a failed part read leaves the last committed manifest and parts intact');
  assert.equal(await store.writeBatch(key,replacement,()=>({raw:'replacement with missing checksum'})),false);
  assert.deepEqual((await boundary.catalog(await boundary.restart()).readBatch(key)).manifest,committedManifest,
    'an invalid descriptor cannot replace the last committed generation');
  boundary.fail({stage:'request',db:cacheDB,store:'payloads'});
  assert.equal(await store.writeBatch(key,replacement,descriptor=>({raw:'new-'+descriptor.index,checksum:'4'.repeat(64)})),false);
  assert.deepEqual((await boundary.catalog(await boundary.restart()).readBatch(key)).manifest,committedManifest,
    'an aborted IDB commit cannot publish or remove any batch generation');

  const boundaryManifest=raw=>({schema:1,scopeKey:'profile-source',generation:1,completeAt:Date.now(),
    kinds:manifest.kinds,parts:[{index:0,key:'live:channels',kind:'live',section:'channels',offset:0,count:1,checksum:'3'.repeat(64)}]});
  const ascii='x'.repeat(1024*1024),unicode='📺'.repeat(262144);
  assert.equal(Buffer.byteLength(ascii),1024*1024);assert.equal(Buffer.byteLength(unicode),1024*1024);
  assert.equal(await store.writeBatch('e'.repeat(64),boundaryManifest(ascii),()=>({raw:ascii,checksum:'3'.repeat(64)})),true,
    'one MiB ASCII chunks remain valid after UTF-16 encryption doubles their code-unit byte size');
  assert.equal(await store.writeBatch('f'.repeat(64),boundaryManifest(unicode),()=>({raw:unicode,checksum:'3'.repeat(64)})),true,
    'one MiB UTF-8 chunks round-trip when surrogate pairs are encrypted');
});

test('a large guide replacement drops its old generation before evicting saved channels',async()=>{
  const boundary=indexedDatabase(), store=boundary.catalog(await boundary.restart());
  const channels='a'.repeat(64), guide='b'.repeat(64), raw='x'.repeat(16*1024*1024);
  assert.equal(await store.write(channels,'saved channels','catalog'),true);
  assert.equal(await store.write(guide,raw,'guide'),true);
  boundary.fail({stage:'commit',db:cacheDB,mode:'readwrite',name:'AbortError'});
  assert.equal(await store.write(guide,raw+'failed','guide'),false);
  assert.equal((await store.read(channels)).raw,'saved channels');
  assert.equal((await store.read(guide)).raw,raw);
  assert.equal(await store.write(guide,raw+'new','guide'),true);
  const restarted=boundary.catalog(await boundary.restart());
  assert.equal((await restarted.read(channels))?.raw,'saved channels','EPG refresh must not force a channel download on restart');
  assert.equal((await restarted.read(guide)).raw,raw+'new');
  const rows=[...boundary.stores(cacheDB).get('metadata').values()];
  assert.equal(rows.length,2);
  assert.ok(rows.reduce((sum,row)=>sum+row.bytes,0)<=64*1024*1024);
});

test('catalog writes evict marked legacy guides before other catalogs',async()=>{
  const boundary=indexedDatabase(),store=boundary.catalog(await boundary.restart());
  const olderCatalog='1'.repeat(64),legacyGuide='2'.repeat(64),newerCatalog='3'.repeat(64),nextCatalog='4'.repeat(64);
  const old='c'.repeat(10*1024*1024),guide='g'.repeat(10*1024*1024),newer='n'.repeat(2*1024*1024),next='x'.repeat(12*1024*1024);
  assert.equal(await store.write(olderCatalog,old,'catalog'),true);
  assert.equal(await store.write(legacyGuide,guide,'catalog'),true);
  assert.equal(await store.write(newerCatalog,newer,'catalog'),true);
  const metadata=boundary.stores(cacheDB).get('metadata');
  const legacy=[...metadata.entries()].find(([,row])=>row.key===legacyGuide);
  delete legacy[1].kind;
  metadata.set(legacy[0],legacy[1]);
  const restarted=boundary.catalog(await boundary.restart());
  assert.equal(await restarted.mark(legacyGuide,'guide'),true);
  assert.equal(boundary.stores(cacheDB).get('metadata').get(legacy[0]).kind,'guide');
  assert.equal(await restarted.write(nextCatalog,next,'catalog'),true);
  assert.equal((await restarted.read(olderCatalog))?.raw,old);
  assert.equal(await restarted.read(legacyGuide),null,'the tagged optional guide is selected ahead of other catalog caches');
  assert.equal((await restarted.read(newerCatalog))?.raw,newer);
  assert.equal((await restarted.read(nextCatalog))?.raw,next);
});

test('webOS backup and memory capabilities do not pretend Tizen or OSE APIs are TV APIs',async()=>{
  const files=require('../platform/backup_files.js').create({environment:{tizen:{filesystem:{resolve(){assert.fail('Tizen is not LG');}}}}});
  assert.deepEqual(files.capabilities(),{import:false,export:false});
  for(const name of ['chooseImport','saveExport','listStorages','listDirectory']) await assert.rejects(files[name]('/media/usb'),{name:'NotSupportedError',code:'backup_files_unavailable'});
  const memory=require('../platform/memory_policy.js').create({environment:{webOS:{service:{request(){assert.fail('No private memory API');}}}}});
  assert.deepEqual(memory.sample(),{maximumEpgBytes:32*1024*1024,verified:false,reason:'unavailable'});
  const state=memory.getState(); state.maximumEpgBytes=1; assert.equal(memory.sample().maximumEpgBytes,32*1024*1024); memory.dispose();
});
