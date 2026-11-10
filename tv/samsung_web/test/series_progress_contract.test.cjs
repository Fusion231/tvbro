'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const createLibrary = require('../platform/library.js').create;
const createUserState = require('../platform/user_state.js').create;

const positionsKey = 'samsung_playback_positions_v1';
const series = {id:'demo-series-1',title:'Codec Test Series',kind:'series'};
const identity = (id,sourceId='source',kind='episode') => JSON.stringify([sourceId,kind,id]);
function canonical() {
  const scope = {console,crypto:crypto.webcrypto,setTimeout,clearTimeout,TextEncoder,TextDecoder};
  scope.window = scope; scope.self = scope;
  vm.createContext(scope);
  vm.runInContext(fs.readFileSync(path.resolve(__dirname,'../../output/samsung-web/core/core.js'),'utf8'),scope);
  return scope.TVBroCanonical;
}
function deferred() {
  let resolve;
  const promise = new Promise(done => {resolve=done;});
  return {promise,resolve};
}
async function harness(t) {
  const core = canonical(), calls = [], gate = {request:null}, sourceCalls = [];
  const configs = ['source','another-source'].map(id => ({id,kind:'demo',label:id,fields:{},settings:{}}));
  let snapshot = {active_local_profile_id:'profile',local_profiles_v1:JSON.stringify([
    {id:'profile',name:'Profile',snapshot:{sources:configs}},
    {id:'other-profile',name:'Other',snapshot:{sources:configs}}
  ])};
  const state = createUserState({store:{readUserState:()=>snapshot,async writeUserState(next){snapshot=next;return next;}}});
  const api = createLibrary({core,userState:state,
    createSource(config,transport) {
      const source = core.createSource(config,transport);
      return {invoke(method,args) {
        sourceCalls.push({method,args:JSON.parse(args)});
        if (method==='seriesProgress' && gate.request) {
          const request = gate.request; gate.request = null;
          request.started.resolve();
          return request.done.promise.then(() => source.invoke(method,args));
        }
        return source.invoke(method,args);
      },dispose:()=>source.dispose()};
    },
    player:{getCapabilities:()=>({})},
    transport:{abort(){},capabilities:()=>({}),request(){throw Error('Demo summary must not request provider HTTP');}},
    cloud:{status:()=>({configured:false}),hasSession:()=>false,query(action){calls.push(action);throw Error('Summary must remain free');}},
    getState:()=>({playing:false,position:0}),stop:()=>Promise.resolve()});
  t.after(()=>api.dispose());
  await api.query('sources.load',{id:'source'});
  const seasons = (await api.query('media.children',{item:series})).items;
  const first = (await api.query('media.children',{item:seasons[0]})).items;
  async function save(rows,profileId='profile') {
    const all = JSON.parse(state.get(positionsKey) || '{}'); all[profileId] = rows;
    await state.set(positionsKey,JSON.stringify(all));
  }
  return {api,state,save,calls,sourceCalls,seasons,first,gate,
    summary:()=>api.query('media.seriesProgress',{item:series,sourceId:'source'})};
}
function checkpoint(position=95,extra={}) {
  return {position,duration:100,updatedAt:'2026-10-27T10:00:00.000Z',...extra};
}

test('series summary uses canonical progress and isolates source/profile/kind without a supporter lookup',async t => {
  const kit = await harness(t);
  await kit.save({
    [identity('bbb')]:checkpoint(),
    [identity('tos')]:checkpoint(95,{removed:true}),
    [identity('bipbop')]:checkpoint(-1),
    [identity('bbb','another-source')]:checkpoint(40,{updatedAt:'2026-10-27T11:00:00.000Z'}),
    [identity('bbb','source','movie')]:checkpoint(40)
  });
  await kit.save({[identity('tos')]:checkpoint(30)},'other-profile');
  const summary = await kit.summary();
  assert.equal(summary.watchedCount,1);
  assert.equal(summary.latestEpisode.id,'bbb');
  assert.equal(summary.latestPosition.finished,true);
  assert.equal(summary.nextEpisode.id,'bipbop');
  assert.equal(summary.complete,false);
  assert.deepEqual(kit.calls,[]);
  const request = kit.sourceCalls.findLast(row=>row.method==='seriesProgress').args;
  assert.equal(request.positions.length,1);
  assert.equal(request.positions[0].updatedAt,Date.parse('2026-10-27T10:00:00.000Z'));
});

test('all saved episode checkpoints participate beyond the visible progress/history limits',async t => {
  const kit = await harness(t), rows = {};
  for (let index=0;index<125;index++) rows[identity('unrelated-'+index)] = checkpoint();
  rows[identity('bbb')] = checkpoint();
  await kit.save(rows);
  const summary = await kit.summary();
  assert.equal(summary.watchedCount,1);
  assert.equal(summary.latestEpisode.id,'bbb');
  assert.equal(summary.nextEpisode.id,'bipbop');
  assert.equal(kit.sourceCalls.findLast(row=>row.method==='seriesProgress').args.positions.length,126);
});

test('latest unfinished episode resumes and a completed season prepares only its next season',async t => {
  const kit = await harness(t);
  await kit.save({[identity('bbb')]:checkpoint(30)});
  const resumed = await kit.summary();
  assert.equal(resumed.latestPosition.finished,false);
  assert.equal(resumed.latestPosition.position,30);
  assert.equal(resumed.nextEpisode.id,'bbb');
  const rows = {};
  kit.first.forEach((item,index) => {rows[identity(item.id)] = checkpoint(95,{updatedAt:Date.parse('2026-10-27T10:00:00Z')+index});});
  await kit.save(rows);
  const next = await kit.summary();
  assert.equal(next.watchedCount,3);
  assert.equal(next.latestEpisode.id,'tos');
  assert.equal(next.nextEpisode.parentId,kit.seasons[1].id);
  assert.equal(next.nextEpisode.episodeNumber,1);
  const unrelated = await kit.api.query('media.seriesProgress',{sourceId:'source',item:{id:'caminandes',title:'Caminandes',kind:'series'}});
  assert.equal(unrelated.watchedCount,0);
  assert.equal(unrelated.latestEpisode,null);
  assert.equal(unrelated.nextEpisode,null);
});

test('a delayed series summary is cancelled after the active profile changes',async t => {
  const kit = await harness(t);
  await kit.save({[identity('bbb')]:checkpoint()});
  const request = {started:deferred(),done:deferred()}; kit.gate.request=request;
  const pending = kit.summary();
  await request.started.promise;
  await kit.state.set('active_local_profile_id','other-profile');
  request.done.resolve();
  await assert.rejects(pending,error=>error.code==='cancelled');
});

test('a summary cannot read a different configured source through the active engine',async t => {
  const kit = await harness(t);
  await assert.rejects(kit.api.query('media.seriesProgress',{item:series,sourceId:'another-source'}),error=>error.code==='cancelled');
  assert.equal(kit.sourceCalls.filter(row=>row.method==='seriesProgress').length,0);
});
