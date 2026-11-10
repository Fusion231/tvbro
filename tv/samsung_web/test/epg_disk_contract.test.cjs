'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),vm=require('node:vm');
const coreFile=path.resolve(__dirname,'../../output/samsung-web/core/core.js');
const profile='local-profile',config={id:'disk-guide',kind:'m3u',fields:{playlistUrl:'https://disk-guide.fixture/list',epgUrl:'https://disk-guide.fixture/guide'}};
const target='<programme channel="target" start="20261107100000 +0000" stop="20261107110000 +0000"><title>Disk guide</title></programme>';
const args={channels:[{id:'target',name:'Target',extra:{tvgId:'target'}}],_tvEpgDisk:true,_tvEpgScope:profile};
function fixture(file) {
  const cache=new Map(),pending=new Map(),calls={network:0,reads:0,largestRead:0,commits:0,releases:0,discarded:0};
  let serial=0,offline=false,offset=0,downloadFile=file;
  const descriptor=record=>record&&({token:record.token,size:record.size,at:record.at});
  function create() {
    const sandbox={console,setTimeout,clearTimeout,TextEncoder,TextDecoder,btoa,atob};sandbox.self=sandbox.window=sandbox;
    sandbox.Date=class extends Date {constructor(...values){super(...(values.length?values:[Date.now()+offset]));}static now(){return Date.now()+offset;}};
    vm.createContext(sandbox);
    if(fs.existsSync(path.resolve(__dirname,'../platform/streaming_gzip.js'))) {
      sandbox.pako=require('pako');vm.runInContext(fs.readFileSync(path.resolve(__dirname,'../platform/streaming_gzip.js'),'utf8'),sandbox);
    }
    vm.runInContext(fs.readFileSync(coreFile,'utf8'),sandbox);
    const source=sandbox.TVBroCanonical.createSource(JSON.stringify(config),async raw=>{
      const request=JSON.parse(raw),op=request.epgFile;
      if(op) {
        if(op.action==='lookup')return JSON.stringify(descriptor(cache.get(op.key))||null);
        const record=[...cache.values(),...pending.values()].find(row=>row.token===op.token);
        assert.ok(record,'file operations require an owned token');
        if(op.action==='read') {
          assert.ok(op.count<=65536);const size=Math.min(op.count,record.size-op.offset),bytes=Buffer.alloc(size),fd=fs.openSync(record.file,'r');
          try {assert.equal(fs.readSync(fd,bytes,0,size,op.offset),size);}finally{fs.closeSync(fd);}
          calls.reads++;calls.largestRead=Math.max(calls.largestRead,size);
          return JSON.stringify({bodyBase64:bytes.toString('base64'),eof:op.offset+size===record.size});
        }
        if(op.action==='commit'){cache.set(record.key,record);pending.delete(record.key);calls.commits++;return 'true';}
        if(op.action==='release'){calls.releases++;return 'true';}
        if(op.action==='discard'){pending.delete(record.key);calls.discarded++;return 'true';}
        throw Error('Unknown file operation');
      }
      if(request.workload!=='epg')return JSON.stringify({status:200,headers:{},body:'#EXTM3U\n#EXTINF:-1 tvg-id="target",Target\nhttps://disk-guide.fixture/live.ts\n'});
      calls.network++;
      assert.equal(request.maximumBodyBytes,512*1024*1024,'disk ceiling must match Android');
      assert.equal(request.maximumDecodedBytes,4096*1024*1024);
      if(offline)return JSON.stringify({errorKind:'network',error:'offline'});
      assert.match(request.epgDiskKey,/^[a-f0-9]{64}$/);
      const record={key:request.epgDiskKey,token:'epg_'+(++serial)+'.bin',size:fs.statSync(downloadFile).size,at:Date.now()+offset,file:downloadFile};
      pending.set(record.key,record);
      return JSON.stringify({status:200,headers:{},url:request.url,bodyFile:descriptor(record),decoded:true});
    });
    return {source,invoke:async(method,input={})=>JSON.parse(await source.invoke(method,JSON.stringify(input)))};
  }
  return {create,calls,cache,pending,offline(value){offline=value;},advance(value){offset+=value;},file(value){downloadFile=value;}};
}
function guideFile(t,large=false) {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tvbro-disk-epg-')),file=path.join(dir,'guide.xml');
  t.after(()=>{
    assert.ok(fs.realpathSync(dir).startsWith(fs.realpathSync(os.tmpdir())+path.sep)&&path.basename(dir).startsWith('tvbro-disk-epg-'));
    fs.rmSync(dir,{recursive:true,force:true});
  });
  const fd=fs.openSync(file,'w');
  try {
    fs.writeSync(fd,'<tv><channel id="target"><display-name>Target</display-name></channel>'+target);
    if(large) {
      const block=Buffer.from(('<programme channel="other" start="20261107100000 +0000" stop="20261107110000 +0000"><title>'+('x'.repeat(300))+'</title></programme>').repeat(512));
      for(let total=0;total<40*1024*1024;total+=block.length)fs.writeSync(fd,block);
    }
    fs.writeSync(fd,'</tv>');
  } finally {fs.closeSync(fd);}
  return file;
}
test('a small native disk guide is parsed, committed and reopened offline by a new core',async t=>{
  const kit=fixture(guideFile(t)),first=kit.create();
  try {
    const result=await first.invoke('epg',args);
    assert.ok(Array.isArray(result),'disk-backed EPG must return programmes rather than an error');
    assert.equal(result[0].title,'Disk guide');assert.equal(kit.calls.commits,1);assert.ok(kit.calls.reads>0);
  }finally{await first.source.dispose();}
  kit.offline(true);const cold=kit.create();
  try {assert.equal((await cold.invoke('epg',args))[0].title,'Disk guide');assert.equal(kit.calls.network,1,'fresh raw disk cache survives process restart');}
  finally{await cold.source.dispose();}
});
test('a native XMLTV larger than 32 MiB stays file-backed and each read is bounded',async t=>{
  const kit=fixture(guideFile(t,true)),core=kit.create();
  try {
    const result=await core.invoke('epg',args);
    assert.equal(result.length,1);assert.equal(result[0].title,'Disk guide');
    assert.ok(kit.calls.reads>640);assert.ok(kit.calls.largestRead<=65536);assert.equal(kit.calls.commits,1);
  }finally{await core.source.dispose();}
});

test('an intentionally empty XMLTV document remains a valid committed guide',async t=>{
  const file=guideFile(t);fs.writeFileSync(file,'<?xml version="1.0"?><tv/>');
  const kit=fixture(file),core=kit.create();
  try {assert.deepEqual(await core.invoke('epg',args),[]);assert.equal(kit.calls.commits,1);}
  finally{await core.source.dispose();}
});

test('disk guide keys isolate profiles and an offline stale refresh retains the committed file',async t=>{
  const kit=fixture(guideFile(t)),first=kit.create();
  try {assert.equal((await first.invoke('epg',args))[0].title,'Disk guide');}finally{await first.source.dispose();}
  const second=kit.create();
  try {await second.invoke('epg',{...args,_tvEpgScope:'another-profile'});assert.equal(kit.cache.size,2);assert.equal(kit.calls.network,2);}
  finally{await second.source.dispose();}
  kit.advance(7*3600000);kit.offline(true);const stale=kit.create();
  try {
    assert.equal((await stale.invoke('epg',args))[0].title,'Disk guide');assert.equal(kit.calls.network,3);
    assert.equal((await stale.invoke('epg',{...args,to:'2026-11-07T13:00:00Z'}))[0].title,'Disk guide');
    assert.equal(kit.calls.network,3,'the original refusal deadline prevents repeat downloads');assert.equal(kit.calls.commits,2);
  }finally{await stale.source.dispose();}
});

async function compressed(file) {
  const output=file+'.gz';
  await require('node:stream/promises').pipeline(fs.createReadStream(file),require('node:zlib').createGzip(),fs.createWriteStream(output));
  return output;
}
test('a disk gzip expanding beyond 32 MiB streams through the canonical parser in a bounded heap',async t=>{
  const file=await compressed(guideFile(t,true)),kit=fixture(file),core=kit.create();
  try {
    const result=await core.invoke('epg',args);
    assert.equal(result.length,1);assert.equal(result[0].title,'Disk guide');assert.equal(kit.calls.commits,1);
    assert.ok(kit.calls.largestRead<=65536);
  }finally{await core.source.dispose();}
});

for(const damage of ['xml','empty','text','html','multiple-roots','crc','truncated'])test('invalid '+damage+' replacement never commits over the previous good disk guide',async t=>{
  const original=guideFile(t),kit=fixture(original),first=kit.create();
  try {assert.equal((await first.invoke('epg',args))[0].title,'Disk guide');}finally{await first.source.dispose();}
  const oldToken=[...kit.cache.values()][0].token;
  let broken=original+'.broken';
  if(['xml','empty','text','html','multiple-roots'].includes(damage)) {
    fs.writeFileSync(broken,{xml:'<tv><programme>',empty:'',text:'Access Denied',html:'<html><body>Provider error</body></html>','multiple-roots':'<tv/><tv/>'}[damage]);
  }
  else {
    broken=await compressed(original);const fd=fs.openSync(broken,'r+');
    try {
      const length=fs.fstatSync(fd).size;
      if(damage==='truncated')fs.ftruncateSync(fd,length-5);
      else {const byte=Buffer.alloc(1);fs.readSync(fd,byte,0,1,length-8);byte[0]^=1;fs.writeSync(fd,byte,0,1,length-8);}
    }finally{fs.closeSync(fd);}
  }
  kit.advance(7*3600000);kit.file(broken);const replacement=kit.create();
  try {
    const result=await replacement.invoke('epg',args);assert.equal(result.code,'epg_invalid_data');
    assert.equal(kit.calls.commits,1);assert.equal([...kit.cache.values()][0].token,oldToken);
    assert.equal(kit.pending.size,0,'failed parsing discards the incomplete generation');
    kit.offline(true);assert.equal((await replacement.invoke('epgCached',args))[0].title,'Disk guide');
  }finally{await replacement.source.dispose();}
});
