'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const acorn = require('acorn');
const backup = require('../platform/backup.js').create({crypto:crypto.webcrypto,now:()=>1700000000000});
const password = 'portable-password-ą';
const aad = Buffer.from('tvbro.backup|1|AES-256-GCM|PBKDF2-SHA256|600000');
const source = {id:'provider',kind:'xtream',label:'TV',fields:{host:'https://provider.invalid',username:'user',password:'provider-private',epgUrls:'https://provider.invalid/guide?token=secret'},settings:{hiddenCategories:{live:['adult']}}};
const prefKey = 'playback_v1_' + Buffer.from(JSON.stringify(['provider','live:news'])).toString('base64url');
const legacyPrefKey = 'playback_v1_' + Buffer.from(JSON.stringify(['provider','episode-1'])).toString('base64url');

function payload() {
  const pin='pbkdf2-sha256$10000$'+Buffer.alloc(16,7).toString('base64')+'$'+Buffer.alloc(32,9).toString('base64');
  return {version:1,createdAt:'2026-10-26T12:00:00.000Z',settings:{sources:JSON.stringify([source]),active_source:'provider',
    local_profiles_v1:JSON.stringify([{id:'main',name:'Main',colorIndex:3,pin,snapshot:{sources:[source],activeSourceId:'provider',metadata:{provider:'tvdb',tmdbApiKey:'metadata-private',autoEnrich:false}}}]),
    active_local_profile_id:'main',app_language:'pl',profile_picker_startup:'always',
    tvbro_parental_controls_v1:JSON.stringify({version:1,verifier:pin,lockSettings:true,channels:[JSON.stringify(['provider','news'])],categories:[]}),
    [prefKey]:JSON.stringify({quality:'auto',buffer:'high',adaptiveBuffer:true,matchRefreshRate:true,aspect:'Fill'}),
    [legacyPrefKey]:JSON.stringify({quality:'1080:6000000',buffer:'high',adaptiveBuffer:true,matchRefreshRate:true,aspect:'4:3'})},
    userState:{favorites:[{source_id:'provider',kind:'live',item_id:'news',created_at:1234}],
      playback_positions:[{source_id:'provider',kind:'episode',item_id:'episode-1',position_ms:45000,duration_ms:180000,updated_at:5678}],
      epg_channel_overrides:[{source_id:'provider',channel_id:'news',guide_id:'1'.repeat(64),guide_channel_id:'news.xml',offset_minutes:-60}]},
    dvrSettings:{maxBufferMilliseconds:2700000,maxBufferBytes:67108864,maxRecordingsBytes:536870912}};
}

// Independent Node/OpenSSL implementation of app/lib/data/app_backup.dart's v1
// wire format. Neither direction calls the production module's crypto helpers.
function encryptNative(value,pass=password) {
  const salt=Buffer.alloc(16,0x23),nonce=Buffer.alloc(12,0x45),key=crypto.pbkdf2Sync(pass,salt,600000,32,'sha256');
  const cipher=crypto.createCipheriv('aes-256-gcm',key,nonce);cipher.setAAD(aad);
  const ciphertext=Buffer.concat([cipher.update(JSON.stringify(value),'utf8'),cipher.final()]);
  return Buffer.from(JSON.stringify({format:'tvbro-backup',version:1,algorithm:'AES-256-GCM',kdf:'PBKDF2-SHA256',iterations:600000,
    salt:salt.toString('base64'),nonce:nonce.toString('base64'),ciphertext:ciphertext.toString('base64'),tag:cipher.getAuthTag().toString('base64')}));
}
function decryptNative(bytes,pass=password) {
  const value=JSON.parse(Buffer.from(bytes).toString('utf8')),key=crypto.pbkdf2Sync(pass,Buffer.from(value.salt,'base64'),600000,32,'sha256');
  const decipher=crypto.createDecipheriv('aes-256-gcm',key,Buffer.from(value.nonce,'base64'));decipher.setAAD(aad);decipher.setAuthTag(Buffer.from(value.tag,'base64'));
  return JSON.parse(Buffer.concat([decipher.update(Buffer.from(value.ciphertext,'base64')),decipher.final()]).toString('utf8'));
}

test('module remains ES5 and requires real asynchronous WebCrypto',()=>{
  acorn.parse(fs.readFileSync(path.join(__dirname,'../platform/backup.js'),'utf8'),{ecmaVersion:5});
  assert.equal(backup.available(),true);
  assert.equal(require('../platform/backup.js').create({environment:{}}).available(),false);
});

test('imports independently encrypted Android envelope and preserves PIN, source fields and portable user data',async()=>{
  const original=payload(),result=await backup.read(encryptNative(original),password),state=result.state;
  assert.equal(result.summary.favoriteCount,1);assert.equal(result.summary.profileCount,1);
  assert.equal(JSON.parse(state.local_profiles_v1)[0].snapshot.sources[0].fields.password,'provider-private');
  assert.equal(JSON.parse(state.local_profiles_v1)[0].pin,JSON.parse(original.settings.local_profiles_v1)[0].pin);
  assert.equal(JSON.parse(state.samsung_favorites_v1).main[0].unresolved,true);
  assert.equal(JSON.parse(state.samsung_playback_positions_v1).main[JSON.stringify(['provider','episode','episode-1'])].position,45);
  assert.equal(JSON.parse(state.samsung_epg_mappings_v1).main.provider.news.offsetMinutes,-60);
  assert.equal(JSON.parse(state.samsung_playback_preferences_v1).main[JSON.stringify(['provider','live','news'])].aspect,'fill');
  const projected=backup.toPayload(state);
  assert.deepEqual(projected.userState,original.userState);
  assert.deepEqual(projected.dvrSettings,original.dvrSettings);
  assert.deepEqual(JSON.parse(projected.settings[legacyPrefKey]),JSON.parse(original.settings[legacyPrefKey]));
  assert.deepEqual(JSON.parse(projected.settings[prefKey]),JSON.parse(original.settings[prefKey]));
});

test('Samsung export decrypts through independent AES-GCM/PBKDF2 and never contains plaintext credentials or device sessions',async()=>{
  const state=backup.toState(payload()).state;
  state['supabase.auth.token']='device-token';state.cloud_device_priv_key='device-secret';state.cloud_content_key_x='content-secret';
  const bytes=await backup.exportState(state,password),envelope=Buffer.from(bytes).toString('utf8');
  for(const secret of ['provider-private','metadata-private','device-token','device-secret','content-secret'])assert.equal(envelope.includes(secret),false);
  const clear=decryptNative(bytes);assert.equal(JSON.parse(clear.settings.sources)[0].fields.password,'provider-private');
  for(const key of ['supabase.auth.token','cloud_device_priv_key','cloud_content_key_x'])assert.equal(Object.hasOwn(clear.settings,key),false);
  const restored=await backup.read(bytes,password);assert.deepEqual(restored.summary,{createdAt:'2023-11-14T22:13:20.000Z',sourceCount:1,profileCount:1,favoriteCount:1});
});

test('cached cloud profiles become locked local recovery profiles without pairing identity',()=>{
  const original=payload(),local=JSON.parse(original.settings.local_profiles_v1)[0],state={local_profiles_v1:'[]',cloud_profile_id:'cloud-id',
    cloud_profile_snapshots_v1:JSON.stringify({'cloud-id':local.snapshot}),cloud_profile_pins_v1:JSON.stringify({'cloud-id':{name:'Cloud',pin:local.pin}}),
    samsung_favorites_v1:JSON.stringify({'cloud:cloud-id':[{sourceId:'provider',channel:{id:'news',kind:'live'}}]})};
  const projected=backup.toPayload(state),profiles=JSON.parse(projected.settings.local_profiles_v1);
  assert.equal(profiles[0].id,'restored-cloud-cloud-id');assert.equal(profiles[0].pin,local.pin);
  assert.equal(projected.settings.active_local_profile_id,profiles[0].id);
  assert.equal(projected.settings.cloud_profile_id,undefined);assert.equal(projected.userState.favorites.length,1);
});

test('conflicting profile rows fail instead of silently merging global Android identities',()=>{
  const state=backup.toState(payload()).state,positions=JSON.parse(state.samsung_playback_positions_v1);
  positions.other=JSON.parse(JSON.stringify(positions.main));positions.other[Object.keys(positions.other)[0]].position=90;state.samsung_playback_positions_v1=JSON.stringify(positions);
  assert.throws(()=>backup.toPayload(state),error=>error.code==='backup_conflict');
});

test('additive recovery retention preserves native limits and fails closed on incompatible profile PIN policies',()=>{
  const original=payload(),state=backup.toState(original).state;
  state.samsung_backup_recovery_v1=JSON.stringify({main:{parentalRules:JSON.parse(state.tvbro_parental_controls_v1),settings:{
    app_language:'pl',profile_picker_startup:'always',samsung_backup_dvr_v1:state.samsung_backup_dvr_v1,samsung_backup_preferences_v1:state.samsung_backup_preferences_v1}}});
  delete state.tvbro_parental_controls_v1;delete state.samsung_backup_dvr_v1;delete state.samsung_backup_preferences_v1;
  const projected=backup.toPayload(state);assert.deepEqual(projected.dvrSettings,original.dvrSettings);
  assert.equal(JSON.parse(projected.settings.tvbro_parental_controls_v1).verifier,JSON.parse(original.settings.tvbro_parental_controls_v1).verifier);
  assert.deepEqual(JSON.parse(projected.settings[legacyPrefKey]),JSON.parse(original.settings[legacyPrefKey]));
  const profiles=JSON.parse(state.local_profiles_v1);profiles.push({id:'other',name:'Unprotected',colorIndex:0,snapshot:{sources:[]}});state.local_profiles_v1=JSON.stringify(profiles);
  assert.throws(()=>backup.toPayload(state),error=>error.code==='backup_conflict');
});

test('tampering, wrong passwords and unsafe envelope parameters reject with credential-free errors',async()=>{
  const bytes=encryptNative(payload()),value=JSON.parse(bytes);value.tag=Buffer.alloc(16,1).toString('base64');
  await assert.rejects(backup.read(Buffer.from(JSON.stringify(value)),password),error=>error.code==='backup_invalid'&&!error.message.includes('provider'));
  await assert.rejects(backup.read(bytes,'wrong-password'),error=>error.code==='backup_invalid');
  value.iterations=1;await assert.rejects(backup.read(Buffer.from(JSON.stringify(value)),password),error=>error.code==='backup_invalid');
  await assert.rejects(backup.read(bytes,'short'),error=>error.code==='backup_password');
  await assert.rejects(backup.read(new Uint8Array(backup.maxFileBytes+1),password),error=>error.code==='backup_invalid');
});

test('fixed table/column identities, policy formats and numeric limits validate before state is exposed',()=>{
  const invalid=[];
  let value=payload();value.userState.favorites[0].unexpected='secret';invalid.push(value);
  value=payload();value.userState.favorites.push({...value.userState.favorites[0]});invalid.push(value);
  value=payload();value.userState.playback_positions[0].updated_at=8640000000000001;invalid.push(value);
  value=payload();value.userState.epg_channel_overrides[0].guide_channel_id=null;invalid.push(value);
  value=payload();value.settings['cloud_device_priv_key']='secret';invalid.push(value);
  value=payload();value.settings.local_profiles_v1=JSON.stringify([{id:'main',pin:'0000',snapshot:{sources:[]}}]);invalid.push(value);
  value=payload();value.settings.sources='[{"id":"a","kind":"demo","label":"x","fields":{},"settings":{"__proto__":{"polluted":true}}}]';invalid.push(value);
  value=payload();value.dvrSettings.maxBufferMilliseconds=9999;invalid.push(value);
  for(const row of invalid)assert.throws(()=>backup.toState(row));
});

test('Samsung projection admits only core-compatible EPG bindings and at most 10,000 per source',()=>{
  let value=payload();value.userState.epg_channel_overrides[0].guide_id='not-a-guide-hash';assert.throws(()=>backup.toState(value));
  value=payload();value.userState.epg_channel_overrides[0].channel_id='c'.repeat(1025);assert.throws(()=>backup.toState(value));
  value=payload();value.userState.epg_channel_overrides[0].guide_channel_id='c'.repeat(1025);assert.throws(()=>backup.toState(value));
  value=payload();const row=value.userState.epg_channel_overrides[0];value.userState.epg_channel_overrides=Array.from({length:10001},(_,i)=>({...row,channel_id:'channel-'+i}));assert.throws(()=>backup.toState(value));
});
