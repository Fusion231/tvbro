'use strict';
// Run after core_builder/build.ps1: node core_builder/test_guide_state.cjs <core-output>
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const output = path.resolve(process.argv[2]);
const initialAt = Date.parse('2026-11-08T10:00:00Z');
const body = '<tv><channel id="target"><display-name>Target</display-name></channel>' +
  '<programme channel="target" start="20261108100000 +0000" stop="20261108110000 +0000"><title>Guide</title></programme></tv>';
const bodyBytes = Buffer.from(body);
const config = {id:'guide-state-fixture',kind:'m3u',fields:{playlistUrl:'https://fixture.invalid/list',epgUrl:'https://fixture.invalid/guide'}};

function engine(clock, disk) {
  const files = disk.files, pending = disk.pending;
  const counters = disk.counters;
  class TestDate extends Date {
    constructor(...args) { super(...(args.length ? args : [clock.value])); }
    static now() { return clock.value; }
  }
  const sandbox = {console,setTimeout,clearTimeout,TextEncoder,TextDecoder,Date:TestDate,atob,btoa};
  sandbox.window = sandbox.self = sandbox;
  vm.createContext(sandbox);
  const file = fs.existsSync(path.join(output,'core.js')) ? 'core.js' : 'canonical-core.js';
  vm.runInContext(fs.readFileSync(path.join(output,file),'utf8'),sandbox);
  const source = sandbox.TVBroCanonical.createSource(JSON.stringify(config),async raw=>{
    const request = JSON.parse(raw), op = request.epgFile;
    if(op) {
      if(op.action==='lookup') return JSON.stringify(files.get(op.key)||null);
      const record = [...files.values(),...pending.values()].find(value=>value.token===op.token);
      assert.ok(record,'native guide file operation uses an owned token');
      if(op.action==='read') {
        const bytes=record.bytes.subarray(op.offset,op.offset+op.count);
        counters.reads++;
        return JSON.stringify({bodyBase64:bytes.toString('base64'),eof:op.offset+bytes.length===record.size});
      }
      if(op.action==='commit') { files.set(record.key,record);pending.delete(record.key);counters.commits++;return 'true'; }
      if(op.action==='discard') { pending.delete(record.key);return 'true'; }
      if(op.action==='release') return 'true';
      throw Error('Unknown guide-file action '+op.action);
    }
    if(request.workload!=='epg') throw Error('Unexpected provider workload '+request.workload);
    counters.requests++;
    if(disk.offline) return JSON.stringify({errorKind:'network',error:'fixture offline'});
    if(!disk.enabled) return JSON.stringify({status:200,headers:{},url:request.url,body,decoded:true});
    const record={key:request.epgDiskKey,token:'epg_guide_state.bin',size:bodyBytes.length,at:clock.value,bytes:bodyBytes};
    pending.set(record.key,record);
    return JSON.stringify({status:200,headers:{},url:request.url,
      bodyFile:{token:record.token,size:record.size,at:record.at},decoded:true});
  });
  return {source,invoke:async(method,args={})=>JSON.parse(await source.invoke(method,JSON.stringify(args)))};
}
function diskState(enabled) {
  return {enabled,offline:false,files:new Map(),pending:new Map(),counters:{requests:0,reads:0,commits:0}};
}
function guideArgs(name='Target') {
  return {channels:[{id:'live-1',name,extra:{tvgId:'target'}}]};
}
async function memoryGuideState() {
  const clock={value:initialAt}, transport=diskState(false), core=engine(clock,transport);
  try {
    assert.deepEqual(await core.invoke('epgState'),{nextRefreshAt:null,retryAt:null});
    assert.ok(Array.isArray(await core.invoke('epg',guideArgs())));
    const first=await core.invoke('epgState');
    assert.deepEqual(first,{nextRefreshAt:initialAt+6*60*60*1000,retryAt:null});
    clock.value+=5*60*60*1000;
    await core.invoke('epg',guideArgs('Renamed Target'));
    assert.equal(transport.counters.requests,1,'a fresh memory guide is reused without a provider request');
    assert.deepEqual(await core.invoke('epgState'),first,'serving cached guide content must not extend its refresh deadline');
  } finally { await core.source.dispose(); }
}
async function diskGuideState() {
  const clock={value:initialAt}, transport=diskState(true), args={...guideArgs(),_tvEpgDisk:true,_tvEpgScope:'profile'};
  const first=engine(clock,transport);
  try {
    assert.ok(Array.isArray(await first.invoke('epg',args)));
    assert.deepEqual(await first.invoke('epgState'),{nextRefreshAt:initialAt+6*60*60*1000,retryAt:null});
    assert.equal(transport.counters.commits,1);
  } finally { await first.source.dispose(); }
  clock.value+=2*60*60*1000;
  const restored=engine(clock,transport);
  try {
    assert.ok(Array.isArray(await restored.invoke('epg',{...args,channels:guideArgs('Renamed Target').channels})));
    assert.equal(transport.counters.requests,1,'a fresh native disk guide is reused without a provider request');
    assert.deepEqual(await restored.invoke('epgState'),{nextRefreshAt:initialAt+6*60*60*1000,retryAt:null},
      'native guide state uses the stored previous.at instead of resetting freshness on read');
  } finally { await restored.source.dispose(); }
}
async function staleDiskRetryState() {
  const clock={value:initialAt}, transport=diskState(true), args={...guideArgs(),_tvEpgDisk:true,_tvEpgScope:'profile'};
  const first=engine(clock,transport);
  try { await first.invoke('epg',args); } finally { await first.source.dispose(); }
  clock.value+=7*60*60*1000;transport.offline=true;
  const stale=engine(clock,transport);
  try {
    assert.ok(Array.isArray(await stale.invoke('epg',{...args,channels:guideArgs('Stale fallback').channels})));
    const state=await stale.invoke('epgState');
    assert.equal(state.nextRefreshAt,initialAt+6*60*60*1000);
    assert.equal(state.retryAt,clock.value+15*60*1000,'stale fallback preserves the active network retry deadline');
  } finally { await stale.source.dispose(); }
}

async function main() {
  await memoryGuideState();
  await diskGuideState();
  await staleDiskRetryState();
  console.log('guide state: fetch-based freshness and retry deadlines passed');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
