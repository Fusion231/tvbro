'use strict';
const assert = require('node:assert/strict');
const { webcrypto } = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { gzipSync } = require('node:zlib');

const sandbox = { console, crypto: webcrypto, setTimeout, clearTimeout, TextEncoder, TextDecoder, atob, btoa, pako: require('pako') };
sandbox.window = sandbox.self = sandbox;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(__dirname, '../platform/streaming_gzip.js'), 'utf8'), sandbox);
vm.runInContext(fs.readFileSync(path.join(process.argv[2], 'core.js'), 'utf8'), sandbox);
const scopes = new Map(), requests = [];
let activeBody, nextDraft = 0;
sandbox.TVBroM3uDiskCreate = owner => {
  if (!scopes.has(owner)) scopes.set(owner, { draft: null, committed: null });
  const store = scopes.get(owner);
  return async (method, encoded) => {
    const args = JSON.parse(encoded);
    let result = null;
    switch (method) {
      case 'state': result = store.committed && store.committed.state; break;
      case 'begin': result = String(++nextDraft); store.draft = new Map(); break;
      case 'add':
        assert.ok(args.rows.length <= 1500);
        for (const row of args.rows) {
          const key = JSON.stringify([row.kind, row.parentId || '', row.id]);
          if (row.kind === 'live' || !store.draft.has(key)) store.draft.set(key, row);
        }
        break;
      case 'commit': {
        const rows = [...store.draft.values()];
        const counts = Object.fromEntries(['live','movie','series'].map(kind =>
          [kind, rows.filter(row => row.kind === kind).length]));
        result = { counts, syncedAt: Date.now(), header: args.header };
        store.committed = { state: result, rows };
        store.draft = null;
        break;
      }
      case 'abort': store.draft = null; break;
      case 'remove': store.committed = null; break;
      case 'read':
      case 'get': {
        const rows = (store.committed?.rows || []).filter(row => row.kind === args.kind &&
          (!args.parentId || row.parentId === args.parentId) &&
          (!args.categoryId || row.categoryId === args.categoryId) &&
          (!args.query || (row.title || row.name).toLowerCase().includes(args.query.toLowerCase())) &&
          (!args.ids || args.ids.includes(row.id))).sort((a, b) => a.order - b.order);
        const offset = args.offset || 0;
        result = method === 'get' ? rows.find(row => row.id === args.id) || null
          : { items: rows.slice(offset, offset + args.limit), count: rows.length };
        break;
      }
      default: throw new Error('Unexpected disk method ' + method);
    }
    return JSON.stringify(result);
  };
};
function open() {
  const stages = [];
  const source = sandbox.TVBroCanonical.createSource(JSON.stringify({
    id: 'local-test', label: 'Fixture', kind: 'm3u', fields: {playlistUrl: 'https://playlist.fixture/local'}
  }), async raw => {
    const request = JSON.parse(raw);
    requests.push(request);
    return { metadata: JSON.stringify({ status: 200, headers: {}, url: request.url }), bodyBlob: new Blob([activeBody]) };
  }, stage => stages.push(stage));
  return { source, stages, invoke: async (method, args = {}) => JSON.parse(await source.invoke(method, JSON.stringify(args))) };
}

async function main() {
  const playlist = '#EXTM3U x-tvg-url="https://guide.fixture/xml"\n' +
    '#EXTINF:-1 group-title="TV",News\nhttps://media.fixture/live/1.ts\n' +
    '#EXTINF:-1 group-title="Cinema",Żuraw\nhttps://media.fixture/movie/1.mp4\n' +
    '#EXTINF:-1 group-title="Serials",Show S01E01\nhttps://media.fixture/series/1.mp4\n' +
    Array.from({length:115}, (_, i) =>
      '#EXTINF:-1 group-title="Cinema",Match ' + i + '\nhttps://media.fixture/movie/match-' + i + '.mp4\n').join('');
  activeBody = gzipSync(playlist);
  const source = open();
  assert.equal(await source.invoke('catalogScope', { scope: 'profile' }), true);
  await Promise.all(['live','movie','series'].map(kind => source.invoke('prepareCatalog', {
    kind, refreshKey: 'all', forceRefresh: false
  })));
  assert.equal(requests.length, 1);
  assert.equal(requests[0].importProgress, true);
  assert.deepEqual(source.stages, ['processing', 'saving']);
  assert.equal(requests[0].streamPlaylist, true);
  assert.equal(requests[0].maximumBodyBytes, undefined);
  const rows = (await source.invoke('mediaItemsPage', { kind: 'movie', page: 1 })).items;
  assert.equal(rows[0].title, 'Żuraw');
  const firstSearchPage = await source.invoke('mediaItemsPage', { kind:'movie', query:'Match', page:1 });
  assert.equal(firstSearchPage.items.length, 100);
  assert.equal(firstSearchPage.hasMore, true);
  const secondSearchPage = await source.invoke('mediaItemsPage', { kind:'movie', query:'Match', page:2 });
  assert.equal(secondSearchPage.items.length, 15);
  assert.equal(secondSearchPage.items[0].title, 'Match 100');
  assert.equal(secondSearchPage.hasMore, false);
  await source.source.dispose();

  const restored = open();
  await restored.invoke('catalogScope', { scope: 'profile' });
  assert.equal((await restored.invoke('catalogState')).kinds.series.count, 1);
  assert.equal((await restored.invoke('mediaByIds', { kind: 'movie', ids: [rows[0].id] }))[0].title, 'Żuraw');
  const shows = (await restored.invoke('mediaItemsPage', {kind:'series', page:1})).items;
  const [season] = await restored.invoke('mediaItems', {kind:'season', parent:shows[0]});
  const [episode] = await restored.invoke('mediaItems', {kind:'episode', parent:season});
  assert.equal((await restored.invoke('resolveMedia', {item:episode})).url, 'https://media.fixture/series/1.mp4');
  assert.equal((await restored.invoke('playbackEpisodes', {item:episode})).parent.id, season.id);
  assert.equal((await restored.invoke('capabilities')).epg, 'supported');
  assert.equal(requests.length, 1);
  activeBody = Buffer.from('invalid, truncated input');
  await assert.rejects(restored.invoke('prepareCatalog', { kind: 'movie', refreshKey: 'bad', forceRefresh: true }));
  assert.equal((await restored.invoke('mediaItemsPage', {kind:'movie', page:1})).items[0].title, 'Żuraw');
  await restored.source.dispose();
}

main().catch(error => { console.error(error); process.exitCode = 1; });
