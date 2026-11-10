'use strict';
// Run after core_builder/build.ps1: node core_builder/test_catalog_memory.cjs <core-output>
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const output = path.resolve(process.argv[2]);
let fakeNow = Date.now();
class TestDate extends Date {
  constructor(...args) { super(...(args.length ? args : [fakeNow])); }
  static now() { return fakeNow; }
}
const sandbox = { console, crypto: crypto.webcrypto, setTimeout, clearTimeout, TextEncoder, TextDecoder, Date: TestDate };
sandbox.window = sandbox; sandbox.self = sandbox;
vm.createContext(sandbox);
if (fs.existsSync(path.join(output, 'polyfills.js'))) vm.runInContext(fs.readFileSync(path.join(output, 'polyfills.js'), 'utf8'), sandbox);
vm.runInContext(fs.readFileSync(path.join(output, fs.existsSync(path.join(output, 'core.js')) ? 'core.js' : 'canonical-core.js'), 'utf8'), sandbox);
const config = { id: 'memory-fixture', kind: 'm3u', fields: { playlistUrl: 'https://fixture.invalid/list.m3u' } };
function fixture(count, padding = '') {
  const rows = ['#EXTM3U', '#EXTINF:-1 group-title="Live",Live', 'https://fixture.invalid/live/1.ts'];
  for (let i = 0; i < count; i++) rows.push(
    '#EXTINF:-1 group-title="Shows",Unique Show ' + i + padding,
    '#EXTVLCOPT:http-user-agent=Fixture Agent',
    'https://fixture.invalid/series/' + i + '.mp4');
  return rows.join('\n');
}
function source(body) {
  let requests = 0, offline = false, responseBody = body;
  const engine = sandbox.TVBroCanonical.createSource(JSON.stringify(config), async raw => {
    const request = JSON.parse(raw);
    assert.equal(offline, false, 'restoring live roots must not contact the provider');
    assert.ok(responseBody, 'restored catalogue must not download');
    assert.equal(request.workload, 'playlist', 'no EPG or metadata required');
    requests++;
    return JSON.stringify({ status: 200, body: responseBody, headers: {}, url: request.url, decoded: true });
  });
  return { engine, requests: () => requests,
    setOffline(value) { offline = value; },
    setBody(value) { responseBody = value; },
    invoke: async (method, args = {}) => {
      const raw = await engine.invoke(method, JSON.stringify(args));
      if (method === 'exportCatalog') assert.ok(Buffer.byteLength(raw) <= 64 * 1024 * 1024 + 2, 'RPC escaping has its own byte bound');
      return JSON.parse(raw);
    } };
}
async function kindPreparationRetention() {
  assert.equal(typeof global.gc, 'function', 'the retention regression runs with explicit V8 GC');
  const count = 5000, refreshes = 7, kit = source(fixture(count));
  global.gc();
  const baseline = process.memoryUsage().heapUsed;
  for (let generation = 0; generation < refreshes; generation++) {
    if (generation > 0) {
      fakeNow += 25 * 60 * 60 * 1000;
      kit.setBody(fixture(count, ' generation ' + generation));
    }
    const prepared = await Promise.all(['live', 'movie', 'series'].map(kind => kit.invoke('prepareCatalog', {
      kind, forceRefresh: false, refreshKey: 'stale-generation-' + generation
    })));
    assert.deepEqual(prepared.map(row => row.complete), [true, true, true]);
    assert.equal(prepared[2].count, count);
    assert.equal(kit.requests(), generation + 1, 'each stale batch reads the playlist once');
    global.gc();
  }
  const retainedBytes = process.memoryUsage().heapUsed - baseline;
  assert.ok(retainedBytes < 48 * 1024 * 1024,
    'settled kind preparations must release prior catalog roots; retained heap=' + retainedBytes);
  await kit.engine.dispose();
  console.log('kind preparations: settled catalog roots released, retained heap=' + retainedBytes);
}
async function load(kit) {
  const [categories, channels] = await Promise.all([kit.invoke('categories'), kit.invoke('channels')]);
  assert.equal(categories.length, 1); assert.equal(channels.length, 1);
}
async function stress() {
  const oversized = process.argv.includes('--oversized');
  const kit = source(fixture(20000, oversized ? ' Ż😀'.repeat(80) : ''));
  await load(kit);
  console.log('large fixture: roots ready');
  const snapshot = await kit.invoke('exportCatalog', { scope: 'test' });
  if (oversized) assert.equal(snapshot, null, 'oversized UTF-8 snapshot must be refused during encoding');
  else assert.equal(typeof snapshot, 'string', 'a fitting large catalogue must still be cached');
  assert.ok(snapshot === null || Buffer.byteLength(snapshot) <= 32 * 1024 * 1024);
  assert.equal((await kit.invoke('channels')).length, 1, 'export must not destroy browsing state');
  const page = await kit.invoke('mediaItemsPage', { kind: 'series', page: 1 });
  const seasons = await kit.invoke('mediaItems', { kind: 'season', parent: page.items[0] });
  const episodes = await kit.invoke('mediaItems', { kind: 'episode', parent: seasons[0] });
  assert.equal(episodes.length, 1, 'export refusal must retain unvisited children too');
  assert.equal((await kit.invoke('resolveMedia', { item: episodes[0] })).headers['User-Agent'], 'Fixture Agent');
  assert.equal(kit.requests(), 1);
  await kit.engine.dispose();
  console.log('large fixture: bounded export completed, snapshot bytes=' + (snapshot === null ? 'refused' : Buffer.byteLength(snapshot)));
}
async function deferredMedia() {
  const body = fixture(20000, ' Ż😀'.repeat(80));
  const first = source(body);
  await load(first);
  const snapshot = await first.invoke('exportCatalog', { scope: 'test', allowDeferredMedia: true });
  assert.equal(typeof snapshot, 'string', 'oversized M3U media hints must still produce a live-only snapshot');
  const payload = JSON.parse(JSON.parse(snapshot).payload);
  assert.equal(payload.hints.mediaOmitted, true, 'the snapshot must explicitly mark deferred VOD data');
  assert.equal(Object.hasOwn(payload.hints, 'media'), false, 'the snapshot must not contain truncated media data');
  await first.engine.dispose();

  const restored = source(body);
  restored.setOffline(true);
  const imported = await restored.invoke('importCatalog', { scope: 'test', snapshot });
  assert.equal(imported.fromCache, true);
  assert.equal((await restored.invoke('categories')).length, 1);
  assert.equal((await restored.invoke('channels')).length, 1);
  assert.equal(restored.requests(), 0, 'live roots restore without a provider request');
  assert.equal(await restored.invoke('exportCatalog', { scope: 'test' }), null,
    'a durable partial cache must not masquerade as a complete rollback snapshot');
  const reexport = await restored.invoke('exportCatalog', { scope: 'test', allowDeferredMedia: true });
  const reexportPayload = JSON.parse(JSON.parse(reexport).payload);
  assert.equal(reexportPayload.hints.mediaOmitted, true, 'durable partial snapshots stay explicitly partial');
  const forged = JSON.parse(reexport);
  const forgedPayload = JSON.parse(forged.payload);
  forgedPayload.reads.push({ method: 'mediaCategories', args: { kind: 'series' }, at: forgedPayload.syncedAt, value: [] });
  forged.payload = JSON.stringify(forgedPayload);
  forged.checksum = crypto.createHash('sha256').update(forged.payload).digest('hex');
  assert.equal(await restored.invoke('importCatalog', { scope: 'test', snapshot: JSON.stringify(forged) }), null,
    'a deferred-media snapshot cannot smuggle optional reads alongside omitted VOD data');

  restored.setOffline(false);
  const categories = await restored.invoke('mediaCategories', { kind: 'series' });
  const page = await restored.invoke('mediaItemsPage', { kind: 'series', categoryId: categories[0].id, page: 1 });
  assert.equal(categories.length, 1);
  assert.equal(page.items.length, 100, 'VOD data becomes available after its deferred full playlist read');
  assert.equal(restored.requests(), 1, 'the first VOD action reparses the original source exactly once');
  await restored.engine.dispose();
  console.log('deferred M3U fixture: live roots restored offline; VOD loaded on first use');
}
async function main() {
  if (process.argv.includes('--kind-preparations')) return kindPreparationRetention();
  if (process.argv.includes('--deferred-media')) return deferredMedia();
  if (process.argv.includes('--stress') || process.argv.includes('--oversized')) return stress();
  const kit = source(fixture(2));
  await load(kit);
  const snapshot = await kit.invoke('exportCatalog', { scope: 'test' });
  const envelope = JSON.parse(snapshot), payload = JSON.parse(envelope.payload);
  assert.equal(envelope.checksum, crypto.createHash('sha256').update(envelope.payload).digest('hex'));
  const media = payload.hints.media;
  const items = [...Object.values(media.roots).flat(), ...Object.values(media.children).flat()];
  assert.equal(items.length, 6);
  for (const item of items) for (const key of ['info', 'trailerUrl', 'sourceHints', 'sourceTitle']) {
    assert.ok(!Object.hasOwn(item, key), 'cache must not retain derived presentation field: ' + key);
  }
  await kit.engine.dispose();
  const restored = source(null);
  assert.equal((await restored.invoke('importCatalog', { scope: 'test', snapshot })).fromCache, true);
  const shows = await restored.invoke('allMediaItems', { kind: 'series' });
  assert.equal(shows.length, 2);
  assert.ok(shows[0].info && shows[0].trailerUrl, 'presentation is still projected for UI reads');
  const seasons = await restored.invoke('mediaItems', { kind: 'season', parent: shows[0] });
  const episodes = await restored.invoke('mediaItems', { kind: 'episode', parent: seasons[0] });
  const stream = await restored.invoke('resolveMedia', { item: episodes[0] });
  assert.equal(stream.url, 'https://fixture.invalid/series/0.mp4');
  assert.equal(stream.headers['User-Agent'], 'Fixture Agent');
  assert.equal(restored.requests(), 0);
  // Old schema-1 snapshots contain UI projections. Their extra fields remain
  // readable; no destructive migration or cache reset is needed.
  for (const item of items) Object.assign(item, { info: {}, trailerUrl: 'https://fixture.invalid/trailer', sourceHints: [], sourceTitle: 'Old UI' });
  envelope.payload = JSON.stringify(payload);
  envelope.checksum = crypto.createHash('sha256').update(envelope.payload).digest('hex');
  assert.equal((await restored.invoke('importCatalog', { scope: 'test', snapshot: JSON.stringify(envelope) })).fromCache, true);
  await restored.engine.dispose();
  console.log('compact cache: offline roundtrip and UI projection passed');
  for (const mode of ['--stress', '--oversized']) {
    const child = spawnSync(process.execPath, ['--max-old-space-size=192', __filename, output, mode],
      { encoding: 'utf8', timeout: 120000, maxBuffer: 1024 * 1024 });
    assert.equal(child.status, 0, '192 MiB heap export regression failed: ' + child.stdout + child.stderr);
    console.log(child.stdout.trim());
  }
  const retention = spawnSync(process.execPath,
    ['--expose-gc', '--max-old-space-size=192', __filename, output, '--kind-preparations'],
    { encoding: 'utf8', timeout: 120000, maxBuffer: 1024 * 1024 });
  assert.equal(retention.status, 0, 'kind preparation retention regression failed: ' + retention.stdout + retention.stderr);
  console.log(retention.stdout.trim());
}
main().catch(error => { console.error(error); process.exitCode = 1; });
