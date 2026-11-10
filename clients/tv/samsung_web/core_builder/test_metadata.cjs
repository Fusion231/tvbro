'use strict';
// Run after the canonical core build: node core_builder/test_metadata.cjs <core-output>
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const output = path.resolve(process.argv[2]);
const sandbox = { console, crypto: crypto.webcrypto, setTimeout, clearTimeout, TextEncoder, TextDecoder };
sandbox.window = sandbox;
sandbox.self = sandbox;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(output, 'core.js'), 'utf8'), sandbox);
const core = sandbox.TVBroCanonical;
assert.ok(core);

const calls = [];
let pendingMetadataResponse = null;
function response(request, body, status = 200) {
  calls.push(request);
  assert.equal(request.workload, 'metadata-json');
  assert.ok(request.maximumBodyBytes <= 4 * 1024 * 1024);
  assert.ok(request.maximumDecodedBytes <= 8 * 1024 * 1024);
  return JSON.stringify({ status, body: JSON.stringify(body), headers: {}, url: request.url, decoded: true });
}
async function transport(raw) {
  const request = JSON.parse(raw);
  const url = new URL(request.url);
  if (pendingMetadataResponse && url.hostname === 'api.themoviedb.org' && url.pathname === '/3/search/movie') {
    const pending = pendingMetadataResponse;
    pendingMetadataResponse = null;
    pending.started();
    await pending.response;
  }
  if (url.hostname === 'api.themoviedb.org' && url.pathname === '/3/search/movie') {
    return response(request, { results: [{ id: 101, title: 'Cache Film', release_date: '2020-01-02', poster_path: '/poster.jpg' }] });
  }
  if (url.hostname === 'api.themoviedb.org' && url.pathname === '/3/movie/101') {
    return response(request, { id: 101, title: 'Cache Film', release_date: '2020-01-02', overview: 'Fixture overview', poster_path: '/poster.jpg', credits: { cast: [] } });
  }
  throw new Error('Unexpected local fixture request: ' + request.url);
}
const sourceConfig = JSON.stringify({ id: 'metadata-fixture', kind: 'demo', fields: {}, settings: {} });
function createSource() { return core.createSource(sourceConfig, transport); }
async function invoke(source, method, args = {}) {
  return JSON.parse(await source.invoke(method, JSON.stringify(args)));
}

async function main() {
  let source = createSource();
  const settings = { provider: 'tmdb', tmdbApiKey: 'fake-tmdb-key', tvdbApiKey: '', tvdbPin: '', mdblistApiKey: '', autoEnrich: true };
  const order = await invoke(source, 'metadata.configure', { config: {
    provider: 'tvdb', tmdbApiKey: 'fake-tmdb-key', tvdbApiKey: 'fake-tvdb-key', tvdbPin: '',
    mdblistApiKey: 'fake-mdblist-key', autoEnrich: false,
  }, language: 'pl' });
  assert.deepEqual(order.providers, ['tvdb', 'tmdb', 'tvmaze', 'mdblist']);
  assert.equal(order.language, 'pol');
  assert.equal(order.autoEnrich, false);
  const configured = await invoke(source, 'metadata.configure', { config: settings, language: 'eng' });
  assert.deepEqual(configured.providers, ['tmdb', 'tvmaze']);
  assert.equal(configured.autoEnrich, true);

  const input = { id: 'movie-1', title: 'Cache Film', kind: 'movie', year: '2020', providerId: null, extra: {} };
  const base = await invoke(source, 'mediaDetails', { item: input });
  const first = await invoke(source, 'metadata.details', { item: base, sourceDetailsLoaded: true });
  assert.equal(first.poster, 'https://image.tmdb.org/t/p/w500/poster.jpg');
  assert.equal(first.description, 'Fixture overview');
  assert.equal(calls.length, 2, 'TMDB search plus detail lookup occur once');

  const second = await invoke(source, 'metadata.details', { item: base, sourceDetailsLoaded: true });
  assert.equal(second.poster, first.poster);
  assert.equal(calls.length, 2, 'repeated detail reads use the provider cache');

  const refreshed = await invoke(source, 'metadata.refresh', { item: base, sourceDetailsLoaded: true });
  assert.equal(refreshed.poster, first.poster);
  assert.equal(calls.length, 3, 'explicit metadata refresh re-queries providers');

  const key = await invoke(source, 'metadata.cacheKey', { scope: 'profile-source-scope' });
  assert.match(key, /^[a-f0-9]{64}$/);
  const snapshot = await invoke(source, 'metadata.export', { scope: 'profile-source-scope' });
  assert.equal(snapshot.schema, 1);
  assert.ok(snapshot.records.length > 0);
  assert.equal(JSON.stringify(snapshot).includes('fake-tmdb-key'), false, 'cache snapshot must not contain credentials');

  const beforeRestore = calls.length;
  await source.dispose();
  source = createSource();
  await invoke(source, 'metadata.configure', { config: settings, language: 'eng' });
  assert.equal(await invoke(source, 'metadata.import', { scope: 'another-profile', snapshot: JSON.stringify(snapshot) }), false);
  assert.equal(await invoke(source, 'metadata.import', { scope: 'profile-source-scope', snapshot: JSON.stringify(snapshot) }), true);
  const offline = await invoke(source, 'metadata.details', { item: base, sourceDetailsLoaded: true });
  assert.equal(offline.poster, first.poster);
  assert.equal(calls.length, beforeRestore, 'restored cache is reused without provider traffic');
  await source.dispose();

  let signalMetadataRequest;
  let releaseMetadataResponse;
  const metadataRequestStarted = new Promise(resolve => { signalMetadataRequest = resolve; });
  const metadataResponse = new Promise(resolve => { releaseMetadataResponse = resolve; });
  const stale = createSource();
  await invoke(stale, 'metadata.configure', { config: settings, language: 'eng' });
  pendingMetadataResponse = { started: signalMetadataRequest, response: metadataResponse };
  const staleLookup = invoke(stale, 'metadata.details', {
    item: { id: 'late-movie', title: 'Cache Film', kind: 'movie', year: '2020', providerId: null, extra: {} },
    sourceDetailsLoaded: true,
  });
  await metadataRequestStarted;
  await invoke(stale, 'metadata.configure', {
    config: { ...settings, tmdbApiKey: 'rotated-fake-key' }, language: 'eng',
  });
  releaseMetadataResponse();
  await assert.rejects(staleLookup);
  const staleSnapshot = await invoke(stale, 'metadata.export', { scope: 'profile-source-scope' });
  assert.equal(staleSnapshot.records.some(record => record.id === 'late-movie'), false,
    'late metadata from a retired configuration must not enter the cache');
  await stale.dispose();

  const redirects = [];
  const redirectSource = core.createSource(sourceConfig, async raw => {
    const request = JSON.parse(raw), url = new URL(request.url);
    redirects.push(request);
    if (url.hostname === 'api.themoviedb.org') {
      return JSON.stringify({status:302, body:'', headers:{location:'https://api.tvmaze.com/search/shows?token=redirect-secret'},
        url:request.url, decoded:true});
    }
    return JSON.stringify({status:200, body:'[]', headers:{}, url:request.url, decoded:true});
  });
  await invoke(redirectSource, 'metadata.configure', {config:settings, language:'en'});
  const redirectBase = await invoke(redirectSource, 'mediaDetails', {item:input});
  await invoke(redirectSource, 'metadata.details', {item:redirectBase, sourceDetailsLoaded:true});
  assert.ok(redirects.length >= 2);
  assert.equal(redirects[1].method, 'GET');
  assert.equal(new URL(redirects[1].url).hostname, 'api.tvmaze.com');
  assert.equal(redirects[1].url.includes('redirect-secret'), false, 'cross-host redirects strip credential query parameters');
  assert.equal(Object.keys(redirects[1].headers || {}).some(name => name.toLowerCase() === 'authorization'), false,
    'cross-host redirects strip authorization headers');
  await redirectSource.dispose();
  console.log('metadata configure, detail cache, and credential-free restart cache passed');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
