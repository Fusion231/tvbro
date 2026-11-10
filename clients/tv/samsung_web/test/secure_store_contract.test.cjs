'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { create } = require('../platform/secure_store.js');

function createKeyManagerDouble({packageIdentity = true} = {}) {
  const data = new Map();
  const foreign = [];
  const saves = [];
  const reads = [];
  const removals = [];
  let activeSaves = 0;
  let maxActiveSaves = 0;
  let saveFailure = null;
  let readFailure = null;
  let listFailure = null;
  let removeFailure = null;
  const keymanager = {
    getData(alias) {
      reads.push({...alias});
      if (readFailure) throw readFailure;
      if (alias.packageId && alias.packageId !== 'TVBroWebTV') {
        const entry = foreign.find(entry => entry.name === alias.name && entry.packageId === alias.packageId);
        if (entry) return entry.rawData;
      }
      if (!data.has(alias.name)) throw Object.assign(new Error('not found'), { name: 'NotFoundError' });
      return data.get(alias.name);
    },
    getDataAliasList() {
      if (listFailure) throw listFailure;
      return [...data.keys()].map(name => ({name, packageId:'TVBroWebTV'}))
        .concat(foreign.map(({name, packageId}) => ({name, packageId})));
    },
    saveData(name, rawData, password, success, failure) {
      saves.push({ name, rawData, password });
      activeSaves += 1;
      maxActiveSaves = Math.max(maxActiveSaves, activeSaves);
      setTimeout(() => {
        activeSaves -= 1;
        if (saveFailure) {
          const error = saveFailure;
          saveFailure = null;
          failure(error);
          return;
        }
        if (data.has(name)) {
          failure(Object.assign(new Error('alias already exists'), {name:'UnknownError'}));
          return;
        }
        data.set(name, rawData);
        success();
      }, 5);
    },
    removeData(alias) {
      removals.push({...alias});
      if (removeFailure) throw removeFailure;
      if (!data.has(alias.name)) throw Object.assign(new Error('not found'), { name: 'NotFoundError' });
      data.delete(alias.name);
    }
  };

  return {
    tizen: {keymanager, ...(packageIdentity ? {package:{getPackageInfo() { return {id:'TVBroWebTV'}; }}} : {})},
    data,
    foreign,
    saves,
    reads,
    removals,
    maxActiveSaves: () => maxActiveSaves,
    failNextSave(error) { saveFailure = error; },
    setReadFailure(error) { readFailure = error; },
    clearReadFailure() { readFailure = null; },
    setListFailure(error) { listFailure = error; },
    setRemoveFailure(error) { removeFailure = error; }
  };
}

test('reads the private alias, stores canonical source snapshots serially, and never uses localStorage', async () => {
  const sdk = createKeyManagerDouble();
  let localStorageAccesses = 0;
  const environment = {
    tizen: sdk.tizen,
    get localStorage() {
      localStorageAccesses += 1;
      throw new Error('localStorage must not be touched');
    }
  };
  const store = create({ environment });
  assert.deepEqual(store.read(), []);

  const first = [{
    id: 'source-a',
    kind: 'xtream',
    label: 'Provider A',
    fields: { host: 'https://provider.test', username: 'user-a', password: 'secret-a' },
    settings: { bufferPreset: 'normal' }
  }];
  const second = [{
    id: 'source-b',
    kind: 'm3u',
    label: 'Playlist B',
    fields: { playlistUrl: 'https://provider.test/list.m3u?token=secret-b' }
  }];
  const writeFirst = store.write(first);
  first[0].fields.password = 'mutated-after-call';
  const writeSecond = store.write(second);
  second[0].label = 'mutated-after-call';
  await Promise.resolve();
  assert.deepEqual(store.read(), [], 'a pending native save must not publish an uncommitted snapshot');
  await Promise.all([writeFirst, writeSecond]);

  assert.equal(sdk.saves.length, 2);
  assert.equal(new Set(sdk.saves.map(save => save.name)).size, 2, 'CREATE-ONLY aliases must be unique');
  assert.ok(sdk.saves.every(save => /^tvbro_sources_v1_g[1-9][0-9]*$/.test(save.name)));
  assert.equal(sdk.saves[0].password, null);
  assert.equal(JSON.parse(sdk.saves[0].rawData)[0].fields.password, 'secret-a');
  assert.equal(JSON.parse(sdk.saves[1].rawData)[0].label, 'Playlist B');
  assert.equal(sdk.maxActiveSaves(), 1, 'writes are serialized');
  assert.deepEqual(store.read(), [{
    id: 'source-b',
    kind: 'm3u',
    label: 'Playlist B',
    fields: { playlistUrl: 'https://provider.test/list.m3u?token=secret-b' }
  }]);
  assert.equal(localStorageAccesses, 0);
  assert.deepEqual(create({tizen:sdk.tizen}).read(), store.read(), 'a fresh adapter reads the second physical save');

  const returned = store.read();
  returned[0].fields.playlistUrl = 'mutated-read-copy';
  assert.equal(store.read()[0].fields.playlistUrl, 'https://provider.test/list.m3u?token=secret-b');
});

test('distinguishes an absent alias from SDK errors and rejects malformed stored data without exposing it', async () => {
  const sdk = createKeyManagerDouble();
  const store = create({ tizen: sdk.tizen });
  assert.deepEqual(store.read(), []);

  const sdkError = Object.assign(new Error('secure database unavailable'), { name: 'UnknownError' });
  const failingRead = createKeyManagerDouble();
  failingRead.data.set('tvbro_sources_v1', '[]');
  failingRead.setReadFailure(sdkError);
  assert.throws(() => create({ tizen: failingRead.tizen }).read(), (error) => error === sdkError);

  const malformed = createKeyManagerDouble();
  malformed.data.set('tvbro_sources_v1', '{"password":"provider-secret"');
  assert.throws(() => create({ tizen: malformed.tizen }).read(), (error) => {
    assert.equal(error.name, 'SyntaxError');
    assert.doesNotMatch(error.message, /provider-secret/);
    return true;
  });

  await store.remove();
  assert.deepEqual(store.read(), []);
});

test('migrates a legacy snapshot only after a successful new-alias save and preserves it on failure', async t => {
  for (const rejectMigration of [false, true]) await t.test(rejectMigration ? 'rejected save' : 'successful save', async () => {
    const sdk = createKeyManagerDouble();
    const legacy = [{id:'legacy', kind:'m3u', label:'Legacy', fields:{playlistUrl:'https://provider.test/old?token=legacy-secret'}}];
    const next = [{id:'next', kind:'m3u', label:'Next', fields:{playlistUrl:'https://provider.test/new?token=next-secret'}}];
    const rawLegacy = JSON.stringify(legacy);
    sdk.data.set('tvbro_sources_v1', rawLegacy);
    const store = create({tizen:sdk.tizen});
    assert.deepEqual(store.read(), legacy);
    assert.equal(sdk.saves.length, 0, 'reading legacy data must not migrate it implicitly');
    if (rejectMigration) sdk.failNextSave(Object.assign(new Error('write rejected'), {name:'UnknownError'}));
    if (rejectMigration) await assert.rejects(store.write(next), {name:'UnknownError'});
    else await store.write(next);
    assert.equal(sdk.data.get('tvbro_sources_v1'), rawLegacy, 'legacy data is never overwritten or removed');
    assert.notEqual(sdk.saves[0].name, 'tvbro_sources_v1');
    assert.deepEqual(store.read(), rejectMigration ? legacy : next);
    assert.deepEqual(create({tizen:sdk.tizen}).read(), rejectMigration ? legacy : next);
    if (rejectMigration) {
      await store.write(next);
      assert.deepEqual(create({tizen:sdk.tizen}).read(), next, 'a rejected migration must not poison later saves');
    }
  });
});

test('keeps the newest two immutable snapshots and commits even when old-alias cleanup fails', async () => {
  const sdk = createKeyManagerDouble();
  const store = create({tizen:sdk.tizen});
  const snapshot = label => [{id:'source', kind:'m3u', label, fields:{playlistUrl:'https://provider.test/list?token=secret'}}];
  await store.write(snapshot('First'));
  await store.write(snapshot('Second'));
  sdk.setRemoveFailure(Object.assign(new Error('cleanup rejected'), {name:'UnknownError'}));
  await store.write(snapshot('Third'));
  assert.equal(sdk.data.size, 3, 'the cleanup failure is a real device rejection');
  assert.deepEqual(store.read(), snapshot('Third'));
  assert.deepEqual(create({tizen:sdk.tizen}).read(), snapshot('Third'));
  sdk.setRemoveFailure(null);
  await store.write(snapshot('Fourth'));
  assert.deepEqual([...sdk.data.keys()].sort(), sdk.saves.slice(-2).map(save => save.name).sort());
  assert.deepEqual(create({tizen:sdk.tizen}).read(), snapshot('Fourth'));
  assert.equal(new Set(sdk.saves.map(save => save.name)).size, 4);
  await store.remove();
  assert.deepEqual(create({tizen:sdk.tizen}).read(), [], 'removal must persist an empty generation across reload');
  assert.equal(sdk.data.size, 2);
});

test('reads generations numerically and rejects the highest malformed payload without legacy or older fallback', async t => {
  for (const domain of ['sources', 'user_state']) await t.test(domain, async () => {
    const sdk = createKeyManagerDouble();
    const base = 'tvbro_' + domain + '_v1';
    const older = domain === 'sources' ? [{id:'old',kind:'m3u',label:'Old',fields:{playlistUrl:'https://provider.test/list'}}] : {app_language:'pl'};
    const latest = domain === 'sources' ? [{id:'new',kind:'m3u',label:'New',fields:{playlistUrl:'https://provider.test/new'}}] : {app_language:'en'};
    sdk.data.set(base, JSON.stringify(older));
    sdk.data.set(base + '_g2', JSON.stringify(older));
    sdk.data.set(base + '_g10', JSON.stringify(latest));
    const read = () => {
      const store = create({tizen:sdk.tizen});
      return domain === 'sources' ? store.read() : store.readUserState();
    };
    assert.deepEqual(read(), latest, 'generation 10 takes precedence over 2 regardless of enumeration order');
    sdk.data.set(base + '_g10', '{"password":"malformed-private-secret"');
    assert.throws(read, error => {
      assert.equal(error.name, 'SyntaxError');
      assert.doesNotMatch(error.message, /malformed-private-secret/);
      return true;
    });
    const store = create({tizen:sdk.tizen});
    await assert.rejects(domain === 'sources' ? store.write([]) : store.writeUserState({}), {name:'SyntaxError'});
    assert.equal(sdk.saves.length, 0);
    assert.equal(sdk.removals.length, 0);
  });
});

test('ignores foreign package and similar namespace aliases during reads, writes and cleanup', async () => {
  const sdk = createKeyManagerDouble();
  sdk.tizen.application = {getCurrentApplication() { return {appInfo:{packageId:'TVBroWebTV'}}; }};
  sdk.tizen.package.getPackageInfo = () => { throw new Error('current application identity must be sufficient'); };
  const own = [{id:'own',kind:'m3u',label:'Own',fields:{playlistUrl:'https://provider.test/own'}}];
  const foreign = {name:'tvbro_sources_v1_g999', packageId:'OtherApp', rawData:'malformed foreign secret'};
  sdk.foreign.push(foreign);
  sdk.data.set('tvbro_sources_v1_g2', JSON.stringify(own));
  sdk.data.set('tvbro_sources_v1_backup_g1000', 'similar namespace secret');
  sdk.data.set('tvbro_user_state_v1_g10', JSON.stringify({app_language:'pl'}));
  const untouched = new Map(sdk.data);
  const store = create({tizen:sdk.tizen});
  assert.deepEqual(store.read(), own);
  for (const label of ['Next', 'Again', 'Latest']) await store.write([{...own[0], label}]);
  assert.equal(create({tizen:sdk.tizen}).read()[0].label, 'Latest');
  assert.deepEqual(store.readUserState(), {app_language:'pl'});
  for (const name of ['tvbro_sources_v1_backup_g1000', 'tvbro_user_state_v1_g10']) {
    assert.equal(sdk.data.get(name), untouched.get(name));
  }
  assert.deepEqual(sdk.foreign, [foreign]);
  assert.equal(sdk.reads.some(alias => alias.name === foreign.name), false);
  assert.equal(sdk.removals.some(alias => alias.name === foreign.name), false);
  assert.ok(sdk.reads.concat(sdk.removals).every(alias => alias.packageId === undefined), 'native calls stay scoped to the caller package');
});

test('fails closed on alias-list failure or unavailable package identity instead of treating existing data as empty', async () => {
  const sdk = createKeyManagerDouble();
  const error = Object.assign(new Error('alias database unavailable'), {name:'UnknownError'});
  sdk.setListFailure(error);
  assert.throws(() => create({tizen:sdk.tizen}).read(), candidate => candidate === error);
  await assert.rejects(create({tizen:sdk.tizen}).write([]), candidate => candidate === error);
  assert.equal(sdk.saves.length, 0);

  const unidentified = createKeyManagerDouble({packageIdentity:false});
  assert.deepEqual(create({tizen:unidentified.tizen}).read(), []);
  await assert.rejects(create({tizen:unidentified.tizen}).write([]), {name:'NotSupportedError'});
  unidentified.data.set('tvbro_sources_v1_g1', '[]');
  assert.throws(() => create({tizen:unidentified.tizen}).read(), {name:'NotSupportedError'});
  await assert.rejects(create({tizen:unidentified.tizen}).write([]), {name:'NotSupportedError'});
  assert.equal(unidentified.reads.length, 0, 'unidentified package metadata must not grant ownership');
  assert.equal(unidentified.saves.length, 0);
});

test('requires KeyManager and keeps the committed snapshot unchanged when a write fails', async () => {
  const missing = create({});
  assert.throws(() => missing.read(), { name: 'NotSupportedError' });
  await assert.rejects(missing.write([]), { name: 'NotSupportedError' });

  const incomplete = create({ tizen: { keymanager: {} } });
  assert.throws(() => incomplete.read(), { name: 'NotSupportedError' });
  await assert.rejects(incomplete.write([]), { name: 'NotSupportedError' });
  await assert.rejects(incomplete.remove(), { name: 'NotSupportedError' });

  const sdk = createKeyManagerDouble();
  const store = create({ tizen: sdk.tizen });
  assert.deepEqual(store.read(), []);
  sdk.failNextSave(Object.assign(new Error('KeyManager refused the write'), { name: 'UnknownError' }));
  await assert.rejects(store.write([{
    id: 'source-failed',
    kind: 'm3u',
    label: 'Not committed',
    fields: { playlistUrl: 'https://provider.test/list?token=secret' }
  }]), { name: 'UnknownError' });
  assert.deepEqual(store.read(), []);
});
