'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {create} = require('../platform/backup_files.js');

function fixture() {
  const files = new Map(), calls = [], streams = [];
  const root = 'removable_sda1';
  let failWrite = false;
  function missing() { const error = Error('Missing file'); error.name = 'NotFoundError'; throw error; }
  const directory = {fullPath:root,isDirectory:true,readOnly:false,
    resolve(name) { return files.get(root+'/'+name) || missing(); },
    listFiles(ok) { queueMicrotask(()=>ok([...files.values()])); },
    createFile(name) { return file(root+'/'+name,Buffer.alloc(0)); },
    deleteFile(path,ok) { calls.push(['delete',path]); files.delete(path); queueMicrotask(ok); }
  };
  function file(path,bytes) {
    const value={fullPath:path,name:path.split('/').at(-1),isDirectory:false,isFile:true,bytes:Buffer.from(bytes),
      get fileSize() { return this.sizeOverride==null?this.bytes.length:this.sizeOverride; },
      openStream(mode,ok) {
        calls.push(['open',path,mode]); let position=0;
        if (mode==='w') value.bytes=Buffer.alloc(0);
        const stream={closed:false,
          get bytesAvailable() { return value.availableOverride==null?(position===value.bytes.length?-1:value.bytes.length-position):value.availableOverride; },
          get eof() { return position===value.bytes.length; },
          readBase64(count) { calls.push(['read',count]); const row=value.bytes.subarray(position,position+count);position+=row.length;return row.toString('base64'); },
          writeBase64(encoded) { const bytes=Buffer.from(encoded,'base64');calls.push(['write',bytes.length]);if(failWrite)throw Error('Disk full');value.bytes=Buffer.concat([value.bytes,bytes]);position+=bytes.length; },
          close() { stream.closed=true;calls.push(['close',path]); }
        };
        streams.push(stream); queueMicrotask(()=>ok(stream));
      }
    };
    files.set(path,value);return value;
  }
  const environment={setTimeout,clearTimeout,atob,btoa,tizen:{filesystem:{
    resolve(path,ok,no,mode) { calls.push(['resolve',path,mode]);queueMicrotask(()=>{if(path===root)ok(directory);else if(files.has(path))ok(files.get(path));else no(Object.assign(Error('Missing'),{name:'NotFoundError'}));}); },
    listStorages(ok) { queueMicrotask(()=>ok([{label:root,state:'MOUNTED',type:'EXTERNAL'},{label:'gone',state:'REMOVED',type:'EXTERNAL'}])); }
  }}};
  return {environment,calls,files,streams,directory,file,api:create({environment}),failWrite() {failWrite=true;}};
}

test('backup files are transferred as exact binary chunks and written only to the chosen folder',async()=>{
  const kit=fixture(),bytes=Uint8Array.from({length:100003},(_,i)=>i%256);
  assert.deepEqual(kit.api.capabilities(),{import:true,export:true});
  assert.deepEqual(await kit.api.listStorages(),[{label:'removable_sda1',state:'MOUNTED',type:'EXTERNAL'}]);
  assert.deepEqual(await kit.api.saveExport(bytes,'TVBro-2026-10-26.tvbro','removable_sda1'),{path:'removable_sda1/TVBro-2026-10-26.tvbro'});
  assert.deepEqual(await kit.api.chooseImport('removable_sda1/TVBro-2026-10-26.tvbro'),bytes);
  assert.equal(kit.streams.every(stream=>stream.closed),true);
  assert.ok(kit.calls.filter(call=>call[0]==='read'||call[0]==='write').every(call=>call[1]<=32768));
  await assert.rejects(kit.api.saveExport(bytes,'TVBro-2026-10-26.tvbro','removable_sda1'),{code:'backup_exists'});
  assert.equal(kit.calls.filter(call=>call[0]==='delete').length,0,'existing user files are never removed');
});

test('backup file access rejects oversized input, remote paths, traversal, unsafe names and non-byte values',async()=>{
  const kit=fixture();
  for(const location of ['https://example.test/backup.tvbro','data:application/octet-stream,hello','content://external/backup.tvbro',
    'file://remote/path.tvbro','removable_sda1/../backup.tvbro','removable_sda1/%2e%2e/backup.tvbro','removable_sda1/%252e%252e/backup.tvbro']) {
    await assert.rejects(kit.api.chooseImport(location),{code:'backup_path_invalid'});
  }
  assert.equal(kit.calls.length,0);
  for(const name of ['../backup.tvbro','folder/name.tvbro','backup.txt','backup\u0000.tvbro']) await assert.rejects(kit.api.saveExport([1],name,'removable_sda1'),{code:'backup_name_invalid'});
  await assert.rejects(kit.api.saveExport([256],'backup.tvbro','removable_sda1'),{code:'backup_invalid'});
  await assert.rejects(kit.api.saveExport({length:32*1024*1024+1},'backup.tvbro','removable_sda1'),{code:'backup_size_limit'});
  const huge=kit.file('removable_sda1/huge.tvbro',[1]);huge.sizeOverride=32*1024*1024+1;
  await assert.rejects(kit.api.chooseImport(huge.fullPath),{code:'backup_size_limit'});
  assert.equal(kit.streams.length,0,'oversized files are rejected before allocation or stream opening');
});

test('failed native writes remove only their newly created incomplete file and reads detect growth',async()=>{
  const kit=fixture();kit.file('removable_sda1/keep.tvbro',[4,5]);kit.failWrite();
  await assert.rejects(kit.api.saveExport([1,2,3],'failed.tvbro','removable_sda1'),/Disk full/);
  assert.equal(kit.files.has('removable_sda1/failed.tvbro'),false);
  assert.equal(kit.files.has('removable_sda1/keep.tvbro'),true);
  assert.equal(kit.streams.at(-1).closed,true);
  const growing=kit.file('removable_sda1/growing.tvbro',[1,2,3]);growing.sizeOverride=2;
  await assert.rejects(kit.api.chooseImport(growing.fullPath),{code:'backup_size_limit'});
  assert.equal(kit.streams.at(-1).closed,true);
});

test('directory listing is bounded, filters backup files and provides native local paths',async()=>{
  const kit=fixture();kit.file('removable_sda1/not-a-backup.mp4',[1]);
  for(let i=0;i<250;i++)kit.file('removable_sda1/backup-'+i+'.tvbro',[i]);
  const result=await kit.api.listDirectory('removable_sda1');
  assert.equal(result.path,'removable_sda1');assert.equal(result.entries.length,200);assert.equal(result.truncated,true);
  assert.deepEqual(result.entries[0],{name:'backup-0.tvbro',path:'removable_sda1/backup-0.tvbro',isDirectory:false,size:1});
});

test('native picker observes its selected reply, with explicit cancellation and fallback when unavailable',async()=>{
  const kit=fixture();kit.file('removable_sda1/picked.tvbro',[1,2,3]);
  let reply;
  kit.environment.tizen.ApplicationControl=function(operation,uri,mime) {this.operation=operation;this.uri=uri;this.mime=mime;};
  kit.environment.tizen.application={launchAppControl(control,id,ok,no,value) {
    assert.equal(control.operation,'http://tizen.org/appcontrol/operation/pick');assert.equal(control.mime,'application/octet-stream');
    reply=value;ok();
  }};
  const opening=kit.api.chooseImport();
  reply.onsuccess([{key:'http://tizen.org/appcontrol/data/selected',value:['removable_sda1/picked.tvbro']}]);
  assert.deepEqual(await opening,new Uint8Array([1,2,3]));
  const cancelled=kit.api.chooseImport();reply.onfailure();await assert.rejects(cancelled,{code:'backup_cancelled'});
  kit.environment.tizen.application.launchAppControl=(control,id,ok,no)=>no(Error('No matching application'));
  await assert.rejects(kit.api.chooseImport(),{code:'backup_path_required'});
  await assert.rejects(kit.api.saveExport([1],'backup.tvbro'),{code:'backup_path_required'});
  assert.deepEqual(create({environment:{}}).capabilities(),{import:false,export:false});
});
