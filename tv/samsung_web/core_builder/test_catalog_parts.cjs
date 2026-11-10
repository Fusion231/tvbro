'use strict';
// Run after core_builder/build.ps1: node core_builder/test_catalog_parts.cjs <core-output>
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const zlib = require('node:zlib');

const output = path.resolve(process.argv[2]);
const sandbox = {console, crypto: crypto.webcrypto, setTimeout, clearTimeout, TextEncoder, TextDecoder};
sandbox.window = sandbox;
sandbox.self = sandbox;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(output, 'core.js'), 'utf8'), sandbox);
const core = sandbox.TVBroCanonical;

function playlist(count, suffix) {
  const rows = ['#EXTM3U', '#EXTINF:-1 group-title="Live",Live channel', 'https://fixture.invalid/live/1.ts'];
  for (let i = 0; i < count; i++) rows.push(
    '#EXTINF:-1 group-title="Shows",' + suffix + ' Show ' + i,
    '#EXTVLCOPT:http-user-agent=Fixture Agent',
    'https://fixture.invalid/series/' + suffix + '-' + i + '.mp4');
  return rows.join('\n');
}

function source(body) {
  const requests = [];
  const engine = core.createSource(JSON.stringify({id:'chunk-fixture', kind:'m3u', fields:{
    playlistUrl:'https://fixture.invalid/list.m3u'
  }}), async raw => {
    const request = JSON.parse(raw);
    requests.push(request);
    if (body == null) throw new Error('Offline fixture must not request a provider.');
    return JSON.stringify({status:200, body, headers:{}, url:request.url, decoded:true});
  });
  return {
    requests,
    async invoke(method, args = {}) {
      return JSON.parse(await engine.invoke(method, JSON.stringify(args)));
    },
    dispose:() => engine.dispose()
  };
}

async function prepare(source, forceRefresh = false, refreshKey = 'cold-batch') {
  return Promise.all(['live','movie','series'].map(kind => source.invoke('prepareCatalog', {
    kind,forceRefresh,refreshKey
  })));
}

async function exportParts(source) {
  const manifest = await source.invoke('beginCatalogExport', {scope:'fixture-profile'});
  assert.ok(manifest.parts.length > 1, 'large fixture must use multiple bounded parts');
  const parts = [];
  let compressed = 0;
  for (const descriptor of manifest.parts) {
    const part = await source.invoke('exportCatalogPart', {index:descriptor.index});
    assert.equal(typeof part.raw, 'string');
    assert.equal(part.checksum, crypto.createHash('sha256').update(part.raw).digest('hex'));
    assert.ok(Buffer.byteLength(part.raw) <= 1024 * 1024, 'each part stays within the one MiB transfer bound');
    assert.equal(part.bytes,Buffer.byteLength(part.raw));
    assert.equal(part.decodedBytes,descriptor.decodedBytes);
    const stored=JSON.parse(part.raw);
    if (stored.format === 'gzip-json') {
      compressed++;
      const decoded=zlib.gunzipSync(Buffer.from(stored.data,'base64'));
      assert.equal(decoded.length,stored.decodedBytes);
      assert.ok(decoded.length <= 1024 * 1024, 'inflated parts stay within the decoded-part bound');
    }
    parts.push({descriptor:{...descriptor,checksum:part.checksum,bytes:part.bytes},raw:part.raw,checksum:part.checksum});
  }
  assert.ok(compressed > 0, 'repetitive provider rows use per-part gzip storage');
  manifest.parts = parts.map(({descriptor}) => descriptor);
  return {manifest,parts};
}

async function importParts(target, exported, count) {
  await target.invoke('beginCatalogImport', {scope:'fixture-profile',manifest:exported.manifest});
  for (const part of exported.parts.slice(0,count)) {
    await target.invoke('importCatalogPart', {index:part.descriptor.index,raw:part.raw,checksum:part.checksum});
  }
}

function legacyBatch(exported, legacyKey) {
  const manifest=JSON.parse(JSON.stringify(exported.manifest)),parts=[];
  manifest.key=legacyKey;
  for(const part of exported.parts) {
    const stored=JSON.parse(part.raw),decoded=stored.format==='gzip-json'
      ? zlib.gunzipSync(Buffer.from(stored.data,'base64')).toString('utf8') : part.raw;
    const row=JSON.parse(decoded);row.key=legacyKey;
    const nextDecoded=JSON.stringify(row),raw=stored.format==='gzip-json'
      ? JSON.stringify({format:'gzip-json',decodedBytes:Buffer.byteLength(nextDecoded),data:zlib.gzipSync(Buffer.from(nextDecoded),{level:6}).toString('base64')})
      : nextDecoded;
    const checksum=crypto.createHash('sha256').update(raw).digest('hex');
    const descriptor={...part.descriptor,bytes:Buffer.byteLength(raw),decodedBytes:Buffer.byteLength(nextDecoded),checksum};
    manifest.parts[descriptor.index]=descriptor;parts.push({descriptor,raw,checksum});
  }
  return {manifest,parts,legacyKey};
}

async function main() {
  let phase = 'source setup';
  const original = source(playlist(12000,'original'));
  const replacement = source(playlist(2,'replacement'));
  const restored = source(null);
  try {
    const capability = await original.invoke('capabilities');
    assert.equal(capability.fullCatalogCache, true, 'platform callers can select chunked cache methods');

    phase = 'cold prepare';
    const prepared = await prepare(original);
    assert.equal(original.requests.length,1,'concurrent cold sections share one M3U playlist read');
    assert.deepEqual(prepared.map(row => [row.kind,row.count,row.complete]), [
      ['live',1,true],['movie',0,true],['series',12000,true]
    ]);
    assert.deepEqual((await original.invoke('catalogState')).kinds.series.count,12000);

    phase = 'forced prepare';
    await prepare(original,true,'forced-batch');
    assert.equal(original.requests.length,2,'a forced three-section refresh shares one additional playlist read');

    phase = 'chunk export';
    const exported = await exportParts(original);
    const legacyExported=legacyBatch(exported,await original.invoke('legacyCacheKey',{scope:'fixture-profile'}));
    const old = await prepare(replacement);
    assert.equal(old[2].count,2);
    phase = 'partial import';
    await importParts(replacement,exported,1);
    assert.equal((await replacement.invoke('catalogState')).kinds.series.count,2,
      'partially imported data must not replace the prior complete catalog');
    await replacement.invoke('abortCatalogImport');

    phase = 'legacy complete import';
    await importParts(restored,legacyExported,legacyExported.parts.length);
    const committed = await restored.invoke('commitCatalogImport');
    assert.deepEqual(committed.kinds.series,{complete:true,count:12000,syncedAt:committed.kinds.series.syncedAt});
    assert.ok(Number.isSafeInteger(committed.kinds.series.syncedAt));

    phase = 'normalized complete import';
    await importParts(replacement,exported,exported.parts.length);
    assert.equal((await replacement.invoke('commitCatalogImport')).kinds.series.count,12000,
      'current normalized-key generations remain importable alongside exact legacy generations');

    const readsBefore = restored.requests.length;
    const page = await restored.invoke('mediaItemsPage',{kind:'series',page:1});
    const secondPage = await restored.invoke('mediaItemsPage',{kind:'series',page:2});
    const search = await restored.invoke('searchMedia',{kind:'series',query:'original show 11999'});
    const season = (await restored.invoke('mediaItems',{kind:'season',parent:page.items[0]}))[0];
    const episode = (await restored.invoke('mediaItems',{kind:'episode',parent:season}))[0];
    const stream = await restored.invoke('resolveMedia',{item:episode});
    assert.equal(page.items.length,100);
    assert.equal(page.hasMore,true);
    assert.equal(secondPage.items[0].title,'original Show 100');
    assert.equal(search[0].title,'original Show 11999');
    assert.ok(season && episode,'M3U series children survive a fresh worker restore');
    assert.equal(stream.url,'https://fixture.invalid/series/original-0.mp4');
    assert.equal(restored.requests.length,readsBefore,'restored pages, children and playback locators stay offline');

    const corrupt = source(null);
    try {
      await corrupt.invoke('beginCatalogImport',{scope:'fixture-profile',manifest:exported.manifest});
      const part = exported.parts[0];
      await assert.rejects(corrupt.invoke('importCatalogPart',{
        index:part.descriptor.index,raw:part.raw + ' ',checksum:part.checksum
      }));
      await assert.rejects(corrupt.invoke('commitCatalogImport'));
      await corrupt.invoke('abortCatalogImport');
      assert.equal((await corrupt.invoke('catalogState')).kinds.series.complete,false,
        'corrupt chunks cannot publish a complete root');
    } finally { await corrupt.dispose(); }

    const bomb = source(null);
    try {
      const manifest=JSON.parse(JSON.stringify(exported.manifest)), descriptor=manifest.parts.find(part=>part.kind==='series');
      const wrapper=JSON.stringify({format:'gzip-json',decodedBytes:descriptor.decodedBytes,
        data:zlib.gzipSync(Buffer.alloc(1024*1024+1)).toString('base64')});
      descriptor.bytes=Buffer.byteLength(wrapper); descriptor.checksum=crypto.createHash('sha256').update(wrapper).digest('hex');
      await bomb.invoke('beginCatalogImport',{scope:'fixture-profile',manifest});
      await assert.rejects(bomb.invoke('importCatalogPart',{index:descriptor.index,raw:wrapper,checksum:descriptor.checksum}),
        'compressed bombs are rejected at the bounded inflate limit');
      await bomb.invoke('abortCatalogImport');

      const crcManifest=JSON.parse(JSON.stringify(exported.manifest)), crcDescriptor=crcManifest.parts.find(part=>part.kind==='series');
      const invalidGzip=zlib.gzipSync(Buffer.alloc(512)); invalidGzip[invalidGzip.length-8]^=1;
      const crcWrapper=JSON.stringify({format:'gzip-json',decodedBytes:512,data:invalidGzip.toString('base64')});
      crcDescriptor.bytes=Buffer.byteLength(crcWrapper); crcDescriptor.decodedBytes=512;
      crcDescriptor.checksum=crypto.createHash('sha256').update(crcWrapper).digest('hex');
      await bomb.invoke('beginCatalogImport',{scope:'fixture-profile',manifest:crcManifest});
      await assert.rejects(bomb.invoke('importCatalogPart',{index:crcDescriptor.index,raw:crcWrapper,checksum:crcDescriptor.checksum}),
        'gzip CRC corruption is rejected');
      await bomb.invoke('abortCatalogImport');
    } finally { await bomb.dispose(); }
  } catch (error) {
    console.error('phase:',phase);
    throw error;
  } finally {
    await original.dispose();
    await replacement.dispose();
    await restored.dispose();
  }
  console.log('catalog chunks: bounded export, atomic import and offline M3U hierarchy passed');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
