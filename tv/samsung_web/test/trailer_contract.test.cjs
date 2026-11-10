'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const createPlatform = require('../platform.js');

// Isolate the native app-control boundary. The actual library has separate
// contracts for profile admission and canonical trailer URI derivation.
function fixture(mode = 'available') {
  const calls = [], timers = new Map(); let options, nextTimer = 0;
  const application = {
    launchAppControl(control, appId, success, failure) {
      assert.equal(this, application);
      calls.push({control,appId,success,failure});
      if (mode === 'throws') throw Error('Native error with https://secret.fixture/private?token=hidden');
    }
  };
  const tizen = {application,ApplicationControl:function(operation,uri) {
    if (mode === 'constructor-throws') throw Error('Sensitive constructor detail');
    this.operation=operation;this.uri=uri;
  }};
  if (mode === 'no-constructor') delete tizen.ApplicationControl;
  if (mode === 'no-launch') delete application.launchAppControl;
  const player = {getState() { return {}; },onState() {}};
  const environment = {
    tizen,URL,
    setTimeout(callback,delay) { const id=++nextTimer;timers.set(id,{callback,delay});return id; },
    clearTimeout(id) { timers.delete(id); },
    TVBroSamsungSecureStore:{create() { return {}; }},
    TVBroSamsungUserState:{create() { return {}; }},
    TVBroSamsungTransport:{create() { return {}; }},
    TVBroSamsungAvplay:{},
    TVBroSamsungLibrary:{create(value) {
      options=value;
      return {getState() { return {}; },onState() {},query(action,args) {
        assert.equal(action,'media.trailer');return options.openTrailer(args.url);
      }};
    }}
  };
  const api = createPlatform(environment,{core:{},validation:{friendlyError(error) { return error.message; }},
    store:{},player,createSource() {},verifyPin() {},hashPin() {}});
  return {api,options,calls,timers};
}

for (const mode of ['no-constructor','no-launch']) {
  test('trailer capability is absent when the native SDK has '+mode, () => {
    const kit=fixture(mode);
    assert.equal(kit.options.openTrailer,undefined);
    assert.equal(kit.calls.length,0);
  });
}

test('only an explicit trailer action launches the validated URI with native app-control', async () => {
  const kit=fixture();
  assert.equal(typeof kit.options.openTrailer,'function');assert.equal(kit.calls.length,0);
  const uri='https://www.youtube.com/watch?v=dQw4w9WgXcQ';
  let opened=false;
  const pending=kit.api.query('media.trailer',{url:uri}).then(() => { opened=true; });
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(kit.calls.length,1);assert.equal(opened,false);
  assert.equal(kit.calls[0].control.operation,'http://tizen.org/appcontrol/operation/view');
  assert.equal(kit.calls[0].control.uri,uri);assert.equal(kit.calls[0].appId,null);
  kit.calls[0].success();await pending;
  assert.equal(opened,true);assert.equal(kit.timers.size,0);
  kit.calls[0].failure(Error('Late duplicate error'));assert.equal(kit.calls.length,1);
});

test('invalid or credential-bearing trailer URIs never reach the SDK', async () => {
  const kit=fixture();
  for (const url of [null,{},'', 'javascript:alert(1)','file:///private/data','data:text/html,content',
    'http://trailers.fixture/watch','https://user:password@trailers.fixture/watch','https://trailers.fixture/with a space']) {
    await assert.rejects(kit.options.openTrailer(url),error => error.code==='trailer_unavailable' &&
      error.message==='Could not open the trailer or YouTube.');
  }
  assert.equal(kit.calls.length,0);assert.equal(kit.timers.size,0);
});

for (const mode of ['throws','constructor-throws']) {
  test('a synchronous native '+mode+' produces only a safe trailer failure', async () => {
    const kit=fixture(mode);
    await assert.rejects(kit.api.query('media.trailer',{url:'https://www.youtube.com/results?search_query=fixture'}),error =>
      error.code==='trailer_unavailable' && error.message==='Could not open the trailer or YouTube.');
    assert.equal(kit.timers.size,0);
  });
}

test('missing native handlers and callback errors preserve the details-safe error without native text', async () => {
  const kit=fixture();
  const pending=kit.options.openTrailer('https://www.youtube.com/results?search_query=fixture');
  const failure=assert.rejects(pending,error => error.code==='trailer_unavailable' &&
    error.message==='Could not open the trailer or YouTube.' && !error.message.includes('private'));
  kit.calls[0].failure({name:'NotFoundError',message:'private native handler details'});
  await failure;assert.equal(kit.timers.size,0);
});

test('a lost app-control callback ends at one deadline without polling', async () => {
  const kit=fixture();
  const pending=kit.options.openTrailer('https://www.youtube.com/results?search_query=fixture');
  const failure=assert.rejects(pending,error => error.code==='trailer_unavailable');
  assert.equal(kit.timers.size,1);
  const timer=[...kit.timers.values()][0];assert.equal(timer.delay,10000);
  timer.callback();await failure;assert.equal(kit.timers.size,0);
});

test('the Samsung 3.0 manifest declares the public app-control launch privilege', () => {
  const manifest=fs.readFileSync(path.join(__dirname,'../config.xml'),'utf8');
  assert.match(manifest,/<tizen:privilege name="http:\/\/tizen\.org\/privilege\/application\.launch"\s*\/>/);
});
