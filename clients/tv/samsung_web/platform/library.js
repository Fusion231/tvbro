(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = { create: factory };
  if (root) root.TVBroSamsungLibrary = { create: factory };
}(typeof window !== 'undefined' ? window : this, function (options) {
  'use strict';
  var organization = typeof require === 'function' ? require('./organization.js') : window.TVBroSamsungOrganization;
  var core = options.core, storage = options.userState, player = options.player;
  var transport = options.transport, cloud = options.cloud;
  var catalogStore = options.catalogStore;
  var requiresHttpsProvider = options.requiresHttpsProvider === true;
  var hostedHttpMessage = 'This provider uses HTTP. This TV version needs HTTPS. Ask your provider for an HTTPS address or use TVBro on Android, Windows or Samsung.';
  var cacheMigrationMessage = 'Saved source data could not be moved safely. The source settings were not changed.';
  var scheduleTimer = options.setTimeout || setTimeout, cancelTimer = options.clearTimeout || clearTimeout;
  var backupCodec = options.backup || (typeof require==='function' ? require('./backup.js').create({}) :
    typeof window!=='undefined' && window.TVBroSamsungBackup ? window.TVBroSamsungBackup.create({environment:window}) : null);
  var backupInspection = null;
  var createSource = options.createSource || core.createSource;
  var verifyPin = options.verifyPin || core.verifyPin, hashPin = options.hashPin || core.hashPin;
  var cachePolicy = core.providerCachePolicy ? JSON.parse(core.providerCachePolicy()) : { catalogMaxAgeMs: 0 };
  var now = options.now || Date.now;
  var maximumReadCacheChars = 2 * 1024 * 1024, maximumReadCacheEntries = 128;
  var active = null, revision = 0, playRevision = 0, unlockedProfile = null;
  var loadingStage = null, loadingRevision = 0, guideTicket = 0, guideFlight = null, guideFlightKey = null, guideCache = null, guideFailure = null, guideRevision = 0;
  var catalogKinds = ['live', 'movie', 'series'];
  var playing = null, savedAt = 0;
  var historyWrite = Promise.resolve();
  var cloudUnlocked = {};
  var cloudListingAvailable = false, cloudProfiles = [], cloudActiveId = null, cloudBootstrapStatus = null;
  var mutationState = null, mutationProfile = null;
  var parentalUnlocked = null, libraryRevision = 0, catalogRevision = 0;
  var autoTimer = null, autoPullTimer = null, autoPlaybackTimer = null, autoRetry = 0, autoPullRetry = 0, autoStarted = null, autoLastPull = 0, autoOperations = Promise.resolve(), disposed = false;
  var syncedSettingKeys = ['aspectMode','bufferPreset','catchupTimezone','catchupOffsetMinutes','catchupMaxDays','expiryReminderDays','streamExtension','hiddenCategories','channelOrganization'];
  var K = { profiles: 'local_profiles_v1', active: 'active_local_profile_id',
    cloudId: 'cloud_profile_id', cloudSources: 'cloud_source_ids', cloudPins: 'cloud_profile_pins_v1',
    cloudSnapshots: 'cloud_profile_snapshots_v1', ownerless: 'profile_state_ownerless',
    settings: 'samsung_settings_v1', pickerStartup: 'profile_picker_startup', favorites: 'samsung_favorites_v1',
    positions: 'samsung_playback_positions_v1', history: 'samsung_history_v1', playbackSync: 'samsung_playback_sync_v1',
    parental: 'tvbro_parental_controls_v1', mappings: 'samsung_epg_mappings_v1', preferences: 'samsung_playback_preferences_v1',
    outbox: 'samsung_cloud_outbox_v1', recovery: 'samsung_backup_recovery_v1', migrated: 'samsung_sources_migrated_v1' };
  function parsed(value, fallback) { return value == null ? fallback : typeof value === 'string' ? JSON.parse(value) : value; }
  function copy(value) { return JSON.parse(JSON.stringify(value)); }
  function error(message, code) { var value = new Error(message); value.code = code; return value; }
  function hostedHttpSource(config) {
    if (!requiresHttpsProvider || !config || !config.fields) return false;
    var fields = config.fields;
    if (config.kind === 'xtream') {
      var host = String(fields.host || '').trim();
      return !!host && !/^https:\/\//i.test(host);
    }
    if (config.kind !== 'm3u') return false;
    return [fields.playlistUrl, fields.epgUrl, fields.epgUrls].some(function (value) {
      return String(value || '').split(/\r?\n/).some(function (url) { return /^\s*http:/i.test(url); });
    });
  }
  function epgError(code, status, causeCode, retryAt) {
    var codes = ['epg_timeout', 'epg_network', 'epg_size_limit', 'epg_invalid_data', 'epg_http', 'epg_retry_deferred', 'epg_unsupported', 'epg_unavailable'];
    var value = error('Program telewizyjny jest niedostępny.', codes.indexOf(code) >= 0 ? code : 'epg_unavailable');
    value.name = 'EpgError';
    if (value.code === 'epg_retry_deferred' && codes.indexOf(causeCode) >= 0 && causeCode !== 'epg_retry_deferred') value.causeCode = causeCode;
    if ((value.code === 'epg_http' || value.causeCode === 'epg_http') && typeof status === 'number' && status % 1 === 0 && status >= 100 && status <= 599) value.status = status;
    if (typeof retryAt === 'number' && isFinite(retryAt) && retryAt % 1 === 0 && retryAt > 0) value.retryAt = retryAt;
    return value;
  }
  function beginLoading(stage) {
    var expected = ++loadingRevision;
    function update(value) {
      if (expected !== loadingRevision) return;
      loadingStage = value;
      if (options.onProgress) options.onProgress();
    }
    update(stage);
    return update;
  }
  function decode(key, fallback, state) { return parsed((state || storage.read())[key], fallback); }
  function profiles(state) {
    var rows = decode(K.profiles, [], state);
    return core.profileNormalize ? parsed(core.profileNormalize(JSON.stringify(rows))) : rows;
  }
  function objectValue(key, fallback, state) {
    try {
      var value = decode(key, fallback, state);
      return value && typeof value === 'object' && !Array.isArray(value) ? value : fallback;
    } catch (_) { return fallback; }
  }
  function cloudSnapshot(state, id) {
    var value = objectValue(K.cloudSnapshots, {}, state)[id];
    if (!value || typeof value !== 'object' || Array.isArray(value)) return { sources: [], managedIds: [] };
    return copy(value);
  }
  function cloudPinCache(state) { return objectValue(K.cloudPins, {}, state); }
  function cloudRow(id) {
    return cloudProfiles.filter(function (profile) { return profile.id === id; })[0] || null;
  }
  function cloudProfile(state, id) {
    if (!id) return null;
    var row = cloudRow(id), lock = cloudPinCache(state)[id];
    if (cloudListingAvailable) {
      if (!row) return null;
    } else {
      // Offline fallback mirrors the native picker: only the active cloud
      // profile with a cached lock is drawable, so the PIN gate stays closed.
      if (!lock || typeof lock.pin !== 'string' || !lock.pin) return null;
      row = { id: id, name: lock.name || 'Cloud profile', pin: lock.pin };
    }
    var pin = row.pin || (lock && lock.pin) || null;
    return { id: id, name: row.name || (lock && lock.name) || 'Cloud profile',
      colorIndex: colorIndex(id), pin: pin, source: 'cloud', snapshot: cloudSnapshot(state, id) };
  }
  function colorIndex(id) {
    var value = 0;
    for (var i = 0; i < id.length; i++) value = (value * 31 + id.charCodeAt(i)) & 0x7fffffff;
    return value % 6;
  }
  function current(state, rows) {
    state = state || storage.read();
    var local = (rows || profiles(state)).filter(function (p) { return p.id === state[K.active]; })[0];
    if (local) { local.source = 'local'; return local; }
    if (mutationState === state && mutationProfile && mutationProfile.source === 'cloud') return mutationProfile;
    if (state[K.ownerless] === '1') return null;
    var id = cloudListingAvailable ? cloudActiveId : state[K.cloudId];
    return cloudProfile(state, id);
  }
  function viewProfile(profile) {
    return profile && { id: profile.id, name: profile.name, colorIndex: profile.colorIndex,
      source: profile.source || 'local', pinSet: !!profile.pin,
      locked: !!profile.pin && (profile.source === 'cloud' ? cloudUnlocked[profile.id] !== profile.pin : unlockedProfile !== profile.id) };
  }
  function mutate(change) { return storage.update(function (state) { change(state); return state; }); }
  function mutateProfile(id, change, expectedSource) {
    return mutate(function (state) {
      var profile = current(state);
      if (!profile || profile.id !== id || (expectedSource && profile.source !== expectedSource)) throw error('Profil został zmieniony.', 'cancelled');
      mutationState = state; mutationProfile = profile;
      try { change(state); }
      finally { mutationState = null; mutationProfile = null; }
      if (profile.source === 'cloud') saveCloudSnapshotInState(state, profile.id, profile.snapshot);
    });
  }
  function setProfiles(state, rows) {
    rows.forEach(function (profile) { if (profile) delete profile.source; });
    state[K.profiles] = JSON.stringify(rows);
  }
  function saveCloudSnapshotInState(state, id, snapshot) {
    var all = objectValue(K.cloudSnapshots, {}, state);
    all[id] = copy(snapshot || { sources: [], managedIds: [] });
    state[K.cloudSnapshots] = JSON.stringify(all);
  }
  function saveCurrentSnapshotInState(state) {
    var profile = current(state);
    if (!profile || !profile.snapshot) return;
    if (profile.source === 'cloud') saveCloudSnapshotInState(state, profile.id, profile.snapshot);
    else {
      var rows = profiles(state), target = rows.filter(function (row) { return row.id === profile.id; })[0];
      if (target) { target.snapshot = copy(profile.snapshot); setProfiles(state, rows); }
    }
  }
  function allowedProfile() {
    var profile = current();
    if (!profile) throw error('Najpierw utwórz lub wybierz profil.', 'profile_required');
    if (profile.pin && (profile.source === 'cloud' ? cloudUnlocked[profile.id] !== profile.pin : unlockedProfile !== profile.id)) {
      throw error('Podaj PIN profilu.', 'pin_required');
    }
    return profile;
  }
  function configList() { var p = allowedProfile(); return copy((p.snapshot && p.snapshot.sources) || []); }
  function profileBucket(key, fallback, state) {
    state = state || storage.read();
    var p = current(state);
    return decode(key, {}, state)[p ? bucketId(p) : ''] || fallback;
  }
  function bucketId(profile) { return profile.source === 'cloud' ? 'cloud:' + profile.id : profile.id; }
  function writeBucket(state, key, value) {
    var p = current(state), all = decode(key, {}, state);
    if (!p) throw error('Wybierz profil.', 'profile_required');
    all[bucketId(p)] = value; state[key] = JSON.stringify(all);
  }
  function validPickerStartup(value) { return value === 'auto' || value === 'always' || value === 'off'; }
  function profilePickerStartup(state, profile) {
    if (validPickerStartup(state[K.pickerStartup])) return state[K.pickerStartup];
    if (Object.prototype.hasOwnProperty.call(state, K.pickerStartup)) return 'auto';
    var all = objectValue(K.settings, {}, state), bucket = profile && all[bucketId(profile)];
    return bucket && validPickerStartup(bucket.profilePickerStartup) ? bucket.profilePickerStartup : 'auto';
  }
  function migratePickerStartup() {
    return mutate(function (state) {
      if (Object.prototype.hasOwnProperty.call(state, K.pickerStartup)) {
        if (!validPickerStartup(state[K.pickerStartup])) state[K.pickerStartup] = 'auto';
        return;
      }
      var profile = current(state), all = objectValue(K.settings, {}, state);
      var key = profile ? bucketId(profile) : '', bucket = all[key];
      state[K.pickerStartup] = bucket && validPickerStartup(bucket.profilePickerStartup)
        ? bucket.profilePickerStartup : 'auto';
      if (bucket && Object.prototype.hasOwnProperty.call(bucket, 'profilePickerStartup')) {
        delete bucket.profilePickerStartup;
        state[K.settings] = JSON.stringify(all);
      }
    });
  }
  function effectiveSettings(state, profile, includeProfileSettings) {
    var value = includeProfileSettings && profile ? profileBucket(K.settings, {}, state) : {};
    delete value.profilePickerStartup;
    value.profilePickerStartup = profilePickerStartup(state, profile);
    return value;
  }
  function languageOptions() {
    if (!core || typeof core.appLanguages !== 'function') return [];
    var rows = parsed(core.appLanguages(), []);
    return Array.isArray(rows) ? rows.filter(function (row) {
      return row && typeof row.code === 'string' && typeof row.name === 'string';
    }) : [];
  }
  function languageState() {
    var languages = languageOptions(), stored = storage.get('app_language');
    var selected = languages.filter(function (row) { return row.code === stored; })[0] || null;
    return { languages: languages, languageCode: selected ? selected.code : 'en', languageSelected: !!selected };
  }
  function sourceConfig(id) {
    var config = configList().filter(function (row) { return row.id === (id || active && active.config.id); })[0];
    if (!config) throw error('Nie znaleziono źródła.', 'source_required');
    return config;
  }
  function contentAllowed(sourceId, item, kind) {
    var rules = parental();
    if (!rules.verifier || parentalUnlocked === rules.verifier) return true;
    return !parsed(core.parentalRules('protects', JSON.stringify({rules:rules,sourceId:sourceId,
      id:item.id,kind:kind || item.kind || 'live',categoryId:item.categoryId || null})));
  }
  function allowedIdIndex(sourceId,items,kind) {
    var rules=parental();
    if (!rules.verifier || parentalUnlocked===rules.verifier) return null;
    var ids=parsed(core.parentalRules('visibleIds',JSON.stringify({rules:rules,sourceId:sourceId,kind:kind,
      items:items.map(function (item) {return {id:item.id,categoryId:item.categoryId || null};})}))),index=Object.create(null);
    ids.forEach(function (id) {index[id]=true;});return index;
  }
  function visibleCategories(config, categories, kind, includeHidden) {
    var hidden = organization.hiddenCategories(config.settings, kind);
    if (includeHidden) return categories;
    var allowed=allowedIdIndex(config.id,categories.map(function (row) {return {id:row.id,categoryId:row.id};}),kind);
    return categories.filter(function (row) { return hidden.indexOf(row.id) < 0 && (!allowed || allowed[row.id]); });
  }
  function visibleChannels(config, channels, includeHidden) {
    var hidden = organization.hiddenCategories(config.settings, 'live');
    var allowed=includeHidden ? null : allowedIdIndex(config.id,channels,'live');
    var organized = organization.apply(channels, config.settings && config.settings.channelOrganization, includeHidden);
    // Keep the public result detached from the provider snapshot, but avoid a
    // JavaScript predicate call for every row when no visibility rule applies.
    if (includeHidden || !hidden.length && !allowed) return organized.slice();
    return organized.filter(function (row) {
      return includeHidden || hidden.indexOf(row.categoryId) < 0 && (!allowed || allowed[row.id]);
    });
  }
  function visibleMedia(config,items,kind) {
    var hidden=organization.hiddenCategories(config.settings,kind),allowed=allowedIdIndex(config.id,items,kind);
    return items.filter(function (item) {return hidden.indexOf(item.categoryId)<0 && (!allowed || allowed[item.id]);});
  }
  function catalogView(source) {
    var config = sourceConfig(source.config.id), org = organization.normalize(config.settings && config.settings.channelOrganization);
    var view = {source:copy(config),expiry:expiryView(config,source.expiry),categories:visibleCategories(config,source.categories.concat(org.groups.map(function (group) {
      return {id:group.id,name:group.name,title:group.name,channelIds:group.channels,custom:true};
    })),'live'),channels:visibleChannels(config,source.channels),capabilities:capabilities(),cachePersisted:source.cachePersisted};
    if (source.preparation) view.preparation = copy(source.preparation);
    return view;
  }
  function expiryView(config, value) {
    value=value || {kind:'unknown',date:null};
    var reminder=Number(config.settings && config.settings.expiryReminderDays || 0),date=Date.parse(value.date),notice=null;
    if (isFinite(date)) {if (now()>=date) notice='expired';else if (reminder>0 && now()>=date-reminder*86400000) notice='reminder';}
    return {kind:value.kind || 'unknown',date:value.date || null,reminderDays:reminder,notice:notice};
  }
  function organizationGet(args) {
    var config = sourceConfig(args.sourceId), kind = args.kind || 'live';
    var ready = active && active.config.id === config.id ? Promise.resolve() : selectSource({id:config.id});
    return ready.then(function () {
      var org = organization.normalize(config.settings && config.settings.channelOrganization);
      return (kind === 'live' ? Promise.resolve(active.categories.concat(org.groups.map(function (group) {
        return {id:group.id,name:group.name,title:group.name,channelIds:group.channels,custom:true};
      }))) : invoke('mediaCategories',{kind:kind})).then(function (categories) {
        return {sourceId:config.id,organization:org,channels:visibleChannels(config,active.channels,true),
          categories:categories,hiddenCategoryIds:organization.hiddenCategories(config.settings,kind),catalog:catalogView(active)};
      });
    });
  }
  function saveSourceSettings(args, settings, fields) {
    var owner = allowedProfile(), config = sourceConfig(args.sourceId), before = copy(config);
    config.settings = Object.assign({},config.settings || {},settings || {});
    config.fields = Object.assign({},config.fields || {},fields || {});
    Object.keys(config.settings).forEach(function (key) { if (config.settings[key] == null) delete config.settings[key]; });
    var invalid = options.validation.validateSource(config.kind,config.label,config.fields);
    if (invalid) return Promise.reject(error(invalid));
    return authorize(args).then(function () { return mutateProfile(owner.id,function (state) {
      var all=profiles(state),p=current(state,all), index=p.snapshot.sources.map(function (row) { return row.id; }).indexOf(config.id);
      if (index < 0) throw error('Nie znaleziono źródła.');
      p.snapshot.sources[index]=config; if (owner.source==='local') setProfiles(state,all);
      queueSettingsInState(state,owner,before,config);
    },owner.source); }).then(function () {
      if (active && active.config.id === config.id) {
        // Presentation-only settings do not discard the warm provider cache.
        var engineKeys=['catchupTimezone','catchupOffsetMinutes','catchupMaxDays','streamExtension','maximumStreams'];
        var rebuild=JSON.stringify(before.fields)!==JSON.stringify(config.fields) || engineKeys.some(function (key) {
          return JSON.stringify(before.settings && before.settings[key])!==JSON.stringify(config.settings[key]);
        });
        if (rebuild) return selectSource({id:config.id});
        active.config=copy(config);
      }
    }).then(function () { scheduleAutoPush(); return config; });
  }
  function sourceSettingsGet(args) {
    var config=sourceConfig(args.sourceId), values=config.settings || {},nativeCapabilities=player.getCapabilities ? player.getCapabilities() : {},buffers=nativeCapabilities.bufferPresets || ['default'];
    var schema=[
      {key:'epgUrls',scope:'fields',type:'urls',label:'Dodatkowe adresy EPG',value:config.fields.epgUrls || '',maxItems:3},
      {key:'catchupTimezone',type:'text',label:'Strefa czasowa archiwum',value:values.catchupTimezone || ''},
      {key:'catchupOffsetMinutes',type:'number',label:'Przesunięcie archiwum (min)',value:values.catchupOffsetMinutes || 0,min:-1440,max:1440},
      {key:'catchupMaxDays',type:'number',label:'Limit dni archiwum',value:values.catchupMaxDays == null ? '' : values.catchupMaxDays,min:0,max:365},
      {key:'maximumStreams',type:'number',label:'Limit równoległych strumieni',value:values.maximumStreams == null ? '' : values.maximumStreams,min:0,max:100},
      {key:'expiryReminderDays',type:'select',label:'Przypomnienie o wygaśnięciu',value:values.expiryReminderDays || 0,options:[0,1,7,30].map(function (n) { return {value:n,label:String(n)}; })},
      {key:'bufferPreset',type:'select',label:'Bufor odtwarzania',value:buffers.indexOf(values.bufferPreset)>=0?values.bufferPreset:'default',options:buffers.filter(function (v) {return v==='default' || v==='stable';}).map(function (v) { return {value:v,label:v}; })}
    ];
    if (config.kind==='m3u') schema.unshift({key:'epgUrl',scope:'fields',type:'text',label:'Główny adres EPG',value:config.fields.epgUrl || ''});
    if (config.kind==='xtream') schema.push({key:'streamExtension',type:'select',label:'Format strumienia',value:values.streamExtension || 'ts',options:['ts','m3u8'].map(function (v) { return {value:v,label:v}; })});
    var ready=active && active.config.id===config.id ? Promise.resolve() : selectSource({id:config.id});
    return ready.then(function () {return invoke('subscriptionExpiry',{});}).then(function (expiry) {
      if (active && active.config.id===config.id) active.expiry=expiry;
      return {sourceId:config.id,settings:values,config:config,fields:schema,expiry:expiryView(config,expiry)};
    });
  }
  function validateSourceSettings(args) {
    var settings=copy(args.settings || {}), fields=copy(args.fields || {});
    ['catchupOffsetMinutes','catchupMaxDays','expiryReminderDays','maximumStreams'].forEach(function (key) {
      if (!Object.prototype.hasOwnProperty.call(settings,key)) return;
      if (settings[key] === '' || settings[key] == null) {settings[key]=null;return;}
      var value=Number(settings[key]), minimum=key==='catchupOffsetMinutes'?-1440:0, maximum=key==='catchupMaxDays'?365:key==='maximumStreams'?100:1440;
      if (!isFinite(value) || value%1 || value<minimum || value>maximum || key==='expiryReminderDays' && [0,1,7,30].indexOf(value)<0) throw error('Nieprawidłowa wartość ustawienia.','settings_invalid');
      settings[key]=value;
    });
    if (settings.bufferPreset != null && ['default','stable','low','normal','high','max'].indexOf(settings.bufferPreset)<0) throw error('Nieprawidłowy bufor.','settings_invalid');
    if (settings.streamExtension != null && ['ts','m3u8'].indexOf(settings.streamExtension)<0) throw error('Nieprawidłowy format strumienia.','settings_invalid');
    if (fields.epgUrls != null) {
      var urls=String(fields.epgUrls).split(/\r?\n/).map(function (line) {return line.trim();}).filter(Boolean);
      if (urls.length>3 || urls.some(function (url) { return !/^https?:\/\/[^\s]+$/i.test(url); })) throw error('Podaj maksymalnie trzy dodatkowe adresy EPG.','settings_invalid');
      fields.epgUrls=urls.join('\n');
    }
    if (fields.epgUrl && !/^https?:\/\/[^\s]+$/i.test(fields.epgUrl)) throw error('Podaj poprawny adres EPG.','settings_invalid');
    return {settings:settings,fields:fields};
  }
  function mappingsFor(sourceId, state) {
    var rows=profileBucket(K.mappings,{},state)[sourceId] || {};
    return Object.keys(rows).map(function (id) {return rows[id];});
  }
  function plain(value) {return value && typeof value==='object' && !Array.isArray(value);}
  function settingsPatch(target, patch) {
    var result=copy(target || {});
    Object.keys(patch || {}).forEach(function (key) {
      if (patch[key]===null) delete result[key];
      else result[key]=plain(patch[key]) ? settingsPatch(plain(result[key])?result[key]:{},patch[key]) : copy(patch[key]);
    });
    return result;
  }
  function pendingOutbox(state) {return profileBucket(K.outbox,{favorites:{},settings:{},drafts:{}},state);}
  function queueSettingsInState(state, owner, before, config) {
    if (owner.source!=='cloud') return;
    var pending=pendingOutbox(state);pending.settings=pending.settings || {};pending.drafts=pending.drafts || {};
    function diff(previous,next,path) {
      if (JSON.stringify(previous)===JSON.stringify(next)) return;
      if (plain(previous) || plain(next)) {
        var previousObject=plain(previous)?previous:{},nextObject=plain(next)?next:{},keys=Object.keys(previousObject).concat(Object.keys(nextObject));
        organization.strings(keys).forEach(function (key) {diff(previousObject[key],nextObject[key],path.concat([key]));});return;
      }
      var key=JSON.stringify([config.id,path]);
      pending.settings[key]={sourceId:config.id,path:path,value:next===undefined?null:copy(next),version:core.newSourceId()};
    }
    syncedSettingKeys.forEach(function (key) {diff(before.settings && before.settings[key],config.settings && config.settings[key],[key]);});
    if (JSON.stringify(before.fields)!==JSON.stringify(config.fields)) pending.drafts[config.id]='edit';
    writeBucket(state,K.outbox,pending);
  }
  function queueFavoriteInState(state,owner,sourceId,item,add) {
    if (owner.source!=='cloud' || ['live','movie','series'].indexOf(item.kind || 'live')<0) return;
    var pending=pendingOutbox(state);pending.favorites=pending.favorites || {};
    pending.favorites[dataKey(sourceId,item)]={sourceId:sourceId,kind:item.kind || 'live',itemId:item.id,add:add,version:core.newSourceId()};
    writeBucket(state,K.outbox,pending);
  }
  function sourcePatch(changes, sourceId) {
    var patch={};
    Object.keys(changes || {}).forEach(function (key) {
      var change=changes[key];if (change.sourceId!==sourceId) return;
      var node=patch;
      change.path.forEach(function (part,index) {if (index===change.path.length-1) node[part]=change.value;else node=node[part] || (node[part]={});});
    });return patch;
  }
  function enqueueAuto(operation) {
    var pending=autoOperations.catch(function () {}).then(operation);
    autoOperations=pending.catch(function () {});return pending;
  }
  function autoEnabled() {return profileBucket(K.settings,{}).autoCloudSync===true;}
  function scheduleAutoPull(delay) {
    if (disposed || !autoEnabled()) return;
    clearTimeout(autoPullTimer);autoPullTimer=setTimeout(function () {
      autoPullTimer=null;enqueueAuto(autoPull).catch(function () {autoPullRetry=Math.min(300000,autoPullRetry?autoPullRetry*2:30000);scheduleAutoPull(autoPullRetry);});
    },delay || 0);
  }
  function autoPush() {
    var owner=current();
    if (disposed || !autoEnabled() || !cloud || !cloud.hasSession() || !owner || owner.source!=='cloud' || viewProfile(owner).locked) return Promise.resolve({sent:false});
    var snapshot=copy(pendingOutbox()),managed=owner.snapshot.managedIds || [],present=(owner.snapshot.sources || []).map(function (row) {return row.id;});
    var favorites=Object.keys(snapshot.favorites || {}).map(function (key) {return snapshot.favorites[key];}).filter(function (row) {return managed.indexOf(row.sourceId)>=0 && present.indexOf(row.sourceId)>=0;});
    var settings=Object.keys(snapshot.settings || {}).map(function (key) {return snapshot.settings[key];}).filter(function (row) {return managed.indexOf(row.sourceId)>=0 && present.indexOf(row.sourceId)>=0;});
    if (!favorites.length && !settings.length) return Promise.resolve({sent:false});
    return cloud.query('push.delta',{profileId:owner.id,favorites:favorites,settings:settings}).then(function () {
      return mutateProfile(owner.id,function (state) {
        var pending=pendingOutbox(state);
        ['favorites','settings'].forEach(function (type) {Object.keys(snapshot[type] || {}).forEach(function (key) {
          var row=snapshot[type][key];if (managed.indexOf(row.sourceId)<0 || present.indexOf(row.sourceId)<0) return;
          if (pending[type] && pending[type][key] && pending[type][key].version===row.version) delete pending[type][key];
        });});writeBucket(state,K.outbox,pending);
      },'cloud');
    }).then(function () {autoRetry=0;return {sent:true};});
  }
  function scheduleAutoPush(delay) {
    if (disposed || !autoEnabled()) return;
    clearTimeout(autoTimer);autoTimer=setTimeout(function () {
      autoTimer=null;enqueueAuto(autoPush).catch(function (failure) {
        if (failure.code==='cancelled') return;
        autoRetry=Math.min(300000,autoRetry ? autoRetry*2 : 30000);scheduleAutoPush(autoRetry);
      });
    },delay==null?5000:delay);
  }
  function autoPull() {
    var owner=current();
    if (disposed || !autoEnabled() || !cloud || !cloud.hasSession() || !owner || owner.source!=='cloud' || viewProfile(owner).locked || now()-autoLastPull<30000) return Promise.resolve({synced:false});
    var expected=revision,target=copy(owner.snapshot),sync=profileBucket(K.playbackSync,null);
    return cloud.query('pull',{profileId:owner.id,localSources:target.sources,localMetadata:target.metadata || {},playbackSync:sync,deferProfileSelection:true}).then(function (snapshot) {
      check(expected);
      if (!snapshot.profile || snapshot.profile.id!==owner.id || !Array.isArray(snapshot.sources)) throw error('Nieprawidłowy profil chmurowy.','cloud_profile_required');
      if ((snapshot.profile.pin || null)!==(owner.pin || null)) {
        cloudProfiles=cloudProfiles.map(function (profile) {return profile.id===owner.id?Object.assign({},profile,{pin:snapshot.profile.pin || null}):profile;});
        delete cloudUnlocked[owner.id];
        if (snapshot.profile.pin) return cacheCloudPins(cloudProfiles).then(function () {throw error('Podaj PIN profilu z panelu.','pin_required');});
      }
      return mutateProfile(owner.id,function (state) {
        check(expected);var p=current(state),pending=pendingOutbox(state),previous=p.snapshot.sources || [],prior=p.snapshot.managedIds || [];
        var remote=snapshot.sources.filter(function (row) {return !pending.drafts || pending.drafts[row.id]!=='remove';}).map(function (row) {
          var local=previous.filter(function (source) {return source.id===row.id;})[0];
          if (pending.drafts && pending.drafts[row.id]==='edit' && local) {row.kind=local.kind;row.label=local.label;row.fields=local.fields;}
          row.settings=settingsPatch(row.settings,sourcePatch(pending.settings,row.id));return row;
        });
        previous.forEach(function (row) {if ((prior.indexOf(row.id)<0 || pending.drafts && pending.drafts[row.id]==='edit') && !remote.some(function (source) {return source.id===row.id;})) remote.push(row);});
        p.snapshot.sources=remote;p.snapshot.managedIds=snapshot.managedSourceIds || snapshot.sources.map(function (row) {return row.id;});
        if (!remote.some(function (source) {return source.id===p.snapshot.activeSourceId;})) p.snapshot.activeSourceId=remote.length?remote[0].id:null;
        if (snapshot.metadata && !pending.metadataDraft) p.snapshot.metadata=snapshot.metadata;
        var rows=mergeCloudFavorites(profileBucket(K.favorites,[],state),snapshot.favorites || [],p.snapshot.managedIds);
        Object.keys(pending.favorites || {}).forEach(function (key) {var change=pending.favorites[key];rows=rows.filter(function (row) {return dataKey(row.sourceId,row.item || row.channel)!==key;});
          if (change.add) {var known=profileBucket(K.favorites,[],state).filter(function (row) {return dataKey(row.sourceId,row.item || row.channel)===key;})[0];if (known) rows.push(known);}
        });writeBucket(state,K.favorites,rows);
        if (snapshot.playbackPositionsAvailable) {writeBucket(state,K.positions,mergeCloudPositions(profileBucket(K.positions,{},state),snapshot.playbackPositions || [],p.snapshot.managedIds));writeBucket(state,K.playbackSync,snapshot.playbackSync || null);}
        saveCurrentSnapshotInState(state);
      },'cloud');
    }).then(function () {
      autoLastPull=now();autoPullRetry=0;
      scheduleAutoPush();
      if (active) {
        var config=configList().filter(function (source) {return source.id===active.config.id;})[0];
        if (config && JSON.stringify(config.fields)===JSON.stringify(active.config.fields) && ['catchupTimezone','catchupOffsetMinutes','catchupMaxDays','streamExtension','maximumStreams'].every(function (key) {
          return JSON.stringify(config.settings && config.settings[key])===JSON.stringify(active.config.settings && active.config.settings[key]);
        })) active.config=config;
      }
      libraryRevision++;if (options.onProgress) options.onProgress();return {synced:true};
    });
  }
  function mappingGet(args) {
    var config=sourceConfig(args.sourceId), row=mappingsFor(config.id).filter(function (item) {return item.channelId===args.channelId;})[0];
    var ready=active && active.config.id===config.id ? Promise.resolve() : selectSource({id:config.id});
    return ready.then(function () {return invoke('epgMapping.get',{query:String(args.query || '').slice(0,120),limit:Math.min(120,Math.max(1,Number(args.limit)||40))});}).then(function (value) {
      return {sourceId:config.id,override:row || {channelId:args.channelId,guideId:null,guideChannelId:null,offsetMinutes:0},available:value.available,channels:value.channels || []};
    });
  }
  function mappingSet(args) {
    var owner=allowedProfile(),config=sourceConfig(args.sourceId),offset=Number(args.offsetMinutes || 0);
    if (typeof args.channelId!=='string' || !args.channelId || args.channelId.length>1024 || !isFinite(offset) || offset%1 || Math.abs(offset)>1440 || !!args.guideId!==!!args.guideChannelId ||
        args.guideId && (typeof args.guideId!=='string' || !/^[a-f0-9]{64}$/.test(args.guideId) || typeof args.guideChannelId!=='string' || args.guideChannelId.length>1024)) throw error('Nieprawidłowe mapowanie EPG.','epg_mapping_invalid');
    return authorize(args).then(function () {return mutateProfile(owner.id,function (state) {
      var all=profileBucket(K.mappings,{},state),rows=all[config.id] || {};
      if (!rows[args.channelId] && (args.guideId || offset) && Object.keys(rows).length>=10000) throw error('Za dużo zapisanych mapowań EPG.','epg_mapping_invalid');
      if (!args.guideId && !offset) delete rows[args.channelId];
      else rows[args.channelId]={channelId:args.channelId,guideId:args.guideId || null,guideChannelId:args.guideChannelId || null,offsetMinutes:offset};
      all[config.id]=rows;writeBucket(state,K.mappings,all);
    },owner.source);}).then(function () {
      ++guideTicket;guideCache=null;guideFailure=null;
      return active && active.config.id===config.id ? invoke('epgMapping.set',{overrides:mappingsFor(config.id)}) : null;
    }).then(function () {return mappingGet(args);});
  }
  function playbackPreferences(sourceId,item) {return profileBucket(K.preferences,{})[dataKey(sourceId,item)] || {};}
  function savePlaybackPreferences(sourceId,item,settings,expectedOwner) {
    var owner=expectedOwner || allowedProfile();
    return mutateProfile(owner.id,function (state) {
      var all=profileBucket(K.preferences,{},state),key=dataKey(sourceId,item),previous=all[key] || {};
      delete all[key];all[key]=Object.assign({},previous,settings);
      var keys=Object.keys(all);while (keys.length>256) delete all[keys.shift()];
      writeBucket(state,K.preferences,all);
    },owner.source);
  }
  function restorePlaybackPreferences(settings) {
    var aspect={fit:'PLAYER_DISPLAY_MODE_LETTER_BOX',fill:'PLAYER_DISPLAY_MODE_FULL_SCREEN',auto:'PLAYER_DISPLAY_MODE_AUTO_ASPECT_RATIO'};
    var tasks=[],tracks={};
    function attempt(callback) {tasks.push(Promise.resolve().then(callback).catch(function () {}));}
    if (aspect[settings.aspect]) attempt(function () {return player.setDisplayMode(aspect[settings.aspect]);});
    if (settings.audio || settings.subtitle) {
      try {tracks=player.getTracks ? player.getTracks() : {};} catch (_) {}
    }
    ['audio','subtitle'].forEach(function (type) {
      var saved=settings[type],rows=Array.isArray(tracks) ? tracks.filter(function (row) {return row.type===(type==='audio'?'AUDIO':'TEXT');}) : type==='audio' ? tracks.audio : tracks.subtitles;
      if (!saved || !Array.isArray(rows)) return;
      var match=rows.filter(function (row) {return saved.language && trackLanguage(row)===saved.language || !saved.language && saved.label && row.label===saved.label;})[0];
      if (match) attempt(function () {return player.selectTrack(type==='audio'?'AUDIO':'TEXT',Number(match.id==null?match.index:match.id));});
    });
    if (typeof settings.subtitlesEnabled==='boolean') attempt(function () {return player.setSubtitlesEnabled(settings.subtitlesEnabled);});
    return Promise.all(tasks);
  }
  function trackLanguage(row) {var info=row.extraInfo || {};return row.language || info.track_lang || info.lang || info.language || '';}
  function invoke(method, args, source) {
    source = source || active;
    if (!source) return Promise.reject(error('Najpierw wybierz źródło.'));
    if (source.catalogCommit) return source.catalogCommit.then(function () { return invoke(method, args, source); });
    var input = JSON.stringify(args || {});
    var share = ['categories', 'channels', 'mediaCategories', 'mediaItemsPage', 'mediaItems', 'allMediaItems', 'searchMedia', 'mediaDetails'].indexOf(method) >= 0;
    var key = method + '\n' + input;
    if (method === 'invalidate') { source.readCache = null; source.reads = null; }
    // Keep serialized metadata only: callers can mutate their result without
    // poisoning later reads. Playback URLs and authorization are never cached.
    var cache = source.readCache || (source.readCache = { entries: Object.create(null), order: [], chars: 0 });
    function removeCached(cacheKey) {
      var entry = cache.entries[cacheKey];
      if (!entry) return;
      cache.chars -= entry.size; delete cache.entries[cacheKey];
      cache.order.splice(cache.order.indexOf(cacheKey), 1);
    }
    if (share && !source.engine.restoreCatalog && cache.entries[key]) {
      var cached = cache.entries[key], age = now() - cached.at;
      if (age >= 0 && age < cachePolicy.catalogMaxAgeMs) {
        cache.order.splice(cache.order.indexOf(key), 1); cache.order.push(key);
        return Promise.resolve(parsed(cached.raw));
      }
      removeCached(key);
    }
    if (share) {
      source.reads = source.reads || Object.create(null);
      if (source.reads[key]) return source.reads[key].then(parsed);
    }
    var pending = source.engine.invoke(method, input).then(function (raw) {
      if (share && !source.engine.restoreCatalog && source.readCache === cache && cachePolicy.catalogMaxAgeMs > 0) {
        var serialized = typeof raw === 'string' ? raw : JSON.stringify(raw);
        var size = key.length + serialized.length;
        if (size <= maximumReadCacheChars) {
          while (cache.order.length && (cache.order.length >= maximumReadCacheEntries || cache.chars + size > maximumReadCacheChars)) removeCached(cache.order[0]);
          cache.entries[key] = { raw: serialized, at: now(), size: size };
          cache.order.push(key); cache.chars += size;
        }
      }
      if (share && source.catalog && source.cacheKey && active === source) scheduleCatalogSave(source);
      return raw;
    });
    var invocations = source.invocations || (source.invocations = []);
    invocations.push(pending);
    function finishedInvocation() { invocations.splice(invocations.indexOf(pending), 1); }
    pending.then(finishedInvocation, finishedInvocation);
    if (share) {
      var reads = source.reads;
      reads[key] = pending;
      function clearRead() { if (reads[key] === pending) delete reads[key]; }
      pending.then(clearRead, clearRead);
    }
    return pending.then(function (raw) {
      if ((method === 'cacheKey' || method === 'guideCacheKey') && typeof raw === 'string' && /^[a-f0-9]{64}$/.test(raw)) return raw;
      if (method !== 'epg') return parsed(raw);
      var value;
      try { value = parsed(raw); } catch (_) { throw epgError('epg_invalid_data'); }
      if (value && value.__tvbroEpgError === 1) throw epgError(value.code, value.status, value.causeCode, value.retryAt);
      if (!Array.isArray(value)) throw epgError('epg_invalid_data');
      return value;
    }, function (failure) {
      if (method !== 'epg' || failure && (failure.code === 'cancelled' || failure.name === 'AbortError')) throw failure;
      throw epgError(failure && failure.name === 'TimeoutError' ? 'epg_timeout' : failure && failure.name === 'NetworkError' ? 'epg_network' : 'epg_unavailable');
    });
  }
  function check(expected) { if (expected !== revision) throw error('Wczytywanie anulowano.', 'cancelled'); }
  function removeStoredSource(config, scope) {
    if (!catalogStore || !config) return Promise.resolve();
    var engine;
    return Promise.resolve().then(function () {
      engine = createSource(JSON.stringify(config), function () { return Promise.reject(error('Wczytywanie anulowano.', 'cancelled')); });
      return Promise.all(['cacheKey', 'guideCacheKey', 'legacyCacheKey', 'legacyGuideCacheKey'].map(function (method) {
        return engine.invoke(method, JSON.stringify({ scope: scope }));
      }));
    }).then(function (keys) {
      return Promise.all(keys.map(function (raw) {
        var key = typeof raw === 'string' && /^[a-f0-9]{64}$/.test(raw) ? raw : parsed(raw);
        return catalogStore.remove(key);
      }));
    }).catch(function () {}).then(function () { if (engine) return engine.dispose(); });
  }
  function engineValue(engine, method, args) {
    return Promise.resolve().then(function () { return engine.invoke(method, JSON.stringify(args || {})); }).then(function (raw) {
      return engine.restoreCatalog ? raw : parsed(raw);
    });
  }
  function migrateLegacySourceCache(config, replacement, scope, engineOverride, allowUnpersistedCache) {
    if (!catalogStore || typeof catalogStore.read !== 'function' || !config) return Promise.resolve(false);
    var engine = engineOverride || null, replacementEngine = null, protectionLease = null, migrationPreserveKeys = null,
      failed = error(cacheMigrationMessage, 'cache_migration_failed');
    function releaseProtectionLease() {
      if (!protectionLease) return;
      var release = protectionLease; protectionLease = null; release();
    }
    var noProvider = function () { return Promise.resolve(JSON.stringify({ errorKind: 'network', error: 'Provider transport is disabled during cache migration.' })); };
    function importBatch(saved, key) {
      if (!saved || !catalogStore.readBatchPart) return Promise.resolve(false);
      var begun = false, manifest = saved.manifest;
      function abort() { return begun ? engineValue(engine, 'abortCatalogImport', {}).catch(function () {}) : Promise.resolve(); }
      function part(position) {
        if (position >= manifest.parts.length) return Promise.resolve();
        var descriptor = manifest.parts[position];
        return catalogStore.readBatchPart(key, saved.token, descriptor.index).then(function (raw) {
          return engineValue(engine, 'importCatalogPart', { index: descriptor.index, raw: raw });
        }).then(function (result) {
          if (result === false) throw new Error('Catalog part rejected.');
          return part(position + 1);
        });
      }
      return engineValue(engine, 'beginCatalogImport', { scope: scope, manifest: manifest }).then(function (result) {
        if (!result || result === false) throw new Error('Catalog import rejected.');
        begun = true; return part(0);
      }).then(function () { return engineValue(engine, 'commitCatalogImport', {}); }).then(function (state) {
        if (!state || state === false) throw new Error('Catalog generation rejected.');
        return true;
      }).catch(function () { return abort().then(function () { return false; }); });
    }
    function importDirect(saved) {
      if (!saved || typeof saved.raw !== 'string') return Promise.resolve(false);
      return engineValue(engine, 'importCatalog', { scope: scope, snapshot: saved.raw }).then(function (value) {
        return !!(value && value.fromCache === true);
      }).catch(function () { return false; });
    }
    function exportCatalog(key, capabilities, writeOptions) {
      if (capabilities && capabilities.fullCatalogCache === true && typeof catalogStore.writeBatch === 'function') {
        return engineValue(engine, 'beginCatalogExport', { scope: scope }).then(function (manifest) {
          if (!manifest || !Array.isArray(manifest.parts)) return false;
          return catalogStore.writeBatch(key, manifest, function (descriptor) {
            return engineValue(engine, 'exportCatalogPart', { index: descriptor.index });
          }, writeOptions);
        });
      }
      return Promise.resolve().then(function () { return engine.invoke('exportCatalog', JSON.stringify({ scope: scope, allowDeferredMedia: true })); }).then(function (raw) {
        if (!engine.restoreCatalog) raw = parsed(raw);
        if (typeof raw !== 'string' && raw) raw = JSON.stringify(raw);
        return typeof raw === 'string' && raw ? catalogStore.write(key, raw, 'catalog', writeOptions) : false;
      });
    }
    function migrateCatalog(keys, snapshots) {
      var currentBatch = snapshots.currentBatch, oldBatch = snapshots.oldBatch;
      var currentRaw = snapshots.currentRaw, oldRaw = snapshots.oldRaw;
      if (!oldBatch && !oldRaw) return Promise.resolve(true);
      function writeMigrated() {
        return engineValue(engine, 'capabilities', {}).then(function (capabilities) {
          return exportCatalog(keys.current, capabilities, { preserveKeys: migrationPreserveKeys }).then(function (saved) {
            if (saved === true) return true;
            if (allowUnpersistedCache) return false;
            throw failed;
          });
        }).catch(function (failure) {
          if (allowUnpersistedCache) return false;
          throw failure;
        });
      }
      return importBatch(currentBatch, keys.current).then(function (ready) {
        if (ready) return true;
        return importDirect(currentRaw).then(function (valid) {
          if (valid) return true;
          return importBatch(oldBatch, keys.legacy).then(function (legacyReady) {
            if (legacyReady) return writeMigrated();
            return importDirect(oldRaw).then(function (legacyValid) {
              if (!legacyValid) {
                if (allowUnpersistedCache) return false;
                if (oldBatch || oldRaw) throw failed;
                return true;
              }
              return writeMigrated();
            });
          });
        });
      });
    }
    function migrateGuide(keys, snapshots) {
      var current = snapshots.currentGuide, old = snapshots.oldGuide;
      function restore(saved) {
        if (!saved || typeof saved.raw !== 'string') return Promise.resolve(false);
        return engineValue(engine, 'importGuide', { scope: scope, snapshot: saved.raw }).then(function (value) { return value === true; })
          .catch(function () { return false; });
      }
      function exportAndWrite() {
        return Promise.resolve().then(function () { return engine.invoke('exportGuide', JSON.stringify({ scope: scope })); }).then(function (raw) {
          if (!engine.restoreGuide) raw = parsed(raw);
          if (typeof raw !== 'string' && raw) raw = JSON.stringify(raw);
          return typeof raw === 'string' && raw ? catalogStore.write(keys.currentGuide, raw, 'guide',
            { preserveKeys: migrationPreserveKeys }) : false;
        });
      }
      return restore(current).then(function (ready) {
        if (ready) return true;
        return restore(old).then(function (legacyReady) {
          if (!legacyReady) {
            if (allowUnpersistedCache) return false;
            if (old) throw failed;
            return true;
          }
          return exportAndWrite().then(function (saved) {
            if (saved === true) return true;
            if (allowUnpersistedCache) return false;
            throw failed;
          }).catch(function (failure) {
            if (allowUnpersistedCache) return false;
            throw failure;
          });
        });
      });
    }
    var operation = Promise.resolve().then(function () {
      if (!engine) engine = createSource(JSON.stringify(config), noProvider);
      return Promise.all([
        engineValue(engine, 'cacheKey', { scope: scope }), engineValue(engine, 'legacyCacheKey', { scope: scope }),
        engineValue(engine, 'guideCacheKey', { scope: scope }), engineValue(engine, 'legacyGuideCacheKey', { scope: scope })
      ]);
    }).then(function (keys) {
      var identity = keys[0], legacy = keys[1], currentGuide = keys[2], oldGuide = keys[3];
      if (replacement) {
        replacementEngine = createSource(JSON.stringify(replacement), noProvider);
        return engineValue(replacementEngine, 'cacheKey', { scope: scope }).then(function (nextIdentity) {
          return nextIdentity === identity ? keys : null;
        });
      }
      return keys;
    }).then(function (keys) {
      if (!keys) return false;
      var snapshotKeys = { current: keys[0], legacy: keys[1], currentGuide: keys[2], legacyGuide: keys[3] };
      if (!/^[a-f0-9]{64}$/.test(snapshotKeys.current) || !/^[a-f0-9]{64}$/.test(snapshotKeys.legacy) ||
          snapshotKeys.current === snapshotKeys.legacy) return false;
      migrationPreserveKeys = [snapshotKeys.current, snapshotKeys.currentGuide,
        snapshotKeys.legacy, snapshotKeys.legacyGuide];
      if (typeof catalogStore.protectKeys === 'function') {
        protectionLease = catalogStore.protectKeys(migrationPreserveKeys);
      }
      return Promise.all([
        catalogStore.read(snapshotKeys.current), catalogStore.read(snapshotKeys.legacy),
        catalogStore.read(snapshotKeys.currentGuide), catalogStore.read(snapshotKeys.legacyGuide),
        typeof catalogStore.readBatch === 'function' ? catalogStore.readBatch(snapshotKeys.current) : null,
        typeof catalogStore.readBatch === 'function' ? catalogStore.readBatch(snapshotKeys.legacy) : null
      ]).then(function (saved) {
        var snapshots = { currentRaw: saved[0], oldRaw: saved[1], currentGuide: saved[2], oldGuide: saved[3],
          currentBatch: saved[4], oldBatch: saved[5] };
        if (!snapshots.oldBatch && !snapshots.oldRaw && !snapshots.oldGuide) return true;
        return migrateCatalog(snapshotKeys, snapshots).then(function (catalogMigrated) {
          return migrateGuide(snapshotKeys, snapshots).then(function (guideMigrated) {
            if (catalogMigrated === false || guideMigrated === false) return false;
            var removals = [];
            if ((snapshots.oldBatch || snapshots.oldRaw) && catalogStore.remove) removals.push(catalogStore.remove(snapshotKeys.legacy));
            if (snapshots.oldGuide && catalogStore.remove) removals.push(catalogStore.remove(snapshotKeys.legacyGuide));
            return Promise.all(removals).then(function () { return true; });
          });
        });
      });
    });
    return operation.catch(function (failure) {
      if (allowUnpersistedCache) return false;
      if (failure && failure.code === 'cache_migration_failed') throw failure;
      throw failed;
    }).then(function (value) {
      var disposals = [];
      if (engine && engine !== engineOverride) disposals.push(Promise.resolve(engine.dispose()).catch(function () {}));
      if (replacementEngine) disposals.push(Promise.resolve(replacementEngine.dispose()).catch(function () {}));
      return Promise.all(disposals).then(function () { releaseProtectionLease(); return value; });
    }, function (failure) {
      var disposals = [];
      if (engine && engine !== engineOverride) disposals.push(Promise.resolve(engine.dispose()).catch(function () {}));
      if (replacementEngine) disposals.push(Promise.resolve(replacementEngine.dispose()).catch(function () {}));
      return Promise.all(disposals).then(function () { releaseProtectionLease(); throw failure; });
    });
  }
  function saveCatalog(source, expected, detached) {
    if (!catalogStore || !source.cacheKey) return Promise.resolve(false);
    if (source.capabilities && source.capabilities.fullCatalogCache === true && typeof catalogStore.writeBatch === 'function') {
      return savePreparedCatalog(source, expected, detached);
    }
    source.cacheDirty = false;
    return source.engine.invoke('exportCatalog', JSON.stringify({ scope: source.cacheScope, allowDeferredMedia: true })).then(function (raw) {
      if (!detached) check(expected);
      if ((!detached && active !== source) || raw == null || raw === 'null') return false;
      // The worker unwraps the Dart JSON string. No catalogue JSON parse on UI.
      if (!source.engine.restoreCatalog) raw = parsed(raw);
      return typeof raw === 'string' ? catalogStore.write(source.cacheKey, raw, 'catalog') : false;
    }).catch(function () {
      if (!detached && expected !== revision) source.cacheDirty = true;
      if (!detached) check(expected);
      return false;
    }).then(function (saved) {
      source.cachePersisted = saved; return saved;
    });
  }
  function scheduleCatalogSave(source) {
    source.cacheDirty = true;
    if (source.cacheRefreshing) return;
    if (!catalogStore || source.cacheSaveTimer || source.cacheSaveFlight) return;
    var expected = revision;
    source.cacheSaveTimer = setTimeout(function () {
      source.cacheSaveTimer = null;
      if (active !== source || expected !== revision) return;
      source.cacheSaveFlight = saveCatalog(source, expected);
      source.cacheSaveFlight.then(function () {
        source.cacheSaveFlight = null;
        if (source.cacheDirty && active === source && expected === revision) scheduleCatalogSave(source);
      }, function () { source.cacheSaveFlight = null; });
    }, 1000);
  }
  function restoreCatalog(source, expected, remaining) {
    if (!catalogStore || !source.cacheKey || remaining === 0) return Promise.resolve(null);
    return catalogStore.read(source.cacheKey).then(function (saved) {
      check(expected);
      if (!saved) return null;
      var restored = source.engine.restoreCatalog
        ? source.engine.restoreCatalog(source.cacheScope, saved.raw)
        : source.engine.invoke('importCatalog', JSON.stringify({ scope: source.cacheScope, snapshot: saved.raw }));
      return restored.then(function (value) {
        check(expected); value = parsed(value);
        if (value) { source.cachePersisted = true; return value; }
        return catalogStore.discard(source.cacheKey, saved.token).then(function () { return restoreCatalog(source, expected, remaining - 1); });
      });
    }).catch(function () { check(expected); return null; });
  }
  function preparation(source) {
    if (!source.preparation) source.preparation = { sections: {}, cacheState: { kinds: {} }, warnings: [] };
    return source.preparation;
  }
  function preparationLabel(kind) {
    return kind === 'live' ? 'Live TV' : kind === 'movie' ? 'Movies' : kind === 'series' ? 'Series' : 'TV guide';
  }
  function updatePreparationWarnings(source) {
    var result = [], sections = preparation(source).sections;
    catalogKinds.concat(['epg']).forEach(function (kind) {
      var row = sections[kind];
      if (row && (row.status === 'failed' || row.status === 'unavailable')) result.push({ kind: kind, label: preparationLabel(kind) });
    });
    source.preparation.warnings = result;
  }
  function syncCatalogState(source, state) {
    if (!state || !state.kinds) throw error('Invalid canonical catalog state.', 'catalog_invalid');
    var kinds = {}, sections = preparation(source).sections;
    catalogKinds.forEach(function (kind) {
      var row = state.kinds[kind] || {}, complete = row.complete === true;
      kinds[kind] = { complete: complete, count: validCount(row.count), syncedAt: row.syncedAt == null ? null : row.syncedAt };
      if (!sections[kind] || sections[kind].status !== 'failed' && sections[kind].status !== 'unavailable') {
        sections[kind] = { status: complete ? kinds[kind].count ? 'ready' : 'empty' : 'pending',
          count: kinds[kind].count, syncedAt: kinds[kind].syncedAt };
      } else {
        sections[kind].count = kinds[kind].count; sections[kind].syncedAt = kinds[kind].syncedAt;
      }
    });
    source.catalogState = Object.assign({}, copy(state), { kinds: kinds });
    source.preparation.cacheState = copy(source.catalogState);
    updatePreparationWarnings(source);
    if (options.onProgress) options.onProgress();
    return source.catalogState;
  }
  function validCount(value) { return typeof value === 'number' && isFinite(value) && value >= 0 ? Math.floor(value) : 0; }
  function setPreparationSection(source, kind, status, count, syncedAt) {
    var row = { status: status };
    if (typeof count === 'number' && isFinite(count) && count >= 0) row.count = Math.floor(count);
    if (syncedAt != null) row.syncedAt = syncedAt;
    preparation(source).sections[kind] = row;
    updatePreparationWarnings(source);
    if (options.onProgress) options.onProgress();
  }
  function setPreparationStage(source, progress) {
    if (!progress) return;
    var sections = preparation(source).sections, stage = null;
    catalogKinds.forEach(function (kind) { if (!stage && sections[kind] && sections[kind].status === 'pending') stage = 'catalog-' + kind; });
    if (!stage && sections.epg && sections.epg.status === 'pending') stage = 'catalog-guide';
    progress(stage || 'catalog-persist');
  }
  function catalogHasContent(source, state) {
    if (state && state.kinds && catalogKinds.some(function (kind) { return validCount(state.kinds[kind] && state.kinds[kind].count) > 0; })) return true;
    return !!(source.catalog && source.catalog[1].length);
  }
  function catalogSyncedAt(value) {
    var parsedValue = typeof value === 'number' ? value : typeof value === 'string' ? Date.parse(value) : NaN;
    return isFinite(parsedValue) && parsedValue > 0 ? parsedValue : 0;
  }
  function refreshDueKinds(source, state) {
    var retryAt = source.catalogRetryAt || {}, maxAge = cachePolicy.catalogMaxAgeMs;
    return catalogKinds.filter(function (kind) {
      if (typeof retryAt[kind] === 'number' && now() < retryAt[kind]) return false;
      var row = state && state.kinds && state.kinds[kind];
      if (!row || row.complete !== true) return true;
      if (!(maxAge > 0)) return false;
      var at = catalogSyncedAt(row.syncedAt);
      return !at || now() < at || now() - at >= maxAge;
    });
  }
  function newRefreshKey(source) {
    if (core && typeof core.newSourceId === 'function') {
      try { var value = core.newSourceId(); if (typeof value === 'string' && value) return value; } catch (_) {}
    }
    return String(source.config.id) + ':' + String(now()) + ':' + String(revision);
  }
  function catalogState(source, expected) {
    return invoke('catalogState', {}, source).then(function (state) {
      check(expected); return syncCatalogState(source, state);
    });
  }
  function prepareCatalogBatch(source, expected, kinds, forceRefresh, progress) {
    if (!kinds.length) return catalogState(source, expected);
    source.catalogRetryAt = source.catalogRetryAt || {};
    var refreshKey = newRefreshKey(source), rowByKind = Object.create(null);
    kinds.forEach(function (kind) { setPreparationSection(source, kind, 'pending'); });
    setPreparationStage(source, progress);
    return Promise.all(kinds.map(function (kind) {
      return invoke('prepareCatalog', { kind: kind, forceRefresh: forceRefresh === true, refreshKey: refreshKey }, source).then(function (row) {
        check(expected);
        if (!row || row.complete !== true) throw error('The canonical catalog is incomplete.', 'catalog_incomplete');
        rowByKind[kind] = row; delete source.catalogRetryAt[kind];
        source.readCache = null; source.reads = null;
        setPreparationSection(source, kind, row.count > 0 ? 'ready' : 'empty', validCount(row.count), row.syncedAt);
        setPreparationStage(source, progress);
        return { ok: true, kind: kind };
      }).catch(function (failure) {
        if (expected !== revision || failure && (failure.code === 'cancelled' || failure.name === 'AbortError')) throw failure;
        var retry = failure && Number(failure.retryAt), retryAt = isFinite(retry) && retry > now() ? retry : now() + 3600000;
        source.catalogRetryAt[kind] = retryAt;
        setPreparationSection(source, kind, 'failed', source.catalogState && source.catalogState.kinds[kind] && source.catalogState.kinds[kind].count,
          source.catalogState && source.catalogState.kinds[kind] && source.catalogState.kinds[kind].syncedAt);
        setPreparationStage(source, progress);
        return { ok: false, kind: kind };
      });
    })).then(function () { return catalogState(source, expected); });
  }
  function readPreparedLive(source, expected, state) {
    var live = state && state.kinds && state.kinds.live;
    if ((!live || live.complete !== true) && source.catalog) {
      source.categories = source.catalog[0]; source.channels = source.catalog[1]; return Promise.resolve(source.catalog);
    }
    if (!live || live.complete !== true) {
      source.categories = []; source.channels = []; source.catalog = [[], []]; return Promise.resolve(source.catalog);
    }
    return Promise.all([invoke('categories', {}, source), invoke('channels', {}, source)]).then(function (parts) {
      check(expected); source.categories = parts[0]; source.channels = parts[1]; source.catalog = parts; source.catalogAt = catalogSyncedAt(live.syncedAt) || now();
      return parts;
    });
  }
  function restoreCatalogBatch(source, expected, remaining) {
    if (!catalogStore || typeof catalogStore.readBatch !== 'function' || !source.cacheKey || remaining === 0) return Promise.resolve(null);
    return catalogStore.readBatch(source.cacheKey).then(function (saved) {
      check(expected); if (!saved) return null;
      var begun = false;
      function abort() {
        return invoke('abortCatalogImport', {}, source).catch(function () {}).then(function () {});
      }
      function importPart(position) {
        if (position >= saved.manifest.parts.length) return Promise.resolve();
        var descriptor = saved.manifest.parts[position];
        return catalogStore.readBatchPart(source.cacheKey, saved.token, descriptor.index).then(function (raw) {
          check(expected);
          return invoke('importCatalogPart', { index: descriptor.index, raw: raw }, source);
        }).then(function (result) {
          check(expected); if (result === false) throw error('Catalog cache part was rejected.', 'cache_invalid');
          return importPart(position + 1);
        });
      }
      return invoke('beginCatalogImport', { scope: source.cacheScope, manifest: saved.manifest }, source).then(function (result) {
        check(expected); if (result === false) throw error('Catalog cache import was rejected.', 'cache_invalid');
        begun = true; return importPart(0);
      }).then(function () { return invoke('commitCatalogImport', {}, source); }).then(function (result) {
        check(expected); if (result === false) throw error('Catalog cache generation was rejected.', 'cache_invalid');
        source.cachePersisted = true; source.catalogBatchRestored = true;
        return catalogState(source, expected);
      }).catch(function (failure) {
        if (expected !== revision || failure && (failure.code === 'cancelled' || failure.name === 'AbortError')) throw failure;
        return (begun ? abort() : Promise.resolve()).then(function () {
          return catalogStore.discardBatch(source.cacheKey, saved.token);
        }).then(function () { check(expected); return restoreCatalogBatch(source, expected, remaining - 1); });
      });
    }).catch(function (failure) { check(expected); return null; });
  }
  function savePreparedCatalog(source, expected, detached) {
    if (!catalogStore || typeof catalogStore.writeBatch !== 'function' || !source.cacheKey) return Promise.resolve(false);
    source.cacheDirty = false;
    return invoke('beginCatalogExport', { scope: source.cacheScope }, source).then(function (manifest) {
      if (!detached) check(expected);
      if ((!detached && active !== source) || !manifest || !Array.isArray(manifest.parts)) return false;
      return catalogStore.writeBatch(source.cacheKey, manifest, function (descriptor) {
        return invoke('exportCatalogPart', { index: descriptor.index }, source);
      });
    }).catch(function () {
      if (!detached && expected !== revision) source.cacheDirty = true;
      if (!detached) check(expected);
      return false;
    }).then(function (saved) {
      source.cachePersisted = saved;
      return saved;
    });
  }
  function setupMetadata(source, expected) {
    if (source.metadataReady) return source.metadataReady;
    var owner = allowedProfile(), config = copy(owner.snapshot && owner.snapshot.metadata || {}), language = languageState().languageCode;
    source.metadataReady = Promise.resolve().then(function () {
      return invoke('metadata.configure', { config: config, language: language }, source);
    }).then(function () {
      check(expected);
      if (!catalogStore || typeof catalogStore.read !== 'function') return;
      return invoke('metadata.cacheKey', { scope: source.cacheScope }, source).then(function (key) {
        check(expected);
        if (typeof key !== 'string' || !/^[a-f0-9]{64}$/.test(key)) return;
        source.metadataKey = key;
        if (typeof catalogStore.mark === 'function') return Promise.resolve(catalogStore.mark(key, 'metadata')).catch(function () {}).then(function () {
          return catalogStore.read(key);
        }).then(function (saved) {
          if (!saved) return;
          check(expected); return invoke('metadata.import', { scope: source.cacheScope, snapshot: saved.raw }, source).catch(function () {});
        });
      });
    }).catch(function () { check(expected); }).then(function () { source.metadataReady = true; });
    return source.metadataReady;
  }
  function saveMetadata(source, expected, detached) {
    if (!catalogStore || !source.metadataKey || typeof catalogStore.write !== 'function') return Promise.resolve(false);
    return invoke('metadata.export', { scope: source.cacheScope }, source).then(function (snapshot) {
      if (!detached) check(expected);
      if ((!detached && active !== source) || typeof snapshot !== 'string' || !snapshot) return false;
      return catalogStore.write(source.metadataKey, snapshot, 'metadata').then(function (saved) {
        if (saved) source.metadataDirty = false;
        return saved;
      });
    }).catch(function () { if (!detached) check(expected); return false; });
  }
  function scheduleMetadataSave(source) {
    if (!catalogStore || !source || !source.metadataKey || source.metadataSaveTimer || source.metadataSaveFlight) return;
    source.metadataDirty = true;
    var expected = revision;
    source.metadataSaveTimer = setTimeout(function () {
      source.metadataSaveTimer = null;
      if (active !== source || expected !== revision) return;
      source.metadataSaveFlight = saveMetadata(source, expected);
      source.metadataSaveFlight.then(function () { source.metadataSaveFlight = null; }, function () { source.metadataSaveFlight = null; });
    }, 1000);
  }
  function metadataMethodUnavailable(failure) {
    return failure && (failure.name === 'NotSupportedError' || failure.code === 'method_unavailable' || /Unknown Source method metadata\./.test(String(failure.message || '')));
  }
  function mediaDetailsWithMetadata(item, source) {
    var expected = revision;
    if (!source || !source.capabilities || source.capabilities.fullCatalogCache !== true) return invoke('mediaDetails', { item: item }, source);
    return Promise.resolve(setupMetadata(source, expected)).then(function () {
      return invoke('metadata.details', { item: item }, source).catch(function (failure) {
        return invoke('mediaDetails', { item: item }, source);
      });
    }).then(function (value) { check(expected); scheduleCatalogSave(source); scheduleMetadataSave(source); return value; });
  }
  function mediaChildrenWithMetadata(parent, source) {
    var expected = revision, kind = parent.kind === 'series' ? 'season' : 'episode';
    return invoke('mediaItems', { kind: kind, parent: parent }, source).then(function (items) {
      if (!source || !source.capabilities || source.capabilities.fullCatalogCache !== true) return items;
      return Promise.resolve(setupMetadata(source, expected)).then(function () {
        return invoke('metadata.children', { parent: parent, items: items }, source).catch(function (failure) {
          return items;
        });
      }).then(function (result) { check(expected); scheduleMetadataSave(source); return Array.isArray(result) ? result : items; });
    });
  }
  function markGuideResult(source, result) {
    var count = result && Array.isArray(result.programmes) ? result.programmes.length : 0;
    source.epgAt = now(); source.epgRetryAt = 0;
    setPreparationSection(source, 'epg', count ? 'ready' : 'empty', count, source.epgAt);
    armEpgRefresh(source, revision);
    return result;
  }
  function markGuideFailure(source, failure) {
    var unavailable = failure && failure.code === 'epg_unsupported';
    var retry = failure && Number(failure.retryAt);
    source.epgRetryAt = isFinite(retry) && retry > now() ? retry : now() + (cachePolicy.epgRetryDelayMs > 0 ? cachePolicy.epgRetryDelayMs : 900000);
    setPreparationSection(source, 'epg', unavailable ? 'unavailable' : 'failed');
    armEpgRefresh(source, revision);
    return null;
  }
  function attemptGuide(source, expected, waitForRefresh) {
    if (source.capabilities && (source.capabilities.epg === false || source.capabilities.epg === 'unsupported' || source.capabilities.epg === 'unavailable')) {
      setPreparationSection(source, 'epg', 'unavailable'); return Promise.resolve(null);
    }
    setPreparationSection(source, 'epg', 'pending');
    var request;
    try { request = source.guideReadFlight || guide({ channels: source.channels || [] }); }
    catch (failure) { check(expected); return Promise.resolve(markGuideFailure(source, failure)); }
    var flight = source.guideReadFlight;
    function applied(value) {
      check(expected);
      return Promise.resolve(flight).then(function () { return markGuideResult(source, value); }, function (failure) {
        check(expected); return markGuideFailure(source, failure);
      });
    }
    if (!waitForRefresh) {
      Promise.resolve(request).then(function (value) { return applied(value); }, function (failure) {
        check(expected); return markGuideFailure(source, failure);
      }).catch(function () {});
      return Promise.resolve(null);
    }
    return Promise.resolve(request).then(function (value) {
      return applied(value);
    }, function (failure) {
      check(expected); markGuideFailure(source, failure); return null;
    }).then(function (value) {
      if (waitForRefresh && value && source.guideKey) {
        clearTimeout(source.guideSaveTimer); source.guideSaveTimer = null;
        return saveGuide(source, expected).catch(function () { return false; }).then(function () { return value; });
      }
      return value;
    });
  }
  function readEpgState(source, expected) {
    return Promise.resolve().then(function () { return invoke('epgState', {}, source); }).then(function (state) {
      check(expected);
      if (!state || typeof state !== 'object') return null;
      var next = state.nextRefreshAt == null ? 0 : Number(state.nextRefreshAt), retry = state.retryAt == null ? 0 : Number(state.retryAt);
      source.epgNextRefreshAt = isFinite(next) && next > 0 ? next : 0;
      if (isFinite(retry) && retry > now()) source.epgRetryAt = retry;
      else if (!source.epgRetryAt || source.epgRetryAt <= now()) source.epgRetryAt = 0;
      return state;
    }, function (failure) { check(expected); return null; });
  }
  function epgRefreshDue(source) {
    if (source.epgRetryAt > now()) return false;
    if (source.epgNextRefreshAt > 0) return now() >= source.epgNextRefreshAt;
    return !(source.epgAt > 0) || now() < source.epgAt || now() - source.epgAt >= cachePolicy.epgMaxAgeMs;
  }
  function scheduleEpgRefresh(source, expected) {
    var retryAt = source.epgRetryAt || 0, nextAt = source.epgNextRefreshAt || 0;
    var dueAt = retryAt > now() ? retryAt : nextAt || (source.epgAt || now()) + cachePolicy.epgMaxAgeMs;
    cancelTimer(source.epgRefreshTimer);
    source.epgRefreshTimer = scheduleTimer(function () {
      source.epgRefreshTimer = null;
      if (active !== source || expected !== revision) return;
      guideCache = null;
      attemptGuide(source, expected, false).catch(function () {});
    }, Math.max(0, dueAt - now()));
  }
  function armEpgRefresh(source, expected) {
    cancelTimer(source.epgRefreshTimer); source.epgRefreshTimer = null;
    if (!source.capabilities || source.capabilities.fullCatalogCache !== true || !(cachePolicy.epgMaxAgeMs > 0) || source.preparation && source.preparation.sections.epg && source.preparation.sections.epg.status === 'unavailable') return;
    readEpgState(source, expected).then(function () {
      if (active === source && expected === revision) scheduleEpgRefresh(source, expected);
    }).catch(function () {});
  }
  function armPreparedCatalogRefresh(source, expected) {
    cancelTimer(source.preparedRefreshTimer); source.preparedRefreshTimer = null;
    if (!(cachePolicy.catalogMaxAgeMs > 0) || !source.catalogState || source.preparationBackgroundFlight) return;
    var deadlines = [], retryAt = source.catalogRetryAt || {};
    catalogKinds.forEach(function (kind) {
      var retry = retryAt[kind] || 0, row = source.catalogState.kinds[kind], at = row && catalogSyncedAt(row.syncedAt);
      deadlines.push(retry > now() ? retry : row && row.complete ? (at || now()) + cachePolicy.catalogMaxAgeMs : now());
    });
    var dueAt = Math.min.apply(Math, deadlines);
    source.preparedRefreshTimer = scheduleTimer(function () {
      source.preparedRefreshTimer = null;
      if (active !== source || expected !== revision) return;
      runPreparedBackground(source, expected, false);
    }, Math.max(0, dueAt - now()));
  }
  function runPreparedBackground(source, expected, includeGuide) {
    if (source.preparationBackgroundFlight || active !== source || expected !== revision) return source.preparationBackgroundFlight || Promise.resolve();
    var state = source.catalogState, due = refreshDueKinds(source, state), jobs = [], catalogJob = Promise.resolve();
    if (due.length) {
      catalogJob = prepareCatalogBatch(source, expected, due, false, null).then(function (next) {
        return readPreparedLive(source, expected, next).then(function () {
          if (due.indexOf('live') >= 0 && !(source.catalogRetryAt && source.catalogRetryAt.live)) {
            catalogRevision++; if (options.onProgress) options.onProgress();
          }
          return savePreparedCatalog(source, expected, false);
        });
      }).catch(function (failure) { check(expected); return null; });
      jobs.push(catalogJob);
    }
    if (includeGuide) jobs.push(readEpgState(source, expected).then(function () {
      if (!epgRefreshDue(source)) { scheduleEpgRefresh(source, expected); return null; }
      guideCache = null;
      return attemptGuide(source, expected, false);
    }));
    if (!jobs.length) { armPreparedCatalogRefresh(source, expected); return Promise.resolve(); }
    var flight = Promise.all(jobs.map(function (job) { return Promise.resolve(job).catch(function () { return null; }); })).then(function () {
      check(expected); return catalogState(source, expected);
    }).then(function (next) {
      if (active === source && expected === revision) {
        source.catalogState = next;
      }
    }).catch(function () {});
    source.preparationBackgroundFlight = flight;
    function finished() {
      if (source.preparationBackgroundFlight === flight) {
        source.preparationBackgroundFlight = null;
        if (active === source && expected === revision) armPreparedCatalogRefresh(source, expected);
      }
    }
    flight.then(finished, finished);
    return flight;
  }
  function schedulePreparedBackground(source, expected) {
    if (source.preparationBackgroundScheduled) return;
    source.preparationChecked = true; source.preparationBackgroundScheduled = true;
    scheduleTimer(function () {
      if (active !== source || expected !== revision) return;
      source.preparationBackgroundScheduled = false;
      runPreparedBackground(source, expected, true);
    }, 0);
  }
  function loadPreparedCatalog(source, expected, state, progress) {
    syncCatalogState(source, state);
    var saved = catalogHasContent(source, state);
    if (saved) {
      return readPreparedLive(source, expected, state).then(function () {
        source.preparationChecked = true;
        if (progress) progress(null);
        schedulePreparedBackground(source, expected);
        return source.catalog;
      });
    }
    catalogKinds.forEach(function (kind) {
      var row = state.kinds[kind];
      if (!row || row.complete !== true) setPreparationSection(source, kind, 'pending', row && row.count, row && row.syncedAt);
    });
    setPreparationSection(source, 'epg', 'pending'); setPreparationStage(source, progress);
    var batch = prepareCatalogBatch(source, expected, catalogKinds, false, progress);
    return batch.then(function (updated) {
      return readPreparedLive(source, expected, updated).then(function () {
        setPreparationStage(source, progress);
        return attemptGuide(source, expected, true);
      }).then(function () {
        return catalogState(source, expected).then(function (finalState) {
          source.catalogState = finalState;
          if (catalogHasContent(source, finalState)) {
            var persistProgress = beginLoading('catalog-persist');
            return savePreparedCatalog(source, expected, false).then(function () {
              if (source.cachePersisted === false && options.onProgress) options.onProgress();
              source.preparationChecked = true; armPreparedCatalogRefresh(source, expected);
              persistProgress(null);
              return source.catalog;
            }, function (failure) {
              persistProgress(null); throw failure;
            });
          }
          source.catalog = null;
          throw error('No channels, movies or series were found in this source.', 'catalog_empty');
        });
      });
    }).then(function (catalog) { if (progress) progress(null); return catalog; }, function (failure) {
      if (progress) progress(null); throw failure;
    });
  }
  function restoreGuide(source, expected) {
    if (!catalogStore || !source || !source.cacheScope) return Promise.resolve();
    if (source.guideReady) return source.guideReady;
    function read(remaining) {
      if (!remaining) return Promise.resolve();
      return catalogStore.read(source.guideKey).then(function (saved) {
        check(expected);
        if (!saved) return;
        var restored = source.engine.restoreGuide
          ? source.engine.restoreGuide(source.cacheScope, saved.raw)
          : source.engine.invoke('importGuide', JSON.stringify({ scope: source.cacheScope, snapshot: saved.raw }));
        return restored.then(function (raw) {
          check(expected);
          if (!parsed(raw)) return catalogStore.discard(source.guideKey, saved.token).then(function () { return read(remaining - 1); });
          source.guideRestored = true;
          return invoke('guideRevision', {}, source).then(function (value) { source.guideSavedRevision = value; });
        });
      });
    }
    source.guideReady = Promise.resolve(source.guideKey || invoke('guideCacheKey', { scope: source.cacheScope }, source)).then(function (key) {
      check(expected); source.guideKey = key; return read(2);
    }).catch(function () { check(expected); });
    return source.guideReady;
  }
  function saveGuide(source, expected, detached) {
    if (!catalogStore || !source || !source.guideKey) return Promise.resolve(false);
    source.guideDirty = false;
    function stillCurrent() { if (!detached) check(expected); }
    return invoke('guideRevision', {}, source).then(function (value) {
      stillCurrent();
      if (value === source.guideSavedRevision) return true;
      return source.engine.invoke('exportGuide', JSON.stringify({ scope: source.cacheScope })).then(function (raw) {
        stillCurrent();
        if (!source.engine.restoreGuide) raw = parsed(raw);
        return catalogStore.write(source.guideKey, raw, 'guide').then(function (saved) {
          if (saved) source.guideSavedRevision = value;
          return saved;
        });
      });
    }).catch(function () {
      if (!detached && expected !== revision) source.guideDirty = true;
      stillCurrent(); return false;
    });
  }
  function scheduleGuideSave(source) {
    if (!catalogStore || !source || !source.guideKey) return;
    source.guideDirty = true;
    if (source.guideSaveTimer || source.guideSaveFlight) return;
    var expected = revision;
    source.guideSaveTimer = setTimeout(function () {
      source.guideSaveTimer = null;
      if (active !== source || expected !== revision) return;
      source.guideSaveFlight = saveGuide(source, expected);
      source.guideSaveFlight.then(function () {
        source.guideSaveFlight = null;
        if (source.guideDirty && active === source && expected === revision) scheduleGuideSave(source);
      }, function () { source.guideSaveFlight = null; });
    }, 1000);
  }
  function flushSource(source, expected, detached) {
    if (!source) return Promise.resolve();
    if (source.flushFlight) return source.flushFlight.catch(function () {}).then(function () {
      if (!detached) check(expected);
      return flushSource(source, expected, detached);
    });
    clearTimeout(source.cacheSaveTimer); source.cacheSaveTimer = null;
    clearTimeout(source.guideSaveTimer); source.guideSaveTimer = null;
    clearTimeout(source.metadataSaveTimer); source.metadataSaveTimer = null;
    var operation = Promise.all([source.cacheSaveFlight, source.guideSaveFlight, source.guideReadFlight, source.metadataSaveFlight].map(function (flight) {
      return Promise.resolve(flight).catch(function () {});
    })).then(function () {
      if (!detached) check(expected);
      // A guide that completed while flushing may have scheduled fresh timers.
      clearTimeout(source.cacheSaveTimer); source.cacheSaveTimer = null;
      clearTimeout(source.guideSaveTimer); source.guideSaveTimer = null;
      clearTimeout(source.metadataSaveTimer); source.metadataSaveTimer = null;
      var catalogue = source.cacheDirty ? saveCatalog(source, expected, detached) : undefined;
      var guide = source.guideDirty ? saveGuide(source, expected, detached) : undefined;
      var metadata = source.metadataDirty ? saveMetadata(source, expected, detached) : undefined;
      if (catalogue) source.cacheSaveFlight = catalogue;
      if (guide) source.guideSaveFlight = guide;
      if (metadata) source.metadataSaveFlight = metadata;
      return Promise.all([catalogue, guide, metadata]).then(function () {
        if (catalogue && source.cacheSaveFlight === catalogue) source.cacheSaveFlight = null;
        if (guide && source.guideSaveFlight === guide) source.guideSaveFlight = null;
        if (metadata && source.metadataSaveFlight === metadata) source.metadataSaveFlight = null;
        if (!detached && active === source && expected === revision) {
          if (source.cacheDirty) scheduleCatalogSave(source);
          if (source.guideDirty) scheduleGuideSave(source);
          if (source.metadataDirty) scheduleMetadataSave(source);
        }
      });
    });
    source.flushFlight = operation;
    function finish() { if (source.flushFlight === operation) source.flushFlight = null; }
    operation.then(finish, finish);
    return operation;
  }
  function flushCatalog() { return flushSource(active, revision, false); }
  function fetchCatalog(source, expected, progress) {
    if (progress) progress('source-connect');
    return invoke('connect', {}, source).then(function () {
      check(expected);
      if (progress) progress('source-channels');
      return Promise.all([invoke('categories', {}, source), invoke('channels', {}, source)]);
    }).then(function (parts) {
      check(expected); source.catalog = parts; source.catalogAt = now();
      // Publish the complete provider result before exporting a potentially
      // large snapshot and writing it to the TV filesystem.
      scheduleCatalogSave(source);
      return parts;
    });
  }
  function armCatalogRefresh(source, expected) {
    if (source.cacheRefreshTimer || source.cacheRefreshFlight || !(cachePolicy.catalogMaxAgeMs > 0)) return;
    var age = now() - source.catalogAt;
    var delay = Math.max(0, cachePolicy.catalogMaxAgeMs - Math.max(0, age));
    if (source.cacheRefreshFailed) delay = Math.max(delay, 3600000);
    source.cacheRefreshTimer = setTimeout(function () {
      source.cacheRefreshTimer = null;
      if (active !== source || expected !== revision) return;
      // Keep the active engine readable (and its guide/player intact) until a
      // separate provider read has produced a complete, importable snapshot.
      var replacement;
      source.cacheRefreshFlight = Promise.resolve().then(function () {
        check(expected);
        replacement = { config: source.config, engine: createSource(JSON.stringify(source.config), function (request, responseOptions) {
          if (expected !== revision) return Promise.resolve(JSON.stringify({ errorKind: 'cancelled' }));
          return transport.request(request, responseOptions);
        }) };
        return fetchCatalog(replacement, expected);
      }).then(function () {
        return replacement.engine.invoke('exportCatalog', JSON.stringify({ scope: source.cacheScope }));
      }).then(function (raw) {
        check(expected);
        if (!replacement.engine.restoreCatalog) raw = parsed(raw);
        if (typeof raw !== 'string') throw error('Nie można zachować katalogu.', 'cache_limit');
        return Promise.resolve(source.guideReadFlight).catch(function () {}).then(function () {
          check(expected);
          var commit = Promise.all((source.invocations || []).map(function (read) { return read.catch(function () {}); })).then(function () {
            check(expected);
            return source.engine.restoreCatalog ? source.engine.restoreCatalog(source.cacheScope, raw)
              : source.engine.invoke('importCatalog', JSON.stringify({ scope: source.cacheScope, snapshot: raw }));
          });
          source.catalogCommit = commit;
          function committed() { if (source.catalogCommit === commit) source.catalogCommit = null; }
          commit.then(committed, committed);
          return commit;
        });
      }).then(function (restored) {
        check(expected);
        if (!parsed(restored)) throw error('Nieprawidłowy katalog.', 'cache_invalid');
        source.catalog = replacement.catalog; source.catalogAt = replacement.catalogAt;
        source.cacheRefreshFailed = false;
        source.categories = source.catalog[0]; source.channels = source.catalog[1];
        source.readCache = null; source.reads = null;
        scheduleCatalogSave(source);
        catalogRevision++; if (options.onProgress) options.onProgress();
      }).then(function () { return replacement.engine.dispose(); }, function (failure) {
        source.cacheRefreshFailed = true;
        return replacement ? replacement.engine.dispose() : undefined;
      }).then(function () {
        source.cacheRefreshFlight = null;
        if (active === source && expected === revision) armCatalogRefresh(source, expected);
      });
    }, delay);
  }
  function release(preservePlay) {
    var progress = saveProgress(options.getState());
    ++revision;
    ++guideTicket; guideCache = null; guideFlight = null; guideFlightKey = null;
    if (!preservePlay) ++playRevision;
    transport.abort();
    var old = active; active = null; playing = null;
    if (old) {
      clearTimeout(old.cacheSaveTimer); clearTimeout(old.cacheRefreshTimer); clearTimeout(old.guideSaveTimer);
      clearTimeout(old.metadataSaveTimer); cancelTimer(old.preparedRefreshTimer); cancelTimer(old.epgRefreshTimer);
    }
    var stopped = Promise.resolve().then(options.stop);
    var disposed = stopped.then(function () {
      if (!old) return;
      return flushSource(old, revision, true).then(function () { return old.engine.dispose(); });
    });
    return Promise.all([progress, disposed, historyWrite]);
  }
  function configure(config, connect, preservePlay) {
    var same = active && active.config.id === config.id && JSON.stringify(active.config) === JSON.stringify(config);
    if (same) {
      var existing = active, currentRevision = revision;
      return (connect ? invoke('connect', {}, existing) : Promise.resolve()).then(function () { check(currentRevision); return existing; });
    }
    var closing = release(preservePlay), expected = revision;
    return closing.then(function () {
      check(expected);
      var source = { config: copy(config), engine: createSource(JSON.stringify(config), function (request, responseOptions) {
        if (expected !== revision) return Promise.resolve(JSON.stringify({ errorKind: 'capability', error: 'Zapytanie anulowano.' }));
        return transport.request(request, responseOptions);
      }), channels: [], categories: [], capabilities: {} };
      active = source;
      return (connect ? invoke('connect', {}, source) : Promise.resolve()).then(function () { check(expected); return invoke('capabilities', {}, source); }).then(function (caps) {
        check(expected); source.capabilities = caps; return source;
      });
    });
  }
  function selectSource(args, preservePlay) {
    var owner = allowedProfile(), profileId = owner.id;
    var config = args.config || configList().filter(function (s) { return s.id === args.id; })[0];
    if (!config) return Promise.reject(error('Nie znaleziono źródła.'));
    if (hostedHttpSource(config)) return Promise.reject(error(hostedHttpMessage, 'hosted_http_blocked'));
    var progress = beginLoading('catalog-read');
    return configure(config, false, preservePlay).then(function (source) {
      source.cacheScope = bucketId(owner);
      if (source.catalog || source.catalogFlight) return source;
      return migrateLegacySourceCache(config, null, source.cacheScope, source.engine, true).then(function () { return source; });
    }).then(function (source) {
      var expected = revision;
      var catalog = source.catalogFlight || (source.catalog ? Promise.resolve(source.catalog) : null);
      if (!catalog) {
        var fullCache = source.capabilities && source.capabilities.fullCatalogCache === true;
        var keys = catalogStore ? Promise.all([
          invoke('cacheKey', { scope: source.cacheScope }, source).then(function (key) {
            source.cacheKey = key;
          }).catch(function () { check(expected); source.cacheKey = null; }),
          invoke('guideCacheKey', { scope: source.cacheScope }, source).then(function (key) {
            source.guideKey = key;
            if (typeof catalogStore.mark === 'function') return Promise.resolve().then(function () {
              return catalogStore.mark(key, 'guide');
            }).catch(function () {});
          }).catch(function () { check(expected); source.guideKey = null; })
        ]) : Promise.resolve();
        catalog = Promise.all([keys, setupMetadata(source, expected)]).then(function () {
          if (fullCache) {
            return restoreCatalogBatch(source, expected, 2).then(function (state) {
              if (state) return state;
              return restoreCatalog(source, expected, 2).then(function (saved) {
                check(expected);
                if (saved) {
                  source.catalog = [saved.categories, saved.channels]; source.catalogAt = catalogSyncedAt(saved.syncedAt) || now();
                  source.categories = source.catalog[0]; source.channels = source.catalog[1];
                  source.capabilities = saved.capabilities || source.capabilities;
                }
                return catalogState(source, expected);
              });
            }).then(function (state) { return loadPreparedCatalog(source, expected, state, progress); });
          }
          return restoreCatalog(source, expected, 2).then(function (saved) {
            check(expected);
            if (saved) {
              source.catalog = [saved.categories, saved.channels]; source.catalogAt = saved.syncedAt;
              source.capabilities = saved.capabilities || source.capabilities;
              return source.catalog;
            }
            return fetchCatalog(source, expected, progress);
          });
        });
        source.catalogFlight = catalog;
        function clearCatalog() { if (source.catalogFlight === catalog) source.catalogFlight = null; }
        catalog.then(clearCatalog, clearCatalog);
      }
      return catalog.then(function (parts) {
        check(expected); source.categories = parts[0]; source.channels = parts[1];
        if (source.capabilities && source.capabilities.fullCatalogCache === true) {
          if (!source.preparationBackgroundScheduled && !source.preparationBackgroundFlight && source.catalogState) armPreparedCatalogRefresh(source, expected);
        } else armCatalogRefresh(source, expected);
        function ready() {return catalogView(source);}
        // Reopening the selected source is navigation, not a profile mutation.
        // Avoid joining unrelated queued KeyManager writes on this warm path.
        var selected = allowedProfile();
        if (selected.id === profileId && selected.source === owner.source && selected.snapshot.activeSourceId === config.id) return ready();
        return mutateProfile(profileId, function (state) {
          check(expected);
          var rows = profiles(state), p = current(state, rows);
          p.snapshot.activeSourceId = config.id; setProfiles(state, rows);
        }, owner.source).then(ready);
      });
    }).then(function (result) { progress(null); return result; }, function (failure) { progress(null); throw failure; });
  }
  function guide(args) {
    var source = active, expected = revision;
    var channels = (args.channels || (source && source.channels) || []).slice(0,40);
    channels = source ? visibleChannels(sourceConfig(source.config.id),channels) : channels;
    var overrides=source ? mappingsFor(source.config.id) : [],offsets=Object.create(null),minimumOffset=0,maximumOffset=0;
    overrides.forEach(function (row) {offsets[row.channelId]=row.offsetMinutes*60000;minimumOffset=Math.min(minimumOffset,offsets[row.channelId]);maximumOffset=Math.max(maximumOffset,offsets[row.channelId]);});
    var from = args.from ? Math.floor(Date.parse(args.from) / 1800000) * 1800000 : null;
    var to = args.to ? Math.ceil(Date.parse(args.to) / 1800000) * 1800000 : null;
    var sourceKey = source && JSON.stringify(source.config);
    var key = JSON.stringify([expected, channels.map(function (channel) { return channel.id; }).sort(), from, to]);
    function cachedWindow() {
      if (!guideCache || guideCache.revision !== expected || now() < guideCache.at || now() - guideCache.at >= 60000) return false;
      if (guideCache.from !== null && (from === null || from < guideCache.from)) return false;
      if (guideCache.to !== null && (to === null || to > guideCache.to)) return false;
      return channels.every(function (channel) { return guideCache.channelIds[channel.id] === true; });
    }
    function present(programmes) {
      var currentTime = now(), currentIso = new Date(currentTime).toISOString();
      var byId = Object.create(null), channelJson = Object.create(null), nowNext = {};
      channels.forEach(function (channel) { byId[channel.id] = channel; });
      programmes = programmes.filter(function (programme) { return byId[programme.channelId] && (!args.from || programme.stop > args.from) && (!args.to || programme.start < args.to); });
      programmes = programmes.map(function (row) {
        var programme = Object.assign({}, row), start = Date.parse(programme.start), stop = Date.parse(programme.stop);
        var channel = channelJson[programme.channelId] || (channelJson[programme.channelId] = JSON.stringify(byId[programme.channelId]));
        programme.canCatchup = !!core.canCatchup(channel, JSON.stringify(row), currentIso);
        var line = nowNext[programme.channelId] || (nowNext[programme.channelId] = {});
        if (start <= currentTime && stop > currentTime) line.now = programme;
        if (start > currentTime && (!line.next || programme.start < line.next.start)) line.next = programme;
        return programme;
      });
      return { programmes: programmes, nowNext: nowNext };
    }
    if (cachedWindow()) return Promise.resolve(present(guideCache.programmes));
    if (guideFlight && guideFlightKey === key) return guideFlight.then(function () {
      check(expected);
      if (!cachedWindow()) throw error('Wczytywanie anulowano.', 'cancelled');
      return present(guideCache.programmes);
    });
    var ticket = ++guideTicket;
    var previous = guideFlight || Promise.resolve();
    var progress, servedCached = false;
    var request = { channels: channels, from: from ? new Date(from-maximumOffset).toISOString() : null, to: to ? new Date(to-minimumOffset).toISOString() : null, _tvEpgScope: source && source.cacheScope };
    function corrected(programmes) {
      return programmes.map(function (programme) {
        var offset=offsets[programme.channelId];
        return offset ? Object.assign({},programme,{start:new Date(Date.parse(programme.start)+offset).toISOString(),stop:new Date(Date.parse(programme.stop)+offset).toISOString()}) : programme;
      });
    }
    function remember(programmes) {
      var channelIds = Object.create(null);
      channels.forEach(function (channel) { channelIds[channel.id] = true; });
      guideCache = { key: key, revision: expected, from: from, to: to, channelIds: channelIds, at: now(), programmes: programmes };
    }
    var cachedRead = Promise.resolve().then(function () {
      check(expected);
      if (ticket !== guideTicket) throw error('Wczytywanie anulowano.', 'cancelled');
      return restoreGuide(source, expected).then(function () {
        check(expected);
        if (ticket !== guideTicket) throw error('Wczytywanie anulowano.', 'cancelled');
        return invoke('epgMapping.set',{overrides:overrides},source).then(function () {
          return source.guideRestored || source.guideLoaded ? invoke('epgCached', request, source).catch(function () { return null; }) : null;
        });
      }).then(function (programmes) {
        check(expected);
        if (ticket !== guideTicket) throw error('Wczytywanie anulowano.', 'cancelled');
        if (!Array.isArray(programmes) || !programmes.length) return null;
        programmes = corrected(programmes); remember(programmes); servedCached = true;
        return programmes;
      });
    });
    var operation = Promise.all([cachedRead, previous.catch(function () {})]).then(function () {
      check(expected);
      if (ticket !== guideTicket) throw error('Wczytywanie anulowano.', 'cancelled');
      if (guideFailure && guideFailure.status !== 403 && guideFailure.sourceKey === sourceKey && now() < guideFailure.retryAt) throw epgError('epg_retry_deferred', guideFailure.status, guideFailure.causeCode, guideFailure.retryAt);
      progress = beginLoading('guide-download');
      return invoke('epg', request, source).then(function (programmes) {
        check(expected);
        source.guideLoaded = true;
        source.epgAt = now(); source.epgRetryAt = 0; armEpgRefresh(source, expected);
        scheduleCatalogSave(source);
        scheduleGuideSave(source);
        return corrected(programmes);
      }, function (failure) {
        check(expected);
        scheduleGuideSave(source);
        throw failure;
      });
    }).then(function (programmes) {
      check(expected);
      if (ticket !== guideTicket) throw error('Wczytywanie anulowano.', 'cancelled');
      remember(programmes);
      if (guideFailure && guideFailure.sourceKey === sourceKey) guideFailure = null;
      if (servedCached) { guideRevision++; if (options.onProgress) options.onProgress(); }
      return present(programmes);
    }).catch(function (failure) {
      if (failure.status !== 403 && failure.code !== 'cancelled' && failure.name !== 'AbortError' && expected === revision && cachePolicy.epgRetryDelayMs > 0) {
        guideFailure = { sourceKey: sourceKey,
          retryAt: typeof failure.retryAt === 'number' ? failure.retryAt : now() + cachePolicy.epgRetryDelayMs,
          causeCode: failure.code === 'epg_retry_deferred' ? failure.causeCode : failure.code,
          status: failure.status };
      }
      throw failure;
    });
    guideFlight = operation;
    guideFlightKey = key;
    if (source) source.guideReadFlight = operation;
    function finish() {
      if (guideFlight === operation) { guideFlight = null; guideFlightKey = null; }
      if (source && source.guideReadFlight === operation) source.guideReadFlight = null;
      if (progress) progress(null);
    }
    operation.then(finish, finish);
    return cachedRead.then(function (programmes) { return programmes ? present(programmes) : operation; });
  }
  function verify(pin, verifier) { return Promise.resolve(verifyPin(String(pin || ''), verifier)); }
  function parental() {
    var profile=current(),recovery=objectValue(K.recovery,{})[profile && profile.id],value = recovery && recovery.parentalRules || decode(K.parental, { version: 1, verifier: null, lockSettings: true, channels: [], categories: [] });
    if (typeof core.parentalRules!=='function' && storage.get(K.parental)==null && !(recovery && recovery.parentalRules)) return value;
    return parsed(core.parentalRules('validate', JSON.stringify({ rules: value })));
  }
  function parentalProof(args, rules) {
    if (!rules.verifier) return Promise.resolve();
    if (!args.pin) return Promise.reject(error('Podaj PIN kontroli rodzicielskiej.', 'pin_required'));
    return verify(args.pin, rules.verifier).then(function (ok) { if (!ok) throw error('Nieprawidłowy PIN.', 'pin_invalid'); });
  }
  function authorize(args, content) {
    allowedProfile();
    var rules = parental();
    if (!rules.verifier || parentalUnlocked === rules.verifier) return Promise.resolve();
    var protects = content ? parsed(core.parentalRules('protects', JSON.stringify({
      rules: rules, sourceId: active.config.id, id: content.id,
      kind: content.kind || 'live', categoryId: content.categoryId || null
    }))) : rules.lockSettings;
    if (!protects) return Promise.resolve();
    return parentalProof(args, rules);
  }
  function dataKey(sourceId, item) { return JSON.stringify([sourceId, item.kind || 'live', item.id]); }
  function supporter() {
    if (!cloud || !cloud.hasSession()) return Promise.resolve(false);
    return cloud.query('supporter.status', {}).then(function (status) {
      return !!core.supporterActive(JSON.stringify(status), new Date().toISOString());
    }).catch(function () { return false; });
  }
  function resume(item, requestedSourceId) {
    var profile = allowedProfile(), expected = revision;
    var sourceId = requestedSourceId || item.sourceId || (active && active.config.id);
    var row = profileBucket(K.positions, {})[dataKey(sourceId, item)] || { position: 0, duration: 0 };
    var finished = false, position = Number(row.position || 0), duration = Number(row.duration || 0);
    if (typeof core.mediaProgress === 'function' && isFinite(position) && isFinite(duration) && position >= 0 && duration >= 0) {
      var positions = parsed(core.mediaProgress(JSON.stringify([{id:item.id,kind:item.kind,position:position,duration:duration}])));
      finished = !!(positions[item.id] && positions[item.id].finished);
    }
    return supporter().then(function (allowed) {
      check(expected);
      var selected = allowedProfile();
      if (selected.id !== profile.id || selected.source !== profile.source) throw error('Profil został zmieniony.', 'cancelled');
      return { position: finished ? 0 : row.position, duration: row.duration, allowed: allowed };
    });
  }
  function mediaProgress(args) {
    var profile = allowedProfile(), sourceId = args.sourceId || (active && active.config.id);
    var expected = revision, items = Array.isArray(args.items) ? args.items.slice(0,80) : [];
    if (!sourceId || !configList().some(function (config) { return config.id === sourceId; })) throw error('Nie znaleziono źródła.');
    var saved = profileBucket(K.positions, {}), rows = [];
    items.forEach(function (item) {
      if (!item || typeof item.id !== 'string' || (item.kind !== 'movie' && item.kind !== 'episode')) return;
      var row = saved[dataKey(sourceId,item)];
      if (!row || row.removed) return;
      var position = Number(row.position), duration = Number(row.duration || 0);
      if (!isFinite(position) || !isFinite(duration) || position < 0 || duration < 0) return;
      rows.push({id:item.id,kind:item.kind,position:position,duration:duration});
    });
    var positions = typeof core.mediaProgress === 'function' ? parsed(core.mediaProgress(JSON.stringify(rows))) : {};
    return supporter().then(function (allowed) {
      check(expected);
      var selected = allowedProfile();
      if (selected.id !== profile.id || selected.source !== profile.source) throw error('Profil został zmieniony.', 'cancelled');
      return {positions:positions,resumeAllowed:allowed};
    });
  }
  function seriesProgress(args) {
    var profile = allowedProfile(), source = active, expected = revision;
    var sourceId = args.sourceId || source && source.config.id, item = args.item;
    if (!source || source.config.id !== sourceId) throw error('Najpierw wybierz źródło.', 'cancelled');
    sourceConfig(sourceId);
    if (!item || item.kind !== 'series' || typeof item.id !== 'string' || !item.id) throw error('Nie znaleziono serialu.');
    var saved = profileBucket(K.positions, {}), positions = [];
    Object.keys(saved).forEach(function (key) {
      var identity;
      try { identity = JSON.parse(key); } catch (_) { return; }
      if (!Array.isArray(identity) || identity.length !== 3 || identity[0] !== sourceId || identity[1] !== 'episode' || typeof identity[2] !== 'string') return;
      var row = saved[key];
      if (!row || row.removed || row.sourceId && row.sourceId !== sourceId) return;
      var position = Number(row.position), duration = Number(row.duration || 0);
      if (!isFinite(position) || !isFinite(duration) || position < 0 || duration < 0) return;
      var updatedAt = typeof row.updatedAt === 'number' ? row.updatedAt : Date.parse(row.updatedAt);
      var content = row.item && row.item.id === identity[2] && row.item.kind === 'episode' ? row.item : null;
      positions.push({id:identity[2],kind:'episode',position:position,duration:duration,
        updatedAt:isFinite(updatedAt) ? updatedAt : 0,item:content});
    });
    return invoke('seriesProgress', {item:item,positions:positions,prepareNext:true}, source).then(function (value) {
      check(expected);
      var selected = allowedProfile();
      if (active !== source || selected.id !== profile.id || selected.source !== profile.source) throw error('Profil został zmieniony.', 'cancelled');
      scheduleCatalogSave(source);
      return value;
    });
  }
  function metadataStatus() {
    var metadata = allowedProfile().snapshot.metadata || {};
    var configured = ['tmdbApiKey','tvdbApiKey','mdblistApiKey'].some(function (key) {
      return typeof metadata[key] === 'string' && metadata[key].trim().length > 0;
    });
    return {source:'provider',configured:configured,externalLookupsAvailable:false,
      provider:metadata.provider === 'tvdb' ? 'tvdb' : 'tmdb',status:'provider_metadata'};
  }
  function saveProgress(state) {
    if (!playing || !playing.item || playing.item.kind === 'live' || !state || !(state.position >= 0)) return Promise.resolve();
    var profile = current();
    if (!profile) return Promise.resolve();
    var snapshot = copy(playing), profileId = profile.id, profileSource = profile.source;
    var decision = typeof core.resumeDecisionForKind === 'function'
      ? core.resumeDecisionForKind(snapshot.item.kind,state.position || 0,state.duration || 0)
      : core.resumeDecision(state.position || 0,state.duration || 0);
    return Promise.resolve(decision).then(function (raw) {
      var decision = parsed(raw);
      if (decision.action === 'ignore') return;
      return mutate(function (data) {
      var currentProfile = current(data);
      if (!currentProfile || currentProfile.id !== profileId || currentProfile.source !== profileSource) return;
      var rows = profileBucket(K.positions, {}, data), key = dataKey(snapshot.sourceId, snapshot.item);
      rows[key] = { sourceId: snapshot.sourceId, item: snapshot.item,
        position: decision.action === 'clear' ? 0 : state.position, duration: state.duration,
        removed: decision.action === 'clear', updatedAt: new Date().toISOString() };
      writeBucket(data, K.positions, rows);
      if (profileSource==='cloud') {var pending=pendingOutbox(data);pending.playback=pending.playback || {};pending.playback[key]=Object.assign({},rows[key],{version:core.newSourceId()});writeBucket(data,K.outbox,pending);}
      });
    }).then(function () {schedulePlaybackPush();});
  }
  function schedulePlaybackPush() {
    if (disposed || !autoEnabled() || autoPlaybackTimer) return;
    autoPlaybackTimer=setTimeout(function () {autoPlaybackTimer=null;enqueueAuto(autoPushPlayback).catch(function () {schedulePlaybackPush();});},120000);
  }
  function autoPushPlayback() {
    var owner=current();
    if (disposed || !autoEnabled() || !cloud || !cloud.hasSession() || !owner || owner.source!=='cloud' || viewProfile(owner).locked) return Promise.resolve({sent:false});
    var snapshot=copy(pendingOutbox().playback || {}),managed=owner.snapshot.managedIds || [],keys=Object.keys(snapshot).filter(function (key) {return managed.indexOf(snapshot[key].sourceId)>=0;});
    if (!keys.length) return Promise.resolve({sent:false});
    return supporter().then(function (allowed) {
      if (!allowed) return {sent:false};
      var rows=keys.map(function (key) {var row=snapshot[key];return {source_id:row.sourceId,kind:row.item.kind,item_id:row.item.id,position_ms:Math.round(row.position*1000),duration_ms:Math.round((row.duration || 0)*1000),updated_at:Date.parse(row.updatedAt),removed:row.removed===true};});
      return cloud.query('push.playback',{profileId:owner.id,playbackPositions:rows}).then(function (result) {
        if (!result.available || result.count!==rows.length) return {sent:false};
        return mutateProfile(owner.id,function (state) {var pending=pendingOutbox(state);keys.forEach(function (key) {if (pending.playback && pending.playback[key] && pending.playback[key].version===snapshot[key].version) delete pending.playback[key];});writeBucket(state,K.outbox,pending);},'cloud').then(function () {return {sent:true};});
      });
    });
  }
  function remember(content, sourceId, profileId, profileSource) {
    return mutateProfile(profileId, function (data) {
      var history = profileBucket(K.history, [], data), key = dataKey(sourceId, content);
      history = history.filter(function (row) { return dataKey(row.sourceId, row.item || row.channel) !== key; });
      history.unshift({ sourceId: sourceId, item: content.kind ? content : null,
        channel: content.kind ? null : content, updatedAt: new Date().toISOString() });
      writeBucket(data, K.history, history.slice(0, 100));
    }, profileSource);
  }
  function favoriteRows(rows, previous) {
    return rows.map(function (row) {
      if (row.sourceId && (row.item || row.channel)) return row;
      var sourceId = row.source_id, kind = row.kind || 'live', id = row.item_id;
      var known = (previous || []).filter(function (entry) { return entry.sourceId === sourceId && dataKey(sourceId, entry.item || entry.channel) === dataKey(sourceId, { id: id, kind: kind }); })[0];
      if (known) return known;
      var content = { id: id, title: id, name: id, extra: {} };
      if (kind !== 'live') content.kind = kind;
      return { sourceId: sourceId, item: kind === 'live' ? null : content, channel: kind === 'live' ? content : null, unresolved: true };
    });
  }
  function favoritesList() {
    var profile = allowedProfile(), profileId = profile.id, profileSource = profile.source, expected = revision;
    var rows = profileBucket(K.favorites, []), groups = {}, ranks=Object.create(null), categoryRanks=Object.create(null), configs=configList();
    function stillCurrent() {
      check(expected);
      var selected = current();
      if (!selected || selected.id !== profileId || selected.source !== profileSource) throw error('Profil został zmieniony.', 'cancelled');
    }
    configs.forEach(function (config) {
      ranks[config.id]=Object.create(null);
      organization.normalize(config.settings && config.settings.channelOrganization).order.forEach(function (id,index) {ranks[config.id][id]=index;});
    });
    if (active) {
      var ranked=organization.apply(active.channels,active.config.settings && active.config.settings.channelOrganization,true),known=Object.create(null);
      ranked.forEach(function (channel,index) {ranks[active.config.id][channel.id]=index;known[channel.id]=channel;});
      categoryRanks[active.config.id]=Object.create(null);active.categories.forEach(function (category,index) {categoryRanks[active.config.id][category.id]=index;});
      rows.forEach(function (row) {if (row.sourceId===active.config.id && row.channel && known[row.channel.id]) {row.channel=known[row.channel.id];delete row.unresolved;}});
    }
    rows.forEach(function (row) {
      var content = row.item || row.channel, kind = content.kind || 'live';
      if (!row.unresolved) return;
      groups[JSON.stringify([row.sourceId, kind])] = { sourceId: row.sourceId, kind: kind };
    });
    var chain = Promise.resolve();
    Object.keys(groups).forEach(function (key) {
      chain = chain.then(function () {
        stillCurrent();
        var group = groups[key], config = configList().filter(function (s) { return s.id === group.sourceId; })[0];
        if (!config || group.kind === 'episode') return;
        var temporary = !active || active.config.id !== config.id;
        var source = temporary ? { config: config, engine: createSource(JSON.stringify(config), function (request, responseOptions) {
          try { stillCurrent(); } catch (_) { return Promise.resolve(JSON.stringify({ errorKind: 'capability', error: 'Zapytanie anulowano.' })); }
          return transport.request(request, responseOptions);
        }) } : active;
        var ready = temporary ? invoke('connect', {}, source) : Promise.resolve();
        return ready.then(function () { stillCurrent(); return Promise.all([invoke(group.kind === 'live' ? 'channels' : 'allMediaItems', { kind: group.kind }, source),
          group.kind==='live' ? invoke('categories',{},source) : Promise.resolve([])]); }).then(function (parts) {
          stillCurrent();
          var items=group.kind==='live' ? organization.apply(parts[0],config.settings && config.settings.channelOrganization,true) : parts[0];
          ranks[group.sourceId]=Object.create(null);items.forEach(function (item,index) {ranks[group.sourceId][item.id]=index;});
          categoryRanks[group.sourceId]=Object.create(null);parts[1].forEach(function (category,index) {if (categoryRanks[group.sourceId][category.id]==null) categoryRanks[group.sourceId][category.id]=index;});
          rows.forEach(function (row) {
            var content = row.item || row.channel;
            if (row.sourceId !== group.sourceId || (content.kind || 'live') !== group.kind) return;
            var match = items.filter(function (item) { return item.id === content.id; })[0];
            if (match) { if (group.kind === 'live') row.channel = match; else row.item = match; delete row.unresolved; }
          });
        }).then(function () { if (temporary) return source.engine.dispose(); }, function () {
          return Promise.resolve(temporary ? source.engine.dispose() : undefined).then(stillCurrent);
        });
      });
    });
    return chain.then(function () {
      stillCurrent();
      var sourceRanks=Object.create(null);configs.forEach(function (config,index) {sourceRanks[config.id]=index;});
      rows=rows.filter(function (row) {
        var config=configs.filter(function (source) {return source.id===row.sourceId;})[0],item=row.item || row.channel,kind=item.kind || 'live';
        if (!config) return false;
        return organization.hiddenCategories(config.settings,kind).indexOf(item.categoryId)<0 &&
          (kind!=='live' || organization.normalize(config.settings && config.settings.channelOrganization).hidden.indexOf(item.id)<0) && contentAllowed(config.id,item,kind);
      }).map(function (row,index) {return {row:row,index:index};});
      function rank(map,id) {return map && map[id]!=null ? map[id] : 1073741824;}
      rows.sort(function (a,b) {
        var x=a.row,y=b.row,xi=x.item || x.channel,yi=y.item || y.channel;
        return rank(sourceRanks,x.sourceId)-rank(sourceRanks,y.sourceId) || rank(categoryRanks[x.sourceId],xi.categoryId)-rank(categoryRanks[y.sourceId],yi.categoryId) || rank(ranks[x.sourceId],xi.id)-rank(ranks[y.sourceId],yi.id) || a.index-b.index;
      });
      return { items: rows.map(function (entry) {entry.row.favorite=true;return entry.row;}) };
    });
  }
  function play(args) {
    var owner = allowedProfile(), profileId = owner.id;
    var content = args.item || args.channel;
    var sourceId = args.sourceId || (active && active.config.id);
    if (!content || !sourceId) return Promise.reject(error('Wybierz pozycję do odtworzenia.'));
    var key = dataKey(sourceId, content);
    var request = ++playRevision;
    if (!args.programme && playing && playing.key === key && options.getState().playing) {
      if (args.rect) player.setRect(args.rect.x, args.rect.y, args.rect.width, args.rect.height);
      return Promise.resolve(options.getState());
    }
    var crossSource = !active || active.config.id !== sourceId || JSON.stringify(active.config)!==JSON.stringify(sourceConfig(sourceId));
    return saveProgress(options.getState()).then(function () {
      if (request !== playRevision) throw error('Odtwarzanie anulowano.', 'cancelled');
      return crossSource ? selectSource({ id: sourceId }, true) : undefined;
    }).then(function () {
      if (request !== playRevision) throw error('Odtwarzanie anulowano.', 'cancelled');
      return authorize(args, content);
    }).then(function () {
      if (request !== playRevision) throw error('Odtwarzanie anulowano.', 'cancelled');
      var method = args.programme ? 'resolveArchive' : args.item ? 'resolveMedia' : 'resolve';
      return invoke(method, { channel: args.channel || content, item: args.item, programme: args.programme });
    }).then(function (stream) {
      if (request !== playRevision) throw error('Odtwarzanie anulowano.', 'cancelled');
      if (requiresHttpsProvider && stream && typeof stream.url === 'string' && /^http:/i.test(stream.url)) {
        throw error(hostedHttpMessage, 'hosted_http_blocked');
      }
      return (args.resumeMode === 'resume' ? resume(content, sourceId) : Promise.resolve({ position: 0, allowed: false })).then(function (position) {
        if (request !== playRevision) throw error('Odtwarzanie anulowano.', 'cancelled');
        if (args.resumeMode === 'resume' && !position.allowed) throw error('Wznowienie wymaga funkcji wspierającego. Możesz odtworzyć od początku.', 'supporter_required');
        playing = { key: key, sourceId: sourceId, item: args.item || null, channel: args.channel || null };
        var preferences=copy(playbackPreferences(sourceId,content)),sourceSettings=active.config.settings || {};
        var buffer=preferences.bufferPreset || sourceSettings.bufferPreset,bufferCapabilities=player.getCapabilities ? player.getCapabilities() : {};
        if (!preferences.aspect) preferences.aspect={Fit:'fit',Fill:'fill',Stretch:'fill','16:9':'auto','4:3':'auto'}[sourceSettings.aspectMode] || 'fit';
        var playbackContext = !args.programme && args.item && active.config.kind === 'xtream' &&
          (content.kind === 'movie' || content.kind === 'episode') && stream.isLive === false
          ? {headerPolicy:'xtream-vod-default'} : null;
        return options.openStream(stream, args.rect, {bufferPreset:buffer==='stable' && (bufferCapabilities.bufferPresets || ['default']).indexOf('stable')>=0?'stable':'default',quality:'auto'}, function () { return request === playRevision; }, playbackContext).then(function () {
          if (request !== playRevision) throw error('Odtwarzanie anulowano.', 'cancelled');
          return restorePlaybackPreferences(preferences).then(function () {if (args.resumeMode === 'resume' && position.position > 0 && !stream.isLive) return player.seek(position.position);});
        }).then(function () {
          if (request !== playRevision) throw error('Odtwarzanie anulowano.', 'cancelled');
          // Native playback is ready. KeyManager persistence must not delay
          // revealing the player or the preview-to-fullscreen handoff.
          historyWrite = remember(content, sourceId, profileId, owner.source).catch(function (failure) {
            try { if (options.onError) options.onError(failure); } catch (_) {}
          });
        }).then(function () { return options.getState(); });
      });
    });
  }
  function capabilities() {
    var native = player.getCapabilities ? player.getCapabilities() : {};
    var io = transport.capabilities();
    return { profiles: true, favorites: true, guide: true, catchup: true, movies: true, series: true,
      requiresHttpsProvider: requiresHttpsProvider,
      backupExport:!!(backupCodec && backupCodec.available() && options.canExportBackup),backupImport:!!(backupCodec && backupCodec.available() && options.canImportBackup),
      resume: true, pairing: !!(cloud && cloud.configured), tracks: !!native.tracks,
      trailer: typeof options.openTrailer === 'function',
      preview: true, rate: !!(native.playbackSpeeds && native.playbackSpeeds.length), aspect: !!(native.displayModes && native.displayModes.length),
      playbackRates: native.playbackSpeeds || native.playbackRates || native.speeds || [],
      aspectModes: [{ id: 'fit', label: 'Dopasuj' }, { id: 'fill', label: 'Pełny ekran' }, { id: 'auto', label: 'Automatycznie' }],
      sourceKinds: io.cookies ? ['m3u', 'xtream', 'stalker'] : ['m3u', 'xtream'],
      sourceFields: { m3u: io.userAgent ? ['playlistUrl', 'epgUrl', 'userAgent'] : ['playlistUrl', 'epgUrl'],
        xtream: ['host', 'username', 'password'], stalker: ['portal', 'mac'] } };
  }
  function cacheCloudPins(rows) {
    var locks = {};
    rows.forEach(function (profile) {
      if (profile.pin) locks[profile.id] = { pin: profile.pin, name: profile.name || '' };
      if (profile.pin && cloudUnlocked[profile.id] !== profile.pin) delete cloudUnlocked[profile.id];
      if (!profile.pin) delete cloudUnlocked[profile.id];
    });
    return mutate(function (state) { state[K.cloudPins] = JSON.stringify(locks); });
  }
  function refreshCloudProfiles() {
    return cloud.query('profiles.list', {}).then(function (rows) {
      cloudProfiles = rows; cloudListingAvailable = true;
      var state = storage.read(), activeId = state[K.cloudId];
      cloudActiveId = activeId && rows.some(function (row) { return row.id === activeId; }) ? activeId : null;
      return cacheCloudPins(rows).then(function () { return rows; });
    });
  }
  function bootstrap(reuseCloud) {
    reuseCloud = reuseCloud === true && cloudListingAvailable && !!cloudBootstrapStatus && cloudBootstrapStatus.paired === true;
    var state = storage.read(), rows = profiles(state);
    if (!rows.length && state[K.migrated] !== 'true') {
      var old = options.sourceStore.read();
      return mutate(function (next) {
        if (old.length) {
          var profile = { id: core.newSourceId(), name: 'Default', colorIndex: 0,
            snapshot: { sources: old, managedIds: [] } };
          setProfiles(next, [profile]); next[K.active] = profile.id;
        }
        next[K.migrated] = 'true';
      }).then(bootstrap);
    }
    var cloudStatus = cloudBootstrapStatus;
    return Promise.resolve(reuseCloud ? null : cloud ? cloud.status() : { configured: false }).then(function (status) {
      if (reuseCloud) return;
      cloudStatus = status;
      cloudBootstrapStatus = status;
      if (cloudStatus && !cloudStatus.error && cloudStatus.paired) {
        return refreshCloudProfiles().then(function (listed) {
          var id = cloudStatus.profileId;
          cloudActiveId = id && listed.some(function (row) { return row.id === id; }) ? id : null;
          if (cloudActiveId) return mutate(function (next) { next[K.cloudId] = cloudActiveId; });
        }).catch(function () { cloudListingAvailable = false; cloudProfiles = []; cloudActiveId = null; });
      }
      if (cloudStatus && !cloudStatus.error) {
        cloudListingAvailable = true; cloudProfiles = []; cloudActiveId = null;
      } else {
        cloudListingAvailable = false; cloudProfiles = []; cloudActiveId = null;
      }
    }).then(function () {
      state = storage.read(); rows = profiles(state);
      var id = cloudListingAvailable ? cloudActiveId : state[K.cloudId];
      if (state[K.ownerless] === '1' && state[K.active]) {
        return mutate(function (next) { delete next[K.ownerless]; }).then(bootstrap);
      }
      var ownerless = state[K.ownerless] === '1' || (rows.length > 0 && !state[K.active] && !id);
      var p = current(state, rows), locked = p && p.pin &&
        (p.source === 'cloud' ? cloudUnlocked[p.id] !== p.pin : unlockedProfile !== p.id);
      if (!Object.prototype.hasOwnProperty.call(state, K.pickerStartup) || !validPickerStartup(state[K.pickerStartup])) {
        return migratePickerStartup().then(bootstrap);
      }
      var language = languageState();
      var all = [];
      if (cloudListingAvailable) cloudProfiles.forEach(function (profile) {
        all.push(viewProfile({ id: profile.id, name: profile.name, colorIndex: colorIndex(profile.id), pin: profile.pin, source: 'cloud' }));
      });
      else {
        var fallback = id && cloudProfile(state, id);
        if (fallback) all.push(viewProfile(fallback));
      }
      rows.forEach(function (profile) { profile.source = 'local'; all.push(viewProfile(profile)); });
      var startupSettings = effectiveSettings(state, p, !!(p && !locked));
      var sources = p && !locked ? p.snapshot.sources || [] : [];
      var activeSource = sources.filter(function (source) { return source.id === p.snapshot.activeSourceId; })[0] || sources[0];
      if (p && !locked && p.source==='cloud' && autoEnabled() && autoStarted!==bucketId(p)) {
        autoStarted=bucketId(p);autoLastPull=0;scheduleAutoPull();
      } else if (!p || locked || p.source!=='cloud') {autoStarted=null;autoLastPull=0;}
      return { profiles: all, profile: viewProfile(p),
        activeProfileId: p ? p.id : null, activeProfileSource: p ? p.source : null,
        ownerless: ownerless,
        showProfilePicker: core.showProfilePicker(startupSettings.profilePickerStartup, all.length,
          !!(p && p.pin), !ownerless),
        languages: language.languages, languageCode: language.languageCode,
        languageSelected: language.languageSelected,
        sources: sources,
        settings: startupSettings,
        favorites: p && !locked ? profileBucket(K.favorites, []) : [],
        history: p && !locked ? profileBucket(K.history, []) : [],
        activeSourceId: activeSource ? activeSource.id : null,
        capabilities: capabilities(), cloud: cloudStatus || { configured: false } };
    });
  }
  function authorizeCloudProfile(profileId, pin) {
    if (!profileId) return Promise.reject(error('Wybierz profil z panelu.', 'cloud_profile_required'));
    var profile = cloudRow(profileId), cached = cloudPinCache()[profileId];
    if (!profile && cloudListingAvailable) return Promise.reject(error('Wybierz profil z panelu.', 'cloud_profile_required'));
    if (!profile && !cloudListingAvailable && cached && cached.pin) {
      profile = { id: profileId, name: cached.name || 'Cloud profile', pin: cached.pin };
    }
    var ready = profile ? Promise.resolve(profile) : cloud.query('profiles.list', {}).then(function (rows) {
      cloudProfiles = rows; cloudListingAvailable = true;
      return cacheCloudPins(rows).then(function () {
        return rows.filter(function (row) { return row.id === profileId; })[0] || null;
      });
    });
    return ready.then(function (selected) {
      if (!selected) throw error('Wybierz profil z panelu.', 'cloud_profile_required');
      if (!selected.pin) { delete cloudUnlocked[selected.id]; return selected; }
      if (cloudUnlocked[selected.id] === selected.pin) return selected;
      if (!pin) throw error('Podaj PIN profilu z panelu.', 'pin_required');
      return verify(pin, selected.pin).then(function (ok) {
        if (!ok) throw error('Nieprawidłowy PIN.', 'pin_invalid');
        cloudUnlocked[selected.id] = selected.pin;
        return selected;
      });
    });
  }
  function pairingBeforeProfile(action, args) {
    if (!cloud) return Promise.reject(error('Chmura wymaga konfiguracji wydawcy.', 'configuration_required'));
    if (action === 'pairing.get') return cloud.query('status', {});
    if (action === 'pairing.start') {
      var request = Object.assign({}, args);
      request.language = request.language || languageState().languageCode;
      return cloud.query('pairing.start', request);
    }
    if (action === 'pairing.status') return cloud.query('pairing.status', args);
    if (action === 'pairing.profiles') return cloud.query('status', {}).then(function (status) {
      if (status.error) throw error('Nie można sprawdzić połączenia z panelem.', 'cloud_unavailable');
      if (!status.paired) { var unpaired = error('Najpierw połącz telewizor z panelem.', 'cloud_profile_required'); unpaired.name = 'CloudStateError'; throw unpaired; }
      return refreshCloudProfiles();
    }).then(function (rows) {
      return rows.map(function (profile) { return { id: profile.id, name: profile.name, pinSet: !!profile.pin }; });
    });
    if (action === 'pairing.pull') return selectCloudProfile({ profileId: args.profileId || storage.get(K.cloudId), pin: args.pin }, false, true);
    if (action === 'pairing.selectProfile') {
      return selectCloudProfile({ profileId: args.profileId, pin: args.pin }, false);
    }
    var wasCloud = current(), wasCloudActive = wasCloud && wasCloud.source === 'cloud';
    return cloud.query('unpair', {}).then(function (value) {
      cloudUnlocked = {}; cloudListingAvailable = true; cloudProfiles = []; cloudActiveId = null; cloudBootstrapStatus = null;
      return mutate(function (state) {
        delete state[K.cloudPins];
        if (wasCloudActive) state[K.ownerless] = '1';
      }).then(function () { return value; });
    });
  }
  function mergeCloudFavorites(existing, incoming, managedIds) {
    var rows = favoriteRows(existing || [], []), managed = {};
    managedIds.forEach(function (id) { managed[id] = true; });
    rows = rows.filter(function (row) { return !managed[row.sourceId]; });
    return rows.concat(favoriteRows(incoming || [], []).filter(function (row) { return !!managed[row.sourceId]; }));
  }
  function mergeCloudPositions(existing, incoming, managedIds) {
    var rows = copy(existing || {}), managed = {};
    managedIds.forEach(function (id) { managed[id] = true; });
    (incoming || []).forEach(function (row) {
      if (!managed[row.source_id]) return;
      var key = dataKey(row.source_id, { kind: row.kind, id: row.item_id }), local = rows[key];
      if (local && (Date.parse(local.updatedAt) > row.updated_at ||
          (Date.parse(local.updatedAt) === row.updated_at && (!row.removed || local.removed)))) return;
      rows[key] = { sourceId: row.source_id,
        item: local && local.item || { kind: row.kind, id: row.item_id, title: row.item_id, extra: {} },
        position: row.removed ? 0 : row.position_ms / 1000,
        duration: row.duration_ms / 1000,
        updatedAt: new Date(row.updated_at).toISOString(), removed: row.removed === true };
    });
    return rows;
  }
  function selectCloudProfile(args, onboarding, forcePull) {
    if (!cloud) return Promise.reject(error('Chmura wymaga konfiguracji wydawcy.', 'configuration_required'));
    if (!args.profileId) return Promise.reject(error('Wybierz profil z panelu.', 'cloud_profile_required'));
    var progress = beginLoading('profile-prepare');
    var expectedRevision = revision, selected, outgoing, target, previousCloudId, previousSourceIds, previousActiveId;
    var previousOwnerless, shortcutResult, cloudBucket;
    var operationStarted = false, selectionAttempted = false, committed = false;
    return bootstrap(true).then(function () {
      check(expectedRevision); previousCloudId = storage.get(K.cloudId); previousSourceIds = storage.get(K.cloudSources);
      previousActiveId = storage.get(K.active); previousOwnerless = storage.get(K.ownerless);
      operationStarted = true;
      return authorizeCloudProfile(args.profileId, args.pin);
    }).then(function (profile) {
      check(expectedRevision);
      selected = profile;
      cloudBucket = 'cloud:' + selected.id;
      var existing = current(), activeIsTarget = existing && existing.source === 'cloud' && existing.id === selected.id;
      outgoing = existing;
      target = cloudSnapshot(storage.read(), selected.id);
      if (!Array.isArray(target.sources)) target.sources = [];
      var hasCachedSources = target.sources.length && target.sources.every(function (source) {
        return source && source.fields && !options.validation.validateSource(source.kind, source.label, source.fields);
      });
      if (!onboarding && !forcePull && hasCachedSources) {
        var activate = activeIsTarget ? Promise.resolve() : release().then(function () {
          if (revision !== expectedRevision + 1) throw error('Wczytywanie anulowano.', 'cancelled');
          selectionAttempted = true;
          return cloud.query('profiles.select', { profileId: selected.id });
        }).then(function () {
          progress('profile-save');
          return storage.update(function (state) {
            if (revision !== expectedRevision + 1) throw error('Wczytywanie anulowano.', 'cancelled');
            if (outgoing) saveCurrentSnapshotInState(state);
            state[K.cloudId] = selected.id; state[K.cloudSources] = (target.managedIds || []).join(',');
            delete state[K.active]; delete state[K.ownerless];
          });
        }).then(function () { committed = true; cloudActiveId = selected.id;parentalUnlocked=null; });
        return activate.then(function () {
          if (cloudBootstrapStatus) cloudBootstrapStatus.profileId = selected.id;
          return bootstrap(true);
        }).then(function (result) { shortcutResult = result; return null; });
      }
      return release().then(function () {
        if (revision !== expectedRevision + 1) throw error('Wczytywanie anulowano.', 'cancelled');
      }).then(function () {
        var sync = objectValue(K.playbackSync, {}, storage.read())[cloudBucket] || null;
        progress('profile-download');
        return cloud.query('pull', { profileId: selected.id, localSources: target.sources, localMetadata: target.metadata || {}, playbackSync: sync, deferProfileSelection: true });
      });
    }).then(function (snapshot) {
      if (shortcutResult) return shortcutResult;
      if (!snapshot || !snapshot.profile || snapshot.profile.id !== selected.id || !Array.isArray(snapshot.sources)) {
        throw error('Wybrany profil z chmury jest niedostępny.', 'cloud_profile_required');
      }
      var remote = snapshot.sources;
      var sourceIds = {}, remoteIds = [];
      remote.forEach(function (source) {
        if (!source || typeof source.id !== 'string' || sourceIds[source.id] || !source.fields || typeof source.fields !== 'object' ||
            options.validation.validateSource(source.kind, source.label, source.fields)) {
          throw error('Profil z chmury zawiera nieprawidłowe źródło.', 'cloud_no_usable_sources');
        }
        sourceIds[source.id] = true; remoteIds.push(source.id);
      });
      if (onboarding && !remote.length) throw error('Profil z chmury nie zawiera użytecznego źródła.', 'cloud_no_usable_sources');
      var priorManaged = Array.isArray(target.managedIds) ? target.managedIds : [], managed = remoteIds;
      var extras = (target.sources || []).filter(function (source) { return !source || priorManaged.indexOf(source.id) < 0; });
      extras.forEach(function (source) {
        if (!source || typeof source.id !== 'string' || !source.fields || typeof source.fields !== 'object' ||
            options.validation.validateSource(source.kind, source.label, source.fields)) {
          throw error('Profil urządzenia zawiera nieprawidłowe źródło.', 'profile_snapshot_invalid');
        }
      });
      if (extras.some(function (source) { return remoteIds.indexOf(source.id) >= 0; })) {
        throw error('Profil z chmury ma identyfikator kolidujący z lokalnym źródłem.', 'cloud_source_id_collision');
      }
      var mergedSources = remote.concat(extras);
      if (revision !== expectedRevision + 1) throw error('Wczytywanie anulowano.', 'cancelled');
      selectionAttempted = true;
      return cloud.query('profiles.select', { profileId: selected.id }).then(function () { progress('profile-save'); return storage.update(function (state) {
        if (revision !== expectedRevision + 1) throw error('Wczytywanie anulowano.', 'cancelled');
        if (outgoing) saveCurrentSnapshotInState(state);
        var activeSource = target.activeSourceId;
        if (!mergedSources.some(function (source) { return source.id === activeSource; })) activeSource = mergedSources.length ? mergedSources[0].id : null;
        var stored = { sources: mergedSources, activeSourceId: activeSource, managedIds: managed };
        var metadata = snapshot.metadata || target.metadata;
        if (metadata) stored.metadata = metadata;
        saveCloudSnapshotInState(state, selected.id, stored);
        state[K.cloudId] = selected.id; state[K.cloudSources] = managed.join(','); delete state[K.active]; delete state[K.ownerless];
        var favorites = objectValue(K.favorites, {}, state);
        favorites[cloudBucket] = mergeCloudFavorites(favorites[cloudBucket], snapshot.favorites || [], managed);
        state[K.favorites] = JSON.stringify(favorites);
        if (snapshot.playbackPositionsAvailable && Array.isArray(snapshot.playbackPositions)) {
          var positions = objectValue(K.positions, {}, state);
          positions[cloudBucket] = mergeCloudPositions(positions[cloudBucket], snapshot.playbackPositions, managed);
          state[K.positions] = JSON.stringify(positions);
          var cursors = objectValue(K.playbackSync, {}, state);
          var sameSources = priorManaged.length === managed.length && priorManaged.every(function (id) { return managed.indexOf(id) >= 0; });
          cursors[cloudBucket] = sameSources ? snapshot.playbackSync || null : null;
          state[K.playbackSync] = JSON.stringify(cursors);
        }
      }); }).then(function () {
        committed = true;
        cloudActiveId = selected.id;
        if (!outgoing || outgoing.source!=='cloud' || outgoing.id!==selected.id) parentalUnlocked=null;
        if (cloudBootstrapStatus) cloudBootstrapStatus.profileId = selected.id;
        return bootstrap(true).then(function (result) { if (onboarding) result.onboardingReady = true; return result; });
      });
    }).catch(function (failure) {
      if (!operationStarted || !selectionAttempted || committed) throw failure;
      cloudActiveId = previousCloudId || null;
      return storage.update(function (state) {
        if (previousCloudId) state[K.cloudId] = previousCloudId; else delete state[K.cloudId];
        if (previousSourceIds) state[K.cloudSources] = previousSourceIds; else delete state[K.cloudSources];
        if (previousOwnerless === '1') state[K.ownerless] = '1';
        else if (!previousCloudId && !previousActiveId) state[K.ownerless] = '1';
        else delete state[K.ownerless];
      }).then(function () {
        if (previousCloudId && cloud) return cloud.query('profiles.select', { profileId: previousCloudId }).catch(function () {});
      }).then(function () { throw failure; });
    }).then(function (result) { progress(null); return result; }, function (failure) { progress(null); throw failure; });
  }
  function addDemoSource(args) {
    var owner = allowedProfile(), profileId = owner.id;
    var demo = { id: 'demo', kind: 'demo', label: 'Demo', fields: {}, settings: {} };
    var invalid = options.validation.validateSource(demo.kind, demo.label, demo.fields);
    if (invalid) return Promise.reject(error('Nie można przygotować źródła Demo.'));
    return authorize(args).then(function () { return release(); }).then(function () {
      return mutateProfile(profileId, function (state) {
        var rows = profiles(state), profile = current(state, rows), sources = profile.snapshot.sources || [];
        if (sources.length && !(sources.length === 1 && sources[0].id === demo.id && sources[0].kind === demo.kind)) {
          throw error('Wybierz pusty profil, aby użyć źródła Demo.', 'profile_not_empty');
        }
        profile.snapshot.sources = sources.length ? sources : [demo];
        profile.snapshot.activeSourceId = demo.id;
        profile.snapshot.managedIds = [];
        setProfiles(state, rows);
      }, owner.source);
    }).then(function () { return bootstrap(); });
  }
  function query(action, args) {
    args = args || {};
    if (action === 'language.get') return Promise.resolve(languageState());
    if (action === 'language.set') {
      var code = args.code || args.languageCode;
      if (typeof code !== 'string' || !languageOptions().some(function (row) { return row.code === code; })) {
        return Promise.reject(error('Wybierz obsługiwany język.', 'language_unsupported'));
      }
      return storage.set('app_language', code).then(languageState);
    }
    if (action === 'pairing.download') return selectCloudProfile(args, true);
    if (action === 'pairing.get' || action === 'pairing.start' || action === 'pairing.status' ||
        action === 'pairing.profiles' || action === 'pairing.selectProfile' || action === 'pairing.pull' || action === 'pairing.unpair') {
      return pairingBeforeProfile(action, args);
    }
    if (action === 'bootstrap') return bootstrap();
    if (action === 'backup.export' || action === 'backup.inspect' || action === 'backup.import') {
      if (!backupCodec || !backupCodec.available()) return Promise.reject(error('Szyfrowane kopie zapasowe są niedostępne na tym telewizorze.','backup_unavailable'));
      return (current() ? authorize(args) : parentalProof(args,parental())).then(function () {
        if (action==='backup.export') return saveProgress(options.getState()).then(function () {return historyWrite;}).then(function () {return backupCodec.exportState(storage.read(),String(args.password || ''));}).then(function (bytes) {return {bytes:bytes,filename:'TVBro-'+new Date(now()).toISOString().slice(0,10)+'.tvbro'};});
        if (action==='backup.inspect') return backupCodec.read(args.bytes,String(args.password || '')).then(function (value) {backupInspection={token:core.newSourceId(),state:value.state,summary:value.summary};return {token:backupInspection.token,summary:value.summary};});
        if (!backupInspection || args.token!==backupInspection.token) throw error('Najpierw sprawdź plik kopii zapasowej.','backup_required');
        var inspected=backupInspection,imported=profiles(inspected.state),added=[];
        return mutate(function (state) {
          var existing=profiles(state),importedParental=decode(K.parental,null,inspected.state),recovery=objectValue(K.recovery,{},state);
          imported.forEach(function (profile) {
            var oldId=profile.id,newId=core.newSourceId(),next=copy(profile);
            next.id=newId;next.name=String(next.name || 'Recovery')+' (Recovery)';
            next.snapshot=next.snapshot || {sources:[],managedIds:[]};next.snapshot.managedIds=[];
            recovery[newId]={settings:{}};
            if (importedParental) recovery[newId].parentalRules=copy(importedParental);
            [K.pickerStartup,'app_language','samsung_backup_dvr_v1','samsung_backup_preferences_v1'].forEach(function (key) {if (inspected.state[key]!=null) recovery[newId].settings[key]=inspected.state[key];});
            existing.push(next);added.push(viewProfile(next));
            [K.favorites,K.positions,K.history,K.mappings,K.preferences].forEach(function (key) {
              var source=objectValue(key,{},inspected.state),target=objectValue(key,{},state);
              if (Object.prototype.hasOwnProperty.call(source,oldId)) {target[newId]=copy(source[oldId]);state[key]=JSON.stringify(target);}
            });
          });state[K.recovery]=JSON.stringify(recovery);setProfiles(state,existing);
        }).then(function () {backupInspection=null;libraryRevision++;if (options.onProgress) options.onProgress();return {importedProfiles:added,summary:inspected.summary};});
      });
    }
    if (action === 'cache.flush') return flushCatalog();
    if (action === 'pairing.autoSync') return enqueueAuto(function () {return autoPull().then(autoPush).then(autoPushPlayback);});
    if (action === 'pairing.flush') return enqueueAuto(function () {return autoPush().then(autoPushPlayback);});
    if (action === 'sources.cancel') return release();
    if (action === 'profiles.list') return bootstrap().then(function (value) { return { profiles: value.profiles, profile: value.profile }; });
    if (action === 'profiles.create') {
      var name = String(args.name || '').trim();
      if (!name) return Promise.reject(error('Podaj nazwę profilu.'));
      return (args.pin ? hashPin(String(args.pin)) : Promise.resolve(null)).then(function (pin) {
        var profile = { id: core.newSourceId(), name: name, colorIndex: profiles().length % 6, snapshot: { sources: [], managedIds: [] } };
        if (pin) profile.pin = pin;
        return release().then(function () { return mutate(function (state) {
          saveCurrentSnapshotInState(state);
          var all = profiles(state); all.push(profile); setProfiles(state, all); state[K.active] = profile.id;
          state[K.cloudSources] = ''; delete state[K.ownerless];
        }); }).then(function () { unlockedProfile = profile.id;parentalUnlocked=null;return bootstrap(); });
      });
    }
    if (action === 'profiles.select') {
      var localTarget = profiles().filter(function (p) { return p.id === args.id; })[0];
      var remoteTarget = cloudRow(args.id);
      var source = args.source;
      if (!source && localTarget && remoteTarget) return Promise.reject(error('Wybierz lokalny lub chmurowy profil.', 'ambiguous_profile'));
      if (!source) source = localTarget ? 'local' : remoteTarget ? 'cloud' : null;
      if (source === 'cloud') return selectCloudProfile({ profileId: args.id, pin: args.pin }, false);
      if (source !== 'local') return Promise.reject(error('Nie znaleziono profilu.', 'profile_required'));
      var target = localTarget;
      if (!target) return Promise.reject(error('Nie znaleziono profilu.'));
      var gate = target.pin && unlockedProfile !== target.id ? verify(args.pin, target.pin) : Promise.resolve(true);
      if (target.pin && !args.pin && unlockedProfile !== target.id) return Promise.reject(error('Podaj PIN profilu.', 'pin_required'));
      return gate.then(function (ok) {
        if (!ok) throw error('Nieprawidłowy PIN.', 'pin_invalid');
        return release();
      }).then(function () { return mutate(function (state) {
        saveCurrentSnapshotInState(state); state[K.active] = target.id;
        state[K.cloudSources] = ''; delete state[K.ownerless];
      }); }).then(function () { unlockedProfile = target.id;parentalUnlocked=null;return bootstrap(true); });
    }
    if (action === 'profiles.pin' && args.source === 'cloud') {
      if (!cloud) return Promise.reject(error('Chmura wymaga konfiguracji wydawcy.', 'configuration_required'));
      var cloudLock = cloudRow(args.id) || (cloudPinCache()[args.id] ? { id: args.id, name: cloudPinCache()[args.id].name, pin: cloudPinCache()[args.id].pin } : null);
      if (!cloudLock) return Promise.reject(error('Nie znaleziono profilu w chmurze.', 'cloud_profile_required'));
      var pinProof = cloudLock.pin ? verify(args.currentPin || args.pin, cloudLock.pin) : Promise.resolve(true);
      if (cloudLock.pin && !args.currentPin && !args.pin) return Promise.reject(error('Podaj PIN profilu.', 'pin_required'));
      return pinProof.then(function (ok) {
        if (!ok) throw error('Nieprawidłowy PIN.', 'pin_invalid');
        return args.pin ? hashPin(String(args.pin)) : null;
      }).then(function (verifier) {
        return cloud.query('profiles.setPin', { profileId: args.id, pin: verifier }).then(function () {
          delete cloudUnlocked[args.id];
          cloudProfiles = cloudProfiles.map(function (profile) {
            if (profile.id !== args.id) return profile;
            return Object.assign({}, profile, { pin: verifier });
          });
          return mutate(function (state) {
            var locks = cloudPinCache(state);
            if (verifier) locks[args.id] = { pin: verifier, name: cloudLock.name || '' };
            else delete locks[args.id];
            state[K.cloudPins] = JSON.stringify(locks);
          });
        });
      }).then(bootstrap);
    }
    if (action === 'profiles.rename' || action === 'profiles.delete' || action === 'profiles.pin') {
      if (args.source === 'cloud') return Promise.reject(error('Zmiana nazwy i usuwanie profilu chmurowego odbywa się w panelu.', 'cloud_profile_readonly'));
      var row = profiles().filter(function (p) { return p.id === args.id; })[0];
      if (!row) return Promise.reject(error('Nie znaleziono profilu.'));
      var proof = row.pin ? verify(args.currentPin || args.pin, row.pin) : Promise.resolve(true);
      if (row.pin && !args.currentPin && !args.pin) return Promise.reject(error('Podaj PIN profilu.', 'pin_required'));
      return proof.then(function (ok) {
        if (!ok) throw error('Nieprawidłowy PIN.', 'pin_invalid');
        return action === 'profiles.pin' && args.pin ? hashPin(String(args.pin)) : null;
      }).then(function (pin) {
        return (action === 'profiles.delete' ? release() : Promise.resolve()).then(function () { return mutate(function (state) {
          var all = profiles(state), target = all.filter(function (p) { return p.id === args.id; })[0];
          if (action === 'profiles.delete') {
            all = all.filter(function (p) { return p.id !== args.id; });
            if (state[K.active] === args.id) { delete state[K.active]; state[K.ownerless] = '1'; state[K.cloudSources] = ''; }
            [K.favorites, K.positions, K.history, K.settings,K.mappings,K.preferences,K.outbox,K.recovery].forEach(function (key) { var map = decode(key, {}, state); delete map[args.id]; state[key] = JSON.stringify(map); });
          } else if (action === 'profiles.pin') target.pin = pin;
          else { if (!String(args.name || '').trim()) throw error('Podaj nazwę.'); target.name = String(args.name).trim(); }
          setProfiles(state, all);
        }); });
      }).then(bootstrap);
    }
    var owner = allowedProfile(), profileId = owner.id, profileSource = owner.source;
    if (action === 'sources.demo') return addDemoSource(args);
    if (action === 'parental.get') {
      var rules = parental();
      return Promise.resolve({ enabled: !!rules.verifier, unlocked:!!rules.verifier && parentalUnlocked===rules.verifier, lockSettings: rules.lockSettings, channels: rules.channels, categories: rules.categories });
    }
    if (action === 'parental.unlock') {var unlockRules=parental();return parentalProof(args,unlockRules).then(function () {parentalUnlocked=unlockRules.verifier;libraryRevision++;if (options.onProgress) options.onProgress();return query('parental.get');});}
    if (action === 'parental.lock') {parentalUnlocked=null;libraryRevision++;if (options.onProgress) options.onProgress();return query('parental.get');}
    if (action === 'parental.setPin' || action === 'parental.toggle') {
      var previousRules = parental();
      return parentalProof(args, previousRules).then(function () {
        if (action === 'parental.setPin') return args.newPin ? hashPin(String(args.newPin)) : null;
        if (!previousRules.verifier) throw error('Najpierw ustaw PIN kontroli rodzicielskiej.');
        return previousRules.verifier;
      }).then(function (verifier) {
        return mutateProfile(profileId, function (state) {
          // A concurrent policy change cannot be overwritten using old proof.
          if (JSON.stringify(parental()) !== JSON.stringify(previousRules)) throw error('Kontrola rodzicielska została zmieniona. Spróbuj ponownie.', 'cancelled');
          var next = copy(previousRules); next.verifier = verifier;
          if (action === 'parental.setPin') {
            if (typeof args.lockSettings === 'boolean') next.lockSettings = args.lockSettings;
          } else {
            if (args.type !== 'channel' && args.type !== 'category') throw error('Wybierz kanał lub kategorię.');
            var key = parsed(core.parentalRules(args.type === 'channel' ? 'channelKey' : 'categoryKey', JSON.stringify({ sourceId: args.sourceId || (active && active.config.id), kind: args.kind || 'live', id: args.id })));
            var list = args.type === 'channel' ? next.channels : next.categories, index = list.indexOf(key);
            if (index < 0) list.push(key); else list.splice(index, 1);
          }
          var validatedRules=core.parentalRules('validate', JSON.stringify({ rules: next }));
          var recovery=objectValue(K.recovery,{},state),ruleProfile=current(state);
          if (recovery[ruleProfile.id] && recovery[ruleProfile.id].parentalRules) {recovery[ruleProfile.id].parentalRules=parsed(validatedRules);state[K.recovery]=JSON.stringify(recovery);}
          else state[K.parental] = validatedRules;
        }, profileSource);
      }).then(function () {libraryRevision++;if (options.onProgress) options.onProgress();return query('parental.get'); });
    }
    if (action === 'sources.list') return Promise.resolve(configList());
    if (action === 'sources.load') return selectSource(args);
    if (action === 'sources.catalog') return Promise.resolve(active && configList().some(function (source) {return source.id===active.config.id;}) ? catalogView(active) : null);
    if (action === 'organization.get') return authorize(args).then(function () {return organizationGet(args);});
    if (action === 'organization.set') {
      var organizationConfig=sourceConfig(args.sourceId),organizationSettings={},kind=args.kind || 'live';
      if (args.organization) organizationSettings.channelOrganization=organization.normalize(args.organization);
      if (Array.isArray(args.hiddenCategoryIds)) {var hidden=copy(organizationConfig.settings && organizationConfig.settings.hiddenCategories || {});hidden[kind]=organization.strings(args.hiddenCategoryIds);organizationSettings.hiddenCategories=hidden;}
      return saveSourceSettings(args,organizationSettings).then(function () {return organizationGet(args);});
    }
    if (action === 'sourceSettings.get') return authorize(args).then(function () {return sourceSettingsGet(args);});
    if (action === 'sourceSettings.set') {var validatedSettings=validateSourceSettings(args);return saveSourceSettings(args,validatedSettings.settings,validatedSettings.fields).then(function () {return sourceSettingsGet(args);});}
    if (action === 'guide.mapping.get') return authorize(args).then(function () {return mappingGet(args);});
    if (action === 'guide.mapping.set') return mappingSet(args);
    if (action === 'guide.search') {
      var searchConfig=sourceConfig(args.sourceId),searchQuery=String(args.query || '').trim().toLowerCase().slice(0,120),searchLimit=Math.min(80,Math.max(1,Number(args.limit)||40)),searchRows=[],searchChannels=Object.create(null);
      if (active && active.config.id===searchConfig.id) visibleChannels(searchConfig,active.channels).forEach(function (channel) {searchChannels[channel.id]=channel;});
      if (searchQuery && guideCache && guideCache.revision===revision) guideCache.programmes.some(function (programme) {
        if (searchChannels[programme.channelId] && (String(programme.title || '')+' '+String(programme.description || '')).toLowerCase().indexOf(searchQuery)>=0) searchRows.push({programme:programme,channel:searchChannels[programme.channelId]});
        return searchRows.length>=searchLimit;
      });
      return Promise.resolve({programmes:searchRows,loadedOnly:true});
    }
    if (action === 'sources.add' || action === 'sources.update' || action === 'sources.remove') {
      var removedConfigId = args.id || args.config && args.config.id;
      var removedConfig = configList().filter(function (source) { return source.id === removedConfigId; })[0];
      var replacementConfig = null, preserveSourceCache = false;
      return authorize(args).then(function () { return release(); }).then(function () {
        if (action === 'sources.remove') return;
        var list = configList(), incoming = copy(args.config || {}), index = list.map(function (source) { return source.id; }).indexOf(incoming.id);
        var previous = index >= 0 ? list[index] : {};
        incoming.fields = Object.assign({}, previous.fields || {}, incoming.fields || {});
        incoming.settings = Object.assign({}, previous.settings || {}, incoming.settings || {});
        var invalid = options.validation.validateSource(incoming.kind, incoming.label, incoming.fields);
        if (invalid) throw error(invalid);
        incoming.id = incoming.id || core.newSourceId(); incoming.label = incoming.label || '';
        replacementConfig = incoming;
        if (removedConfig) return migrateLegacySourceCache(removedConfig, replacementConfig, bucketId(owner)).then(function (preserved) {
          preserveSourceCache = preserved === true;
        });
      }).then(function () { return mutateProfile(profileId, function (state) {
        var all = profiles(state), p = current(state, all), list = p.snapshot.sources;
        if (action === 'sources.remove') list = list.filter(function (s) { return s.id !== args.id; });
        else {
          var config = replacementConfig, index = list.map(function (s) { return s.id; }).indexOf(config.id);
          var previous = index >= 0 ? list[index] : {};
          if (index < 0) list.push(config); else list[index] = config;
          queueSettingsInState(state,owner,previous,config);
        }
        if (owner.source==='cloud') {var pending=pendingOutbox(state);pending.drafts=pending.drafts || {};pending.drafts[removedConfigId || replacementConfig.id]=action==='sources.remove'?'remove':'edit';writeBucket(state,K.outbox,pending);}
        p.snapshot.sources = list; setProfiles(state, all);
      }, profileSource); }).then(function () {
        var sources = configList(), replacement = sources.filter(function (source) { return source.id === removedConfigId; })[0];
        return (removedConfig && JSON.stringify(removedConfig) !== JSON.stringify(replacement) && !preserveSourceCache
          ? removeStoredSource(removedConfig, bucketId(owner)) : Promise.resolve()).then(function () { return sources; });
      });
    }
    if (action === 'catalog.categories' || action==='catalog.items') {
      var browsingSource=active,browsingRevision=revision,browsingConfig=sourceConfig();
      if (action==='catalog.categories') return invoke('mediaCategories',{kind:args.kind},browsingSource).then(function (rows) {check(browsingRevision);return visibleCategories(browsingConfig,rows,args.kind);});
      return args.query ? invoke('searchMedia',args,browsingSource).then(function (items) {check(browsingRevision);return {items:visibleMedia(browsingConfig,items,args.kind),page:1,hasMore:false};}) :
        invoke('mediaItemsPage',args,browsingSource).then(function (page) {check(browsingRevision);page.items=visibleMedia(browsingConfig,page.items,args.kind);return page;});
    }
    if (action === 'media.details') return mediaDetailsWithMetadata(args.item, active);
    if (action === 'media.refresh') {
      var refreshing = active, expectedRefresh = revision, oldCatalog = refreshing && refreshing.catalog, oldAt = refreshing && refreshing.catalogAt;
      if (!refreshing) return Promise.reject(error('Najpierw wybierz źródło.'));
      if (refreshing.detailsRefreshFlight) return refreshing.detailsRefreshFlight;
      if (refreshing.capabilities && refreshing.capabilities.fullCatalogCache === true) {
        refreshing.detailsRefreshFlight = Promise.resolve(setupMetadata(refreshing, expectedRefresh)).then(function () {
          return invoke('metadata.refresh', { item: args.item }, refreshing).catch(function (failure) {
            if (!metadataMethodUnavailable(failure)) throw failure;
            return mediaDetailsWithMetadata(args.item, refreshing);
          });
        }).then(function (item) {
          check(expectedRefresh); refreshing.readCache = null; refreshing.reads = null;
          scheduleCatalogSave(refreshing); scheduleMetadataSave(refreshing); return item;
        });
        var metadataRefreshFlight = refreshing.detailsRefreshFlight;
        function clearMetadataRefresh() { if (refreshing.detailsRefreshFlight === metadataRefreshFlight) refreshing.detailsRefreshFlight = null; }
        metadataRefreshFlight.then(clearMetadataRefresh, clearMetadataRefresh);
        return metadataRefreshFlight;
      }
      clearTimeout(refreshing.cacheRefreshTimer); refreshing.cacheRefreshTimer = null;
      var backup;
      refreshing.detailsRefreshFlight = Promise.resolve(refreshing.cacheRefreshFlight).catch(function () {}).then(flushCatalog).then(function () {
        return refreshing.engine.invoke('exportCatalog', JSON.stringify({ scope: refreshing.cacheScope }));
      }).then(function (raw) {
        check(expectedRefresh); backup = refreshing.engine.restoreCatalog ? raw : parsed(raw);
        oldCatalog = refreshing.catalog; oldAt = refreshing.catalogAt;
        // A bounded export can refuse a large catalogue. Never discard its
        // in-memory seasons/episodes if a failed refresh cannot restore them.
        if (typeof backup !== 'string' || backup === 'null') throw error('Katalog jest zbyt duży, aby bezpiecznie odświeżyć szczegóły.', 'cache_limit');
        refreshing.cacheRefreshing = true;
        return invoke('invalidate', {}, refreshing);
      }).then(function () { check(expectedRefresh); return fetchCatalog(refreshing, expectedRefresh); }).then(function () {
        check(expectedRefresh); return invoke('mediaDetails', { item: args.item }, refreshing);
      }).then(function (item) {
        check(expectedRefresh); refreshing.cacheRefreshing = false; refreshing.cacheRefreshFailed = false;
        scheduleCatalogSave(refreshing); return item;
      }, function (failure) {
        refreshing.cacheRefreshing = false; refreshing.cacheRefreshFailed = true;
        if (active !== refreshing || revision !== expectedRefresh) throw failure;
        refreshing.catalog = oldCatalog; refreshing.catalogAt = oldAt;
        var restored = typeof backup === 'string' ? (refreshing.engine.restoreCatalog
          ? refreshing.engine.restoreCatalog(refreshing.cacheScope, backup)
          : refreshing.engine.invoke('importCatalog', JSON.stringify({ scope: refreshing.cacheScope, snapshot: backup }))) : Promise.resolve();
        return restored.then(function () { refreshing.readCache = null; throw failure; });
      });
      var refreshFlight = refreshing.detailsRefreshFlight;
      function finishRefresh() { refreshing.detailsRefreshFlight = null; if (active === refreshing && revision === expectedRefresh) armCatalogRefresh(refreshing, expectedRefresh); }
      refreshFlight.then(finishRefresh, finishRefresh);
      return refreshFlight;
    }
    if (action === 'media.trailer') {
      if (typeof options.openTrailer !== 'function' || typeof core.mediaTrailer !== 'function') throw error('Could not open the trailer or YouTube.', 'trailer_unavailable');
      return Promise.resolve(options.openTrailer(core.mediaTrailer(JSON.stringify(args.item))));
    }
    if (action === 'media.progress') return mediaProgress(args);
    if (action === 'media.seriesProgress') return seriesProgress(args);
    if (action === 'media.metadataStatus') return metadataStatus();
    if (action === 'media.children') return mediaChildrenWithMetadata(args.item, active).then(function (items) { return { items: items }; });
    if (action === 'media.episodes') { var episodeSource = active; return invoke('playbackEpisodes', {item:args.item}, episodeSource).then(function (value) {
      if (active === episodeSource) scheduleCatalogSave(episodeSource);
      return value;
    }); }
    if (action === 'playback.play' || action === 'playback.preview') return play(args);
    if (action === 'playback.stop') {
      ++playRevision;
      var progress = saveProgress(options.getState()); playing = null;
      return Promise.all([progress, options.stop(), historyWrite]);
    }
    if (action === 'player.rect') { var rect = args.rect; player.setRect(rect.x, rect.y, rect.width, rect.height); return Promise.resolve(); }
    if (action === 'player.tracks') return Promise.resolve(player.getTracks());
    if (action === 'player.selectTrack') {
      var trackPlaying=playing && copy(playing),trackOwner=allowedProfile(),trackRevision=playRevision;
      var selection=args.type==='subtitle' && args.id==='off' ? player.setSubtitlesEnabled(false) : player.selectTrack(args.type==='subtitle'?'TEXT':'AUDIO',Number(args.id));
      return Promise.resolve(selection).then(function () {
        if (!trackPlaying || trackRevision!==playRevision) return;
        var prefs={},tracks=player.getTracks(),rows=Array.isArray(tracks) ? tracks.filter(function (row) {return row.type===(args.type==='subtitle'?'TEXT':'AUDIO');}) : args.type==='subtitle'?tracks.subtitles:tracks.audio;
        if (args.type==='subtitle') prefs.subtitlesEnabled=args.id!=='off';
        var selected=Array.isArray(rows) && rows.filter(function (row) {return String(row.id==null?row.index:row.id)===String(args.id);})[0];
        if (selected) prefs[args.type==='subtitle'?'subtitle':'audio']={language:trackLanguage(selected),label:selected.label || ''};
        return savePlaybackPreferences(trackPlaying.sourceId,trackPlaying.item || trackPlaying.channel,prefs,trackOwner);
      });
    }
    if (action === 'player.rate') return Promise.resolve(player.setSpeed(Number(args.rate)));
    if (action === 'player.aspect') {
      var aspectPlaying=playing && copy(playing),aspectOwner=allowedProfile(),aspectRevision=playRevision;
      if (['fit','fill','auto'].indexOf(args.fit)<0) throw error('Nieprawidłowy format obrazu.','settings_invalid');
      return Promise.resolve(player.setDisplayMode({fit:'PLAYER_DISPLAY_MODE_LETTER_BOX',fill:'PLAYER_DISPLAY_MODE_FULL_SCREEN',auto:'PLAYER_DISPLAY_MODE_AUTO_ASPECT_RATIO'}[args.fit])).then(function () {
        if (aspectPlaying && aspectRevision===playRevision) return savePlaybackPreferences(aspectPlaying.sourceId,aspectPlaying.item || aspectPlaying.channel,{aspect:args.fit},aspectOwner);
      });
    }
    if (action === 'playback.preferences.get') return Promise.resolve(playbackPreferences(args.sourceId || active.config.id,args.item || {id:args.channelId,kind:'live'}));
    if (action === 'playback.preferences.set') return savePlaybackPreferences(args.sourceId || active.config.id,args.item || {id:args.channelId,kind:'live'},args.settings || {});
    if (action === 'resume.get') return resume(args.item, args.sourceId);
    if (action === 'history.list') return historyWrite.then(function () { return { items: profileBucket(K.history, []) }; });
    if (action === 'favorites.list') return favoritesList();
    if (action === 'favorites.toggle') {
      var content = args.item || args.channel, sourceId = args.sourceId || (active && active.config.id), favorite;
      return mutate(function (state) {
        var rows = profileBucket(K.favorites, [], state), key = dataKey(sourceId, content);
        var index = rows.map(function (r) { return dataKey(r.sourceId, r.item || r.channel); }).indexOf(key);
        favorite = index < 0;
        if (favorite) rows.push({ sourceId: sourceId, item: args.item || null, channel: args.channel || null });
        else rows.splice(index, 1);
        writeBucket(state, K.favorites, rows);
        queueFavoriteInState(state,owner,sourceId,content,favorite);
      }).then(function () {scheduleAutoPush();return { favorite: favorite }; });
    }
    if (action === 'guide') {
      return guide(args);
    }
    if (action === 'settings.get') {
      var settingsState = storage.read(), settingsProfile = current(settingsState);
      return Promise.resolve({ settings: effectiveSettings(settingsState, settingsProfile, true), fields: [
      { key: 'profilePickerStartup', label: 'Wybór profilu przy starcie', type: 'select', options: ['auto', 'always', 'off'].map(function (v) { return { value: v, label: v }; }) },
      { key: 'autoCloudSync', label: 'Automatyczna synchronizacja', type:'select', options:[{value:false,label:'Wyłączona'},{value:true,label:'Włączona'}] }
      ] });
    }
    if (action === 'settings.set') {
      var incomingSettings = Object.assign({}, args.settings || {});
      var hasPickerMode = Object.prototype.hasOwnProperty.call(incomingSettings, 'profilePickerStartup');
      var pickerMode = incomingSettings.profilePickerStartup;
      if (hasPickerMode && !validPickerStartup(pickerMode)) {
        return Promise.reject(error('Wybierz prawidłowy tryb wyboru profilu.', 'profile_picker_startup_invalid'));
      }
      delete incomingSettings.profilePickerStartup;
      if (Object.prototype.hasOwnProperty.call(incomingSettings,'autoCloudSync')) {
        if (incomingSettings.autoCloudSync==='true') incomingSettings.autoCloudSync=true;
        if (incomingSettings.autoCloudSync==='false') incomingSettings.autoCloudSync=false;
        if (typeof incomingSettings.autoCloudSync!=='boolean') throw error('Nieprawidłowa synchronizacja.','settings_invalid');
      }
      return authorize(args).then(function () { return mutateProfile(profileId, function (state) {
      if (hasPickerMode) state[K.pickerStartup] = pickerMode;
      var next = Object.assign({}, profileBucket(K.settings, {}, state), incomingSettings);
      delete next.profilePickerStartup;
      if (next.parental) { core.parentalRules('validate', JSON.stringify({ rules: next.parental })); state[K.parental] = JSON.stringify(next.parental); delete next.parental; }
      writeBucket(state, K.settings, next);
      }, profileSource); }).then(function () {
        if (incomingSettings.autoCloudSync===true) {autoLastPull=0;scheduleAutoPull();}
        if (incomingSettings.autoCloudSync===false) {clearTimeout(autoTimer);clearTimeout(autoPullTimer);autoStarted=null;}
        return query('settings.get');
      });
    }
    if (action === 'pairing.push') {
      if (!cloud) return Promise.reject(error('Chmura wymaga konfiguracji wydawcy.', 'configuration_required'));
      var payload = Object.assign({}, args), selectedProfileId = payload.profileId || storage.get(K.cloudId);
      var pendingAtPush=copy(pendingOutbox()),pushOwnerBucket=bucketId(owner);
      payload.profileId = selectedProfileId;
      payload.sources = configList(); payload.metadata = allowedProfile().snapshot.metadata || {};
      payload.favorites = profileBucket(K.favorites, []).map(function (row) {
        var item = row.item || row.channel;
        return { source_id: row.sourceId, kind: item.kind || 'live', item_id: item.id };
      });
      return cloud.query('profiles.list', {}).then(function (rows) {
        var remote = rows.filter(function (row) { return row.id === selectedProfileId; })[0];
        if (!remote) throw error('Wybierz profil w panelu.', 'cloud_profile_required');
        if (remote.pin && cloudUnlocked[remote.id] !== remote.pin) {
          if (!args.pin) throw error('Podaj PIN profilu z panelu.', 'pin_required');
          return verify(args.pin, remote.pin).then(function (ok) {
            if (!ok) throw error('Nieprawidłowy PIN.', 'pin_invalid');
            cloudUnlocked[remote.id] = remote.pin;
          });
        }
      }).then(function () { return supporter(); }).then(function (allowed) {
        if (allowed) {
          var rows = profileBucket(K.positions, {});
          payload.playbackPositions = Object.keys(rows).map(function (key) {
            var row = rows[key];
            return { source_id: row.sourceId, kind: row.item.kind, item_id: row.item.id,
              position_ms: Math.round(row.position * 1000), duration_ms: Math.round(row.duration * 1000),
              updated_at: Date.parse(row.updatedAt), removed: row.removed === true };
          });
        }
        return cloud.query('push', payload);
      }).then(function (result) {
        if (owner.source!=='cloud' || owner.id!==selectedProfileId) return result;
        var sentSources=payload.sources.map(function (source) {return source.id;}),sentPlayback=Object.create(null);
        (payload.playbackPositions || []).forEach(function (row) {sentPlayback[dataKey(row.source_id,{kind:row.kind,id:row.item_id})]=true;});
        return mutate(function (state) {
          var all=objectValue(K.outbox,{},state),pending=all[pushOwnerBucket];
          if (!pending) return;
          ['favorites','settings','playback'].forEach(function (type) {
            Object.keys(pendingAtPush[type] || {}).forEach(function (key) {
              var row=pendingAtPush[type][key];
              if (type==='favorites' && result.favoritesSynced!==true || type==='settings' && sentSources.indexOf(row.sourceId)<0 ||
                  type==='playback' && (result.playbackPositionsSynced!==true || !sentPlayback[key])) return;
              if (pending[type] && pending[type][key] && pending[type][key].version===row.version) delete pending[type][key];
            });
          });
          all[pushOwnerBucket]=pending;state[K.outbox]=JSON.stringify(all);
        }).then(function () {return result;});
      });
    }
    return Promise.reject(error('Nieznana czynność: ' + action));
  }
  return {
    stopPlayback: function () { try { return query('playback.stop', {}); } catch (error) { return Promise.reject(error); } },
    query: function (action, args) { return Promise.resolve().then(function () { return query(action, args || {}); }); },
    getState: function () { var state = options.getState(); state.currentItem = playing && (playing.item || playing.channel); state.loadingStage = loadingStage; state.catalogPreparation=active && active.preparation ? copy(active.preparation) : null; state.libraryRevision=libraryRevision; state.catalogRevision=catalogRevision; state.guideRevision=guideRevision; return state; },
    onState: function (state) {
      if (!state.playing && !state.buffering && playing && playing.item) saveProgress(state).catch(options.onError);
      else if (playing && playing.item && Date.now() - savedAt > 10000) { savedAt = Date.now(); saveProgress(state).catch(options.onError); }
    },
    dispose: function () {disposed=true;clearTimeout(autoTimer);clearTimeout(autoPullTimer);clearTimeout(autoPlaybackTimer);return autoOperations.catch(function () {}).then(release);}
  };
}));
