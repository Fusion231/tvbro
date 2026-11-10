// Existing QA server; real packaged Worker/core/gzip, synthetic native disk IO.
async (page) => {
  const origin=new URL(page.url()).origin;
  if(new URL(origin).hostname!=='127.0.0.1')throw Error('Loopback QA required');
  await page.goto(origin);
  await page.locator('#language-view').waitFor({state:'visible'});
  return page.evaluate(async origin=>{
    const bytes=new Uint8Array(await (await fetch(origin+'/fixture/guide.xml')).arrayBuffer());
    if(bytes[0]!==31||bytes[1]!==139)throw Error('Expected raw gzip fixture');
    let saved=null,downloads=0,reads=0,largest=0,commits=0;
    const bridge=window.TVBroSamsungSourceWorker.create(window,{mergeCooldowns:async()=>{},epgDiskAvailable:()=>true});
    const config={id:'native-disk-browser',kind:'m3u',fields:{playlistUrl:origin+'/fixture/playlist.m3u',epgUrl:origin+'/fixture/guide.xml'}};
    async function transport(raw) {
      const request=JSON.parse(raw),op=request.epgFile;
      if(op) {
        if(op.action==='lookup')return JSON.stringify(saved);
        if(op.action==='read') {
          if(op.count>65536)throw Error('Unbounded native read');
          const chunk=bytes.slice(op.offset,op.offset+op.count);reads++;largest=Math.max(largest,chunk.length);
          return {bodyBuffer:chunk.buffer,eof:op.offset+chunk.length===bytes.length};
        }
        if(op.action==='commit'){saved={token:'epg_browser_1.bin',size:bytes.length,at:Date.now()};commits++;return 'true';}
        return 'true';
      }
      if(request.workload==='epg') {
        if(request.maximumBodyBytes!==512*1024*1024||request.maximumDecodedBytes!==4096*1024*1024)throw Error('Wrong disk policy');
        downloads++;return JSON.stringify({status:200,headers:{},url:request.url,bodyFile:{token:'epg_browser_1.bin',size:bytes.length,at:Date.now()},decoded:true});
      }
      const response=await fetch(request.url);
      return JSON.stringify({status:response.status,headers:{},url:request.url,body:await response.text(),decoded:true});
    }
    let source=bridge.createSource(JSON.stringify(config),transport);
    try {
      const channels=await source.invoke('channels','{}');
      const args={channels:channels.slice(0,1),_tvEpgScope:'browser-profile'};
      const first=await source.invoke('epg',JSON.stringify(args));
      if(first.length!==3||commits!==1||downloads!==1)throw Error('Native disk guide did not parse/commit');
      await source.dispose();source=bridge.createSource(JSON.stringify(config),transport);
      const restored=await source.invoke('epg',JSON.stringify(args));
      if(restored.length!==3||downloads!==1)throw Error('A new worker failed to reuse the disk guide');
      return {status:'passed',programmes:restored.length,downloads,reads,largestRead:largest,commits,
        scope:'Packaged browser Worker, canonical parser and streaming gzip; simulated native file boundary, no physical TV qualification.'};
    } finally {await source.dispose();}
  },origin);
}
