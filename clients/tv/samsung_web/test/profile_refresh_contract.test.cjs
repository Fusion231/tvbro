'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {create} = require('../platform/library.js');
const createUserState = require('../platform/user_state.js').create;

function fixture() {
  let saved = {samsung_sources_migrated_v1:'true',profile_picker_startup:'always'};
  const storage = createUserState({store:{readUserState:()=>saved,writeUserState:async value=>{saved=value;}}});
  const remote = {id:'cloud',name:'Cloud',updated_at:'2026-11-01T00:00:00Z',pin:null};
  let sources = [{id:'source',kind:'m3u',label:'Original',fields:{playlistUrl:'https://provider.test/list.m3u'},settings:{}}];
  const calls = [];
  const cloud = {configured:true,status:async()=>({paired:true,profileId:'cloud'}),query:async(action)=>{
    calls.push(action);
    if(action==='profiles.list') return [{...remote}];
    if(action==='profiles.select') return {};
    if(action==='pull') return {profile:{...remote},sources:structuredClone(sources),favorites:[]};
    throw Error('Unexpected cloud action: '+action);
  }};
  const api = create({userState:storage,sourceStore:{read:()=>[]},cloud,
    core:{showProfilePicker:mode=>mode!=='off',newSourceId:()=> 'local'},
    validation:{validateSource:()=>null},player:{getCapabilities:()=>({})},
    transport:{capabilities:()=>({}),abort(){}},getState:()=>({}),stop:async()=>{}});
  return {api,storage,remote,cloud,calls,setSources:value=>{sources=value;}};
}

test('selecting a changed cloud profile refreshes its sources without restarting the process', async t=>{
  const kit=fixture();t.after(()=>kit.api.dispose());
  await kit.api.query('bootstrap');
  await kit.api.query('pairing.download',{profileId:'cloud'});
  kit.remote.updated_at='2026-11-13T00:00:00Z';
  kit.setSources([{id:'source',kind:'m3u',label:'Changed',fields:{playlistUrl:'https://provider.test/new.m3u'},settings:{}}]);
  const selected=await kit.api.query('profiles.select',{id:'cloud',source:'cloud'});
  assert.equal(selected.sources[0].label,'Changed');
  assert.equal(kit.calls.filter(action=>action==='pull').length,2);
});

test('unchanged cloud revisions reuse the saved profile and keep local source edits', async t=>{
  const kit=fixture();t.after(()=>kit.api.dispose());
  await kit.api.query('bootstrap');
  await kit.api.query('pairing.download',{profileId:'cloud'});
  await kit.api.query('sources.update',{config:{id:'source',kind:'m3u',label:'TV edit',fields:{playlistUrl:'https://provider.test/local.m3u'},settings:{}}});
  const selected=await kit.api.query('profiles.select',{id:'cloud',source:'cloud'});
  assert.equal(selected.sources[0].label,'TV edit');
  assert.equal(kit.calls.filter(action=>action==='pull').length,1);
});

test('refreshing choices after resume retains the profile that owns current playback', async t=>{
  const kit=fixture();t.after(()=>kit.api.dispose());
  await kit.api.query('bootstrap');
  await kit.api.query('pairing.download',{profileId:'cloud'});
  const second={id:'other',name:'New account profile',updated_at:'2026-11-13T00:00:00Z',pin:null};
  const query=kit.cloud.query;
  kit.cloud.status=async()=>({paired:true,profileId:'other'});
  kit.cloud.query=action=>action==='profiles.list'?Promise.resolve([{...kit.remote},second]):query(action);
  const listing=await kit.api.query('profiles.list',{preserveSelection:true});
  assert.equal(listing.profiles.length,2);
  assert.equal(kit.storage.get('cloud_profile_id'),'cloud');
  assert.equal((await kit.api.query('sources.list'))[0].label,'Original');
});

test('a changed cloud PIN is checked before a saved profile can open', async t=>{
  const kit=fixture();t.after(()=>kit.api.dispose());
  await kit.api.query('bootstrap');await kit.api.query('pairing.download',{profileId:'cloud'});
  const saved=kit.storage.get('cloud_profile_snapshots_v1');
  kit.remote.pin='new-verifier';kit.remote.updated_at='2026-11-13T00:00:00Z';
  await assert.rejects(kit.api.query('profiles.select',{id:'cloud',source:'cloud'}),{code:'pin_required'});
  assert.equal(kit.storage.get('cloud_profile_snapshots_v1'),saved);
  assert.equal(kit.calls.filter(action=>action==='pull').length,1);
});

test('failed refresh preserves the saved profile and a later selection retries the changed revision', async t=>{
  const kit=fixture();t.after(()=>kit.api.dispose());
  await kit.api.query('bootstrap');await kit.api.query('pairing.download',{profileId:'cloud'});
  const saved=kit.storage.get('cloud_profile_snapshots_v1'),query=kit.cloud.query;
  kit.remote.updated_at='2026-11-13T00:00:00Z';
  kit.cloud.query=action=>action==='pull'?Promise.reject(Object.assign(Error('Offline'),{name:'NetworkError'})):query(action);
  await assert.rejects(kit.api.query('profiles.select',{id:'cloud',source:'cloud'}),{name:'NetworkError'});
  assert.equal(kit.storage.get('cloud_profile_snapshots_v1'),saved);
  kit.cloud.query=query;
  kit.setSources([{id:'source',kind:'m3u',label:'Recovered',fields:{playlistUrl:'https://provider.test/new.m3u'},settings:{}}]);
  const selected=await kit.api.query('profiles.select',{id:'cloud',source:'cloud'});
  assert.equal(selected.sources[0].label,'Recovered');
});

test('direct startup with the chooser disabled refreshes changed cloud sources before opening content', async t=>{
  const kit=fixture();t.after(()=>kit.api.dispose());
  await kit.api.query('bootstrap');await kit.api.query('pairing.download',{profileId:'cloud'});
  await kit.storage.set('profile_picker_startup','off');
  kit.remote.updated_at='2026-11-13T00:00:00Z';
  kit.setSources([{id:'source',kind:'m3u',label:'Startup update',fields:{playlistUrl:'https://provider.test/new.m3u'},settings:{}}]);
  const boot=await kit.api.query('bootstrap');
  assert.equal(boot.showProfilePicker,false);
  assert.equal(boot.sources[0].label,'Startup update');
});

test('refreshing a changed revision adds remote sources while preserving pending local source edits', async t=>{
  const kit=fixture();t.after(()=>kit.api.dispose());
  await kit.api.query('bootstrap');await kit.api.query('pairing.download',{profileId:'cloud'});
  await kit.api.query('sources.update',{config:{id:'source',kind:'m3u',label:'TV edit',fields:{playlistUrl:'https://provider.test/local.m3u'},settings:{}}});
  kit.remote.updated_at='2026-11-13T00:00:00Z';
  kit.setSources([
    {id:'source',kind:'m3u',label:'Cloud edit',fields:{playlistUrl:'https://provider.test/cloud.m3u'},settings:{}},
    {id:'new',kind:'m3u',label:'New cloud source',fields:{playlistUrl:'https://provider.test/extra.m3u'},settings:{}}
  ]);
  const selected=await kit.api.query('profiles.select',{id:'cloud',source:'cloud'});
  assert.equal(selected.sources[0].label,'TV edit');
  assert.equal(selected.sources[0].fields.playlistUrl,'https://provider.test/local.m3u');
  assert.equal(selected.sources[1].label,'New cloud source');
});

test('refreshing cloud sources retains favorite changes waiting to be uploaded', async t=>{
  const kit=fixture();t.after(()=>kit.api.dispose());
  await kit.api.query('bootstrap');await kit.api.query('pairing.download',{profileId:'cloud'});
  await kit.api.query('favorites.toggle',{sourceId:'source',channel:{id:'channel',name:'Local favorite'}});
  kit.remote.updated_at='2026-11-13T00:00:00Z';
  await kit.api.query('profiles.select',{id:'cloud',source:'cloud'});
  const favorites=await kit.api.query('favorites.list');
  assert.equal(favorites.items.length,1);
  assert.equal(favorites.items[0].channel.id,'channel');
});
