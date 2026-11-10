'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const acorn = require('acorn');

// Execute the actual UI handlers with DOM/rendering and platform IO boundaries.
const source = fs.readFileSync(path.join(__dirname, '../ui/app.js'), 'utf8');
const declarations = acorn.parse(source, {ecmaVersion:2022}).body[0].expression.callee.body.body;
const handlers = declarations.filter(node => node.type === 'FunctionDeclaration' &&
  ['chooseCloudProfile', 'pairingAction'].includes(node.id.name)).map(node => source.slice(node.start, node.end)).join('\n');

function harness({sources = [], paired = false, onboarding = false, profiles = []} = {}) {
  const calls = [], dialogs = [], nodes = {}, applied = [];
  let completed = 0, download;
  const view = {screen:'pairing', sources, pairingOnboarding:onboarding, pairingRequest:0, pairingState:{}, pairingBusy:false};
  const environment = {
    view, Promise, array:value => Array.isArray(value) ? value : [], t:value => value,
    byId:id => nodes[id] || (nodes[id] = {}), text:(node,value) => { node.textContent = value; },
    afterLoadingPaint:() => Promise.resolve(), stopPairingWatch() {}, status() {}, focus() {},
    cancelled:() => new Error('cancelled'), message:error => error.message,
    report:error => { throw error; },
    renderPairing(data) { view.pairingState = data; if (typeof data.paired === 'boolean') view.pairingPaired = data.paired; if (data.code) view.pairingCode = data.code; },
    applyBootstrap:data => applied.push(data), continuePairing:() => { completed++; },
    refreshBootstrap:() => Promise.resolve(), renderSources() {}, closeDialog() {}, dialogButton() {},
    dialog() { const record = {body:{appendChild() {}},actions:{firstChild:{}},error:{}}; dialogs.push(record); return record; },
    element:() => ({appendChild() {},querySelector() {return {};}}), button:() => ({}),
    query(action,args) {
      calls.push({action,args});
      if (action === 'pairing.get') return Promise.resolve({paired});
      if (action === 'pairing.start') return Promise.resolve({code:'ABCD2345',paired:false});
      if (action === 'pairing.profiles') return Promise.resolve(profiles);
      if (action === 'pairing.download') return new Promise(resolve => { download = resolve; });
      throw new Error('Unexpected UI action: ' + action);
    }
  };
  vm.createContext(environment); vm.runInContext(handlers, environment);
  return {environment,view,calls,dialogs,applied,get completed() {return completed;},finishDownload:data => download(data)};
}

test('first pairing from an empty account screen starts full onboarding automatically', async () => {
  const kit = harness();
  await kit.environment.pairingAction('get');
  assert.equal(kit.view.pairingOnboarding, true);
  assert.deepEqual(kit.calls.map(call => call.action), ['pairing.get','pairing.start']);
});

test('local playlists and already paired accounts retain manual transfer management', async () => {
  for (const options of [{sources:[{id:'local'}]}, {paired:true}]) {
    const kit = harness(options);
    await kit.environment.pairingAction('get');
    assert.equal(kit.view.pairingOnboarding, false);
    assert.deepEqual(kit.calls.map(call => call.action), ['pairing.get']);
  }
});

test('a sole onboarding profile waits for its complete download before continuing', async () => {
  const kit = harness({paired:true,onboarding:true,profiles:[{id:'cloud',name:'Cloud',pinSet:true}]});
  let started;
  const observed = new Promise(resolve => {started = resolve;});
  const query = kit.environment.query;
  kit.environment.query = (action,args) => { const result = query(action,args); if (action === 'pairing.download') started(); return result; };
  const pending = kit.environment.pairingAction('get');
  await observed;
  assert.equal(kit.completed, 0); assert.equal(kit.applied.length, 0); assert.equal(kit.dialogs.length, 0);
  assert.deepEqual(JSON.parse(JSON.stringify(kit.calls.at(-1))), {action:'pairing.download',args:{profileId:'cloud'}});
  const snapshot = {paired:true,onboardingReady:true,favorites:[{sourceId:'source',item:{id:'500'}}],sources:[{id:'source',settings:{streamExtension:'m3u8'}}]};
  kit.finishDownload(snapshot); await pending;
  assert.equal(kit.completed, 1); assert.deepEqual(kit.applied, [snapshot]);
});

test('multiple onboarding profiles still wait for an explicit choice', async () => {
  const kit = harness({paired:true,onboarding:true,profiles:[{id:'first'},{id:'second'}]});
  await kit.environment.pairingAction('get');
  assert.equal(kit.dialogs.length, 1); assert.equal(kit.completed, 0);
  assert.deepEqual(kit.calls.map(call => call.action), ['pairing.get','pairing.profiles']);
});
