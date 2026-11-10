'use strict';
// Preserves the gzip-memory fix shipped in the supplied 0.1.31 WGT.
const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const zlib = require('node:zlib');
if (isMainThread) {
  (async () => {
    const row = i => '<programme channel="' + (i < 24 ? 'target' : 'other') + '" start="20261020100000 +0000" stop="20261020110000 +0000"><title>Programme</title><desc>' + 'x'.repeat(80) + '</desc></programme>';
    const xml = '<tv><channel id="target"><display-name>Target</display-name></channel>' + Array.from({length:120000}, (_,i) => row(i)).join('') + '</tv>';
    const bytes = Buffer.from(xml), gzip = zlib.gzipSync(bytes);
    for (const mode of ['plain', 'gzip', 'invalid-crc', 'decoded-size-limit']) {
      let body = mode === 'plain' ? bytes : Buffer.from(gzip);
      if (mode === 'invalid-crc') body[body.length - 8] ^= 1;
      if (mode === 'decoded-size-limit') body = zlib.gzipSync(Buffer.from(xml.replace('</tv>', '') + xml + '</tv>'));
      const result = await new Promise((resolve, reject) => {
        const worker = new Worker(__filename, { workerData:{output:path.resolve(process.argv[2]),body}, resourceLimits:{maxOldGenerationSizeMb:128} });
        const timer = setTimeout(() => { worker.terminate(); reject(Error('EPG fixture timed out')); },60000);
        worker.once('message', value => { clearTimeout(timer); resolve(value); });
        worker.once('error', error => { clearTimeout(timer); reject(error); });
        worker.once('exit', code => { if (code) { clearTimeout(timer); reject(Error('EPG worker exited: '+code)); } });
      });
      if (mode === 'plain' || mode === 'gzip') assert.equal(result.programmes,24,JSON.stringify(result));
      else assert.equal(result.error,'epg_invalid_data',JSON.stringify(result));
      console.log(JSON.stringify({mode,...result,heapLimitMiB:128}));
    }
  })().catch(error => { console.error(error); process.exitCode=1; });
} else {
  (async () => {
    const sandbox={console,setTimeout,clearTimeout,TextEncoder,TextDecoder};sandbox.window=sandbox.self=sandbox;vm.createContext(sandbox);
    const file=fs.existsSync(path.join(workerData.output,'core.js'))?'core.js':'canonical-core.js';
    vm.runInContext(fs.readFileSync(path.join(workerData.output,file),'utf8'),sandbox);
    const config={id:'epg-memory',kind:'m3u',fields:{playlistUrl:'https://fixture.invalid/list',epgUrl:'https://fixture.invalid/guide'}};
    const source=sandbox.TVBroCanonical.createSource(JSON.stringify(config),async raw=>{
      const request=JSON.parse(raw);
      return JSON.stringify({status:200,headers:{},url:request.url,decoded:true,
        ...(request.workload==='epg'?{bodyBase64:Buffer.from(workerData.body).toString('base64')}:{body:'#EXTM3U\n#EXTINF:-1 tvg-id="target",Target\nhttps://fixture.invalid/live/1.ts\n'})});
    });
    const invoke=async(method,args={})=>JSON.parse(await source.invoke(method,JSON.stringify(args)));
    try {
      const channels=await invoke('channels'),result=await invoke('epg',{channels});
      parentPort.postMessage(Array.isArray(result)?{programmes:result.length}:{error:result.code});
    } finally { await source.dispose(); }
  })().catch(()=>{parentPort.postMessage({error:'source-error'});process.exitCode=1;});
}
