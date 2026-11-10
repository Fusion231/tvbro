// playwright-cli run-code --filename against ui_browser_server.cjs.
// A fresh real Worker must restore serialized cache with the provider offline.
async (page) => {
  await page.unrouteAll();
  const origin = new URL(page.url()).origin;
  if (new URL(origin).hostname !== '127.0.0.1') throw Error('Loopback QA required');
  await page.goto(origin);
  await page.locator('#language-view').waitFor({state:'visible'});
  return page.evaluate(async origin => {
    let offline = false;
    const requests = [];
    const worker = window.TVBroSamsungSourceWorker.create(window, {mergeCooldowns: async () => {}});
    const config = {id:'durable-worker',kind:'m3u',label:'Worker cache',fields:{
      playlistUrl:origin+'/fixture/playlist.m3u',epgUrl:origin+'/fixture/guide.xml'
    },settings:{}};
    const transport = async raw => {
      const request = JSON.parse(raw); requests.push(new URL(request.url).pathname);
      if (offline) throw Error('Provider offline');
      const response = await fetch(request.url);
      const bytes=new Uint8Array(await response.arrayBuffer());
      let binary='';for(const byte of bytes)binary+=String.fromCharCode(byte);
      return {status:response.status,bodyBase64:btoa(binary),url:request.url,headers:{},decoded:true};
    };
    const invoke = (source, method, args = {}) => source.invoke(method, JSON.stringify(args));
    const scope = 'local:worker-qa';
    let source = worker.createSource(JSON.stringify(config), transport);
    try {
      await invoke(source, 'connect'); await invoke(source, 'categories');
      const channels = await invoke(source, 'channels');
      const now = Date.now(), from = new Date(now - 2*3600000).toISOString();
      const guide = await invoke(source, 'epg', {channels,from,to:new Date(now + 2*3600000).toISOString()});
      if (channels.length !== 161 || guide.length !== 3) throw Error('Incomplete provider fixture');
      const catalog = await invoke(source, 'exportCatalog', {scope});
      const guideSnapshot = await invoke(source, 'exportGuide', {scope});
      await source.dispose(); offline = true;
      source = worker.createSource(JSON.stringify(config), transport);
      if (await source.restoreGuide('local:other-owner', guideSnapshot)) throw Error('Guide leaked between profiles');
      if (await source.restoreGuide(scope, guideSnapshot.slice(0,-4))) throw Error('Corrupt guide was accepted');
      if (!await source.restoreCatalog(scope, catalog)) throw Error('Cold catalogue restore failed');
      if (!await source.restoreGuide(scope, guideSnapshot)) throw Error('Cold guide restore failed');
      const before = requests.length;
      if ((await invoke(source, 'channels')).length !== 161) throw Error('Lost cold channels');
      const restored = await invoke(source, 'epg', {channels,from,to:new Date(now + 3*3600000).toISOString()});
      if (restored.length !== guide.length) throw Error('Different guide window lost raw cached feed');
      if (requests.length !== before) throw Error('Cold cache contacted offline provider');
      return {status:'passed',coldProviderRequests:requests.length-before,channels:161,programmes:restored.length,
        corruptGuideRejected:true,profileIsolation:true,
        scope:'Actual packaged Dart source in two browser Workers; serialized storage boundary, synthetic provider. Not TV restart proof.'};
    } finally { await source.dispose(); }
  }, origin);
}
