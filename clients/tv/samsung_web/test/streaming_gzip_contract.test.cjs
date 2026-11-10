'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),zlib=require('node:zlib');
let create;
try {create=require('../platform/streaming_gzip.js').create;}catch(error){if(error.code!=='MODULE_NOT_FOUND')throw error;}
function decode(body,maximum=64*1024*1024) {
  assert.equal(typeof create,'function');const push=create(maximum),chunks=[];let peak=0,result;
  for(let offset=0;offset<body.length;offset+=1024) {
    result=JSON.parse(push(body.subarray(offset,offset+1024).toString('base64'),false));
    if(result.error)return result;
    const batch=result.chunks.map(value=>Buffer.from(value,'base64'));peak=Math.max(peak,batch.reduce((sum,chunk)=>sum+chunk.length,0));
    chunks.push(...batch);
  }
  result=JSON.parse(push('',true));if(result.error)return result;
  chunks.push(...result.chunks.map(value=>Buffer.from(value,'base64')));
  return {body:Buffer.concat(chunks),peak,ended:result.ended};
}
test('gzip streaming roundtrips without retaining full inflater output',()=>{
  const original=Buffer.from('Program Łódź\n'.repeat(2000)),body=zlib.gzipSync(original);
  const result=decode(body);assert.equal(result.error,undefined);assert.deepEqual(result.body,original);assert.equal(result.ended,true);
});
for(const kind of ['crc','size','truncated','garbage','zero-padding'])test('streamed gzip rejects '+kind,()=>{
  let body=zlib.gzipSync(Buffer.from('programme'.repeat(1000)));
  if(kind==='crc')body[body.length-8]^=1;
  if(kind==='size')body[body.length-4]^=1;
  if(kind==='truncated')body=body.subarray(0,body.length-5);
  if(kind==='garbage')body=Buffer.concat([body,Buffer.from('invalid trailing body')]);
  if(kind==='zero-padding')body=Buffer.concat([body,Buffer.from([0,0])]);
  assert.equal(decode(body).error,'invalid-gzip');
});
test('decoded work limit interrupts expansion and oversized compressed pushes are rejected',()=>{
  const body=zlib.gzipSync(Buffer.alloc(1024*1024));assert.equal(decode(body,100000).error,'limit');
  const push=create(1024*1024);assert.equal(JSON.parse(push(Buffer.alloc(1025).toString('base64'),false)).error,'invalid-gzip');
});
test('concatenated gzip members are validated even across separate pushes',()=>{
  const a=zlib.gzipSync(Buffer.from('one')),b=zlib.gzipSync(Buffer.from('two')),push=create(1024);
  const first=JSON.parse(push(a.toString('base64'),false)),second=JSON.parse(push(b.toString('base64'),false)),end=JSON.parse(push('',true));
  assert.equal(first.error,undefined);assert.equal(second.error,undefined);assert.equal(end.ended,true);
  assert.equal(Buffer.concat([...first.chunks,...second.chunks,...end.chunks].map(value=>Buffer.from(value,'base64'))).toString(),'onetwo');
});
test('a 40 MiB expansion is emitted in bounded batches without accumulating a result',()=>{
  const body=zlib.gzipSync(Buffer.alloc(40*1024*1024,120),{level:9}),push=create(64*1024*1024);
  let size=0,peak=0;
  for(let offset=0;offset<body.length;offset+=1024) {
    const value=JSON.parse(push(body.subarray(offset,offset+1024).toString('base64'),false));assert.equal(value.error,undefined);
    let batch=0;for(const encoded of value.chunks){const count=Buffer.byteLength(encoded,'base64');assert.ok(count<=32768);batch+=count;}
    size+=batch;peak=Math.max(peak,batch);
  }
  const end=JSON.parse(push('',true));assert.equal(end.ended,true);assert.equal(size,40*1024*1024);assert.ok(peak<=2*1024*1024);
});
