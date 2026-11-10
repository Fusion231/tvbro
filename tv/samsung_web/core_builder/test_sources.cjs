'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const assert = require('node:assert/strict');
const output = path.resolve(process.argv[2]);
const bytes = fs.readFileSync(path.join(output, 'core.js'));
const sandbox = {console, crypto:crypto.webcrypto, setTimeout, clearTimeout, TextEncoder, TextDecoder};
sandbox.window = sandbox; sandbox.self = sandbox;
vm.createContext(sandbox);
vm.runInContext(bytes.toString('utf8'), sandbox, {filename:'compiled-original-core.js'});
const core = sandbox.TVBroCanonical;
const checks = [];
function fixture(config, route) {
  const requests = [];
  const source = core.createSource(JSON.stringify(config), async text => {
    const request = JSON.parse(text), url = new URL(request.url);
    requests.push(request);
    const result = await route(url, request);
    if (result && result.rawResponse) return JSON.stringify(result.rawResponse);
    return JSON.stringify({status:200, body:typeof result === 'string' ? result : JSON.stringify(result),
      url:request.url, headers:{}, decoded:true});
  });
  return {requests, source, invoke:async (method,args={}) => JSON.parse(await source.invoke(method,JSON.stringify(args)))};
}
async function check(name, action) { await action(); checks.push({name,passed:true}); }
const programme = {channelId:'11', title:'Fixture programme', start:'2026-10-20T10:00:00.000Z', stop:'2026-10-20T10:30:00.000Z'};
const xml = (channels, programmes) => '<?xml version="1.0"?><tv>'+channels+programmes+'</tv>';
const guideChannel = (id,name) => '<channel id="'+id+'"><display-name>'+name+'</display-name></channel>';
const guideProgramme = (id,title) => '<programme channel="'+id+'" start="20261020100000 +0000" stop="20261020103000 +0000"><title>'+title+'</title><desc>Guide fixture</desc></programme>';

async function main() {
  await check('catalog cache identity excludes only the label and retains owner and connection binding', async () => {
    const base={id:'cache-identity',kind:'m3u',label:'Before',fields:{playlistUrl:'https://cache-identity.fixture/list'},settings:{streamExtension:'m3u8'}};
    const before=fixture(base,()=>''), renamed=fixture({...base,label:'After'},()=>''), changed=fixture({...base,fields:{...base.fields,playlistUrl:'https://other.fixture/list'}},()=>{});
    try {
      assert.equal(await before.invoke('cacheKey',{scope:'profile-a'}),await renamed.invoke('cacheKey',{scope:'profile-a'}));
      assert.notEqual(await before.invoke('legacyCacheKey',{scope:'profile-a'}),await renamed.invoke('legacyCacheKey',{scope:'profile-a'}));
      assert.notEqual(await before.invoke('cacheKey',{scope:'profile-a'}),await before.invoke('cacheKey',{scope:'profile-b'}));
      assert.notEqual(await before.invoke('cacheKey',{scope:'profile-a'}),await changed.invoke('cacheKey',{scope:'profile-a'}));
    } finally { await Promise.all([before.source.dispose(),renamed.source.dispose(),changed.source.dispose()]); }
  });

  await check('legacy catalog and guide snapshots import only with their exact prior configuration', async () => {
    const config={id:'legacy-cache',kind:'m3u',label:'Before rename',fields:{playlistUrl:'https://legacy-cache.fixture/list'},settings:{}};
    const first=fixture(config,()=> '#EXTM3U\n#EXTINF:-1 group-title="News",Legacy channel\nhttps://streams.fixture/legacy.ts\n');
    let snapshot, guideSnapshot, legacyKey, legacyGuideKey;
    try {
      await first.invoke('categories'); await first.invoke('channels');
      snapshot=await first.invoke('exportCatalog',{scope:'local:owner'});
      guideSnapshot=await first.invoke('exportGuide',{scope:'local:owner'});
      legacyKey=await first.invoke('legacyCacheKey',{scope:'local:owner'});
      legacyGuideKey=await first.invoke('legacyGuideCacheKey',{scope:'local:owner'});
    } finally { await first.source.dispose(); }
    const catalogEnvelope=JSON.parse(snapshot);catalogEnvelope.key=legacyKey;
    catalogEnvelope.checksum=crypto.createHash('sha256').update(catalogEnvelope.payload).digest('hex');
    const guideEnvelope=JSON.parse(guideSnapshot);guideEnvelope.key=legacyGuideKey;
    guideEnvelope.checksum=crypto.createHash('sha256').update(guideEnvelope.payload).digest('hex');
    const same=fixture(config,()=>{throw new Error('A restored legacy snapshot must not request the provider.');});
    const otherScope=fixture(config,()=>{throw new Error('A legacy key from another owner must be rejected.');});
    const otherSource=fixture({...config,fields:{playlistUrl:'https://other.fixture/list'}},()=>{throw new Error('A legacy key from another source must be rejected.');});
    try {
      assert.equal((await same.invoke('importCatalog',{scope:'local:owner',snapshot:JSON.stringify(catalogEnvelope)})).fromCache,true);
      assert.equal(await same.invoke('importGuide',{scope:'local:owner',snapshot:JSON.stringify(guideEnvelope)}),true);
      assert.equal(JSON.parse(await same.invoke('exportCatalog',{scope:'local:owner'})).key,await same.invoke('cacheKey',{scope:'local:owner'}));
      assert.equal(await otherScope.invoke('importCatalog',{scope:'local:other',snapshot:JSON.stringify(catalogEnvelope)}),null);
      assert.equal(await otherSource.invoke('importCatalog',{scope:'local:owner',snapshot:JSON.stringify(catalogEnvelope)}),null);
      assert.equal(same.requests.length,0);
    } finally { await Promise.all([same.source.dispose(),otherScope.source.dispose(),otherSource.source.dispose()]); }
  });

  await check('M3U durable catalog restores unvisited VOD and series without another playlist download', async () => {
    const config={id:'durable-m3u',kind:'m3u',fields:{playlistUrl:'https://durable-m3u.fixture/list'},settings:{}};
    const first=fixture(config,()=> '#EXTM3U\n#EXTINF:-1 group-title="TV",Live\nhttps://streams.fixture/live/1.ts\n'+
      '#EXTINF:-1 group-title="Films",Movie\nhttps://streams.fixture/movie/2.mp4\n'+
      '#EXTINF:-1 group-title="Shows",Show S01 E02\nhttps://streams.fixture/series/3.mp4\n'+
      '#EXTINF:-1 group-title="Shows",Show S01 E01\nhttps://streams.fixture/series/4.mp4\n');
    let snapshot;
    try {
      await first.invoke('categories'); await first.invoke('channels');
      snapshot=await first.invoke('exportCatalog',{scope:'profile'});
      assert.equal(typeof snapshot,'string');
    } finally { await first.source.dispose(); }
    const second=fixture(config,()=>{throw new Error('Restored catalog must not fetch another playlist');});
    try {
      assert.equal((await second.invoke('importCatalog',{scope:'profile',snapshot})).fromCache,true);
      assert.equal((await second.invoke('channels')).length,1);
      assert.equal((await second.invoke('mediaCategories',{kind:'movie'}))[0].title,'Films');
      const movies=await second.invoke('allMediaItems',{kind:'movie'}), series=await second.invoke('allMediaItems',{kind:'series'});
      assert.equal(movies.length,1); assert.equal(series.length,1);
      const seasons=await second.invoke('mediaItems',{kind:'season',parent:series[0]});
      const episodes=await second.invoke('mediaItems',{kind:'episode',parent:seasons[0]});
      assert.deepEqual(episodes.map(item=>item.episodeNumber),[1,2]);
      assert.equal((await second.invoke('resolveMedia',{item:episodes[0]})).url,'https://streams.fixture/series/4.mp4');
      assert.equal(second.requests.length,0);
      const envelope=JSON.parse(snapshot), payload=JSON.parse(envelope.payload);
      delete payload.hints.media;
      envelope.payload=JSON.stringify(payload); envelope.checksum=crypto.createHash('sha256').update(envelope.payload).digest('hex');
      assert.equal(await second.invoke('importCatalog',{scope:'profile',snapshot:JSON.stringify(envelope)}),null,
        'legacy incomplete M3U snapshots require a fresh catalog');
      assert.equal((await second.invoke('allMediaItems',{kind:'movie'})).length,1,'invalid restore does not replace valid state');
    } finally { await second.source.dispose(); }
  });
  await check('guide memory allowance is bounded and isolated to each source invocation', async () => {
    const config={id:'guide-budget',kind:'m3u',fields:{playlistUrl:'https://budget.fixture/list',epgUrl:'https://budget.fixture/guide'},settings:{}};
    for (const [requested,expected] of [[undefined,32],[48*1024*1024,48],[64*1024*1024,64],[512*1024*1024,32],['67108864',32]]) {
      const kit=fixture(config,url=>url.pathname==='/list'?'#EXTM3U\n#EXTINF:-1 tvg-id="alpha",Alpha\nhttps://streams.fixture/live/1.ts\n':
        xml(guideChannel('alpha','Alpha'),guideProgramme('alpha','Guide')));
      try {
        const channels=await kit.invoke('channels');
        await kit.invoke('epg',{channels,_tvEpgMaximumBytes:requested});
        const request=kit.requests.find(request=>request.workload==='epg');
        assert.equal(request.maximumBodyBytes,expected*1024*1024);
        assert.equal(request.maximumDecodedBytes,expected*1024*1024);
      } finally { await kit.source.dispose(); }
    }
  });
  await check('mixed M3U shares one local catalog across Live, movies and series', async () => {
    const kit=fixture({id:'mixed-m3u',kind:'m3u',fields:{playlistUrl:'https://mixed-m3u.fixture/list'},settings:{}}, () =>
      '#EXTM3U\n#EXTINF:-1 group-title="TV",Live\nhttps://streams.fixture/live/1.ts\n'+
      '#EXTINF:-1 group-title="Films",Movie\n#EXTVLCOPT:http-user-agent=Fixture Agent\nhttps://streams.fixture/movie/2.mp4\n'+
      '#EXTINF:-1 group-title="Shows",Show S01 E02\nhttps://streams.fixture/series/3.mp4\n'+
      '#EXTINF:-1 group-title="Shows",Show S01 E01\nhttps://streams.fixture/series/4.mp4\n');
    try {
      const [channels,movies,series]=await Promise.all([
        kit.invoke('channels'),kit.invoke('allMediaItems',{kind:'movie'}),kit.invoke('allMediaItems',{kind:'series'})]);
      assert.equal(channels.length,1); assert.equal(movies.length,1); assert.equal(series.length,1);
      const seasons=await kit.invoke('mediaItems',{kind:'season',parent:series[0]});
      const episodes=await kit.invoke('mediaItems',{kind:'episode',parent:seasons[0]});
      assert.deepEqual(episodes.map(e=>e.episodeNumber),[1,2]);
      const movie=await kit.invoke('resolveMedia',{item:movies[0]});
      const episode=await kit.invoke('resolveMedia',{item:episodes[0]});
      assert.equal(movie.isLive,false); assert.equal(episode.isLive,false);
      assert.equal(movie.headers['User-Agent'],'Fixture Agent');
      assert.equal(kit.requests.length,1);
    } finally { await kit.source.dispose(); }
  });
  await check('a cache-only miss never defers the following real guide refresh', async () => {
    const config={id:'partial-guide',kind:'m3u',fields:{playlistUrl:'https://partial-playlist.fixture/list',
      epgUrl:'https://partial-primary.fixture/guide',epgUrls:'https://partial-extra.fixture/guide'},settings:{}};
    const route=url=>url.host==='partial-playlist.fixture'?'#EXTM3U\n#EXTINF:-1 tvg-id="alpha",Alpha\nhttps://streams.fixture/alpha.ts\n#EXTINF:-1 tvg-id="beta",Beta\nhttps://streams.fixture/beta.ts\n':
      url.host==='partial-primary.fixture'?xml(guideChannel('alpha','Alpha'),guideProgramme('alpha','Primary')):
        xml(guideChannel('beta','Beta'),guideProgramme('beta','Supplement'));
    const first=fixture(config,route);let snapshot,catalogue,channels;
    try {
      await first.invoke('categories');channels=await first.invoke('channels');await first.invoke('epg',{channels});
      catalogue=await first.invoke('exportCatalog',{scope:'profile'});
      const envelope=JSON.parse(await first.invoke('exportGuide',{scope:'profile'})),payload=JSON.parse(envelope.payload);
      payload.entries=payload.entries.filter(row=>!Buffer.from(row.bytes,'base64').toString().includes('Supplement'));
      envelope.payload=JSON.stringify(payload);envelope.checksum=crypto.createHash('sha256').update(envelope.payload).digest('hex');
      snapshot=JSON.stringify(envelope);
    } finally {await first.source.dispose();}
    const restarted=fixture(config,route);
    try {
      assert.equal((await restarted.invoke('importCatalog',{scope:'profile',snapshot:catalogue})).fromCache,true);
      assert.equal(await restarted.invoke('importGuide',{scope:'profile',snapshot}),true);
      const args={channels,from:'2026-10-20T09:00:00.000Z',to:'2026-10-20T12:00:00.000Z'};
      await restarted.invoke('epgCached',args);
      assert.equal(restarted.requests.length,0,'cached-only reads never contact the provider');
      const after=JSON.parse(JSON.parse(await restarted.invoke('exportGuide',{scope:'profile'})).payload);
      assert.deepEqual(after.failures,{},'a missing saved feed is not a provider failure');
      assert.deepEqual((await restarted.invoke('epg',args)).map(row=>row.title).sort(),['Primary','Supplement']);
      assert.equal(restarted.requests.length,1,'the missing feed remains eligible for its real request');
    } finally {await restarted.source.dispose();}
  });
  await check('original M3U SourceConfig, parsing/cache, catch-up and multi-guide gzip/XMLTV merge', async () => {
    const primary = xml(guideChannel('alpha','Alpha'),guideProgramme('alpha','Primary'));
    const extra = xml(guideChannel('other-alpha','Alpha')+guideChannel('other-beta','Beta'),
      guideProgramme('other-alpha','Must not replace primary')+guideProgramme('other-beta','Supplement'));
    const kit = fixture({id:'m3u-source',kind:'m3u',label:'Canonical M3U',
      fields:{playlistUrl:'https://playlist.fixture/list.m3u',epgUrls:'https://extra-guide.fixture/guide.xml\nhttps://extra-guide.fixture/guide.xml',userAgent:''},
      settings:{catchupTimezone:'UTC',catchupMaxDays:3}}, (url,request) => {
      if(url.host==='playlist.fixture') {
        assert.equal(request.workload,'playlist');
        return '#EXTM3U url-tvg="https://primary-guide.fixture/guide.xml.gz"\n'+
          '#EXTINF:-1 tvg-id="alpha" group-title="News" catchup="default" catchup-days="7" catchup-source="https://streams.fixture/archive?start={start}&end={end}",Alpha FHD\nhttps://streams.fixture/alpha.m3u8\n'+
          '#EXTINF:-1 tvg-id="beta" group-title="News",Beta\nhttps://streams.fixture/beta.m3u8\n';
      }
      assert.equal(request.workload,'epg');
      if(url.host==='primary-guide.fixture')return {rawResponse:{status:200,bodyBase64:zlib.gzipSync(primary).toString('base64'),url:url.href,headers:{'content-encoding':'gzip'}}};
      if(url.host==='extra-guide.fixture')return extra;
      throw Error('Unexpected synthetic request '+url);
    });
    assert.equal((await kit.invoke('capabilities')).epg,'supported');
    await kit.invoke('connect');
    const channels = await kit.invoke('channels');
    assert.equal(channels.length,2);
    assert.equal((await kit.invoke('categories')).length,1);
    assert.equal(kit.requests.filter(r=>r.workload==='playlist').length,1);
    const stream = await kit.invoke('resolve',{channel:channels[0]});
    assert.equal(stream.url,'https://streams.fixture/alpha.m3u8');
    assert.deepEqual(stream.headers,{});
    const archive = await kit.invoke('resolveArchive',{channel:channels[0],programme:{...programme,channelId:channels[0].id}});
    assert.equal(new URL(archive.url).searchParams.get('start'),'1792490400');
    assert.equal(archive.isLive,false);
    const guide = await kit.invoke('epg',{channels});
    assert.deepEqual(guide.map(p=>p.title).sort(),['Primary','Supplement']);
    assert.equal(kit.requests.filter(r=>r.url.includes('extra-guide')).length,1);
    assert.equal(guide[0].start,'2026-10-20T10:00:00.000Z');
    assert.equal((await kit.invoke('capabilities')).catchupCapability.maxArchiveWindowMs,3*86400000);
    await kit.source.dispose();
    await assert.rejects(kit.invoke('channels'));
  });

  await check('original Xtream authentication sharing, VOD paging/search/detail, series hierarchy and finite resolves', async () => {
    const kit = fixture({id:'xtream-source',kind:'xtream',label:'Canonical Xtream',
      fields:{host:'https://xtream.fixture/',username:'fixture-user',password:'fixture-pass'},
      settings:{streamExtension:'m3u8',catchupTimezone:'UTC'}}, url => {
      assert.equal(url.searchParams.get('username'),'fixture-user');
      const action=url.searchParams.get('action');
      if(!action)return {user_info:{auth:1,status:'Active',exp_date:'4102444800',max_connections:'2',active_cons:'0'},server_info:{timezone:'UTC'}};
      if(action==='get_live_categories')return [{category_id:7,category_name:'News'}];
      if(action==='get_live_streams')return [{stream_id:11,name:'Live',category_id:7,epg_channel_id:'live-guide',tv_archive:1,tv_archive_duration:2}];
      if(action==='get_vod_categories')return [{category_id:'movies',category_name:'Movies'}];
      if(action==='get_series_categories')return [{category_id:'series',category_name:'Series'}];
      if(action==='get_vod_streams')return Array.from({length:15},(_,i)=>({stream_id:500+i,name:'Film '+i,category_id:'movies',container_extension:'mkv'}));
      if(action==='get_series')return [{series_id:900,name:'Series',category_id:'series'}];
      if(action==='get_vod_info')return {info:{plot:'Original detail',movie_image:'https://images.fixture/film.png'},movie_data:{}};
      if(action==='get_series_info')return {info:{plot:'Series detail'},seasons:[{season_number:1,name:'Season One'}],episodes:{'1':[
        {id:901,title:'Pilot',episode_num:1,container_extension:'mp4',info:{duration_secs:'120'}}]}};
      throw Error('Unexpected fixture action '+action);
    });
    await Promise.all([kit.invoke('connect'),kit.invoke('connect')]);
    assert.equal(kit.requests.length,1);
    assert.equal((await kit.invoke('categories'))[0].title,'News');
    const channel=(await kit.invoke('channels'))[0];
    assert.equal(channel.archiveDays,2);
    const first=await kit.invoke('mediaItemsPage',{kind:'movie',categoryId:'movies',page:1});
    assert.equal(first.items.length,14); assert.equal(first.hasMore,true);
    const second=await kit.invoke('mediaItemsPage',{kind:'movie',categoryId:'movies',page:2});
    assert.equal(second.items.length,1);
    assert.equal(kit.requests.filter(r=>r.url.includes('get_vod_streams')).length,1);
    assert.equal((await kit.invoke('searchMedia',{kind:'movie',query:'Film 14',categoryId:'movies'})).length,1);
    const movie=await kit.invoke('mediaDetails',{item:first.items[0]});
    assert.equal(movie.description,'Original detail');
    const vod=await kit.invoke('resolveMedia',{item:movie});
    assert.equal(vod.url,'https://xtream.fixture/movie/fixture-user/fixture-pass/500.mkv');
    assert.equal(vod.isLive,false); assert.equal(vod.providerAccount.maximumStreams,2);
    const series=(await kit.invoke('mediaItemsPage',{kind:'series',categoryId:'series',page:1})).items[0];
    const detailedSeries=await kit.invoke('mediaDetails',{item:series});
    const season=(await kit.invoke('mediaItemsPage',{kind:'season',parent:detailedSeries})).items[0];
    assert.equal(season.title,'Season One');
    const episode=(await kit.invoke('mediaItemsPage',{kind:'episode',parent:season})).items[0];
    assert.equal(episode.title,'Pilot'); assert.equal(episode.durationSeconds,120);
    assert.equal((await kit.invoke('resolveMedia',{item:episode})).url,'https://xtream.fixture/series/fixture-user/fixture-pass/901.mp4');
    const archive=await kit.invoke('resolveArchive',{channel,programme});
    assert.equal(archive.url,'https://xtream.fixture/timeshift/fixture-user/fixture-pass/30/2026-10-20:10-00/11.m3u8');
    assert.equal(archive.isLive,false);
    assert.equal((await kit.invoke('subscriptionExpiry')).kind,'dated');
    await kit.source.dispose();
  });

  await check('original Stalker endpoint/profile, native headers, live/VOD/series, portal EPG and fresh links', async () => {
    const kit=fixture({id:'stalker-source',kind:'stalker',label:'Canonical Stalker',fields:{portal:'https://stalker.fixture/c/',mac:'00:11:22:33:44:55'}}, (url,request)=>{
      assert.match(request.headers.Cookie,/mac=00:11:22:33:44:55/);
      assert.match(request.headers['user-agent'],/MAG200/);
      assert.equal(request.workload,'stalker-json');
      const action=url.searchParams.get('action'), type=url.searchParams.get('type');
      if(action==='handshake')return {js:{token:'fixture-token'}};
      assert.equal(request.headers.authorization,'Bearer fixture-token');
      if(action==='get_profile')return {js:{timezone:'UTC'}};
      if(action==='get_genres')return {js:[{id:'1',title:'News'}]};
      if(action==='get_all_channels')return {js:{data:[{id:11,name:'Stalker Live',cmd:'ffmpeg http://streams.fixture/live/11',tv_genre_id:'1',tv_archive:1}]}};
      if(action==='get_categories')return {js:[{id:type==='series'?'series':'movies',title:type==='series'?'Series':'Movies'}]};
      if(action==='get_ordered_list') {
        let data;
        if(type==='series' && url.searchParams.get('movie_id'))data=[];
        else if(type==='series')data=[{id:'900',name:'Stalker Series',is_series:1}];
        else data=[{id:'500',name:'Stalker Film',cmd:'ffmpeg http://streams.fixture/vod/500.mp4',is_series:0}];
        return {js:{data,total_items:data.length,max_page_items:14}};
      }
      if(action==='get_movie_details')return {js:{description:'Stalker details',seasons:[{season_number:1,name:'Stalker season'}],
        episodes:{'1':[{id:'901',name:'Stalker Pilot',series_number:1,cmd:'ffmpeg http://streams.fixture/episode/901.mp4'}]}}};
      if(action==='get_epg_info')return {js:{'11':[{name:'Portal guide',start_timestamp:1792490400,stop_timestamp:1792492200,descr:'Portal detail'}]}};
      if(action==='create_link')return {js:{cmd:'ffmpeg http://streams.fixture/result.m3u8',subtitles:[{url:'http://streams.fixture/en.srt',lang:'en'}]}};
      if(action==='get_main_info')return {js:{end_date:'2030-12-31'}};
      throw Error('Unexpected fixture action '+action);
    });
    await kit.invoke('connect');
    assert.equal(kit.requests.length,2);
    const channel=(await kit.invoke('channels'))[0];
    assert.equal((await kit.invoke('categories'))[0].title,'News');
    assert.equal((await kit.invoke('resolve',{channel})).url,'http://streams.fixture/result.m3u8');
    const vod=(await kit.invoke('mediaItemsPage',{kind:'movie',categoryId:'movies'})).items[0];
    assert.equal(vod.title,'Stalker Film');
    const detail=await kit.invoke('mediaDetails',{item:vod});
    assert.equal(detail.description,'Stalker details');
    const resolved=await kit.invoke('resolveMedia',{item:vod});
    assert.equal(resolved.isLive,false); assert.equal(resolved.subtitles[0].language,'en');
    const series=(await kit.invoke('mediaItemsPage',{kind:'series',categoryId:'series'})).items[0];
    const detailedSeries=await kit.invoke('mediaDetails',{item:series});
    const season=(await kit.invoke('mediaItemsPage',{kind:'season',parent:detailedSeries})).items[0];
    assert.equal(season.kind,'season');
    const episode=(await kit.invoke('mediaItemsPage',{kind:'episode',parent:season})).items[0];
    assert.equal(episode.kind,'episode');
    assert.equal((await kit.invoke('resolveMedia',{item:episode})).isLive,false);
    const guide=await kit.invoke('epg',{channels:[channel]});
    assert.equal(guide[0].title,'Portal guide');
    assert.equal((await kit.invoke('resolveArchive',{channel,programme})).isLive,false);
    assert.equal((await kit.invoke('subscriptionExpiry')).kind,'dated');
    assert.ok(kit.requests.filter(r=>new URL(r.url).searchParams.get('action')==='create_link').length>=4);
    await kit.source.dispose();
  });

  await check('original refusal gate blocks subsequent requests without credential leakage', async () => {
    const kit=fixture({id:'blocked',kind:'xtream',fields:{host:'https://refused.fixture',username:'fixture',password:'fixture'}}, url=>
      ({rawResponse:{status:429,body:'Rate limit',url:url.href,headers:{'retry-after':'600'},decoded:true}}));
    await assert.rejects(kit.invoke('connect'));
    await assert.rejects(kit.invoke('channels'));
    assert.equal(kit.requests.length,1);
    await kit.source.dispose();
  });

  await check('original PIN hashing/verification and fail-closed parental ancestry rules', async () => {
    const verifier=await core.hashPin('1234');
    assert.equal(core.isPinVerifier(verifier),true);
    assert.equal(await core.verifyPin('1234',verifier),true);
    assert.equal(await core.verifyPin('4321',verifier),false);
    assert.equal(core.isPinVerifier('future-algorithm$unknown'),false);
    const key=JSON.parse(core.parentalRules('categoryKey',JSON.stringify({sourceId:'source',kind:'episode',id:'locked'})));
    assert.deepEqual(JSON.parse(key),['source','series','locked']);
    const rules={version:1,verifier,lockSettings:true,channels:[],categories:[key]};
    assert.equal(JSON.parse(core.parentalRules('protects',JSON.stringify({rules,sourceId:'source',kind:'episode',id:'episode',categoryId:null}))),true);
    assert.equal(JSON.parse(core.parentalRules('protects',JSON.stringify({rules,sourceId:'other',kind:'episode',id:'episode',categoryId:null}))),false);
    assert.throws(()=>core.parentalRules('validate','{"rules":{"version":2}}'));
  });
  await check('original supporter validity and AppDatabase save/clear/ignore resume decisions', async () => {
    assert.equal(core.supporterActive('{"supported":true,"valid_until":"2030-01-01T00:00:00Z"}','2026-10-20T00:00:00Z'),true);
    assert.equal(core.supporterActive('{"supported":true,"valid_until":"2020-01-01T00:00:00Z"}','2026-10-20T00:00:00Z'),false);
    assert.equal(core.supporterActive('{"supported":false,"valid_until":"2030-01-01T00:00:00Z"}','2026-10-20T00:00:00Z'),false);
    assert.equal(core.supporterActive('{}','2026-10-20T00:00:00Z'),false);
    assert.equal(JSON.parse(await core.resumeDecision(9.999,100)).action,'ignore');
    assert.deepEqual(JSON.parse(await core.resumeDecision(10,100)),{action:'save',positionMs:10000,durationMs:100000});
    assert.equal(JSON.parse(await core.resumeDecision(94.999,100)).action,'save');
    assert.equal(JSON.parse(await core.resumeDecision(95,100)).action,'clear');
    assert.equal(JSON.parse(await core.resumeDecision(2,2)).action,'clear');
    assert.equal(JSON.parse(await core.resumeDecision(15,0)).action,'save');
    const archived={id:'11',name:'Archive',archiveDays:7};
    assert.equal(core.canCatchup(JSON.stringify(archived),JSON.stringify(programme),'2026-10-20T10:30:00Z'),true);
    assert.equal(core.canCatchup(JSON.stringify(archived),JSON.stringify(programme),'2026-10-20T10:29:59Z'),false);
    assert.equal(core.canCatchup('{"id":"11","name":"No archive","archiveDays":0}',JSON.stringify(programme),'2026-10-20T11:00:00Z'),false);
  });
  await check('original LocalProfile/ProfileSnapshot defaults and opaque metadata preservation', async () => {
    const value=JSON.parse(core.profileNormalize('[{"id":"profile","pin":"  ","snapshot":{"sources":[],"metadata":{"kind":"fixture"},"managedIds":[42]}}]'))[0];
    assert.equal(value.name,''); assert.equal(value.colorIndex,0);
    assert.equal(value.pin,undefined);
    assert.deepEqual(value.snapshot,{sources:[],metadata:{kind:'fixture'},managedIds:['42']});
    assert.deepEqual(JSON.parse(core.profileNormalize('{"id":"empty"}')).snapshot,{sources:[]});
  });
  await check('original public CloudConfig defaults and canonical pairing language/code link',async()=>{
    const config=JSON.parse(core.cloudConfig());
    assert.equal(config.enabled,true);assert.equal(config.configured,true);
    assert.equal(new URL(config.apiUrl).protocol,'https:');assert.equal(new URL(config.panelUrl).protocol,'https:');
    assert.equal(config.anonKey,'tvbro_public_client');
    const link=new URL(core.pairingPanelLink(config.panelUrl,' ABCD1234 ','pl'));
    assert.equal(link.searchParams.get('code'),'ABCD1234');assert.equal(link.searchParams.get('lang'),'pl');
    assert.equal(link.origin,new URL(config.panelUrl).origin);
  });
  await check('original onboarding language catalog and parameter substitution',async()=>{
    assert.deepEqual(JSON.parse(core.appLanguages()).map(language=>language.code),['en','pl']);
    assert.equal(core.translateUi('Download from cloud','pl','{}'),'Pobierz z chmury');
    assert.equal(core.translateUi('Found {count} ready source(s).','pl','{"count":3}'),'Gotowe źródła: 3.');
    assert.equal(core.translateUi('Download from cloud','en','{}'),'Download from cloud');
    assert.equal(core.translateUi('Download from cloud','unknown','{}'),'Download from cloud');
    assert.equal(JSON.parse(core.translationCatalog())['Download from cloud'],'Pobierz z chmury');
  });
  await check('original startup picker decisions include PIN and ownerless overrides',async()=>{
    for(const [mode,count,locked,active,expected] of [
      ['auto',0,false,false,true],['auto',1,false,true,false],['auto',2,false,true,true],
      ['always',1,false,true,true],['off',2,false,true,false],['off',1,true,true,true],
      ['off',1,false,false,true],['unknown',2,false,true,true]
    ]) assert.equal(core.showProfilePicker(mode,count,locked,active),expected,JSON.stringify({mode,count,locked,active}));
  });
  const report={schemaVersion:1,status:'compiled_original_sources_fixture_checks_passed',tests:checks,
    jsSha256:crypto.createHash('sha256').update(bytes).digest('hex'),
    execution:'Actual compiled original Source classes; only physical HTTP and session IO are bindings',
    physicalProviderOrTvTested:false};
  fs.writeFileSync(path.join(output,'source-test.json'),JSON.stringify(report,null,2));
  console.log(JSON.stringify(report,null,2));
}
main().catch(error=>{console.error(error);process.exitCode=1;});
