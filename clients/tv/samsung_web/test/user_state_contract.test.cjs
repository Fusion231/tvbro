'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const createSecureStore = require('../platform/secure_store.js').create;
const createUserState = require('../platform/user_state.js').create;

function createKeyManagerDouble() {
  const data = new Map();
  const saves = [];
  let activeSaves = 0;
  let maxActiveSaves = 0;
  let failure = null;
  const keymanager = {
    getData(identifier) {
      if (!data.has(identifier.name)) throw Object.assign(new Error('not found'), {name:'NotFoundError'});
      return data.get(identifier.name);
    },
    getDataAliasList() {
      return [...data.keys()].map(name => ({name, packageId:'TVBroWebTV'}));
    },
    saveData(name, rawData, password, success, reject) {
      saves.push({name, rawData, password});
      activeSaves += 1;
      maxActiveSaves = Math.max(maxActiveSaves, activeSaves);
      setTimeout(() => {
        activeSaves -= 1;
        if (failure) {
          const error = failure;
          failure = null;
          reject(error);
          return;
        }
        if (data.has(name)) {
          reject(Object.assign(new Error('alias already exists'), {name:'UnknownError'}));
          return;
        }
        data.set(name, rawData);
        success();
      }, 2);
    },
    removeData(identifier) {
      if (!data.has(identifier.name)) throw Object.assign(new Error('not found'), {name:'NotFoundError'});
      data.delete(identifier.name);
    }
  };
  return {
    data, saves, tizen:{keymanager, package:{getPackageInfo() { return {id:'TVBroWebTV'}; }}},
    maxActiveSaves:() => maxActiveSaves,
    failNext(error) { failure = error; }
  };
}

function adapters() {
  const sdk = createKeyManagerDouble();
  let localStorageAccesses = 0;
  const environment = {
    tizen:sdk.tizen,
    get localStorage() {
      localStorageAccesses += 1;
      throw new Error('Plain storage must not be accessed.');
    }
  };
  const secureStore = createSecureStore({environment, tizen:sdk.tizen});
  return {
    sdk, secureStore, userState:createUserState({store:secureStore}),
    localStorageAccesses:() => localStorageAccesses
  };
}

test('stores source-compatible profile keys and user snapshots in a separate KeyManager alias', async () => {
  const kit = adapters();
  const source = [{
    id:'source-1', kind:'m3u', label:'Kitchen TV',
    fields:{playlistUrl:'https://provider.invalid/list.m3u?token=fixture'}
  }];
  await kit.secureStore.write(source);
  assert.deepEqual(kit.userState.read(), {});
  assert.equal(kit.userState.keys.localProfiles, 'local_profiles_v1');
  assert.equal(kit.userState.get('active_local_profile_id'), null);

  await kit.userState.set(kit.userState.keys.localProfiles, JSON.stringify([{id:'profile-1', name:'Home'}]));
  await kit.userState.set(kit.userState.keys.activeLocalProfileId, 'profile-1');
  await kit.userState.write({
    local_profiles_v1:JSON.stringify([{id:'profile-1', name:'Home'}]),
    active_local_profile_id:'profile-1',
    favorites_v1:'[]',
    playback_positions_v1:'{}',
    playback_history_v1:'[]',
    tvbro_parental_controls_v1:JSON.stringify({
      version:1, verifier:'fixture-verifier', lockSettings:true, channels:[], categories:[]
    })
  });

  assert.deepEqual(kit.userState.read(), {
    local_profiles_v1:JSON.stringify([{id:'profile-1', name:'Home'}]),
    active_local_profile_id:'profile-1', favorites_v1:'[]',
    playback_positions_v1:'{}', playback_history_v1:'[]',
    tvbro_parental_controls_v1:JSON.stringify({
      version:1, verifier:'fixture-verifier', lockSettings:true, channels:[], categories:[]
    })
  });
  const reloaded = createSecureStore({tizen:kit.sdk.tizen});
  assert.deepEqual(reloaded.read(), source);
  assert.deepEqual(createUserState({store:reloaded}).read(), kit.userState.read());
  assert.ok(kit.sdk.saves.some(save => /^tvbro_sources_v1_g[1-9][0-9]*$/.test(save.name)));
  assert.ok(kit.sdk.saves.some(save => /^tvbro_user_state_v1_g[1-9][0-9]*$/.test(save.name)));
  assert.equal(new Set(kit.sdk.saves.map(save => save.name)).size, kit.sdk.saves.length);
  assert.equal(kit.sdk.saves.every(save => save.password === null), true);
  assert.equal(kit.localStorageAccesses(), 0);
});

test('serializes key CRUD and leaves the last committed state intact after KeyManager failure', async () => {
  const kit = adapters();
  await Promise.all([
    kit.userState.set('local_profiles_v1', '[]'),
    kit.userState.set('active_local_profile_id', 'profile-a'),
    kit.userState.set('profile_picker_startup', 'auto')
  ]);
  assert.deepEqual(kit.userState.read(), {
    local_profiles_v1:'[]', active_local_profile_id:'profile-a', profile_picker_startup:'auto'
  });
  assert.equal(kit.sdk.maxActiveSaves(), 1);

  const committed = kit.userState.read();
  kit.sdk.failNext(Object.assign(new Error('write failed'), {name:'UnknownError'}));
  await assert.rejects(kit.userState.set('local_profiles_v1', '["new"]'), {name:'UnknownError'});
  assert.deepEqual(kit.userState.read(), committed);
  assert.equal(createUserState({store:createSecureStore({tizen:kit.sdk.tizen})}).get('local_profiles_v1'), '[]');

  await kit.userState.remove('active_local_profile_id');
  assert.equal(kit.userState.get('active_local_profile_id'), null);
  assert.equal(kit.localStorageAccesses(), 0);
});

test('source and user-state generations migrate, reload, clean up and clear without crossing namespaces', async () => {
  const kit = adapters();
  const sources = [{id:'legacy-source',kind:'m3u',label:'Legacy',fields:{playlistUrl:'https://provider.invalid/list?token=legacy-secret'}}];
  const state = {local_profiles_v1:'[{"id":"legacy-profile","pin":"canonical-verifier"}]', app_language:'pl'};
  kit.sdk.data.set('tvbro_sources_v1', JSON.stringify(sources));
  kit.sdk.data.set('tvbro_user_state_v1', JSON.stringify(state));
  assert.deepEqual(kit.secureStore.read(), sources);
  assert.deepEqual(kit.userState.read(), state);
  kit.sdk.failNext(Object.assign(new Error('migration failed'), {name:'UnknownError'}));
  await assert.rejects(kit.userState.set('app_language', 'en'), {name:'UnknownError'});
  assert.deepEqual(createUserState({store:createSecureStore({tizen:kit.sdk.tizen})}).read(), state);
  for (const language of ['en', 'de', 'fr']) await kit.userState.set('app_language', language);
  const userAliases = [...kit.sdk.data].filter(([name]) => name.startsWith('tvbro_user_state_v1'));
  for (const label of ['First source change', 'Second source change', 'Latest source']) {
    await kit.secureStore.write([{...sources[0], label}]);
  }
  assert.deepEqual([...kit.sdk.data].filter(([name]) => name.startsWith('tvbro_user_state_v1')), userAliases,
    'source cleanup must preserve every committed user-state alias');
  let reloaded = createSecureStore({tizen:kit.sdk.tizen});
  assert.equal(reloaded.read()[0].label, 'Latest source');
  assert.deepEqual(reloaded.readUserState(), {...state, app_language:'fr'});
  await kit.secureStore.remove();
  reloaded = createSecureStore({tizen:kit.sdk.tizen});
  assert.deepEqual(reloaded.read(), []);
  assert.deepEqual(reloaded.readUserState(), {...state, app_language:'fr'});
  const sourceAliases = [...kit.sdk.data].filter(([name]) => name.startsWith('tvbro_sources_v1'));
  await kit.secureStore.removeUserState();
  reloaded = createSecureStore({tizen:kit.sdk.tizen});
  assert.deepEqual(reloaded.readUserState(), {});
  assert.deepEqual(reloaded.read(), []);
  assert.deepEqual([...kit.sdk.data].filter(([name]) => name.startsWith('tvbro_sources_v1')), sourceAliases,
    'user-state cleanup must preserve every source alias');
  assert.equal(kit.sdk.data.get('tvbro_sources_v1'), JSON.stringify(sources));
  assert.equal(kit.sdk.data.get('tvbro_user_state_v1'), JSON.stringify(state));
  assert.equal(kit.localStorageAccesses(), 0);
});

test('serializes atomic profile updates with concurrent single-key cloud writes', async () => {
  const kit = adapters();
  await Promise.all([
    kit.userState.update(state => {
      state.local_profiles_v1 = '[{"id":"profile-a"}]';
      state.active_local_profile_id = 'profile-a';
    }),
    kit.userState.set('supabase_session', '{"access_token":"fixture"}')
  ]);
  assert.deepEqual(kit.userState.read(), {
    local_profiles_v1:'[{"id":"profile-a"}]',
    active_local_profile_id:'profile-a',
    supabase_session:'{"access_token":"fixture"}'
  });
  assert.equal(kit.sdk.maxActiveSaves(), 1);
  assert.equal(kit.localStorageAccesses(), 0);
});

test('requires KeyManager and rejects invalid key/value records without persistence', async () => {
  assert.throws(() => createUserState({}), {name:'NotSupportedError'});
  const kit = adapters();
  await assert.rejects(kit.userState.set('', 'value'), {name:'TypeError'});
  await assert.rejects(kit.userState.set('valid-key', 42), {name:'TypeError'});
  await assert.rejects(kit.userState.write({invalid:42}), {name:'TypeError'});
  await assert.rejects(kit.userState.update('not a function'), {name:'TypeError'});
  assert.equal(kit.sdk.saves.length, 0);
});
