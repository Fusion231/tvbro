'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const create = require('../platform/catalog_store.js').create;

// Only the Tizen filesystem boundary is synthetic; exercise the actual store.
function filesystem() {
  const files = new Map(); let failure = null;
  function makeFile(name, raw, size = Buffer.byteLength(raw)) {
    return {name, raw, isDirectory: false, get fileSize() { return size; },
      readAsText(ok) { queueMicrotask(() => ok(raw)); },
      openStream(mode, ok) {
        assert.equal(mode, 'r'); let position = 0; const bytes = new TextEncoder().encode(raw);
        queueMicrotask(() => ok({get bytesAvailable() { return bytes.length-position; },
          get eof() { return position>=bytes.length; },
          readBytes(count) {const value=bytes.slice(position,position+count);position+=value.length;return Array.from(value);},
          close() {}}));
      }};
  }
  function missing() { const error = Error('Missing file'); error.name = 'NotFoundError'; throw error; }
  const directory = {
    isDirectory: true, fullPath: 'wgt-private/tvbro_catalog_v1',
    resolve(name) { return files.get(name) || missing(); },
    listFiles(ok) { queueMicrotask(() => ok([...files.values()])); },
    createFile(name) {
      const file = {name, raw: '', isDirectory: false,
        get fileSize() { return Buffer.byteLength(this.raw); },
        readAsText(ok) { queueMicrotask(() => ok(file.raw)); },
        openStream(mode, ok) { let position=0; queueMicrotask(() => ok({
          get bytesAvailable() { return new TextEncoder().encode(file.raw).length-position; },
          get eof() { return position>=new TextEncoder().encode(file.raw).length; },
          readBytes(count) {const value=new TextEncoder().encode(file.raw).slice(position,position+count);position+=value.length;return Array.from(value);},
          writeBytes(bytes) { if (failure && failure(name)) throw Error('Disk full'); file.raw += new TextDecoder().decode(new Uint8Array(bytes)); },
          close() {}
        })); }
      };
      files.set(name, file); return file;
    },
    deleteFile(path, ok) { files.delete(path.split('/').pop()); queueMicrotask(ok); }
  };
  const environment = {Blob, TextEncoder, TextDecoder, setTimeout, tizen: {filesystem: {
    resolve(path, ok) { assert.equal(path, 'wgt-private'); queueMicrotask(() => ok({resolve: () => directory})); }
  }}};
  return {files, environment, fail(predicate) { failure = predicate; },
    seedGeneration(key, token, raw, size) {
      const name=key+'.'+token+'.json', marker='v1\n'+raw.length;
      files.set(name,makeFile(name,raw,size));files.set(name+'.ok',makeFile(name+'.ok',marker));
    }, restart() { return create({environment}); }};
}

test('Tizen catalogue store reopens complete generations and rejects partial/corrupt newest files', async () => {
  const fs = filesystem(), key = 'a'.repeat(64), store = fs.restart();
  const first = 'x'.repeat(32767) + '📺 kanały';
  assert.equal(await store.write(key, first), true);
  assert.equal((await fs.restart().read(key)).raw, first);
  assert.equal(await store.write(key, 'second'), true);
  const newest = await store.read(key);
  fs.files.get(key + '.' + newest.token + '.json').raw = 'truncated';
  assert.equal((await fs.restart().read(key)).raw, first);
  const orphan = key + '.9999999999999-0.json';
  fs.files.set(orphan, {name: orphan, raw: 'partial', fileSize: 7});
  assert.equal((await fs.restart().read(key)).raw, first);
  assert.equal(fs.files.has(orphan), false);
});

test('failed data/marker writes keep the previous generation and removal isolates source keys', async () => {
  const fs = filesystem(), key = 'b'.repeat(64), other = 'c'.repeat(64), store = fs.restart();
  await store.write(key, 'good'); await store.write(other, 'other source');
  for (const suffix of ['.json', '.ok']) {
    fs.fail(name => name.endsWith(suffix));
    assert.equal(await store.write(key, 'new'), false);
    assert.equal((await fs.restart().read(key)).raw, 'good');
  }
  fs.fail(null);
  await assert.rejects(store.write(key,'invalid options','catalog',{preserveKeys:['not-a-cache-key']}),{name:'TypeError'});
  assert.equal(await store.remove(key), true);
  assert.equal(await fs.restart().read(key), null);
  assert.equal((await fs.restart().read(other)).raw, 'other source');
  await assert.rejects(store.remove('../invalid'), {name: 'TypeError'});
});

test('migration writes preserve the exact legacy catalog and guide through near-quota pruning and marker failure', async () => {
  const fs=filesystem(), legacyCatalog='d'.repeat(64), legacyGuide='e'.repeat(64),
    nextCatalog='f'.repeat(64), nextGuide='a'.repeat(64), otherOld='b'.repeat(64), otherNew='c'.repeat(64);
  fs.seedGeneration(legacyCatalog,'1-0','legacy catalog');
  fs.seedGeneration(legacyGuide,'1-0','legacy guide');
  fs.seedGeneration(otherOld,'2-0','other oldest',32*1024*1024);
  fs.seedGeneration(otherNew,'3-0','other newest',32*1024*1024);
  const store=fs.restart(), preserve={preserveKeys:[nextCatalog,nextGuide,legacyCatalog,legacyGuide]};
  const release=store.protectKeys(preserve.preserveKeys);
  try {
    assert.equal(await store.write(nextCatalog,'normalized catalog','catalog',preserve),true);
    fs.seedGeneration('9'.repeat(64),'4-0','concurrent cache write',32*1024*1024);
    assert.equal(await store.write('9'.repeat(64),'other source write','catalog'),true,
      'an unrelated write during migration must also honor the active protection lease');
    assert.equal(fs.files.has(otherNew+'.3-0.json'),false,'an unprotected old cache makes room while legacy keys are leased');
    assert.equal((await store.read(nextCatalog)).raw,'normalized catalog',
      'the normalized catalog destination remains available until the guide write succeeds');
    fs.fail(name=>name.startsWith(nextGuide+'.')&&name.endsWith('.ok'));
    assert.equal(await store.write(nextGuide,'normalized guide','guide',preserve),false,
      'a failed destination marker leaves both legacy snapshots in place');
  } finally { release(); }

  const restarted=fs.restart();
  assert.equal((await restarted.read(legacyCatalog)).raw,'legacy catalog');
  assert.equal((await restarted.read(legacyGuide)).raw,'legacy guide');
  assert.equal((await restarted.read(nextCatalog)).raw,'normalized catalog');
  assert.equal(await restarted.read(nextGuide),null);
  assert.equal(fs.files.has(otherOld+'.2-0.json'),false,'unprotected old cache data makes room before a protected source key');
});

test('protected catalog and guide keys make quota failure leave the legacy snapshots restart-readable', async () => {
  const fs=filesystem(),legacyCatalog='1'.repeat(64),legacyGuide='2'.repeat(64),
    nextCatalog='3'.repeat(64),nextGuide='4'.repeat(64),
    preserve={preserveKeys:[nextCatalog,nextGuide,legacyCatalog,legacyGuide]},maximumFile=32*1024*1024;
  fs.seedGeneration(legacyCatalog,'1-0','legacy catalog',maximumFile);
  fs.seedGeneration(legacyGuide,'1-0','legacy guide',maximumFile);
  const store=fs.restart();

  assert.equal(await store.write(nextCatalog,'normalized catalog','catalog',preserve),false,
    'the store refuses a destination that would exceed the budget while both legacy keys are protected');
  const restarted=fs.restart();
  assert.equal((await restarted.read(legacyCatalog)).raw,'legacy catalog');
  assert.equal((await restarted.read(legacyGuide)).raw,'legacy guide');
  assert.equal(await restarted.read(nextCatalog),null);
});

test('migration pin keeps both normalized destinations when an unrelated near-quota write cannot fit', async () => {
  const fs=filesystem(),legacyCatalog='5'.repeat(64),legacyGuide='6'.repeat(64),
    nextCatalog='7'.repeat(64),nextGuide='8'.repeat(64),other='9'.repeat(64),
    preserveKeys=[nextCatalog,nextGuide,legacyCatalog,legacyGuide],mebibyte=1024*1024;
  fs.seedGeneration(legacyCatalog,'1-0','legacy catalog',20*mebibyte);
  fs.seedGeneration(legacyGuide,'1-0','legacy guide',10*mebibyte);
  fs.seedGeneration(nextCatalog,'2-0','normalized catalog',20*mebibyte);
  fs.seedGeneration(nextGuide,'3-0','normalized guide',10*mebibyte);
  const store=fs.restart(),release=store.protectKeys(preserveKeys);
  try {
    assert.equal(await store.write(other,'x'.repeat(16*mebibyte),'catalog'),false,
      'a regular write is refused instead of evicting a destination or legacy generation');
    const restarted=fs.restart();
    assert.equal((await restarted.read(legacyCatalog)).raw,'legacy catalog');
    assert.equal((await restarted.read(legacyGuide)).raw,'legacy guide');
    assert.equal((await restarted.read(nextCatalog)).raw,'normalized catalog');
    assert.equal((await restarted.read(nextGuide)).raw,'normalized guide');
  } finally { release(); }
});

test('active protection leases are bounded and release idempotently', () => {
  const store=filesystem().restart(),leases=[];
  for(let index=0;index<16;index++) leases.push(store.protectKeys([index.toString(16).padStart(64,'0')]));
  assert.throws(()=>store.protectKeys(['f'.repeat(64)]),{name:'QuotaExceededError'});
  leases[0]();leases[0]();
  const available=store.protectKeys(['f'.repeat(64)]);available();
  leases.slice(1).forEach(release=>release());
});
