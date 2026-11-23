'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const vm = require('node:vm');
const fs = require('node:fs');
const bridge = require('../platform/source_worker.js');
const workerScript = fs.readFileSync(require.resolve('../platform/source_worker.js'), 'utf8');

function workerEnvironment(invoke, messages) {
  class Worker {
    constructor() {
      const scope = {
        importScripts() {},
        TVBroCanonical: {providerGateInit: async () => {}, createSource: (_config, transport, reportProgress) => ({
          async invoke() { return JSON.stringify(await invoke(await transport('{}'), reportProgress)); }
        })},
        postMessage: value => {
          const data = structuredClone(value);
          if (messages) messages.push(data);
          queueMicrotask(() => this.onmessage?.({data}));
        }
      };
      scope.self = scope;
      vm.runInNewContext(workerScript, scope);
      this.scope = scope;
    }
    postMessage(value, transfer) {
      const data = structuredClone(value, {transfer});
      queueMicrotask(() => this.scope.onmessage({data}));
    }
    terminate() {}
  }
  return {Worker,setTimeout,clearTimeout};
}

test('the source worker pulls only the playlist bytes it consumes and closes the response', async () => {
  let reads = 0, close;
  const closed = new Promise(resolve => { close = resolve; });
  const app = bridge.create(workerEnvironment(async response => {
    const first = await response.bodyStream.next();
    response.bodyStream.close();
    return {status:JSON.parse(response.metadata).status, bytes:Array.from(first)};
  }));
  const source = app.createSource('{}', async () => ({status:200,url:'https://streams.invalid/list',bodyStream:{
    async next() { reads++; return new Uint8Array([35,69,88,84]); },
    close
  }}));
  assert.deepEqual(await source.invoke('connect','{}'),{status:200,bytes:[35,69,88,84]});
  await closed;
  assert.equal(reads,1);
  await source.dispose();
});

test('disposing the source closes an in-flight playlist read', async () => {
  let initialRead, close;
  const reading = new Promise(resolve => { initialRead = resolve; });
  const closed = new Promise(resolve => { close = resolve; });
  const app = bridge.create(workerEnvironment(response => response.bodyStream.next()));
  const source = app.createSource('{}', async () => ({status:200,url:'https://streams.invalid/list',bodyStream:{
    next() { initialRead(); return closed.then(() => null); },
    close
  }}));
  const invoked = source.invoke('connect','{}');
  await Promise.race([reading,invoked]);
  await source.dispose();
  await assert.rejects(invoked,{name:'AbortError'});
  await closed;
});

test('import stages cross the worker boundary without provider data or events from a disposed source', async () => {
  const messages = [], stages = [];
  let workerProgress, transportProgress;
  const app = bridge.create(workerEnvironment((_response, reportProgress) => {
    if (reportProgress) {
      workerProgress = reportProgress;
      reportProgress('processing');
      reportProgress('https://private.invalid/customer-password');
    }
    return {usable:true};
  }, messages));
  const source = app.createSource('{}', async (_request, options) => {
    transportProgress = options.onImportProgress;
    transportProgress?.('waiting');
    transportProgress?.('downloading');
    transportProgress?.({stage:'processing'});
    return '{}';
  }, stage => stages.push(stage));
  const other = app.createSource('{}', async () => '{}');
  assert.deepEqual(await source.invoke('connect','{}'), {usable:true});
  assert.deepEqual(stages, ['waiting','downloading','processing']);
  assert.deepEqual(messages.filter(message => message.type === 'importProgress'), [
    {type:'importProgress',source:1,stage:'processing'}
  ]);
  await source.dispose();
  transportProgress('downloading');
  workerProgress('saving');
  await other.invoke('connect','{}');
  assert.deepEqual(stages, ['waiting','downloading','processing']);
  assert.equal(messages.filter(message => message.type === 'importProgress').length, 1);
  await other.dispose();
});
