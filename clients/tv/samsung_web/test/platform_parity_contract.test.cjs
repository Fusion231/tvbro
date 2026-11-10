'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const createPlatform = require('../platform.js');

function fixture(files) {
  const calls = [], documentEvents = {}, events = {};
  let enabled = false, options, guideFailure;
  const environment = {
    TVBroCanonical:{}, TVBroPanelValidation:{friendlyError:error=>error.message},
    TVBroSamsungSecureStore:{create:()=>({})},
    TVBroSamsungUserState:{create:()=>({})},
    TVBroSamsungTransport:{create:()=>({})}, TVBroSamsungAvplay:{},
    TVBroSamsungLibrary:{create:value=>{ options=value; return {
      getState:()=>({}), onState:()=>{},
      stopPlayback:()=>{calls.push('playback.stop');return Promise.resolve();},
      query:action=>{ calls.push(action); return action==='guide'&&guideFailure ? Promise.reject(guideFailure) : Promise.resolve(action==='settings.get'?{settings:{autoCloudSync:enabled}}:{}); }
    }; }},
    document:{hidden:false,addEventListener:(name,listener)=>{documentEvents[name]=listener;}},
    addEventListener:(name,listener)=>{events[name]=listener;}
  };
  const api = createPlatform(environment,{backupFiles:files,player:{onState:()=>{},getState:()=>({})},createSource:()=>{},verifyPin:()=>{},hashPin:()=>{}});
  return {api,calls,options,environment,documentEvents,events,enable:()=>{enabled=true;},rejectGuide:failure=>{guideFailure=failure;}};
}

for(const deferred of [false,true]) test('oversized M3U guide gives the source-settings remedy even during its retry wait: '+deferred,async()=>{
  const kit=fixture();kit.rejectGuide({code:deferred?'epg_retry_deferred':'epg_size_limit',causeCode:'epg_size_limit',retryAt:Date.now()+900000});
  await assert.rejects(kit.api.query('guide'),failure=>{
    assert.match(failure.message,/mniejszy.*EPG/i);assert.match(failure.message,/ustawieniach źródła/);
    assert.match(failure.message,deferred?/\[EPG:RETRY SIZE\]/:/\[EPG:SIZE\]/);return true;
  });
});

test('lifecycle sync stays off until explicit setting, then flushes after stopping playback', async()=>{
  const kit=fixture();
  kit.events.online(); kit.documentEvents.visibilitychange();
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(kit.calls.some(action=>action.startsWith('pairing.')),false);
  kit.enable(); kit.events.online();
  await new Promise(resolve=>setImmediate(resolve));
  assert.ok(kit.calls.includes('pairing.autoSync'));
  kit.calls.length=0; kit.environment.document.hidden=true; kit.documentEvents.visibilitychange();
  await new Promise(resolve=>setImmediate(resolve));
  assert.ok(kit.calls.indexOf('playback.stop')>=0);
  assert.ok(kit.calls.indexOf('playback.stop')<kit.calls.indexOf('pairing.flush'));
});

test('native Samsung platform keeps the hosted HTTPS requirement disabled',()=>{
  const kit=fixture();
  assert.equal(kit.options.requiresHttpsProvider,false);
});

test('backup platform routes preserve typed bytes and actual file capabilities', async()=>{
  const bytes=new Uint8Array([1,2,3]), calls=[];
  const kit=fixture({capabilities:()=>({import:true,export:true}),
    listStorages:async()=>[{label:'removable_a'}],listDirectory:async path=>({path,entries:[]}),
    chooseImport:async path=>{calls.push(path);return bytes;},
    saveExport:async(data,name,directory)=>{assert.equal(data,bytes);return {path:directory+'/'+name};}});
  assert.equal(kit.options.canImportBackup,true); assert.equal(kit.options.canExportBackup,true);
  assert.deepEqual(await kit.api.query('backup.files.list'),{storages:[{label:'removable_a'}]});
  assert.deepEqual(await kit.api.query('backup.files.list',{path:'removable_a'}),{path:'removable_a',entries:[]});
  assert.equal((await kit.api.query('backup.import.read',{path:'removable_a/one.tvbro'})).bytes,bytes);
  assert.deepEqual(calls,['removable_a/one.tvbro']);
  assert.deepEqual(await kit.api.query('backup.export.save',{bytes,filename:'one.tvbro',directoryPath:'removable_a'}),{path:'removable_a/one.tvbro'});
  assert.equal(kit.calls.length,0);
  const unavailable=fixture();
  assert.equal(unavailable.options.canImportBackup,false);
  await assert.rejects(unavailable.api.query('backup.import.read'),{code:'backup_unavailable'});
});
