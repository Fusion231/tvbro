(function (root, factory) {
  var api = {create:function (options) { return factory(options || {}, root); }};
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.TVBroSamsungBackup = api;
}(typeof window !== 'undefined' ? window : typeof global !== 'undefined' ? global : this, function (options, root) {
  'use strict';
  // Android AppBackupService v1. Only this encrypted envelope leaves the device.
  var maximumBytes = 32 * 1024 * 1024, iterations = 600000, maximumRows = 200000;
  var environment = options.environment || root, crypto = options.crypto || environment.crypto;
  var subtle = crypto && (crypto.subtle || crypto.webkitSubtle);
  var Encoder = options.TextEncoder || environment.TextEncoder, Decoder = options.TextDecoder || environment.TextDecoder;
  var encode64 = options.btoa || environment.btoa, decode64 = options.atob || environment.atob;
  var settingKeys = ['sources','active_source','metadata_config','local_profiles_v1','active_local_profile_id',
    'profile_picker_startup','profile_state_ownerless','app_language','tvbro_parental_controls_v1','update_track'];
  var tables = {favorites:['source_id','kind','item_id','created_at'],
    playback_positions:['source_id','kind','item_id','position_ms','duration_ms','updated_at'],
    epg_channel_overrides:['source_id','channel_id','guide_id','guide_channel_id','offset_minutes']};
  var defaultDvr = {maxBufferMilliseconds:1800000,maxBufferBytes:1073741824,maxRecordingsBytes:10737418240};
  function failure(code) {
    var error = new Error(code === 'backup_password' ? 'Use a password with at least 8 characters.' :
      code === 'backup_unavailable' ? 'Encrypted backups are unavailable on this TV.' :
      code === 'backup_conflict' ? 'Cannot export profiles with conflicting settings for the same source.' :
      'Incorrect password or damaged backup.'); error.code = code || 'backup_invalid'; return error;
  }
  function invalid() { throw failure('backup_invalid'); }
  function object(value) { return !!value && typeof value === 'object' && !Array.isArray(value); }
  function integer(value, minimum, maximum) { return typeof value === 'number' && isFinite(value) && value % 1 === 0 && value >= minimum && value <= maximum; }
  function identity(value) { return typeof value === 'string' && value.trim().length > 0 && value.length <= 4096; }
  function clone(value) { return JSON.parse(JSON.stringify(value)); }
  function parse(value, fallback) { return value == null ? fallback : typeof value === 'string' ? JSON.parse(value) : value; }
  function readJson(value) {var result = JSON.parse(value);jsonTree(result,0,{left:1500000});return result;}
  function dictionary(value) { if (!object(value)) invalid(); return value; }
  function array(value) { if (!Array.isArray(value)) invalid(); return value; }
  function utf8(value) { return new Encoder().encode(value); }
  function decode(value) { return new Decoder('utf-8', {fatal:true}).decode(value); }
  function base64(bytes) {
    var parts = [];
    for (var start = 0; start < bytes.length; start += 8192) parts.push(String.fromCharCode.apply(null, bytes.subarray(start, start + 8192)));
    return encode64(parts.join(''));
  }
  function unbase64(value, maximum) {
    if (typeof value !== 'string' || value.length % 4 || value.length > Math.ceil(maximum / 3) * 4 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) invalid();
    var raw = decode64(value), bytes = new Uint8Array(raw.length);
    if (bytes.length > maximum) invalid();
    for (var i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
    return bytes;
  }
  function jsonTree(value, depth, budget) {
    if (--budget.left < 0 || depth > 32) invalid();
    if (value === null || typeof value === 'boolean' || typeof value === 'string') return;
    if (typeof value === 'number') { if (!isFinite(value)) invalid(); return; }
    if (!object(value) && !Array.isArray(value)) invalid();
    Object.keys(value).forEach(function (key) {
      if (key === '__proto__' || key === 'constructor' || key === 'prototype') invalid();
      jsonTree(value[key], depth + 1, budget);
    });
  }
  function verifier(value) {
    if (typeof value !== 'string' || value.length > 256) invalid();
    var parts = value.split('$');
    if (parts.length !== 4 || parts[0] !== 'pbkdf2-sha256' || !/^\d+$/.test(parts[1]) || !integer(Number(parts[1]),1,1000000)) invalid();
    var salt = unbase64(parts[2],64); if (salt.length < 8 || unbase64(parts[3],32).length !== 32) invalid();
  }
  function metadata(value) {
    dictionary(value);
    ['provider','tmdbApiKey','tvdbApiKey','tvdbPin','mdblistApiKey'].forEach(function (key) { if (value[key] != null && typeof value[key] !== 'string') invalid(); });
    if (value.autoEnrich != null && typeof value.autoEnrich !== 'boolean') invalid();
  }
  function sources(value) {
    var ids = Object.create(null);
    array(value).forEach(function (source) {
      dictionary(source);
      if (!identity(source.id) || ids[source.id] || ['demo','m3u','xtream','stalker'].indexOf(source.kind) < 0 || typeof source.label !== 'string') invalid();
      ids[source.id] = true; dictionary(source.fields);
      Object.keys(source.fields).forEach(function (key) { if (typeof source.fields[key] !== 'string') invalid(); });
      if (source.settings != null) dictionary(source.settings);
    }); return ids;
  }
  function snapshot(value) {
    dictionary(value); var ids = sources(value.sources || []);
    if (value.activeSourceId != null && !ids[value.activeSourceId]) invalid();
    if (value.metadata != null) metadata(value.metadata);
    if (value.managedIds != null) array(value.managedIds).forEach(function (id) { if (typeof id !== 'string') invalid(); });
  }
  function parental(value) {
    dictionary(value);
    if (value.version !== 1 || typeof value.lockSettings !== 'boolean') invalid();
    if (value.verifier != null) verifier(value.verifier);
    ['channels','categories'].forEach(function (key) {
      array(value[key]).forEach(function (encoded) {
        if (typeof encoded !== 'string') invalid(); var parts = JSON.parse(encoded);
        if (!Array.isArray(parts) || parts.length !== (key === 'channels' ? 2 : 3) || parts.some(function (part) { return typeof part !== 'string'; })) invalid();
      });
    });
  }
  function validateUserState(state) {
    dictionary(state);
    if (Object.keys(state).length !== 3 || Object.keys(state).some(function (key) { return !tables[key]; })) invalid();
    Object.keys(tables).forEach(function (table) {
      var rows = array(state[table]), seen = Object.create(null); if (rows.length > maximumRows) invalid();
      rows.forEach(function (row) {
        dictionary(row); var columns = tables[table], key;
        if (Object.keys(row).length !== columns.length || Object.keys(row).some(function (column) { return columns.indexOf(column) < 0; }) || !identity(row.source_id)) invalid();
        if (table === 'epg_channel_overrides') {
          if (!identity(row.channel_id) || (row.guide_id === null) !== (row.guide_channel_id === null) || row.guide_id !== null && (!identity(row.guide_id) || !identity(row.guide_channel_id)) || !integer(row.offset_minutes,-1440,1440)) invalid();
          key = JSON.stringify([row.source_id,row.channel_id]);
        } else {
          if (!identity(row.item_id) || (table === 'favorites' ? ['live','movie','series'] : ['movie','episode']).indexOf(row.kind) < 0) invalid();
          columns.slice(3).forEach(function (column) { if (!integer(row[column],0,9007199254740991)) invalid(); });
          if (row[table === 'favorites' ? 'created_at' : 'updated_at'] > 8640000000000000) invalid();
          key = JSON.stringify([row.source_id,row.kind,row.item_id]);
        }
        if (seen[key]) invalid(); seen[key] = true;
      });
    });
  }
  function compatibleMappings(rows) {
    var counts = Object.create(null);
    rows.forEach(function (row) {
      if (row.channel_id.length > 1024 || row.guide_channel_id != null && row.guide_channel_id.length > 1024 || row.guide_id != null && !/^[a-f0-9]{64}$/.test(row.guide_id)) invalid();
      counts[row.source_id] = (counts[row.source_id] || 0) + 1; if (counts[row.source_id] > 10000) invalid();
    });
  }
  function validate(payload) {
    dictionary(payload); jsonTree(payload,0,{left:1500000});
    if (payload.version !== 1 || typeof payload.createdAt !== 'string' || !isFinite(Date.parse(payload.createdAt)) || Object.keys(payload).some(function (key) { return ['version','createdAt','settings','userState','dvrSettings'].indexOf(key) < 0; })) invalid();
    var settings = dictionary(payload.settings);
    Object.keys(settings).forEach(function (key) { if ((settingKeys.indexOf(key) < 0 && key.indexOf('playback_v1_') !== 0) || typeof settings[key] !== 'string') invalid(); });
    var ids = sources(readJson(settings.sources)); if (settings.active_source != null && !ids[settings.active_source]) invalid();
    var profiles = array(readJson(settings.local_profiles_v1)), profileIds = Object.create(null);
    profiles.forEach(function (profile) {
      dictionary(profile);
      if (!identity(profile.id) || profileIds[profile.id] || profile.name != null && typeof profile.name !== 'string' || profile.colorIndex != null && !integer(profile.colorIndex,-9007199254740991,9007199254740991)) invalid();
      profileIds[profile.id] = true; if (profile.pin != null && profile.pin !== '') verifier(profile.pin); snapshot(profile.snapshot || {sources:[]});
    });
    if (settings.active_local_profile_id != null && !profileIds[settings.active_local_profile_id]) invalid();
    if (settings.metadata_config != null) metadata(readJson(settings.metadata_config));
    if (settings.tvbro_parental_controls_v1 != null) parental(readJson(settings.tvbro_parental_controls_v1));
    if (settings.app_language != null && ['en','pl'].indexOf(settings.app_language) < 0) invalid();
    if (settings.profile_picker_startup != null && ['auto','always','off'].indexOf(settings.profile_picker_startup) < 0) invalid();
    Object.keys(settings).forEach(function (key) {
      if (key.indexOf('playback_v1_') !== 0) return;
      var encoded = key.slice(12).replace(/-/g,'+').replace(/_/g,'/'); while (encoded.length % 4) encoded += '=';
      var parts = readJson(decode(unbase64(encoded,16384))), pref = dictionary(readJson(settings[key]));
      if (!Array.isArray(parts) || parts.length !== 2 || !identity(parts[0]) || !identity(parts[1])) invalid();
      ['quality','buffer','aspect'].forEach(function (field) { if (pref[field] != null && typeof pref[field] !== 'string') invalid(); });
      ['adaptiveBuffer','matchRefreshRate'].forEach(function (field) { if (pref[field] != null && typeof pref[field] !== 'boolean') invalid(); });
    });
    validateUserState(payload.userState);
    var dvr = dictionary(payload.dvrSettings), duration = dvr.maxBufferMilliseconds == null ? defaultDvr.maxBufferMilliseconds : dvr.maxBufferMilliseconds;
    if (!integer(duration,10000,86400000)) invalid();
    ['maxBufferBytes','maxRecordingsBytes'].forEach(function (key) { if (!integer(dvr[key] == null ? defaultDvr[key] : dvr[key],1048576,9007199254740991)) invalid(); });
    return payload;
  }
  function portableProfile(profile) {
    var result = {id:profile.id,name:profile.name || '',colorIndex:profile.colorIndex || 0,
      snapshot:{sources:clone(profile.snapshot && profile.snapshot.sources || [])}};
    if (profile.pin) result.pin = profile.pin;
    if (profile.snapshot && profile.snapshot.activeSourceId) result.snapshot.activeSourceId = profile.snapshot.activeSourceId;
    if (profile.snapshot && profile.snapshot.metadata) result.snapshot.metadata = clone(profile.snapshot.metadata);
    return result;
  }
  function toPayload(state) {
    dictionary(state);
    var profiles = array(parse(state.local_profiles_v1,[])).map(portableProfile), active = state.active_local_profile_id;
    var recovery = dictionary(parse(state.samsung_backup_recovery_v1,{})), retainedDvr = state.samsung_backup_dvr_v1;
    var cloud = dictionary(parse(state.cloud_profile_snapshots_v1,{})), locks = dictionary(parse(state.cloud_profile_pins_v1,{}));
    Object.keys(cloud).forEach(function (id) {
      var nextId = 'restored-cloud-' + id, suffix = 0;
      while (profiles.some(function (profile) { return profile.id === nextId; })) nextId = 'restored-cloud-' + id + '-' + (++suffix);
      var profile = portableProfile({id:nextId,name:locks[id] && locks[id].name || 'Restored cloud profile',colorIndex:0,pin:locks[id] && locks[id].pin,snapshot:cloud[id]});
      profiles.push(profile);
      if (!active && state.profile_state_ownerless !== '1' && state.cloud_profile_id === id) active = nextId;
    });
    var selected = profiles.filter(function (profile) { return profile.id === active; })[0];
    var settings = {sources:JSON.stringify(selected ? selected.snapshot.sources : []),local_profiles_v1:JSON.stringify(profiles)};
    var savedPreferences = dictionary(parse(state.samsung_backup_preferences_v1,{}));
    var globalRules = parse(state.tvbro_parental_controls_v1,{version:1,verifier:null,lockSettings:true,channels:[],categories:[]}), portableRules = null;
    function policyKey(rules) {parental(rules);return JSON.stringify({version:1,verifier:rules.verifier || null,lockSettings:rules.lockSettings,channels:rules.channels.slice().sort(),categories:rules.categories.slice().sort()});}
    profiles.forEach(function (profile) {
      var saved = recovery[profile.id] || {}, rules = saved.parentalRules || globalRules, encodedRules = policyKey(rules);
      if (portableRules && portableRules !== encodedRules) throw failure('backup_conflict'); portableRules = encodedRules;
      var values = saved.settings || {}, oldPreferences = dictionary(parse(values.samsung_backup_preferences_v1,{}));
      Object.keys(oldPreferences).forEach(function (key) {
        if (savedPreferences[key] && JSON.stringify(parse(savedPreferences[key])) !== JSON.stringify(parse(oldPreferences[key]))) throw failure('backup_conflict');savedPreferences[key] = oldPreferences[key];
      });
      if (values.samsung_backup_dvr_v1 != null) {
        if (retainedDvr != null && JSON.stringify(parse(retainedDvr)) !== JSON.stringify(parse(values.samsung_backup_dvr_v1))) throw failure('backup_conflict');retainedDvr = values.samsung_backup_dvr_v1;
      }
    });
    Object.keys(savedPreferences).forEach(function (key) {if (key.indexOf('playback_v1_') !== 0 || typeof savedPreferences[key] !== 'string') invalid();settings[key] = savedPreferences[key];});
    if (selected) {settings.active_local_profile_id = selected.id;if (selected.snapshot.activeSourceId) settings.active_source = selected.snapshot.activeSourceId;if (selected.snapshot.metadata) settings.metadata_config = JSON.stringify(selected.snapshot.metadata);}
    ['profile_picker_startup','app_language','tvbro_parental_controls_v1','update_track'].forEach(function (key) { if (state[key] != null) settings[key] = state[key]; });
    if (portableRules && (state.tvbro_parental_controls_v1 != null || Object.keys(recovery).length)) settings.tvbro_parental_controls_v1 = portableRules;
    var activeRecovery = recovery[active] && recovery[active].settings || {};
    ['profile_picker_startup','app_language'].forEach(function (key) {if (activeRecovery[key] != null) settings[key] = activeRecovery[key];});
    var userState = {favorites:[],playback_positions:[],epg_channel_overrides:[]}, seen = {favorites:Object.create(null),playback_positions:Object.create(null),epg_channel_overrides:Object.create(null)};
    function add(table,row,key) {
      var encoded = JSON.stringify(row); if (seen[table][key] && seen[table][key] !== encoded) throw failure('backup_conflict');
      if (!seen[table][key]) {seen[table][key] = encoded; userState[table].push(row);}
    }
    var favorites = dictionary(parse(state.samsung_favorites_v1,{})), positions = dictionary(parse(state.samsung_playback_positions_v1,{})), mappings = dictionary(parse(state.samsung_epg_mappings_v1,{}));
    Object.keys(favorites).forEach(function (bucket) { array(favorites[bucket]).forEach(function (entry) {
      var item = entry.item || entry.channel || {}, row = {source_id:entry.sourceId,kind:item.kind || 'live',item_id:item.id,created_at:entry.createdAt == null ? 0 : entry.createdAt}; add('favorites',row,JSON.stringify([row.source_id,row.kind,row.item_id]));
    }); });
    Object.keys(positions).forEach(function (bucket) { Object.keys(dictionary(positions[bucket])).forEach(function (key) {
      var entry = positions[bucket][key]; if (entry.removed) return;
      var item = entry.item || {}, stamp = Date.parse(entry.updatedAt), row = {source_id:entry.sourceId,kind:item.kind,item_id:item.id,
        position_ms:Math.round(entry.position * 1000),duration_ms:Math.round(entry.duration * 1000),updated_at:isFinite(stamp) ? stamp : 0};
      add('playback_positions',row,JSON.stringify([row.source_id,row.kind,row.item_id]));
    }); });
    Object.keys(mappings).forEach(function (bucket) { Object.keys(dictionary(mappings[bucket])).forEach(function (sourceId) {
      Object.keys(dictionary(mappings[bucket][sourceId])).forEach(function (channelId) {
        var entry = mappings[bucket][sourceId][channelId], row = {source_id:sourceId,channel_id:channelId,guide_id:entry.guideId || null,guide_channel_id:entry.guideChannelId || null,offset_minutes:entry.offsetMinutes || 0};
        add('epg_channel_overrides',row,JSON.stringify([sourceId,channelId]));
      });
    }); });
    var preferences = dictionary(parse(state.samsung_playback_preferences_v1,{}));
    Object.keys(preferences).forEach(function (bucket) { Object.keys(dictionary(preferences[bucket])).forEach(function (key) {
      var parts = JSON.parse(key), entry = preferences[bucket][key]; if (!Array.isArray(parts) || parts.length !== 3) invalid();
      var pref = clone(entry.portable || {quality:'auto',buffer:null,adaptiveBuffer:false,matchRefreshRate:false,aspect:null});
      if (entry.aspect) pref.aspect = {fit:'Fit',fill:'Fill',auto:'Auto'}[entry.aspect] || pref.aspect;
      var identityKey = 'playback_v1_' + base64(utf8(JSON.stringify([parts[0],parts[1] + ':' + parts[2]]))).replace(/\+/g,'-').replace(/\//g,'_');
      var encoded = JSON.stringify(pref), previous = settings[identityKey];
      if (previous && JSON.stringify(JSON.parse(previous)) !== JSON.stringify(entry.portable || pref) && previous !== encoded) throw failure('backup_conflict'); settings[identityKey] = encoded;
    }); });
    var payload = {version:1,createdAt:new Date(options.now ? options.now() : Date.now()).toISOString(),settings:settings,userState:userState,dvrSettings:parse(retainedDvr,defaultDvr)};
    compatibleMappings(userState.epg_channel_overrides);
    return validate(payload);
  }
  function toState(payload) {
    validate(payload);
    compatibleMappings(payload.userState.epg_channel_overrides);
    var settings = payload.settings, profiles = JSON.parse(settings.local_profiles_v1).map(portableProfile), active = settings.active_local_profile_id;
    var selected = profiles.filter(function (profile) { return profile.id === active; })[0], currentSources = JSON.parse(settings.sources);
    if (!selected && (currentSources.length || !profiles.length && Object.keys(tables).some(function (key) { return payload.userState[key].length > 0; }))) {
      var id = 'restored-profile', suffix = 0; while (profiles.some(function (profile) {return profile.id === id;})) id = 'restored-profile-' + (++suffix);
      selected = {id:id,name:'Restored profile',colorIndex:0,snapshot:{sources:[]}}; profiles.push(selected); active = id;
    }
    if (selected) {
      selected.snapshot.sources = currentSources;
      delete selected.snapshot.activeSourceId; if (settings.active_source) selected.snapshot.activeSourceId = settings.active_source;
      if (settings.metadata_config) selected.snapshot.metadata = JSON.parse(settings.metadata_config);
    }
    var state = {local_profiles_v1:JSON.stringify(profiles),samsung_sources_migrated_v1:'true',samsung_backup_dvr_v1:JSON.stringify(payload.dvrSettings)}, savedPreferences = {};
    Object.keys(settings).forEach(function (key) {if (key.indexOf('playback_v1_') === 0) savedPreferences[key] = settings[key];});state.samsung_backup_preferences_v1 = JSON.stringify(savedPreferences);
    if (active) state.active_local_profile_id = active; else state.profile_state_ownerless = '1';
    ['profile_picker_startup','app_language','tvbro_parental_controls_v1','update_track'].forEach(function (key) { if (settings[key] != null) state[key] = settings[key]; });
    var favorites = {}, positions = {}, mappings = {}, preferences = {}, history = {};
    profiles.forEach(function (profile) { favorites[profile.id] = [];positions[profile.id] = {};mappings[profile.id] = {};preferences[profile.id] = {};history[profile.id] = []; });
    function owners(sourceId) {
      var matches = profiles.filter(function (profile) { return profile.snapshot.sources.some(function (source) { return source.id === sourceId; }); }).map(function (profile) { return profile.id; });
      return matches.length ? matches : selected ? [selected.id] : profiles.length ? [profiles[0].id] : [];
    }
    payload.userState.favorites.forEach(function (row) {owners(row.source_id).forEach(function (owner) {
      var item = {id:row.item_id,kind:row.kind,title:'',name:''}; favorites[owner].push({sourceId:row.source_id,item:row.kind === 'live' ? null : item,channel:row.kind === 'live' ? item : null,unresolved:true,createdAt:row.created_at});
    });});
    payload.userState.playback_positions.forEach(function (row) {owners(row.source_id).forEach(function (owner) {
      var entry = {sourceId:row.source_id,item:{id:row.item_id,kind:row.kind,title:''},position:row.position_ms / 1000,duration:row.duration_ms / 1000,updatedAt:new Date(row.updated_at).toISOString(),removed:false};
      positions[owner][JSON.stringify([row.source_id,row.kind,row.item_id])] = entry;history[owner].push(entry);
    });});
    payload.userState.epg_channel_overrides.forEach(function (row) {owners(row.source_id).forEach(function (owner) {
      var sourceRows = mappings[owner][row.source_id] || (mappings[owner][row.source_id] = {});
      sourceRows[row.channel_id] = {channelId:row.channel_id,guideId:row.guide_id,guideChannelId:row.guide_channel_id,offsetMinutes:row.offset_minutes};
    });});
    Object.keys(settings).forEach(function (key) {
      if (key.indexOf('playback_v1_') !== 0) return;
      var encoded = key.slice(12).replace(/-/g,'+').replace(/_/g,'/'); while (encoded.length % 4) encoded += '=';
      var parts = JSON.parse(decode(unbase64(encoded,16384))), split = parts[1].indexOf(':'), kind = parts[1].slice(0,split), id = parts[1].slice(split + 1), pref = JSON.parse(settings[key]);
      if (split < 1 || !id) return;
      owners(parts[0]).forEach(function (owner) {
        var aspect = {fit:'fit',fill:'fill',auto:'auto'}[String(pref.aspect || '').toLowerCase()], entry = {portable:pref}; if (aspect) entry.aspect = aspect;
        preferences[owner][JSON.stringify([parts[0],kind,id])] = entry;
      });
    });
    Object.keys(history).forEach(function (owner) {history[owner].sort(function (a,b) {return Date.parse(b.updatedAt) - Date.parse(a.updatedAt);});history[owner] = history[owner].slice(0,120);});
    state.samsung_favorites_v1 = JSON.stringify(favorites);state.samsung_playback_positions_v1 = JSON.stringify(positions);state.samsung_epg_mappings_v1 = JSON.stringify(mappings);
    state.samsung_playback_preferences_v1 = JSON.stringify(preferences);state.samsung_history_v1 = JSON.stringify(history);
    return {state:state,summary:{createdAt:payload.createdAt,sourceCount:currentSources.length,profileCount:profiles.length,favoriteCount:payload.userState.favorites.length}};
  }
  function available() { return !!(subtle && typeof subtle.importKey === 'function' && typeof subtle.deriveKey === 'function' && typeof subtle.encrypt === 'function' && typeof subtle.decrypt === 'function' && crypto && typeof crypto.getRandomValues === 'function' && Encoder && Decoder && encode64 && decode64); }
  function passwordCheck(password) { if (typeof password !== 'string' || password.length < 8 || password.length > 4096) throw failure('backup_password'); }
  function derive(password,salt,usage) {
    return subtle.importKey('raw',utf8(password),{name:'PBKDF2'},false,['deriveKey']).then(function (key) {
      return subtle.deriveKey({name:'PBKDF2',hash:'SHA-256',salt:salt,iterations:iterations},key,{name:'AES-GCM',length:256},false,[usage]);
    });
  }
  function sanitize(error) {
    if (error && ['backup_password','backup_unavailable','backup_conflict'].indexOf(error.code) >= 0) throw error;
    throw failure('backup_invalid');
  }
  function exportPayload(payload,password) {
    return Promise.resolve().then(function () {
      passwordCheck(password); if (!available()) throw failure('backup_unavailable');validate(payload);
      var cleartext = utf8(JSON.stringify(payload)); if (cleartext.length > maximumBytes * 3 / 4 - 1024) invalid();
      var salt = crypto.getRandomValues(new Uint8Array(16)), nonce = crypto.getRandomValues(new Uint8Array(12));
      return derive(password,salt,'encrypt').then(function (key) {
        return subtle.encrypt({name:'AES-GCM',iv:nonce,additionalData:utf8('tvbro.backup|1|AES-256-GCM|PBKDF2-SHA256|600000'),tagLength:128},key,cleartext);
      }).then(function (encrypted) {
        var bytes = new Uint8Array(encrypted), result = utf8(JSON.stringify({format:'tvbro-backup',version:1,algorithm:'AES-256-GCM',kdf:'PBKDF2-SHA256',iterations:iterations,
          salt:base64(salt),nonce:base64(nonce),ciphertext:base64(bytes.subarray(0,bytes.length - 16)),tag:base64(bytes.subarray(bytes.length - 16))}));
        if (result.length > maximumBytes) invalid(); return result;
      });
    }).catch(sanitize);
  }
  function read(bytes,password) {
    return Promise.resolve().then(function () {
      passwordCheck(password); if (!available()) throw failure('backup_unavailable');
      if (typeof bytes === 'string') {if (bytes.length > maximumBytes) invalid();bytes = utf8(bytes);}
      else if (bytes instanceof ArrayBuffer) bytes = new Uint8Array(bytes);
      else if (Array.isArray(bytes)) {if (bytes.length > maximumBytes || bytes.some(function (value) {return !integer(value,0,255);})) invalid();bytes = new Uint8Array(bytes);}
      if (!(bytes instanceof Uint8Array) || !bytes.length || bytes.length > maximumBytes) invalid();
      var envelope = dictionary(JSON.parse(decode(bytes)));
      if (envelope.format !== 'tvbro-backup' || envelope.version !== 1 || envelope.algorithm !== 'AES-256-GCM' || envelope.kdf !== 'PBKDF2-SHA256' || envelope.iterations !== iterations) invalid();
      var salt = unbase64(envelope.salt,16), nonce = unbase64(envelope.nonce,12), tag = unbase64(envelope.tag,16), ciphertext = unbase64(envelope.ciphertext,maximumBytes * 3 / 4);
      if (salt.length !== 16 || nonce.length !== 12 || tag.length !== 16) invalid();
      var combined = new Uint8Array(ciphertext.length + 16); combined.set(ciphertext);combined.set(tag,ciphertext.length);
      return derive(password,salt,'decrypt').then(function (key) {return subtle.decrypt({name:'AES-GCM',iv:nonce,additionalData:utf8('tvbro.backup|1|AES-256-GCM|PBKDF2-SHA256|600000'),tagLength:128},key,combined);});
    }).then(function (cleartext) {return toState(JSON.parse(decode(new Uint8Array(cleartext))));}).catch(function (error) {
      if (error && (error.code === 'backup_password' || error.code === 'backup_unavailable')) throw error;throw failure('backup_invalid');
    });
  }
  return {available:available,maxFileBytes:maximumBytes,validate:validate,validateUserState:validateUserState,
    toPayload:toPayload,toState:toState,exportPayload:exportPayload,exportState:function (state,password) {return Promise.resolve().then(function () {passwordCheck(password);if (!available()) throw failure('backup_unavailable');return exportPayload(toPayload(state),password);}).catch(sanitize);},read:read};
}));
