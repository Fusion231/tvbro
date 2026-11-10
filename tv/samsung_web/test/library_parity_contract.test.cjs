'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const library=require('../platform/library.js');
const organization=require('../platform/organization.js');
const profiles=new Set();
test.afterEach(async()=>{for(const api of profiles)await api.dispose();profiles.clear();});
const clone=value=>JSON.parse(JSON.stringify(value));
const sourceId='90a03a25-9dbf-43c2-a0ab-66737e7f4301';
const remoteId='f1d7e5d2-1e02-4e4c-8d29-11b4f11a0502';
const config={id:sourceId,kind:'m3u',label:'Fixture',fields:{playlistUrl:'https://fixture.test/list',userAgent:'Keep secret'},settings:{bufferPreset:'normal'}};
const channels=[{id:'b',name:'Beta',categoryId:'news'},{id:'a',name:'Alpha',categoryId:'news'},{id:'h',name:'Hidden',categoryId:'adult'}];
const categories=[{id:'news',title:'News'},{id:'adult',title:'Adult'}];
function deferred(){let resolve;return {promise:new Promise(r=>resolve=r),resolve:value=>resolve(value)};}
function harness({cloudProfile=false,cloudRoute}={}){
  let state={},next=0;
  const calls={engine:[],open:[],aspect:[],track:[],cloud:[]};
  const store={read:()=>clone(state),get:key=>state[key]===undefined?null:state[key],set:(key,value)=>store.update(s=>{s[key]=value;}),
    update:fn=>Promise.resolve().then(()=>{const changed=clone(state);fn(changed);state=changed;return clone(state);})};
  const core={newSourceId:()=>`11111111-1111-4111-8111-${String(++next).padStart(12,'0')}`,profileNormalize:value=>value,
    providerCachePolicy:()=>JSON.stringify({catalogMaxAgeMs:0,epgRetryDelayMs:900000}),showProfilePicker:()=>false,
    appLanguages:()=>JSON.stringify([{code:'en',name:'English'}]),hashPin:pin=>Promise.resolve('hashed:'+pin),verifyPin:(pin,hash)=>Promise.resolve(hash==='hashed:'+pin),
    parentalRules(action,text){const value=JSON.parse(text),r=value.rules;if(action==='validate')return JSON.stringify(r);
      if(action==='channelKey'||action==='categoryKey')return JSON.stringify([value.sourceId,value.kind,value.id].join('|'));
      if(action==='visibleIds')return JSON.stringify(value.items.filter(item=>!r.channels.includes([value.sourceId,value.kind,item.id].join('|'))&&!r.categories.includes([value.sourceId,value.kind,item.categoryId].join('|'))).map(item=>item.id));
      return JSON.stringify(!!r.verifier&&(r.channels.includes([value.sourceId,value.kind,value.id].join('|'))||r.categories.includes([value.sourceId,value.kind,value.categoryId].join('|'))));},
    canCatchup:()=>false,resumeDecision:()=>JSON.stringify({action:'save'}),resumeDecisionForKind:()=>JSON.stringify({action:'save'}),supporterActive:value=>JSON.parse(value).supported===true};
  const createSource=()=>({invoke(method,text){const args=JSON.parse(text);calls.engine.push({method,args});
    let value;
    if(method==='capabilities')value={};else if(method==='categories')value=categories;else if(method==='channels')value=channels;
    else if(method==='mediaCategories')value=categories;else if(method==='mediaItemsPage')value={items:[{id:'movie',kind:'movie',categoryId:'news',title:'Movie'}],page:1,hasMore:false};
    else if(method==='epgMapping.get')value={available:true,channels:[{guideId:'guide',guideChannelId:'a',channelId:'a',name:'Alpha guide'}]};
    else if(method==='epg')value=[{channelId:'a',start:'2026-10-26T09:00:00.000Z',stop:'2026-10-26T10:00:00.000Z',title:'Morning show'}];
    else if(method==='subscriptionExpiry')value={kind:'dated',date:'2026-10-27T00:00:00.000Z'};
    else if(method==='resolve'||method==='resolveMedia')value={url:'https://fixture.test/play',isLive:method==='resolve',headers:{}};
    else if(method==='connect'||method==='epgMapping.set')value=null;else throw Error('Unknown method '+method);
    return Promise.resolve(JSON.stringify(value));},dispose:()=>Promise.resolve()});
  const player={getCapabilities:()=>({}),getTracks:()=>[{type:'AUDIO',index:2,extraInfo:{track_lang:'pol'}},{type:'AUDIO',index:7,extraInfo:{track_lang:'eng'}}],
    setDisplayMode:value=>calls.aspect.push(value),selectTrack:(type,id)=>calls.track.push([type,id]),setSubtitlesEnabled:()=>{},setRect:()=>{},seek:()=>{}};
  let playback={playing:false,buffering:false,position:0,duration:0};
  const cloud={configured:true,hasSession:()=>cloudProfile,status:()=>Promise.resolve({configured:true,paired:cloudProfile,profileId:cloudProfile?remoteId:null}),
    query(action,args){calls.cloud.push({action,args:clone(args)});if(cloudRoute)return cloudRoute(action,args);
      if(action==='profiles.list')return Promise.resolve([{id:remoteId,name:'Remote',pin:null}]);
      if(action==='supporter.status')return Promise.resolve({supported:true});
      if(action==='push.delta')return Promise.resolve({});
      if(action==='push.playback')return Promise.resolve({available:true,count:args.playbackPositions.length});
      if(action==='pull')return Promise.resolve({profile:{id:remoteId},sources:[clone(config)],managedSourceIds:[sourceId],favorites:[],metadata:{},playbackPositionsAvailable:false});
      throw Error('Unexpected cloud '+action);}};
  if(cloudProfile)state={cloud_profile_id:remoteId,cloud_profile_snapshots_v1:JSON.stringify({[remoteId]:{sources:[clone(config)],managedIds:[sourceId],activeSourceId:sourceId}})};
  const api=library.create({core,createSource,userState:store,sourceStore:{read:()=>[]},player,cloud,validation:{validateSource:()=>null},transport:{capabilities:()=>({cookies:true,userAgent:true}),abort:()=>{}},
    now:()=>Date.parse('2026-10-26T12:00:00Z'),stop:()=>{playback.playing=false;return Promise.resolve();},getState:()=>({...playback}),
    openStream:(stream,rect,preferences)=>{calls.open.push(preferences);playback.playing=true;return Promise.resolve();},onError:()=>{}});
  profiles.add(api);
  return {api,store,calls,async setup(){await api.query('bootstrap');if(!cloudProfile){await api.query('profiles.create',{name:'Local'});await api.query('sources.add',{config:clone(config)});}return api.query('sources.load',{id:sourceId});}};
}
test('organization preserves native IDs, order, custom groups and hidden rows across persisted source edits',async()=>{
  const h=harness();await h.setup();
  const saved=await h.api.query('organization.set',{sourceId,organization:{names:{a:'Renamed'},hidden:['h'],order:['a','b'],groups:[{id:'tvbro.group.mine',name:'Mine',channels:['a']}]},hiddenCategoryIds:['adult']});
  assert.deepEqual(saved.catalog.channels.map(row=>row.id),['a','b']);assert.equal(saved.catalog.channels[0].name,'Renamed');
  assert.equal(saved.channels.length,3);assert.deepEqual(saved.catalog.categories.at(-1).channelIds,['a']);
  const config=(await h.api.query('sources.list'))[0];assert.equal(config.fields.userAgent,'Keep secret');assert.equal(config.settings.channelOrganization.names.a,'Renamed');
  await h.api.query('favorites.toggle',{sourceId,channel:channels[0]});await h.api.query('favorites.toggle',{sourceId,channel:channels[1]});
  assert.deepEqual((await h.api.query('favorites.list')).items.map(row=>row.channel.id),['a','b']);
  assert.deepEqual(organization.normalize({hidden:['x','x'],groups:[{id:'invalid',name:'x'}]}).hidden,['x']);
});
test('parental visibility changes only after a verified unlock and settings preserve source credentials',async()=>{
  const h=harness();await h.setup();await h.api.query('parental.setPin',{newPin:'1234'});await h.api.query('parental.toggle',{pin:'1234',type:'category',id:'adult'});
  assert.deepEqual((await h.api.query('sources.catalog')).channels.map(row=>row.id),['b','a']);
  await assert.rejects(h.api.query('parental.unlock',{pin:'bad'}),e=>e.code==='pin_invalid');
  await h.api.query('parental.unlock',{pin:'1234'});assert.equal((await h.api.query('sources.catalog')).channels.length,3);
  await h.api.query('sourceSettings.set',{sourceId,settings:{catchupOffsetMinutes:60,expiryReminderDays:7},fields:{epgUrls:'https://fixture.test/a\nhttps://fixture.test/b'}});
  const saved=(await h.api.query('sources.list'))[0];assert.equal(saved.fields.userAgent,'Keep secret');assert.equal(saved.settings.catchupOffsetMinutes,60);
  assert.equal((await h.api.query('sourceSettings.get',{sourceId})).fields.find(field=>field.key==='epgUrls').maxItems,3);
  await assert.rejects(h.api.query('sourceSettings.set',{sourceId,fields:{epgUrls:Array(4).fill('https://fixture.test/a').join('\n')}}),e=>e.code==='settings_invalid');
});
test('manual guide offsets expand only the current bounded window and programme search reads no extra guide',async()=>{
  const h=harness();await h.setup();await h.api.query('guide.mapping.set',{sourceId,channelId:'a',offsetMinutes:60});
  const guide=await h.api.query('guide',{channels,from:'2026-10-26T10:00:00.000Z',to:'2026-10-26T11:00:00.000Z'});
  assert.equal(guide.programmes[0].start,'2026-10-26T10:00:00.000Z');
  const read=h.calls.engine.find(row=>row.method==='epg');assert.equal(read.args.from,'2026-10-26T09:00:00.000Z');assert.ok(read.args.channels.length<=40);
  const before=h.calls.engine.length,search=await h.api.query('guide.search',{sourceId,query:'morning'});assert.equal(search.programmes.length,1);assert.equal(h.calls.engine.length,before);
});
test('legacy Android buffer settings stay playable and aspect preferences do not leak between channels',async()=>{
  const h=harness();await h.setup();await h.api.query('playback.play',{sourceId,channel:channels[0]});
  assert.equal(h.calls.open[0].bufferPreset,'default');await h.api.query('player.aspect',{fit:'fill'});
  await h.api.query('playback.play',{sourceId,channel:channels[1]});assert.equal(h.calls.aspect.at(-1),'PLAYER_DISPLAY_MODE_LETTER_BOX');
  await h.api.query('playback.play',{sourceId,channel:channels[0]});assert.equal(h.calls.aspect.at(-1),'PLAYER_DISPLAY_MODE_FULL_SCREEN');
});
test('automatic sync is opt-in and sends durable favorite/path deltas without replacing whole collections',async()=>{
  const h=harness({cloudProfile:true});await h.setup();await h.api.query('favorites.toggle',{sourceId,channel:channels[1]});
  await h.api.query('pairing.flush');assert.equal(h.calls.cloud.filter(row=>row.action==='push.delta').length,0);
  await h.store.update(state=>{state.samsung_settings_v1=JSON.stringify({['cloud:'+remoteId]:{autoCloudSync:true}});});
  await h.api.query('organization.set',{sourceId,organization:{names:{a:'Remote rename'},hidden:[],order:[],groups:[]}});
  await h.api.query('pairing.flush');const sent=h.calls.cloud.find(row=>row.action==='push.delta').args;
  assert.deepEqual(sent.favorites.map(row=>[row.itemId,row.add]),[['a',true]]);
  assert.ok(sent.settings.some(row=>row.path.join('.')==='channelOrganization.names.a'));
  assert.equal(h.calls.cloud.some(row=>row.action==='push'),false);assert.equal(Object.keys(JSON.parse(h.store.get('samsung_cloud_outbox_v1'))['cloud:'+remoteId].favorites).length,0);
});
test('a toggle made during a delta upload stays durable for the next upload',async()=>{
  const started=deferred(),complete=deferred();let blocked=true;
  const h=harness({cloudProfile:true,cloudRoute(action,args){
    if(action==='profiles.list')return Promise.resolve([{id:remoteId,name:'Remote',pin:null}]);
    if(action==='push.delta'){if(blocked){blocked=false;started.resolve();return complete.promise;}return Promise.resolve({});}
    throw Error('Unexpected '+action);
  }});await h.setup();
  await h.store.update(state=>{state.samsung_settings_v1=JSON.stringify({['cloud:'+remoteId]:{autoCloudSync:true}});});
  await h.api.query('favorites.toggle',{sourceId,channel:channels[1]});const push=h.api.query('pairing.flush');await started.promise;
  await h.api.query('favorites.toggle',{sourceId,channel:channels[1]});complete.resolve({});await push;
  const pending=JSON.parse(h.store.get('samsung_cloud_outbox_v1'))['cloud:'+remoteId];assert.equal(Object.values(pending.favorites)[0].add,false);
  await h.api.query('pairing.flush');assert.equal(Object.keys(JSON.parse(h.store.get('samsung_cloud_outbox_v1'))['cloud:'+remoteId].favorites).length,0);
});
test('cloud pulls overlay pending local favorites and nested organization edits',async()=>{
  const h=harness({cloudProfile:true});await h.setup();
  await h.api.query('favorites.toggle',{sourceId,channel:channels[1]});
  await h.api.query('organization.set',{sourceId,organization:{names:{a:'Offline name'},hidden:[],order:[],groups:[]}});
  await h.store.update(state=>{state.samsung_settings_v1=JSON.stringify({['cloud:'+remoteId]:{autoCloudSync:true}});});
  await h.api.query('pairing.autoSync');
  assert.equal((await h.api.query('sources.list'))[0].settings.channelOrganization.names.a,'Offline name');
  assert.deepEqual((await h.api.query('favorites.list')).items.map(row=>row.channel.id),['a']);
});
test('encrypted backup import adds fresh recovery profiles and preserves the existing owner and user state',async()=>{
  const original=harness();await original.setup();await original.api.query('favorites.toggle',{sourceId,channel:channels[1]});
  const exported=await original.api.query('backup.export',{password:'fixture-password'});assert.ok(exported.bytes instanceof Uint8Array);
  const target=harness();await target.setup();await target.api.query('favorites.toggle',{sourceId,channel:channels[0]});
  const before=target.store.read(),inspection=await target.api.query('backup.inspect',{bytes:exported.bytes,password:'fixture-password'});
  const imported=await target.api.query('backup.import',{token:inspection.token});assert.equal(imported.importedProfiles.length,1);
  const after=target.store.read(),freshId=imported.importedProfiles[0].id;
  assert.equal(after.active_local_profile_id,before.active_local_profile_id);assert.notEqual(freshId,before.active_local_profile_id);
  assert.equal(JSON.parse(after.local_profiles_v1).length,2);assert.deepEqual(JSON.parse(after.local_profiles_v1)[0],JSON.parse(before.local_profiles_v1)[0]);
  const favorites=JSON.parse(after.samsung_favorites_v1);assert.deepEqual(favorites[before.active_local_profile_id],JSON.parse(before.samsung_favorites_v1)[before.active_local_profile_id]);
  assert.equal(favorites[freshId][0].channel.id,'a');assert.equal(after.samsung_settings_v1,before.samsung_settings_v1);
  await target.api.query('profiles.select',{id:freshId});assert.equal((await target.api.query('sources.list'))[0].fields.userAgent,'Keep secret');
  await assert.rejects(target.api.query('backup.import',{token:inspection.token}),error=>error.code==='backup_required');
});
test('resolved favorites from an inactive source never download a catalogue merely to sort',async()=>{
  const h=harness();await h.setup();await h.api.query('favorites.toggle',{sourceId,channel:channels[0]});await h.api.query('sources.cancel');
  const before=h.calls.engine.length;assert.equal((await h.api.query('favorites.list')).items.length,1);assert.equal(h.calls.engine.length,before);
});
test('invalid manual EPG bindings reject before changing persisted overrides',async()=>{
  const h=harness();await h.setup();const before=h.store.read();
  await assert.rejects(h.api.query('guide.mapping.set',{sourceId,channelId:'a',guideId:'invalid',guideChannelId:'a'}),error=>error.code==='epg_mapping_invalid');
  assert.deepEqual(h.store.read(),before);
});
test('a cloud source removal preserves current native playback without causing mirror retries',async()=>{
  const h=harness({cloudProfile:true,cloudRoute(action){
    if(action==='profiles.list')return Promise.resolve([{id:remoteId,name:'Remote',pin:null}]);
    if(action==='pull')return Promise.resolve({profile:{id:remoteId},sources:[],managedSourceIds:[],favorites:[],playbackPositionsAvailable:false});
    throw Error('Unexpected '+action);
  }});await h.setup();await h.api.query('playback.play',{sourceId,channel:channels[0]});
  await h.store.update(state=>{state.samsung_settings_v1=JSON.stringify({['cloud:'+remoteId]:{autoCloudSync:true}});});
  await h.api.query('pairing.autoSync');assert.equal((await h.api.query('sources.list')).length,0);assert.equal(await h.api.query('sources.catalog'),null);assert.equal(h.api.getState().playing,true);
});
test('manual full pushes acknowledge exact represented deltas and preserve toggles made during upload',async()=>{
  const started=deferred(),complete=deferred();let calls=0;
  const h=harness({cloudProfile:true,cloudRoute(action){
    if(action==='profiles.list')return Promise.resolve([{id:remoteId,name:'Remote',pin:null}]);
    if(action==='supporter.status')return Promise.resolve({supported:false});
    if(action==='push'){calls++;if(calls===1){started.resolve();return complete.promise;}return Promise.resolve({favoritesSynced:true});}
    throw Error('Unexpected '+action);
  }});await h.setup();
  await h.api.query('favorites.toggle',{sourceId,channel:channels[1]});await h.api.query('organization.set',{sourceId,organization:{names:{a:'Before push'},hidden:[],order:[],groups:[]}});
  const push=h.api.query('pairing.push',{profileId:remoteId});await started.promise;
  await h.api.query('favorites.toggle',{sourceId,channel:channels[1]});complete.resolve({favoritesSynced:true});await push;
  let pending=JSON.parse(h.store.get('samsung_cloud_outbox_v1'))['cloud:'+remoteId];assert.equal(Object.keys(pending.settings).length,0);assert.equal(Object.values(pending.favorites)[0].add,false);
  await h.api.query('pairing.push',{profileId:remoteId});pending=JSON.parse(h.store.get('samsung_cloud_outbox_v1'))['cloud:'+remoteId];assert.equal(Object.keys(pending.favorites).length,0);
});
