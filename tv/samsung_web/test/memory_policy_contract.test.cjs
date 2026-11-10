'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { create } = require('../platform/memory_policy.js');
const sourceWorker = require('../platform/source_worker.js');
const mib = 1024 * 1024;

function hardware() {
  let usage = 60 * 1024, limit = 768 * 1024, available = 1024 * mib, warning;
  const calls = [];
  const environment = { webapis: { pms: {
    getVersion: () => '1.0', getWebAppMemoryUsage: () => usage, getWebAppMemoryLimit: () => limit
  }}, tizen: { systeminfo: {
    getTotalMemory: () => 2 * 1024 * mib, getAvailableMemory: () => available,
    addPropertyValueChangeListener(type, callback) { calls.push(type); warning = callback; return 9; },
    removePropertyValueChangeListener(id) { calls.push(id); }
  }}};
  return { environment, calls, usage(value) { usage = value; }, limit(value) { limit = value; },
    available(value) { available = value; }, memory(status) { warning({status}); } };
}

test('unknown hardware and system RAM alone retain 32 MiB', () => {
  assert.equal(create({environment:{}}).sample().maximumEpgBytes, 32 * mib);
  const kit = hardware(); delete kit.environment.webapis.pms;
  assert.equal(create({environment:kit.environment}).sample().maximumEpgBytes, 32 * mib);
});

test('PMS KiB app allowance and system byte margin permit bounded tiers only', () => {
  const kit = hardware(), policy = create({environment:kit.environment});
  assert.equal(policy.sample().maximumEpgBytes, 64 * mib);
  kit.usage(220 * 1024);
  assert.equal(policy.sample().maximumEpgBytes, 48 * mib);
  kit.usage(400 * 1024);
  assert.equal(policy.sample().maximumEpgBytes, 32 * mib);
  kit.usage(60 * 1024); kit.available(575 * mib);
  assert.equal(policy.sample().maximumEpgBytes, 32 * mib, 'system memory retains a separate 128 MiB reserve');
  kit.available(800 * mib);
  assert.equal(policy.sample().maximumEpgBytes, 64 * mib);
  kit.available(2000 * mib); kit.limit(1000 * 1024); kit.usage(60 * 1024);
  assert.equal(policy.sample().maximumEpgBytes, 64 * mib, 'never exceeds the hard upper bound');
  kit.limit(380 * 1024);
  assert.equal(policy.sample().maximumEpgBytes, 32 * mib, 'a normal 380 MiB app allowance cannot fund a larger serialized guide');
});

test('low-memory notifications and unavailable or invalid readings revoke an upgraded allowance', () => {
  const kit = hardware(), policy = create({environment:kit.environment});
  assert.equal(policy.sample().maximumEpgBytes, 64 * mib);
  kit.memory('WARNING');
  assert.equal(policy.sample().maximumEpgBytes, 32 * mib);
  kit.memory('unknown');
  assert.equal(policy.sample().maximumEpgBytes, 32 * mib,'unrecognized status cannot clear memory pressure');
  kit.memory('NORMAL');
  assert.equal(policy.sample().maximumEpgBytes, 64 * mib);
  kit.environment.webapis.pms.getWebAppMemoryLimit = () => { throw new Error('SecurityError'); };
  assert.equal(policy.sample().maximumEpgBytes, 32 * mib);
  for (const value of [NaN, Infinity, -1, '389120', 1.5, 3 * 1024 * 1024]) {
    kit.environment.webapis.pms.getWebAppMemoryLimit = () => value;
    assert.equal(policy.sample().maximumEpgBytes, 32 * mib);
  }
  const state = policy.getState(); state.maximumEpgBytes = 999;
  assert.equal(policy.getState().maximumEpgBytes, 32 * mib);
  policy.dispose(); policy.dispose();
  assert.deepEqual(kit.calls, ['MEMORY',9]);
});

test('source worker samples guide allowance at execution and leaves other arguments unchanged', async () => {
  const calls = [];
  let worker, maximum = 64 * mib, samples = 0;
  class Worker {
    constructor() { worker = this; queueMicrotask(() => this.onmessage({data:{type:'ready'}})); }
    postMessage(message) {
      calls.push(message);
      queueMicrotask(() => this.onmessage({data:{type:'result',id:message.id,value:[]}}));
    }
    terminate() {}
  }
  const bridge = sourceWorker.create({Worker,setTimeout,clearTimeout}, {
    epgDiskAvailable:()=>true,
    memoryPolicy:{sample() { samples++; return {maximumEpgBytes:maximum}; }}
  });
  const source = bridge.createSource('{}', async () => '{}');
  await source.invoke('channels','{}');
  await source.invoke('epg','{"channels":[]}');
  maximum = 32 * mib;
  await source.invoke('epg','{"channels":[],"from":"2026-10-26"}');
  assert.equal(samples,2);
  assert.equal(calls.find(call=>call.method==='channels').args,'{}');
  assert.deepEqual(calls.filter(call=>call.method==='epg').map(call=>JSON.parse(call.args)),[
    {channels:[],_tvEpgMaximumBytes:64*mib,_tvEpgDisk:true},{channels:[],from:'2026-10-26',_tvEpgMaximumBytes:32*mib,_tvEpgDisk:true}
  ]);
  await source.dispose();
  assert.equal(worker.onmessage,null);
});
