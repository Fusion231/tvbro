'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const acorn = require('acorn');

// Execute the shipped startup and selection handlers. Only the UI and query
// boundaries are doubled; PIN authorization stays behind profiles.select.
const source = fs.readFileSync(path.join(__dirname, '../ui/app.js'), 'utf8');
const names = ['routeAfterLanguage', 'selectExistingProfile'];
const declarations = acorn.parse(source, {ecmaVersion:2022}).body[0].expression.callee.body.body;
const handlers = declarations.filter(node => node.type === 'FunctionDeclaration' && names.includes(node.id.name))
  .map(node => source.slice(node.start,node.end)).join('\n');

function deferred() {
  let resolve, reject;
  const promise = new Promise((done,failed) => { resolve = done; reject = failed; });
  return {promise,resolve,reject};
}
function harness(options = {}) {
  const selection = deferred(), calls = [];
  const profile = options.profile === null ? null : Object.assign({id:'remembered',source:'cloud',locked:false},options.profile);
  const view = {profile,settings:{profilePickerStartup:options.mode || 'off'},
    showProfilePicker:options.picker === undefined ? !!(profile && profile.locked) : options.picker,
    screen:'sources',request:0,busy:false,profileSelecting:false};
  const env = {Promise,view,
    showProfiles() { calls.push(['picker']); view.screen = 'profiles'; },
    openProfileContent() { calls.push(['open',view.profile.id]); view.screen = 'home'; },
    refreshParental() { calls.push(['parental']); return Promise.resolve(); },
    report(error) { calls.push(['error',error.code]); },
    t:value => value,status() {},
    profileSelectionBusy(value) { view.busy = value; view.profileSelecting = value; },
    afterLoadingPaint:() => Promise.resolve(),
    cancelled() { const error = Error('Cancelled'); error.code = 'cancelled'; return error; },
    query(action,args) { calls.push([action,args.id,args.source]); return selection.promise; },
    afterProfile(data) { calls.push(['authorized',data.profile.id]); view.profile = data.profile; view.screen = 'home'; }
  };
  vm.createContext(env); vm.runInContext(handlers,env);
  return {env,view,calls,selection,settle:() => new Promise(resolve => setImmediate(resolve))};
}

test('startup off opens the remembered unlocked profile without opening the chooser', () => {
  const kit = harness(); kit.env.routeAfterLanguage();
  assert.deepEqual(kit.calls,[['open','remembered'],['parental']]);
  assert.equal(kit.view.screen,'home');
});

for (const source of ['local','cloud']) {
  test('startup off selects only the remembered locked '+source+' profile through the normal authorization path', async () => {
    const kit = harness({profile:{id:'saved-'+source,source,locked:true},picker:true});
    kit.env.routeAfterLanguage(); await kit.settle();
    assert.deepEqual(kit.calls,[['picker'],['profiles.select','saved-'+source,source]]);
    assert.equal(kit.view.screen,'profiles'); assert.equal(kit.view.profileSelecting,true);
    kit.selection.resolve({profile:{id:'saved-'+source,source,locked:false}}); await kit.settle();
    assert.deepEqual(kit.calls[2],['authorized','saved-'+source]);
    assert.equal(kit.view.screen,'home'); assert.equal(kit.view.profileSelecting,false);
  });
}

for (const mode of ['auto','always']) {
  test(mode+' startup preserves the requested chooser instead of auto-selecting a locked profile', async () => {
    const kit = harness({mode,profile:{locked:true},picker:true}); kit.env.routeAfterLanguage(); await kit.settle();
    assert.deepEqual(kit.calls,[['picker']]); assert.equal(kit.view.profileSelecting,false);
  });
}

test('startup without an active profile keeps the chooser even when the mode is off', async () => {
  const kit = harness({profile:null,picker:false}); kit.env.routeAfterLanguage(); await kit.settle();
  assert.deepEqual(kit.calls,[['picker']]); assert.equal(kit.view.profile,null);
});

test('cancelling automatic PIN authorization leaves the chooser usable and never retries itself', async () => {
  const kit = harness({profile:{locked:true},picker:true});
  kit.env.routeAfterLanguage(); await kit.settle();
  const cancelled = Error('Cancelled PIN'); cancelled.code = 'cancelled'; kit.selection.reject(cancelled);
  await kit.settle(); await kit.settle();
  assert.equal(kit.calls.filter(call => call[0] === 'profiles.select').length,1);
  assert.equal(kit.calls.filter(call => call[0] === 'picker').length,1);
  assert.equal(kit.calls.some(call => call[0] === 'authorized'),false);
  assert.equal(kit.view.screen,'profiles'); assert.equal(kit.view.profile.locked,true);
  assert.equal(kit.view.busy,false); assert.equal(kit.view.profileSelecting,false);
});

test('a changed startup screen cannot receive a late automatic profile authorization', async () => {
  const kit = harness({profile:{locked:true},picker:true}); kit.env.routeAfterLanguage(); await kit.settle();
  kit.view.request++; kit.view.screen = 'language';
  kit.selection.resolve({profile:{id:'remembered',locked:false}}); await kit.settle();
  assert.equal(kit.calls.some(call => call[0] === 'authorized'),false);
  assert.equal(kit.view.screen,'language');
});
