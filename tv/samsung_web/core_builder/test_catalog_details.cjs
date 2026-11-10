'use strict';
// Run after core_builder/build.ps1: node core_builder/test_catalog_details.cjs <core-output>
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const zlib = require('node:zlib');

const output = path.resolve(process.argv[2]);
const config = {id:'details-fixture',kind:'xtream',label:'Details fixture',fields:{
  host:'https://fixture.invalid',username:'fixture-user',password:'fixture-pass'
}};
const requests = [];
let movieRevision = 0;
let largePlot = null;
function sourceRequestCount() {
  return requests.filter(value=>new URL(value).hostname==='fixture.invalid').length;
}
function route(url) {
  const action=url.searchParams.get('action');
  if(!action)return {user_info:{auth:1,status:'Active',exp_date:'4102444800'}};
  if(action==='get_live_categories')return [{category_id:'news',category_name:'News'}];
  if(action==='get_live_streams')return [{stream_id:11,name:'Live',category_id:'news'}];
  if(action==='get_vod_categories')return [{category_id:'movies',category_name:'Movies'}];
  if(action==='get_series_categories')return [{category_id:'series',category_name:'Series'}];
  if(action==='get_vod_streams')return [{stream_id:500,name:movieRevision?'Film revised':'Film',category_id:'movies',container_extension:'mp4'}];
  if(action==='get_series')return [{series_id:900,name:'Series',category_id:'series'}];
  if(action==='get_vod_info')return {info:{plot:largePlot??`Movie provider detail ${movieRevision}`}};
  if(action==='get_series_info')return {info:{plot:largePlot??'Series provider detail'},
    seasons:[{season_number:1,name:'Season 1'}],episodes:{'1':[{id:901,title:'Pilot',episode_num:1}]}};
  throw Error('Unexpected fixture action '+action);
}
function source(offline=false) {
  const sandbox={console,crypto:crypto.webcrypto,setTimeout,clearTimeout,TextEncoder,TextDecoder};
  sandbox.window=sandbox.self=sandbox;
  vm.createContext(sandbox);
  const file=fs.existsSync(path.join(output,'core.js'))?'core.js':'canonical-core.js';
  vm.runInContext(fs.readFileSync(path.join(output,file),'utf8'),sandbox);
  const engine=sandbox.TVBroCanonical.createSource(JSON.stringify(config),async raw=>{
    const request=JSON.parse(raw),url=new URL(request.url);
    requests.push(url.href);
    if(offline)return JSON.stringify({errorKind:'network',error:'offline fixture'});
    return JSON.stringify({status:200,body:JSON.stringify(route(url)),headers:{},url:request.url,decoded:true});
  });
  return {engine,invoke:async(method,args={})=>JSON.parse(await engine.invoke(method,JSON.stringify(args)))};
}
async function exportParts(origin) {
  const manifest=await origin.invoke('beginCatalogExport',{scope:'details-profile'});
  assert.ok(manifest&&manifest.parts.length>0);
  const parts=[];
  for(const descriptor of manifest.parts) {
    const part=await origin.invoke('exportCatalogPart',{index:descriptor.index});
    assert.equal(part.checksum,crypto.createHash('sha256').update(part.raw).digest('hex'));
    parts.push({raw:part.raw,checksum:part.checksum,descriptor:{...descriptor,bytes:part.bytes,checksum:part.checksum}});
  }
  manifest.parts=parts.map(part=>part.descriptor);
  return {manifest,parts};
}
async function importParts(target,snapshot) {
  await target.invoke('beginCatalogImport',{scope:'details-profile',manifest:snapshot.manifest});
  for(const part of snapshot.parts)await target.invoke('importCatalogPart',{
    index:part.descriptor.index,raw:part.raw,checksum:part.checksum
  });
  await target.invoke('commitCatalogImport');
}
function decodedPart(raw) {
  const envelope=JSON.parse(raw);
  return envelope.format==='gzip-json'
    ?JSON.parse(zlib.gunzipSync(Buffer.from(envelope.data,'base64')).toString('utf8'))
    :envelope;
}
function storedPart(value) {
  const raw=JSON.stringify(value),bytes=Buffer.from(raw),compressed=zlib.gzipSync(bytes);
  return compressed.length<bytes.length
    ?JSON.stringify({format:'gzip-json',decodedBytes:bytes.length,data:compressed.toString('base64')})
    :raw;
}

async function main() {
  const original=source(),restored=source(true),invalidTarget=source(true);
  try {
    await original.invoke('metadata.configure',{config:{},language:'eng'});
    await Promise.all(['live','movie','series'].map(kind=>original.invoke('prepareCatalog',{
      kind,refreshKey:'details-cold',forceRefresh:false
    })));
    const movie=(await original.invoke('allMediaItems',{kind:'movie'}))[0];
    const series=(await original.invoke('allMediaItems',{kind:'series'}))[0];
    assert.equal((await original.invoke('metadata.details',{item:movie})).description,'Movie provider detail 0');
    assert.equal((await original.invoke('metadata.details',{item:series})).description,'Series provider detail');
    const seasons=await original.invoke('mediaItems',{kind:'season',parent:series});
    assert.equal(seasons[0].title,'Season 1');
    const page=await original.invoke('mediaItemsPage',{kind:'episode',parent:seasons[0],page:1});
    assert.equal(page.items[0].title,'Pilot');

    movieRevision=1;
    await Promise.all(['live','movie','series'].map(kind=>original.invoke('prepareCatalog',{
      kind,refreshKey:'details-updated',forceRefresh:true
    })));
    const updatedMovie=(await original.invoke('allMediaItems',{kind:'movie'}))[0];
    assert.equal(updatedMovie.title,'Film revised');
    assert.equal((await original.invoke('metadata.details',{item:updatedMovie})).description,'Movie provider detail 1',
      'a changed root row must not reuse stale provider details with the same ID');
    const updatedSeries=(await original.invoke('allMediaItems',{kind:'series'}))[0];
    await original.invoke('metadata.details',{item:updatedSeries});
    const updatedSeasons=await original.invoke('mediaItems',{kind:'season',parent:updatedSeries});
    const updatedPage=await original.invoke('mediaItemsPage',{kind:'episode',parent:updatedSeasons[0],page:1});
    assert.equal(updatedPage.items[0].title,'Pilot');

    const saved=await exportParts(original),before=sourceRequestCount();
    const invalid={manifest:JSON.parse(JSON.stringify(saved.manifest)),parts:saved.parts.map(part=>({...part,
      descriptor:{...part.descriptor}}))};
    let corrupted=false;
    for(let index=0;index<invalid.parts.length&&!corrupted;index++) {
      const envelope=decodedPart(invalid.parts[index].raw);
      const chunk=envelope.records.find(record=>record.type==='mediaReadChunk');
      if(!chunk)continue;
      chunk.id=(chunk.id[0]==='f'?'e':'f')+chunk.id.slice(1);
      const raw=storedPart(envelope),checksum=crypto.createHash('sha256').update(raw).digest('hex');
      const descriptor={...invalid.parts[index].descriptor,bytes:Buffer.byteLength(raw),checksum};
      invalid.parts[index]={raw,checksum,descriptor};
      invalid.manifest.parts[index]=descriptor;
      corrupted=true;
    }
    assert.ok(corrupted,'fixture should export a bounded provider read');
    await invalidTarget.invoke('metadata.configure',{config:{},language:'eng'});
    await invalidTarget.invoke('beginCatalogImport',{scope:'details-profile',manifest:invalid.manifest});
    for(const part of invalid.parts)await invalidTarget.invoke('importCatalogPart',{
      index:part.descriptor.index,raw:part.raw,checksum:part.checksum
    });
    await assert.rejects(()=>invalidTarget.invoke('commitCatalogImport'));
    assert.deepEqual(await invalidTarget.invoke('catalogState'),{kinds:{
      live:{complete:false,count:0,syncedAt:null},movie:{complete:false,count:0,syncedAt:null},
      series:{complete:false,count:0,syncedAt:null}
    }},'a late optional-read validation error must not publish staged roots');

    await restored.invoke('metadata.configure',{config:{},language:'eng'});
    await importParts(restored,saved);
    assert.deepEqual(await restored.invoke('catalogState'),await original.invoke('catalogState'));
    assert.equal((await restored.invoke('metadata.details',{item:updatedMovie})).description,'Movie provider detail 1');
    assert.equal(sourceRequestCount(),before,'restored movie details do not reconnect to Xtream');
    assert.equal((await restored.invoke('metadata.details',{item:updatedSeries})).description,'Series provider detail');
    assert.equal(sourceRequestCount(),before,'restored series details do not reconnect to Xtream');
    const restoredSeasons=await restored.invoke('mediaItems',{kind:'season',parent:updatedSeries});
    assert.equal(restoredSeasons[0].title,'Season 1');
    assert.equal(sourceRequestCount(),before,'restored series seasons do not reconnect to Xtream');
    const restoredPage=await restored.invoke('mediaItemsPage',{kind:'episode',parent:restoredSeasons[0],page:1});
    assert.equal(restoredPage.items[0].title,'Pilot');
    assert.equal(sourceRequestCount(),before,'restored episode pages do not reconnect to Xtream');
    assert.equal(sourceRequestCount(),before,'restored provider details and visited series children stay offline');
  } finally {
    await original.engine.dispose();
    await restored.engine.dispose();
    await invalidTarget.engine.dispose();
  }
  largePlot='漢'.repeat(350_000);
  const oversized=source(),oversizedRestored=source(true);
  try {
    await oversized.invoke('metadata.configure',{config:{},language:'eng'});
    await Promise.all(['live','movie','series'].map(kind=>oversized.invoke('prepareCatalog',{
      kind,refreshKey:'unicode-read-budget',forceRefresh:false
    })));
    const movie=(await oversized.invoke('allMediaItems',{kind:'movie'}))[0];
    const series=(await oversized.invoke('allMediaItems',{kind:'series'}))[0];
    const requestsBeforeDetails=sourceRequestCount();
    assert.equal((await oversized.invoke('metadata.details',{item:movie})).description.length,350_000);
    const afterMovie=sourceRequestCount();
    assert.equal((await oversized.invoke('metadata.details',{item:series})).description.length,350_000);
    assert.equal(sourceRequestCount(),afterMovie+1,'both oversized detail reads fit the existing character cache');
    await oversized.invoke('metadata.details',{item:movie});
    assert.equal(sourceRequestCount(),afterMovie+1,'the oversized movie detail remains cached in memory');
    assert.equal(afterMovie,requestsBeforeDetails+1);
    const largeSnapshot=await exportParts(oversized);
    let readBytes=0;
    for(const part of largeSnapshot.parts)for(const record of decodedPart(part.raw).records)
      if(record.type==='mediaReadChunk')readBytes+=Buffer.from(record.data,'base64').length;
    assert.ok(readBytes>1024*1024&&readBytes<=4*1024*1024,
      'exported UTF-8 read chunks stay within the import aggregate bound while retaining a large detail');
    await oversizedRestored.invoke('metadata.configure',{config:{},language:'eng'});
    await importParts(oversizedRestored,largeSnapshot);
    assert.deepEqual(await oversizedRestored.invoke('catalogState'),await oversized.invoke('catalogState'),
      'optional-read truncation preserves complete primary catalog roots');
  } finally {
    await oversized.engine.dispose();
    await oversizedRestored.engine.dispose();
    largePlot=null;
  }
  console.log('catalog details: changed provider rows and bounded reads restore offline across Xtream movie and series');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
