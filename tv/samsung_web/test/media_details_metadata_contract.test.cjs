'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const createLibrary = require('../platform/library.js').create;
const createUserState = require('../platform/user_state.js').create;

function canonical() {
  const scope = {console,crypto:crypto.webcrypto,setTimeout,clearTimeout,TextEncoder,TextDecoder};
  scope.window = scope; scope.self = scope;
  vm.createContext(scope);
  vm.runInContext(fs.readFileSync(path.join(__dirname,'../../output/samsung-web/core/core.js'),'utf8'),scope);
  return scope.TVBroCanonical;
}
function media(kind='movie',extra={}) {
  return {id:'42',title:'Display title',kind,extra};
}
async function details(core,item,info) {
  const engine = core.createSource(JSON.stringify({id:'metadata-fixture',kind:'xtream',label:'Fixture',
    fields:{host:'https://metadata.fixture',username:'fixture',password:'fixture'},settings:{}}), async raw => {
    const request = JSON.parse(raw), action = new URL(request.url).searchParams.get('action');
    const body = action ? {info} : {user_info:{auth:1,status:'Active',exp_date:'4102444800'}};
    return JSON.stringify({status:200,url:request.url,headers:{},decoded:true,body:JSON.stringify(body)});
  });
  try { return JSON.parse(await engine.invoke('mediaDetails',JSON.stringify({item}))); }
  finally { await engine.dispose(); }
}

test('canonical details expose the exact Android MediaInfo fields from provider and cached metadata', async () => {
  const core = canonical();
  const item = media('movie',{providerTitle:'PL | Source [MULTI AUDIO]',metadata:{tmdb:{credits:{
    cast:[{name:'Actor One',character:'Hero',profile_path:'/one.jpg'},{name:'Actor Two',character:'Guest'}],
    crew:[{name:'Director From TMDB',job:'Director'}]}}}});
  const result = await details(core,item,{plot:'Provider description',genre:'Drama / Mystery',country:'Poland; France',
    director:'Provider Director',original_title:'Original title',releasedate:'2026-03-04',duration:'01:42:00',
    cast:[{name:'Actor One',character:'Narrator'}],youtube_trailer:'abcdefghijk'});
  assert.equal(result.description,'Provider description');
  assert.deepEqual(result.info.genres,['Drama','Mystery']);
  assert.deepEqual(result.info.countries,['Poland','France']);
  assert.deepEqual(result.info.directors,['Provider Director']);
  assert.equal(result.info.originalTitle,'Original title');
  assert.equal(result.info.releaseDate,'2026-03-04');
  assert.equal(result.info.durationSeconds,6120);
  assert.deepEqual(result.info.cast,[{name:'Actor One',role:'Narrator, Hero',photoUrl:'https://image.tmdb.org/t/p/w185/one.jpg'},
    {name:'Actor Two',role:'Guest',photoUrl:null}]);
  assert.equal(result.trailerUrl,'https://www.youtube.com/watch?v=abcdefghijk');
  assert.equal(result.sourceTitle,'PL | Source [MULTI AUDIO]');
  assert.ok(result.sourceHints.includes('Multi audio'));
});

test('episode metadata uses known info containers and ignores unrelated episode trees', async () => {
  const core = canonical();
  const result = await details(core,media('episode',{info:{genre:'Science Fiction',duration_secs:2700,
    actors:'Episode Actor'},episodes:[{cast:'Unrelated Actor',genre:'Wrong genre'}]}),{});
  assert.deepEqual(result.info.genres,[],'MediaInfo does not recursively inspect arbitrary info/episode maps');
  assert.equal(result.info.cast.length,0);
  const nested = await details(core,media('episode',{details:{info:{genre:'Science Fiction',duration_secs:2700,
    actors:'Episode Actor'}},episodes:[{cast:'Unrelated Actor',genre:'Wrong genre'}]}),{});
  assert.deepEqual(nested.info.genres,['Science Fiction']);
  assert.equal(nested.info.durationSeconds,2700);
  assert.deepEqual(nested.info.cast,[{name:'Episode Actor',role:null,photoUrl:null}]);
});

test('canonical playback decisions retain completed episodes while completed movies clear their resume row', async () => {
  const core = canonical();
  assert.equal(JSON.parse(await core.resumeDecisionForKind('movie',95,100)).action,'clear');
  assert.equal(JSON.parse(await core.resumeDecisionForKind('episode',95,100)).action,'save');
  const progress = JSON.parse(core.mediaProgress(JSON.stringify([
    {id:'finished',kind:'episode',position:95,duration:100},
    {id:'partial',kind:'episode',position:30,duration:100},
    {id:'unknown',kind:'movie',position:50,duration:0}
  ])));
  assert.deepEqual(progress.finished,{position:95,duration:100,progress:0.95,finished:true});
  assert.equal(progress.partial.finished,false); assert.equal(progress.unknown.progress,0);
});

function progressFixture(core, delayed, extraOptions) {
  const configs=[{id:'source',kind:'m3u',label:'Source',fields:{playlistUrl:'https://source.fixture/list.m3u'},settings:{}}];
  const episode={id:'episode',kind:'episode'}, movie={id:'movie',kind:'movie'};
  const key=item=>JSON.stringify(['source',item.kind,item.id]);
  let snapshot={active_local_profile_id:'profile',local_profiles_v1:JSON.stringify([
    {id:'profile',name:'Profile',snapshot:{sources:configs,metadata:{provider:'tmdb',tmdbApiKey:'fixture-not-real'}}},
    {id:'other',name:'Other',snapshot:{sources:configs}}
  ]),samsung_playback_positions_v1:JSON.stringify({profile:{
    [key(episode)]:{position:95,duration:100},[key(movie)]:{position:30,duration:120},
    [JSON.stringify(['another-source','episode','other'])]:{position:50,duration:100}
  },other:{[key(episode)]:{position:15,duration:100}}})};
  const state=createUserState({store:{readUserState:()=>snapshot,async writeUserState(next){snapshot=next;return next;}}});
  let reads=0;
  const api=createLibrary(Object.assign({core,userState:state,createSource(){throw Error('Progress must not query provider');},
    player:{getCapabilities:()=>({})},transport:{abort(){},capabilities:()=>({})},
    cloud:{status:()=>({configured:false}),hasSession:()=>true,query(action){assert.equal(action,'supporter.status');reads++;
      return delayed || Promise.resolve({supported:true,valid_until:'2099-01-01T00:00:00Z'});}},
    getState:()=>({playing:false,position:0}),stop:()=>Promise.resolve()},extraOptions));
  return {api,state,episode,movie,reads:()=>reads};
}

test('visible progress batches one supporter lookup and returns only the selected source/profile', async t => {
  const kit=progressFixture(canonical()); t.after(()=>kit.api.dispose());
  const result=await kit.api.query('media.progress',{sourceId:'source',items:[kit.episode,kit.movie,{id:'other',kind:'episode'}]});
  assert.equal(kit.reads(),1); assert.equal(result.resumeAllowed,true);
  assert.deepEqual(Object.keys(result.positions).sort(),['episode','movie']);
  assert.equal(result.positions.episode.finished,true); assert.equal(result.positions.movie.progress,0.25);
  const status=await kit.api.query('media.metadataStatus');
  assert.deepEqual(status,{source:'provider',configured:true,externalLookupsAvailable:false,provider:'tmdb',status:'provider_metadata'});
  assert.equal(JSON.stringify(status).includes('fixture-not-real'),false);
  assert.equal(kit.reads(),1,'metadata remains free and does not read supporter or a metadata provider');
});

test('a delayed progress batch cannot expose a profile that changed during the supporter check', async t => {
  let finish; const delayed=new Promise(resolve=>{finish=resolve;});
  const kit=progressFixture(canonical(),delayed); t.after(()=>kit.api.dispose());
  const pending=kit.api.query('media.progress',{sourceId:'source',items:[kit.episode]});
  await new Promise(resolve=>setImmediate(resolve));
  await kit.state.set('active_local_profile_id','other');
  finish({supported:true,valid_until:'2099-01-01T00:00:00Z'});
  await assert.rejects(pending,error=>error.code==='cancelled');
});

test('a watched episode keeps its watched marker while resume starts it from the beginning', async t => {
  const kit=progressFixture(canonical()); t.after(()=>kit.api.dispose());
  const episode=await kit.api.query('resume.get',{sourceId:'source',item:kit.episode});
  assert.deepEqual(episode,{position:0,duration:100,allowed:true});
  const movie=await kit.api.query('resume.get',{sourceId:'source',item:kit.movie});
  assert.deepEqual(movie,{position:30,duration:120,allowed:true});
  const progress=await kit.api.query('media.progress',{sourceId:'source',items:[kit.episode]});
  assert.equal(progress.positions.episode.finished,true);
  assert.equal(progress.positions.episode.position,95,'reading resume must retain the episode watched state');
});

test('a delayed resume lookup cannot return the previous profile position after a profile switch', async t => {
  let finish; const request=new Promise(resolve=>{finish=resolve;});
  const kit=progressFixture(canonical(),request); t.after(()=>kit.api.dispose());
  const pending=kit.api.query('resume.get',{sourceId:'source',item:kit.movie});
  await new Promise(resolve=>setImmediate(resolve));
  await kit.state.set('active_local_profile_id','other');
  finish({supported:true,valid_until:'2099-01-01T00:00:00Z'});
  await assert.rejects(pending,error=>error.code==='cancelled');
});

test('trailers require the real platform launcher and recompute the original canonical destination', async t => {
  const core=canonical(), unsupported=progressFixture(core); t.after(()=>unsupported.api.dispose());
  const unsupportedState=await unsupported.api.query('bootstrap');
  assert.equal(unsupportedState.capabilities.trailer,false);
  await assert.rejects(unsupported.api.query('media.trailer',{item:media()}),error=>error.code==='trailer_unavailable');
  const opened=[];
  const kit=progressFixture(core,null,{openTrailer(url){opened.push(url);return {opened:true};}}); t.after(()=>kit.api.dispose());
  assert.equal((await kit.api.query('bootstrap')).capabilities.trailer,true);
  const item=media('movie',{youtube_trailer:'abcdefghijk'}); item.trailerUrl='https://untrusted.fixture';
  assert.deepEqual(await kit.api.query('media.trailer',{item}),{opened:true});
  assert.deepEqual(opened,['https://www.youtube.com/watch?v=abcdefghijk']);
  await kit.api.query('media.trailer',{item:media()});
  const fallback=new URL(opened[1]);
  assert.equal(fallback.origin,'https://www.youtube.com');
  assert.equal(fallback.searchParams.get('search_query'),'Display title zwiastun PL');
  assert.equal(kit.reads(),0,'an explicit trailer launch does not read supporter or a metadata provider');
});
