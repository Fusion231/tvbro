'use strict';
const assert = require('node:assert/strict');
const test = require('node:test');
const create = require('../platform/epg_files.js').create;

test('LG adapter exposes bounded metadata RPCs through the private service', async () => {
  const calls = [];
  const environment = {atob, Blob, setTimeout, clearTimeout, webOS:{service:{request(uri, options) {
    const call = {uri, options, cancelled:false};
    calls.push(call);
    queueMicrotask(() => options.onSuccess({returnValue:true,status:200,url:options.parameters.url,
      headers:{'content-type':'application/json'},bodyBase64:Buffer.from('{"ok":true}').toString('base64'),decoded:true}));
    return {cancel() { call.cancelled = true; }};
  }}}};
  const adapter = create({environment});
  const body = '{"apikey":"fixture-only"}';
  const response = await adapter.requestMetadata({url:'https://api4.thetvdb.com/v4/login',method:'POST',body,
    headers:{'content-type':'application/json'},workload:'metadata-json',maximumBodyBytes:4*1024*1024,
    maximumDecodedBytes:8*1024*1024,totalTimeoutMs:45000,idleTimeoutMs:20000});
  assert.equal(calls[0].uri,'luna://online.tvbro.webos.epg/');
  assert.equal(calls[0].options.method,'requestMetadata');
  assert.equal(calls[0].options.subscribe,true);
  assert.equal(calls[0].options.parameters.method,'POST');
  assert.equal(calls[0].options.parameters.body,body);
  assert.equal(Buffer.from(response.bodyBase64,'base64').toString(),'{"ok":true}');
  await assert.rejects(adapter.requestMetadata({url:'https://api4.thetvdb.com/v4/login',method:'POST',body,
    headers:{},workload:'playlist'}),{name:'TypeError'});
});
