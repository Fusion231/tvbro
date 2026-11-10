'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const output = path.resolve(process.argv[2]);
const bytes = fs.readFileSync(path.join(output, 'core.js'));
const sandbox = {console, crypto: crypto.webcrypto, setTimeout, clearTimeout, TextEncoder, TextDecoder};
sandbox.window = sandbox;
sandbox.self = sandbox;
vm.createContext(sandbox);
vm.runInContext(bytes.toString('utf8'), sandbox);
const core = sandbox.TVBroCanonical;
assert.ok(core);
const cases = [];
function run(name, action) { action(); cases.push({name, passed: true}); }
run('canonical M3U variants, categories and EPG header', () => {
  const result = JSON.parse(core.parseM3u('#EXTM3U url-tvg="https://epg.invalid/a.xml"\n#EXTINF:-1 tvg-id="same" group-title="News",One\nhttps://example.invalid/live/1\n#EXTINF:-1 tvg-id="same" group-title="News",Two\nhttps://example.invalid/live/2\n'));
  assert.equal(result.channels.length, 2);
  assert.notEqual(result.channels[0].id, result.channels[1].id);
  assert.equal(result.headerEpgUrl, 'https://epg.invalid/a.xml');
  assert.equal(result.categories[0].title, 'News');
});
run('canonical Xtream archive flag and fallback window', () => {
  const channels = JSON.parse(core.mapXtreamLive(JSON.stringify([
    {stream_id: 3, name: 'Three', tv_archive: 1, tv_archive_duration: 0},
    {stream_id: 4, name: 'Four', tv_archive: 0, tv_archive_duration: 30},
  ])));
  assert.equal(channels[0].archiveDays, 7);
  assert.equal(channels[1].archiveDays, 0);
});
run('canonical media mapping', () => {
  const media = JSON.parse(core.mapXtreamMedia('[{"stream_id":8,"name":"Film","stream_icon":"https://example.invalid/poster.png"}]', 'movie'));
  assert.equal(media[0].id, '8');
  assert.equal(media[0].kind, 'movie');
});
run('canonical series progress retains more than a visible window of history', () => {
  const episodes=Array.from({length:130},(_,index)=>({id:'episode-'+index,title:'Episode '+index,
    kind:'episode',parentId:'season',seasonNumber:1,episodeNumber:index+1}));
  const positions=episodes.slice(0,126).map((item,index)=>({id:item.id,kind:'episode',
    position:index===125?180:1140,duration:1200,updatedAt:index+1}));
  const progress=JSON.parse(core.seriesProgress(JSON.stringify({episodes,positions})));
  assert.equal(progress.watchedCount,125);
  assert.equal(progress.latestEpisode.id,'episode-125');
  assert.equal(progress.nextEpisode.id,'episode-125');
  assert.equal(progress.latestPosition.position,180);
  assert.equal(progress.latestPosition.finished,false);
});
run('canonical series progress advances across seasons and keeps unknown duration resumable', () => {
  const episodes=[{id:'last',title:'Last',kind:'episode',parentId:'season-1',seasonNumber:1,episodeNumber:9},
    {id:'next',title:'Next',kind:'episode',parentId:'season-2',seasonNumber:2,episodeNumber:1}];
  let progress=JSON.parse(core.seriesProgress(JSON.stringify({episodes,positions:[
    {id:'last',kind:'episode',position:1140,duration:1200,updatedAt:20}]})));
  assert.equal(progress.nextEpisode.id,'next');
  progress=JSON.parse(core.seriesProgress(JSON.stringify({episodes,positions:[
    {id:'last',kind:'episode',position:3600,duration:0,updatedAt:20},
    {id:'next',kind:'movie',position:1140,duration:1200,updatedAt:30}]})));
  assert.equal(progress.watchedCount,0);
  assert.equal(progress.nextEpisode.id,'last');
});
run('canonical opaque M3U identifier', () => {
  const expected = 'm3u-channel:' + crypto.createHash('sha256').update('http://example.invalid/a').digest('hex');
  assert.equal(core.stableM3uChannelId('HTTP://EXAMPLE.INVALID:80/a#fragment'), expected);
});
run('canonical secure random source UUID', () => {
  const a = core.newSourceId(), b = core.newSourceId();
  assert.match(a, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.notEqual(a, b);
});
const config = JSON.stringify({fields:{host:'provider.invalid/',username:'user name',password:'p&x'},settings:{streamExtension:'m3u8'}});
run('canonical API URI expression encodes query credentials', () => {
  const uri = new URL(core.xtreamApiUrl(config, '{"action":"get_live_streams"}'));
  assert.equal(uri.origin, 'http://provider.invalid');
  assert.equal(uri.pathname, '/player_api.php');
  assert.equal(uri.searchParams.get('username'), 'user name');
  assert.equal(uri.searchParams.get('password'), 'p&x');
});
async function main() {
  const resolved = JSON.parse(await core.resolveXtream(config, '{"id":"9","name":"Channel","extra":{"streamId":"10"}}'));
  assert.equal(resolved.url, 'http://provider.invalid/live/user%20name/p%26x/10.m3u8');
  cases.push({name:'exact original async Xtream resolve body',passed:true});
  const m3u = JSON.parse(await core.resolveM3u('{"fields":{"userAgent":"Canonical-test"}}',
      '{"id":"one","name":"One","extra":{"url":"https://example.invalid/one.m3u8"}}'));
  assert.equal(m3u.url, 'https://example.invalid/one.m3u8');
  assert.equal(m3u.headers['User-Agent'], 'Canonical-test');
  assert.equal(m3u.isLive, true);
  cases.push({name:'exact original M3U resolve and user agent',passed:true});
  for (const fields of [{}, {userAgent:''}]) {
    const noAgent = JSON.parse(await core.resolveM3u(JSON.stringify({fields}),
        '{"id":"one","name":"One","extra":{"url":"https://example.invalid/one.m3u8"}}'));
    assert.deepEqual(noAgent.headers, {});
  }
  cases.push({name:'original SourceConfig._opt omits missing and empty user agent',passed:true});
  const whitespaceAgent = JSON.parse(await core.resolveM3u('{"fields":{"userAgent":"   "}}',
      '{"id":"one","name":"One","extra":{"url":"https://example.invalid/one.m3u8"}}'));
  assert.equal(whitespaceAgent.headers['User-Agent'], '   ');
  cases.push({name:'original SourceConfig._opt preserves nonempty whitespace verbatim',passed:true});
  assert.equal(await core.validateXtreamAuth('{"user_info":{"auth":1,"status":"Active","exp_date":"unlimited"}}'), true);
  await assert.rejects(core.validateXtreamAuth('{"user_info":{"auth":0}}'));
  await assert.rejects(core.validateXtreamAuth('{"user_info":{"auth":1,"status":"Disabled"}}'));
  await assert.rejects(core.validateXtreamAuth('{"user_info":{"auth":1,"exp_date":"946684800"}}'));
  cases.push({name:'canonical authentication positive flag, status and expiry guards',passed:true});
  const categories = JSON.parse(core.mapXtreamCategories('[{"category_id":7,"category_name":"News"}]'));
  assert.deepEqual(categories, [{id:'7',title:'News'}]);
  assert.deepEqual(JSON.parse(core.mapXtreamCategories('{}')), []);
  cases.push({name:'canonical categories after transport boundary',passed:true});
  const policy = JSON.parse(core.networkPolicy('playlist'));
  assert.equal(policy.maximumBodyBytes, 128 * 1024 * 1024);
  assert.equal(policy.maximumDecodedBytes, 256 * 1024 * 1024);
  assert.equal(policy.totalTimeoutMs, 5 * 60 * 1000);
  assert.equal(JSON.parse(core.networkPolicy('provider-json')).totalTimeoutMs, 3 * 60 * 1000);
  cases.push({name:'canonical HTTP workload policies',passed:true});
  const series={id:'demo-series-1',title:'Codec Test Series',kind:'series'};
  const makeSeriesSource=()=>core.createSource(JSON.stringify({id:'series-progress',kind:'demo',fields:{},settings:{}}),
    async()=>{throw Error('Demo series must not use the network');});
  let seriesSource=makeSeriesSource();
  const invokeSeries=async(method,args={})=>JSON.parse(await seriesSource.invoke(method,JSON.stringify(args)));
  try {
    await invokeSeries('categories');await invokeSeries('channels');
    const seasons=await invokeSeries('mediaItems',{kind:'season',parent:series});
    let progress=await invokeSeries('seriesProgress',{item:series,positions:[]});
    assert.equal(progress.latestEpisode,null);assert.equal(progress.nextEpisode,null);
    let envelope=JSON.parse(await invokeSeries('exportCatalog',{scope:'series-test'}));
    assert.equal(JSON.parse(envelope.payload).reads.some(read=>read.args.kind==='episode'),false,
      'An untouched series must leave every episode catalog lazy');
    const firstSeason=await invokeSeries('mediaItems',{kind:'episode',parent:seasons[0]});
    const positions=firstSeason.map((item,index)=>({id:item.id,kind:'episode',position:1140,duration:1200,updatedAt:index+1,item}));
    progress=await invokeSeries('seriesProgress',{item:series,positions});
    assert.equal(progress.watchedCount,3);assert.equal(progress.nextEpisode.seasonNumber,2);
    assert.equal(progress.nextEpisode.episodeNumber,1);assert.equal(progress.complete,false);
    envelope=JSON.parse(await invokeSeries('exportCatalog',{scope:'series-test'}));
    const partial=JSON.parse(envelope.payload);
    for(const read of partial.reads) {
      if(read.method==='mediaItems'&&read.args.kind==='episode'&&read.args.parent.id===seasons[0].id) {
        read.method='mediaItemsPage';read.args.page=1;read.value={items:read.value,page:1,totalPages:2};
      }
    }
    envelope.payload=JSON.stringify(partial);envelope.checksum=crypto.createHash('sha256').update(envelope.payload).digest('hex');
    assert.equal((await invokeSeries('importCatalog',{scope:'series-test',snapshot:JSON.stringify(envelope)})).fromCache,true);
    progress=await invokeSeries('seriesProgress',{item:series,positions});
    assert.equal(progress.nextEpisode,null,'A partial current season must block a cached later season');
    assert.equal(progress.complete,false);
    const gap=JSON.parse(envelope.payload);
    gap.reads=gap.reads.flatMap(read=>read.method==='mediaItemsPage'&&read.args.kind==='episode'&&read.args.parent.id===seasons[0].id
      ?[1,3].map(page=>({...read,args:{...read.args,page},value:{items:[firstSeason[page-1]],page,totalPages:3}})):[read]);
    envelope.payload=JSON.stringify(gap);envelope.checksum=crypto.createHash('sha256').update(envelope.payload).digest('hex');
    assert.equal((await invokeSeries('importCatalog',{scope:'series-test',snapshot:JSON.stringify(envelope)})).fromCache,true);
    progress=await invokeSeries('seriesProgress',{item:series,positions:positions.slice(0,1)});
    assert.equal(progress.watchedCount,1);assert.equal(progress.nextEpisode,null,
      'An unloaded second page must block a same-season jump from page 1 to page 3');
    progress=await invokeSeries('seriesProgress',{item:series,positions:[positions[0],{...positions[2],position:180,updatedAt:30}]});
    assert.equal(progress.watchedCount,1);assert.equal(progress.latestEpisode.id,firstSeason[2].id);
    assert.equal(progress.nextEpisode.id,firstSeason[2].id,'A cached later-page unfinished episode remains resumable');
    progress=await invokeSeries('seriesProgress',{item:series,positions:[positions[0],{...positions[2],updatedAt:30}]});
    assert.equal(progress.watchedCount,2);assert.equal(progress.complete,false,
      'Missing pages do not discard watched history or establish completion');
    await seriesSource.dispose();seriesSource=makeSeriesSource();
    await invokeSeries('mediaItems',{kind:'season',parent:series});
    progress=await invokeSeries('seriesProgress',{item:series,positions:positions.slice(0,1)});
    assert.equal(progress.watchedCount,1);
    assert.equal(progress.latestEpisode.id,'bbb');assert.equal(progress.nextEpisode.id,'bipbop');
    cases.push({name:'canonical series cache laziness, cross-season continuation, missing-page guards and restart history',passed:true});
  } finally { await seriesSource.dispose(); }
  let es5 = null;
  let parser = 'Node bundled Acorn';
  try {
    const acorn = require('internal/deps/acorn/acorn/dist/acorn');
    try {acorn.parse(bytes.toString('utf8'), {ecmaVersion:5}); es5={passed:true};}
    catch(error) {es5={passed:false,error:String(error.message)};}
  } catch(error) {es5={passed:null,error:'Bundled Acorn unavailable'};}
  const report = {schemaVersion:1,status:'compiled_original_core_functional_checks_passed',
    tests:cases,jsSha256:crypto.createHash('sha256').update(bytes).digest('hex'),
    legacySyntax:{parser,ecma5:es5},runtime:'Node VM with explicit browser globals and WebCrypto',
    chrome47DeviceRuntimeQualified:false};
  fs.writeFileSync(path.join(output,'core-test.json'), JSON.stringify(report,null,2));
  console.log(JSON.stringify(report,null,2));
}
main().catch(error=>{console.error(error);process.exitCode=1;});
