'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');
const transportModule = require(path.resolve(__dirname, '../platform/transport.js'));

class FakeXhr {
  constructor(environment) { this.environment = environment; this.headers = {}; this.responseText = '{"token":"fixture-token"}'; this.status = 200; this.responseURL = ''; }
  open(method, url) { this.method = method; this.url = url; this.responseURL = url; }
  setRequestHeader(name, value) { this.headers[name] = value; }
  getAllResponseHeaders() { return 'content-type: application/json\r\n'; }
  getResponseHeader() { return null; }
  send(body) {
    this.body = body;
    this.readyState = 2;
    this.onreadystatechange();
    this.onload();
  }
  abort() { if (this.onabort) this.onabort(); }
}

test('metadata transport preserves TVDB POST method, JSON body, and headers', async () => {
  const requests = [];
  const environment = {
    navigator: { userAgent: 'fixture' },
    setTimeout, clearTimeout,
    XMLHttpRequest: function () { const xhr = new FakeXhr(environment); requests.push(xhr); return xhr; },
    Blob,
  };
  const core = {
    providerGateInit: async () => 'null',
    providerGateMerge: async () => 'null',
    providerGateRecord: () => {},
    providerGateRun: async (_raw, perform) => perform(),
  };
  const userState = { get: () => '{}', set: async () => 'null' };
  const transport = transportModule.create(environment, { core, userState });
  const body = JSON.stringify({ apikey: 'fixture-only' });
  const result = await transport.request(JSON.stringify({
    url: 'https://api4.thetvdb.com/v4/login', method: 'POST', body,
    headers: { 'content-type': 'application/json', accept: 'application/json' },
    workload: 'metadata-json', maximumBodyBytes: 4 * 1024 * 1024,
    maximumDecodedBytes: 8 * 1024 * 1024, totalTimeoutMs: 45000, idleTimeoutMs: 20000,
  }));
  assert.equal(JSON.parse(result).status, 200);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].method, 'POST');
  assert.equal(requests[0].body, body);
  assert.equal(requests[0].headers['content-type'], 'application/json');
});
