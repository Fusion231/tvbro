'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const build = JSON.parse(fs.readFileSync(path.join(__dirname, '../../output/samsung-web/latest-build.json')));
const payload = process.env.TVBRO_SAMSUNG_TEST_PAYLOAD || build.payload;

function fixture(route) {
  const sandbox = {console, crypto: crypto.webcrypto, setTimeout, clearTimeout, TextEncoder, TextDecoder};
  sandbox.window = sandbox; sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(payload, 'canonical-core.js'), 'utf8'), sandbox);
  const requests = [];
  const source = sandbox.TVBroCanonical.createSource(JSON.stringify({id: 'mapping-fixture', kind: 'm3u', label: 'Mapping',
    fields: {playlistUrl: 'https://mapping.fixture/list', epgUrl: 'https://mapping.fixture/guide'}}), async raw => {
    const request = JSON.parse(raw); requests.push(request);
    const body = route ? await route(request) : response(request);
    return JSON.stringify({status: 200, url: request.url, body, headers: {}, decoded: true});
  });
  return {source, requests, invoke: async (method, args = {}) => JSON.parse(await source.invoke(method, JSON.stringify(args)))};
}

function response(request) {
  if (request.url.endsWith('/list')) return '#EXTM3U\n#EXTINF:-1 tvg-id="alpha" group-title="TV",Alpha\nhttps://streams.fixture/live/a.ts\n';
  return '<?xml version="1.0"?><tv><channel id="alpha"><display-name>Alpha</display-name></channel>' +
    '<channel id="manual"><display-name>Manual choice</display-name></channel>' +
    ['alpha', 'manual'].map(id => '<programme channel="' + id + '" start="20261020100000 +0000" stop="20261020110000 +0000"><title>' + id + '</title></programme>').join('') + '</tv>';
}

test('manual EPG binding changes cached results, resets to automatic and preserves guide download reuse', async () => {
  const kit = fixture();
  try {
    await kit.invoke('connect');
    const channels = await kit.invoke('channels');
    assert.deepEqual((await kit.invoke('epg', {channels})).map(row => row.title), ['alpha']);
    const choices = await kit.invoke('epgMapping.get', {query: 'manual', limit: 1});
    assert.equal(choices.available, true); assert.equal(choices.channels.length, 1);
    const choice = choices.channels[0];
    assert.equal(choice.name, 'Manual choice'); assert.match(choice.guideId, /^[a-f0-9]{64}$/);
    const overrides = [{channelId: channels[0].id, guideId: choice.guideId, guideChannelId: choice.channelId, offsetMinutes: 60}];
    const first = await kit.invoke('epgMapping.set', {overrides});
    assert.equal((await kit.invoke('epgMapping.set', {overrides})).revision, first.revision);
    const mapped = await kit.invoke('epg', {channels});
    assert.deepEqual(mapped.map(row => row.title), ['manual']);
    assert.equal(mapped[0].start, '2026-10-20T10:00:00.000Z', 'The library applies offsets once, outside the raw Source bridge.');
    await kit.invoke('epgMapping.set', {overrides: []});
    assert.deepEqual((await kit.invoke('epg', {channels})).map(row => row.title), ['alpha']);
    assert.equal(kit.requests.filter(row => row.url.endsWith('/guide')).length, 1);
    for (const overrides of [
      [{channelId: channels[0].id, guideId: choice.guideId}],
      [{channelId: channels[0].id, offsetMinutes: 1441}],
      [{channelId: channels[0].id}, {channelId: channels[0].id}],
    ]) await assert.rejects(kit.invoke('epgMapping.set', {overrides}));
  } finally { await kit.source.dispose(); }
});

test('mapping catalogue and mapped programmes survive the existing bounded catalog snapshot', async () => {
  const first = fixture();
  let snapshot, channels, overrides;
  try {
    await first.invoke('connect'); await first.invoke('categories');
    channels = await first.invoke('channels');
    await first.invoke('epg', {channels});
    const choice = (await first.invoke('epgMapping.get', {query: 'manual'})).channels[0];
    overrides = [{channelId: channels[0].id, guideId: choice.guideId, guideChannelId: choice.channelId}];
    await first.invoke('epgMapping.set', {overrides});
    await first.invoke('epg', {channels});
    snapshot = await first.invoke('exportCatalog', {scope: 'local:owner'});
  } finally { await first.source.dispose(); }
  const second = fixture(() => { throw new Error('Offline: restored guide should not download.'); });
  try {
    assert.ok(await second.invoke('importCatalog', {scope: 'local:owner', snapshot}));
    assert.equal((await second.invoke('epgMapping.get', {query: 'manual'})).channels[0].name, 'Manual choice');
    await second.invoke('epgMapping.set', {overrides});
    assert.deepEqual((await second.invoke('epg', {channels})).map(row => row.title), ['manual']);
    assert.equal(second.requests.length, 0);
  } finally { await second.source.dispose(); }
});

test('changing a mapping while a guide is loading cancels its obsolete result', async () => {
  let release, reached;
  const waiting = new Promise(resolve => { reached = resolve; });
  const kit = fixture(async request => {
    if (request.url.endsWith('/guide')) {
      reached(); await new Promise(resolve => { release = resolve; });
    }
    return response(request);
  });
  try {
    await kit.invoke('connect'); const channels = await kit.invoke('channels');
    const pending = kit.invoke('epg', {channels});
    const cancelled = assert.rejects(pending);
    await waiting;
    await kit.invoke('epgMapping.set', {overrides: [{channelId: channels[0].id, offsetMinutes: 30}]});
    release(); await cancelled;
  } finally { if (release) release(); await kit.source.dispose(); }
});
