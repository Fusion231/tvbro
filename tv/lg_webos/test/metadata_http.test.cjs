'use strict';
const assert = require('node:assert/strict');
const {EventEmitter} = require('node:events');
const {PassThrough} = require('node:stream');
const test = require('node:test');
const metadataHttp = require('../epg_service/metadata_http.js');

function fixture(steps) {
  const calls = [];
  const https = {request(options, callback) {
    const request = new EventEmitter();
    request.writes = [];
    request.write = value => request.writes.push(String(value));
    request.abort = () => { request.aborted = true; };
    request.end = () => {
      const step = steps.shift();
      calls.push({options, request});
      if (step === null) return;
      if (!step) throw new Error('Missing local HTTP fixture response');
      setImmediate(() => {
        const response = new PassThrough();
        response.statusCode = step.status || 200;
        response.headers = step.headers || {};
        callback(response);
        response.end(step.body || '');
      });
    };
    return request;
  }};
  return {client:metadataHttp.create({https}), calls};
}

function payload(overrides = {}) {
  return Object.assign({url:'https://api4.thetvdb.com/v4/login', method:'POST',
    headers:{'content-type':'application/json'}, body:'{"apikey":"fixture-key","pin":"fixture-pin"}',
    workload:'metadata-json', maximumBodyBytes:4*1024*1024, maximumDecodedBytes:8*1024*1024,
    totalTimeoutMs:45000, idleTimeoutMs:20000}, overrides);
}

test('native metadata HTTP preserves the TVDB login POST without logging its body', async () => {
  const bridge = fixture([{body:'{"data":{"token":"fixture-token"}}', headers:{'content-type':'application/json'}}]);
  const response = await bridge.client.request(payload()).promise;
  assert.equal(bridge.calls.length, 1);
  assert.equal(bridge.calls[0].options.hostname, 'api4.thetvdb.com');
  assert.equal(bridge.calls[0].options.method, 'POST');
  assert.equal(bridge.calls[0].options.path, '/v4/login');
  assert.equal(bridge.calls[0].request.writes[0], '{"apikey":"fixture-key","pin":"fixture-pin"}');
  assert.equal(bridge.calls[0].options.headers['accept-encoding'], 'identity');
  assert.equal(Buffer.from(response.bodyBase64, 'base64').toString(), '{"data":{"token":"fixture-token"}}');
  assert.equal(JSON.stringify(response).includes('fixture-key'), false);
});

test('native metadata HTTP rejects hosts, methods, and paths outside the original clients', async () => {
  const bridge = fixture([]);
  for (const value of [
    payload({url:'http://api4.thetvdb.com/v4/login'}),
    payload({url:'https://other.invalid/v4/login'}),
    payload({url:'https://api4.thetvdb.com/v4/login', method:'GET', body:''}),
    payload({url:'https://api.themoviedb.org/3/movie/1', method:'POST'}),
    payload({url:'https://api.mdblist.com/admin', method:'GET', body:''}),
    payload({url:'https://api.mdblist.com/imdb/movie/%2F..%2Fadmin/?apikey=secret', method:'GET', body:''}),
  ]) await assert.rejects(bridge.client.request(value).promise, {kind:'invalid'});
  assert.equal(bridge.calls.length, 0);
});

test('native metadata HTTP idle timeout covers a request waiting for response headers', async t => {
  t.mock.timers.enable({apis:['setTimeout']});
  const bridge = fixture([null]);
  const request = bridge.client.request(payload({url:'https://api.themoviedb.org/3/movie/1', method:'GET', body:'', headers:{}}));
  const result = request.promise.then(() => 'resolved', error => error.kind);
  t.mock.timers.tick(20000);
  await Promise.resolve();
  const observed = await Promise.race([result, Promise.resolve('pending')]);
  request.cancel();
  assert.equal(observed, 'timeout');
  assert.equal(bridge.calls[0].request.aborted, true);
});

test('native metadata HTTP returns redirects to the gated caller and bounds response bytes', async () => {
  const bridge = fixture([{status:302, headers:{location:'https://api.tvmaze.com/search/shows?token=private'} }]);
  const response = await bridge.client.request(payload({url:'https://api4.thetvdb.com/v4/search', method:'GET', body:'', headers:{}})).promise;
  assert.equal(response.status, 302);
  assert.equal(response.headers.location, 'https://api.tvmaze.com/search/shows?token=private');
  assert.equal(bridge.calls.length, 1, 'each physical redirect hop is separately gated in the worker');

  const bounded = fixture([{body:'12345', headers:{'content-length':'5'}}]);
  await assert.rejects(bounded.client.request(payload({url:'https://api.themoviedb.org/3/movie/1', method:'GET', body:'', headers:{}, maximumBodyBytes:4})).promise,
    {kind:'limit'});
});
