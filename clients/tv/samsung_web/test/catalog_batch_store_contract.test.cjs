'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const {filesystem} = require('./helpers/catalog_filesystem.cjs');
const key = 'd'.repeat(64), other = 'e'.repeat(64);

function batch(values, cacheKey = key) {
  const manifest = {schema:1,key:cacheKey,generation:'fixture',kinds:{},parts:values.map((raw,index) => ({index,kind:'live',count:1,decodedBytes:Buffer.byteLength(raw)}))};
  return {manifest, readPart:descriptor => Promise.resolve({raw:values[descriptor.index],checksum:crypto.createHash('sha256').update(values[descriptor.index]).digest('hex')})};
}
async function write(store, values, cacheKey = key, options) {
  const value = batch(values, cacheKey);
  return store.writeBatch(cacheKey, value.manifest, value.readPart, options);
}
async function read(store, cacheKey = key) {
  const saved = await store.readBatch(cacheKey);
  if (!saved) return null;
  const parts = [];
  for (const descriptor of saved.manifest.parts) parts.push(await store.readBatchPart(cacheKey,saved.token,descriptor.index));
  return {saved, parts};
}

test('real Samsung batch store restores bounded parts and checksummed descriptors after restart', async () => {
  const disk = filesystem(), values = ['kanały 📺', 'films', 'series'];
  const value = batch(values);
  assert.equal(await disk.restart().writeBatch(key,value.manifest,value.readPart), true);
  assert.equal(value.manifest.parts[0].checksum, undefined, 'input manifest is not mutated');
  const restored = await read(disk.restart());
  assert.deepEqual(restored.parts, values);
  assert.equal(restored.saved.count, values.length);
  assert.ok(restored.saved.manifest.parts.every((part,index) => part.bytes === Buffer.byteLength(values[index]) && /^[a-f0-9]{64}$/.test(part.checksum)));
  await assert.rejects(disk.restart().readBatchPart('../invalid',restored.saved.token,0), {name:'TypeError'});
  await assert.rejects(disk.restart().readBatchPart(key,'../invalid',0), {name:'TypeError'});
});

test('failed part or commit writes retain the previous complete generation', async () => {
  const disk = filesystem(), store = disk.restart();
  assert.equal(await write(store,['old']), true);
  const before = [...disk.files.keys()].sort();
  for (const fail of [name => name.includes('.part-1.'), name => name.endsWith('.json.ok')]) {
    disk.fail(fail);
    assert.equal(await write(store,['new first','new second']), false);
    assert.deepEqual((await read(disk.restart())).parts,['old']);
    assert.deepEqual([...disk.files.keys()].sort(),before,'failed generations leave no orphan parts');
  }
  disk.fail(null);
  const next = batch(['new']);
  assert.equal(await store.writeBatch(key,next.manifest,() => Promise.reject(Error('worker cancelled'))),false);
  assert.deepEqual((await read(disk.restart())).parts,['old']);
});

test('missing batch parts fall back to a previous generation and discard removes all its files', async () => {
  const disk = filesystem(), store = disk.restart();
  await write(store,['old']);
  await write(store,['new','second']);
  const newest = await store.readBatch(key);
  const partName = [...disk.files.keys()].find(name => name.includes('.'+newest.token+'.part-1.'));
  disk.files.delete(partName);
  assert.deepEqual((await read(disk.restart())).parts,['old']);
  await write(store,['other source'],other);
  const current = await store.readBatch(key);
  assert.equal(await store.discardBatch(key,current.token),true);
  assert.equal(await store.readBatch(key),null);
  assert.deepEqual((await read(store,other)).parts,['other source']);
});

test('same-length manifest corruption falls back without losing the previous batch', async () => {
  for (const corrupt of [raw=>'!'+raw.slice(1),raw=>raw.replace('tvbro-catalog-batch-v1','tvbro-catalog-batch-v2')]) {
    const disk=filesystem(),store=disk.restart();
    await write(store,['old']);await write(store,['new']);
    const newest=await store.readBatch(key);
    const file=disk.files.get(key+'.'+newest.token+'.json');
    file.raw=corrupt(file.raw);
    const restored=await read(disk.restart());
    assert.ok(restored,'an unreadable newest manifest must not hide the previous batch');
    assert.deepEqual(restored.parts,['old']);
    assert.equal([...disk.files.keys()].some(name=>name.includes('.'+newest.token+'.')),false);
  }
});

test('batch generations share quota, protection and removal with legacy cache files', async () => {
  const disk = filesystem(), store = disk.restart();
  await write(store,['one']); await write(store,['two']); await write(store,['three']);
  assert.equal([...disk.files.keys()].filter(name => name.endsWith('.json.ok')).length,2);
  assert.equal([...disk.files.keys()].filter(name => name.includes('.part-')).length,2);
  assert.deepEqual((await read(store)).parts,['three']);
  const third = 'f'.repeat(64);
  disk.seedGeneration(other,'1-0','protected legacy',32*1024*1024-512);
  disk.seedGeneration(third,'1-0','second protected legacy',32*1024*1024-512);
  const release = store.protectKeys([other,third,key]);
  try {
    assert.equal(await write(store,['x'.repeat(1024)]),false);
    assert.deepEqual((await read(store)).parts,['three']);
  } finally { release(); }
  assert.equal(await store.remove(key),true);
  assert.equal([...disk.files.keys()].some(name => name.startsWith(key+'.')),false);
});

test('invalid or oversized parts cannot replace a committed batch', async () => {
  const disk = filesystem(), store = disk.restart();
  await write(store,['good']);
  const value = batch(['bad']);
  assert.equal(await store.writeBatch(key,value.manifest,() => Promise.resolve({raw:'bad',checksum:'invalid'})),false);
  assert.equal(await write(store,['x'.repeat(1024*1024+1)]),false);
  assert.deepEqual((await read(store)).parts,['good']);
  await assert.rejects(store.writeBatch('../bad',value.manifest,value.readPart),{name:'TypeError'});
});

test('restart removes orphan chunks and leaves canonical legacy snapshots available for import', async () => {
  const disk=filesystem(),store=disk.restart();
  await write(store,['saved']);
  const orphan=key+'.9999999999999-0.part-0.json';
  disk.files.set(orphan,{name:orphan,isDirectory:false,fileSize:7,raw:'partial'});
  assert.deepEqual((await read(disk.restart())).parts,['saved']);
  assert.equal(disk.files.has(orphan),false);
  const legacy=JSON.stringify({schema:1,key:other,checksum:'a'.repeat(64),payload:'legacy canonical catalog'});
  await store.write(other,legacy);
  assert.equal(await store.readBatch(other),null);
  assert.equal((await store.read(other)).raw,legacy);
});

test('quota includes batch part bytes when deciding whether a protected cache can be replaced', async () => {
  const disk=filesystem();
  disk.environment.setTimeout=callback=>queueMicrotask(callback);
  const store=disk.restart(),third='f'.repeat(64),target='a'.repeat(64),mib=1024*1024;
  await write(store,['x'.repeat(mib)]);
  disk.seedGeneration(other,'1-0','protected legacy',31*mib-4096);
  disk.seedGeneration(third,'1-0','protected legacy',31*mib-4096);
  const release=store.protectKeys([key,other,third]);
  try {
    assert.equal(await store.write(target,'x'.repeat(2*mib)),false,
      'ignoring the 1 MiB of part data would incorrectly admit this write');
    assert.ok(await store.readBatch(key));
  } finally {release();}
});
