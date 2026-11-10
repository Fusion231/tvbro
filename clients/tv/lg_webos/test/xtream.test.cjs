'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const createPlatform = require('../../samsung_web/platform.js');
const libraryModule = require('../../samsung_web/platform/library.js');
const userStateModule = require('../../samsung_web/platform/user_state.js');
const playerModule = require('../platform/player.js');

const defaultUserAgent = 'VLC/3.0.20 LibVLC/3.0.20';
const platforms = new Set();
test.afterEach(async () => {
  const pending = [...platforms]; platforms.clear();
  await Promise.all(pending.map(api => api.query('sources.cancel')));
});

function canonicalModules() {
  const output = path.resolve(__dirname, '../../output/samsung-web');
  const build = JSON.parse(fs.readFileSync(path.join(output, 'latest-build.json'), 'utf8'));
  const sandbox = { console, crypto: crypto.webcrypto, setTimeout, clearTimeout, TextEncoder, TextDecoder };
  sandbox.window = sandbox; sandbox.self = sandbox;
  vm.createContext(sandbox);
  for (const file of ['polyfills.js', 'panel-validation.js']) {
    vm.runInContext(fs.readFileSync(path.join(build.payload, file), 'utf8'), sandbox, { filename: file });
  }
  vm.runInContext(fs.readFileSync(path.join(output, 'core/core.js'), 'utf8'), sandbox, { filename: 'canonical-core.js' });
  return { core: sandbox.TVBroCanonical, validation: sandbox.TVBroPanelValidation };
}

function mediaElement() {
  const listeners = new Map(), loaded = [];
  const video = {
    style: { objectFit: '' }, readyState: 0, paused: true, ended: false, seeking: false,
    currentTime: 0, duration: 120, src: '', hidden: true, firstChild: null, playbackRate: 1,
    addEventListener(name, callback) {
      if (!listeners.has(name)) listeners.set(name, new Set());
      listeners.get(name).add(callback);
    },
    removeEventListener(name, callback) { if (listeners.has(name)) listeners.get(name).delete(callback); },
    emit(name) { for (const callback of [...(listeners.get(name) || [])]) callback({ type: name, target: video }); },
    setAttribute() {},
    removeAttribute(name) { if (name === 'src') this.src = ''; },
    load() { this.readyState = this.src ? 4 : 0; if (this.src) loaded.push(this.src); },
    play() { this.paused = false; queueMicrotask(() => this.emit('playing')); },
    pause() { this.paused = true; }
  };
  return { video, loaded };
}

function harness(route) {
  const { core, validation } = canonicalModules();
  const media = mediaElement(), nativePlayer = playerModule.create({ video: media.video, timerHost: globalThis });
  const opens = [], resolved = [], requests = [], checked = [];
  const originalOpen = nativePlayer.open;
  nativePlayer.open = (url, options) => {
    Object.freeze(options.headers);
    opens.push({ url, options });
    return originalOpen(url, options);
  };
  let user = {};
  const store = {
    read() { return []; }, readUserState() { return { ...user }; },
    writeUserState(next) { user = { ...next }; return Promise.resolve(); }
  };
  const transport = {
    capabilities() { return { cookies: true, userAgent: true }; }, abort() {},
    checkStream(url) { checked.push(url); return Promise.resolve(); },
    async request(text) {
      const request = JSON.parse(text); requests.push(request);
      const response = await route(new URL(request.url), request);
      return JSON.stringify({ status: 200, body: typeof response === 'string' ? response : JSON.stringify(response),
        url: request.url, headers: {}, decoded: true });
    }
  };
  const environment = {
    TVBroCanonical: core, TVBroPanelValidation: validation, TVBroSamsungLibrary: libraryModule,
    TVBroSamsungUserState: userStateModule, TVBroSamsungTransport: { create() { return transport; } },
    innerWidth: 1920, innerHeight: 1080
  };
  const api = createPlatform(environment, {
    storeModule: {}, store, playerModule, player: nativePlayer,
    verifyPin: core.verifyPin, hashPin: core.hashPin,
    createSource(config, request) {
      const source = core.createSource(config, request);
      return {
        async invoke(method, args) {
          const result = await source.invoke(method, args);
          if (method === 'resolveMedia') resolved.push(JSON.parse(result));
          return result;
        },
        dispose() { return source.dispose(); }
      };
    }
  });
  platforms.add(api);
  return { api, media, opens, resolved, requests, checked };
}

function xtreamRoute(url) {
  const action = url.searchParams.get('action');
  if (!action) return { user_info: { auth: 1, status: 'Active', max_connections: '2' }, server_info: { timezone: 'UTC' } };
  if (action === 'get_live_categories' || action === 'get_live_streams') return [];
  if (action === 'get_vod_categories') return [{ category_id: 'movies', category_name: 'Movies' }];
  if (action === 'get_series_categories') return [{ category_id: 'series', category_name: 'Series' }];
  if (action === 'get_vod_streams') return [{ stream_id: 500, name: 'Film', category_id: 'movies', container_extension: 'mkv' }];
  if (action === 'get_series') return [{ series_id: 900, name: 'Show', category_id: 'series' }];
  if (action === 'get_series_info') return { info: {}, seasons: [{ season_number: 1, name: 'Season One' }],
    episodes: { '1': [{ id: 901, title: 'Pilot', episode_num: 1, container_extension: 'mp4' }] } };
  throw new Error('Unexpected Xtream fixture action: ' + action);
}

async function load(kit, config) {
  await kit.api.query('bootstrap');
  await kit.api.query('profiles.create', { name: 'Living room' });
  const saved = (await kit.api.query('sources.add', { config }))[0];
  await kit.api.query('sources.load', { id: saved.id });
  return saved;
}

test('canonical Xtream movie and episode reach the native LG player at the original URLs', async () => {
  const kit = harness(xtreamRoute);
  const source = await load(kit, { kind: 'xtream', label: 'Xtream',
    fields: { host: 'https://xtream.fixture/', username: 'fixture-user', password: 'fixture-pass' }, settings: {} });
  const movie = (await kit.api.query('catalog.items', { kind: 'movie', categoryId: 'movies', page: 1 })).items[0];
  const series = (await kit.api.query('catalog.items', { kind: 'series', categoryId: 'series', page: 1 })).items[0];
  const season = (await kit.api.query('media.children', { item: series })).items[0];
  const episode = (await kit.api.query('media.children', { item: season })).items[0];
  for (const item of [movie, episode]) {
    await kit.api.query('playback.play', { sourceId: source.id, item });
    assert.equal(kit.api.getState().playing, true);
    assert.equal(kit.api.getState().isLive, false);
    assert.equal(kit.api.getState().currentItem.id, item.id);
  }
  const expectedUrls = [
    'https://xtream.fixture/movie/fixture-user/fixture-pass/500.mkv',
    'https://xtream.fixture/series/fixture-user/fixture-pass/901.mp4'
  ];
  assert.deepEqual(kit.media.loaded, expectedUrls);
  assert.deepEqual(kit.checked, expectedUrls);
  assert.deepEqual(kit.resolved.map(stream => stream.url), expectedUrls);
  for (const [index, open] of kit.opens.entries()) {
    assert.equal(open.url, kit.resolved[index].url);
    assert.equal(open.options.headerPolicy, 'xtream-vod-default');
    assert.deepEqual(open.options.headers, { 'user-agent': defaultUserAgent });
    assert.deepEqual(kit.resolved[index].headers, open.options.headers);
    assert.equal(kit.resolved[index].headerPolicy, undefined, 'Canonical resolver data stays unchanged.');
  }
  assert.ok(kit.requests.every(request => new URL(request.url).pathname === '/player_api.php'),
    'The existing canonical API handles discovery; media playback loads its direct URL.');
});

test('an M3U movie with the same VLC header never receives the Xtream exception', async () => {
  const kit = harness(() => '#EXTM3U\n#EXTINF:-1 group-title="Movies",Film\n' +
    '#EXTVLCOPT:http-user-agent=' + defaultUserAgent + '\nhttps://streams.fixture/movie/500.mp4\n');
  const source = await load(kit, { kind: 'm3u', label: 'M3U', fields: { playlistUrl: 'https://playlist.fixture/list' }, settings: {} });
  const item = (await kit.api.query('catalog.items', { kind: 'movie', page: 1 })).items[0];
  await assert.rejects(kit.api.query('playback.play', { sourceId: source.id,
    item: { ...item, sourceKind: 'xtream', headerPolicy: 'xtream-vod-default' }, headerPolicy: 'xtream-vod-default' }),
  { name: 'NotSupportedError' });
  assert.equal(kit.opens[0].options.headerPolicy, undefined);
  assert.deepEqual(kit.opens[0].options.headers, { 'User-Agent': defaultUserAgent });
  assert.deepEqual(kit.media.loaded, []);
});

test('Stalker VOD keeps its required headers and is refused without the Xtream exception', async () => {
  const kit = harness(url => {
    const action = url.searchParams.get('action');
    if (action === 'handshake') return { js: { token: 'fixture-token' } };
    if (action === 'get_profile') return { js: { timezone: 'UTC' } };
    if (action === 'get_genres') return { js: [] };
    if (action === 'get_all_channels') return { js: { data: [] } };
    if (action === 'get_categories') return { js: [{ id: 'movies', title: 'Movies' }] };
    if (action === 'get_ordered_list') return { js: { data: [{ id: '500', name: 'Film',
      cmd: 'ffmpeg http://streams.fixture/vod/500.mp4', is_series: 0 }], total_items: 1, max_page_items: 14 } };
    if (action === 'create_link') return { js: { cmd: 'ffmpeg http://streams.fixture/result.mp4' } };
    throw new Error('Unexpected Stalker fixture action: ' + action);
  });
  const source = await load(kit, { kind: 'stalker', label: 'Stalker',
    fields: { portal: 'https://stalker.fixture/c/', mac: '00:11:22:33:44:55' }, settings: {} });
  const item = (await kit.api.query('catalog.items', { kind: 'movie', categoryId: 'movies', page: 1 })).items[0];
  await assert.rejects(kit.api.query('playback.play', { sourceId: source.id, item }), { name: 'NotSupportedError' });
  assert.equal(kit.opens[0].options.headerPolicy, undefined);
  assert.deepEqual(kit.opens[0].options.headers, kit.resolved[0].headers);
  assert.match(kit.opens[0].options.headers['user-agent'], /MAG200/);
  assert.deepEqual(kit.media.loaded, []);
});
