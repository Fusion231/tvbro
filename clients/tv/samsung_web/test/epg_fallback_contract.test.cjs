'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const output = path.resolve(__dirname, '../../output/samsung-web');

function fixture(xmltvStatus = 502, apiStatus = 200) {
  const build = JSON.parse(fs.readFileSync(path.join(output, 'latest-build.json')));
  const sandbox = {console, setTimeout, clearTimeout, TextEncoder, TextDecoder};
  sandbox.self = sandbox.window = sandbox;
  vm.createContext(sandbox);
  for (const file of ['polyfills.js', 'canonical-core.js']) {
    vm.runInContext(fs.readFileSync(path.join(build.payload, file), 'utf8'), sandbox);
  }
  const calls = [];
  const config = {id:'epg',kind:'xtream',label:'Fixture',fields:{host:'https://fixture.invalid',username:'user',password:'pass'}};
  const transport = async raw => {
    const request = JSON.parse(raw), url = new URL(request.url);
    calls.push({path:url.pathname,id:url.searchParams.get('stream_id'),at:Date.now()});
    if (url.pathname === '/xmltv.php') return JSON.stringify(xmltvStatus === 'limit'
      ? {errorKind:'limit',error:'Guide too large'}
      : {status:xmltvStatus,body:xmltvStatus === 200 ? '<tv></tv>' : 'unavailable',headers:{}});
    assert.equal(url.searchParams.get('action'), 'get_short_epg');
    return JSON.stringify({status:apiStatus,headers:{},body:JSON.stringify({epg_listings:[{
      start_timestamp:'1792962000',stop_timestamp:'1792965600',
      title:Buffer.from('Wiadomości').toString('base64'),description:Buffer.from('Opis').toString('base64')
    }]})});
  };
  return {calls, create:() => sandbox.TVBroCanonical.createSource(JSON.stringify(config), transport)};
}
const channels = [{id:'1',name:'One',extra:{}},{id:'2',name:'Two',extra:{}}];
async function invoke(source, method, args) { return JSON.parse(await source.invoke(method, JSON.stringify(args))); }

for (const failure of [502, 'limit']) test('actual Samsung core falls back after '+failure+', rate limits and reuses durable per-channel cache', async () => {
  const kit = fixture(failure), source = kit.create();
  try {
    const first = await invoke(source, 'epg', {channels});
    assert.equal(first.length, 2); assert.equal(first[0].title, 'Wiadomości');
    assert.deepEqual(kit.calls.map(c => c.path), ['/xmltv.php','/player_api.php','/player_api.php']);
    assert.ok(kit.calls[2].at - kit.calls[1].at >= 950);
    await invoke(source, 'epg', {channels:channels.slice().reverse()});
    assert.equal(kit.calls.length, 3, 'overlapping windows must not refetch channels or XMLTV');
    const snapshot = await invoke(source, 'exportGuide', {scope:'profile'});
    const restarted = kit.create();
    try {
      assert.equal(await invoke(restarted, 'importGuide', {scope:'profile',snapshot}), true);
      const restored = await invoke(restarted, 'epg', {channels});
      assert.equal(restored.length, 2);
      assert.equal(kit.calls.length, 3, 'restart must not re-download cached programmes');
    } finally { await restarted.dispose(); }
  } finally { await source.dispose(); }
});

for (const status of [401,403,429]) test('Samsung core does not use fallback after HTTP '+status, async () => {
  const kit=fixture(status),source=kit.create();
  try {
    const result=await invoke(source,'epg',{channels});
    assert.equal(result.status,status); assert.equal(kit.calls.length,1);
  } finally {await source.dispose();}
});

test('successful XMLTV never probes per-channel API', async () => {
  const kit=fixture(200),source=kit.create();
  try {assert.deepEqual(await invoke(source,'epg',{channels}),[]);assert.equal(kit.calls.length,1);}
  finally {await source.dispose();}
});

test('hardware budget does not change the guide refusal cache key or retry deadline', async () => {
  const kit=fixture(429),source=kit.create();
  try {
    const first=await invoke(source,'epg',{channels,_tvEpgMaximumBytes:48*1024*1024});
    assert.equal(first.status,429); assert.ok(first.retryAt>Date.now());
    const second=await invoke(source,'epg',{channels,_tvEpgMaximumBytes:32*1024*1024});
    assert.equal(second.retryAt,first.retryAt); assert.equal(kit.calls.length,1);
  } finally {await source.dispose();}
});

test('failed channel API stops after one request and pauses other windows', async () => {
  const kit=fixture(502,502),source=kit.create();
  try {
    const result=await invoke(source,'epg',{channels});
    assert.equal(result.status,502); assert.equal(kit.calls.length,2);
    await invoke(source,'epg',{channels:[{id:'3',name:'Three',extra:{}}]});
    assert.equal(kit.calls.length,2,'no API retry or fan-out after refusal');
  } finally {await source.dispose();}
});
