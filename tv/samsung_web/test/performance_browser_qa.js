// playwright-cli run-code --filename, against ui_browser_server.cjs.
// Actual packaged facade, Worker, Dart sources and transport; synthetic HTTP/SDK.
async (page) => {
  const origin = new URL(page.url()).origin;
  if (new URL(origin).hostname !== '127.0.0.1') throw Error('Loopback QA server required');
  const requests = [], errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const playlist = '#EXTM3U\n' + Array.from({length:10000},(_,i)=>
    '#EXTINF:-1 group-title="Group '+(i%20)+'",Channel '+i+'\n'+origin+'/fixture/live/'+i+'.m3u8\n').join('');
  await page.route('**/*', route => {
    const url = new URL(route.request().url());
    if (url.origin !== origin) return route.abort();
    if (url.pathname === '/fixture/performance.m3u') {
      requests.push('playlist');
      return route.fulfill({status:200,contentType:'text/plain',body:playlist});
    }
    if (url.pathname === '/player_api.php') requests.push(url.searchParams.get('action') || 'auth');
    return route.continue();
  });
  await page.goto(origin);
  await page.locator('#language-view').waitFor({state:'visible'});
  await page.evaluate(async origin=>{
    const api=window.TVBroSamsungPlatform;
    await api.query('profiles.create',{name:'Performance QA'});
    await api.query('sources.add',{config:{id:'performance-live',kind:'m3u',label:'10k channels',fields:{playlistUrl:origin+'/fixture/performance.m3u'},settings:{}}});
  },origin);
  await page.evaluate(() => {
    window.__perf = {frames:[],longTasks:[],started:performance.now(),running:true};
    let last=performance.now();
    function frame(now) { window.__perf.frames.push(now-last);last=now;if(window.__perf.running)requestAnimationFrame(frame); }
    requestAnimationFrame(frame);
    window.__perf.observer=new PerformanceObserver(list=>window.__perf.longTasks.push(...list.getEntries().map(entry=>entry.duration)));
    window.__perf.observer.observe({entryTypes:['longtask']});
  });
  const channelCount=await page.evaluate(async()=> (await window.TVBroSamsungPlatform.query('sources.load',{id:'performance-live'})).channels.length);
  if(channelCount!==10000) throw Error('Incomplete catalog');
  const sourceLoadMs=await page.evaluate(()=>performance.now()-window.__perf.started);
  const catalog=await page.evaluate(async()=>{
    const api=window.TVBroSamsungPlatform, sources=await api.query('sources.list');
    const start=performance.now();
    for(let i=0;i<20;i++) await api.query('sources.load',{id:sources[0].id});
    return {warm20Ms:performance.now()-start};
  });
  if(requests.filter(value=>value==='playlist').length!==1) throw Error('Warm catalog repeated playlist download');
  const movie=await page.evaluate(async origin=>{
    const api=window.TVBroSamsungPlatform;
    await api.query('sources.add',{config:{id:'performance-vod',kind:'xtream',label:'VOD QA',fields:{host:origin,username:'fixture-user',password:'fixture-pass'},settings:{}}});
    await api.query('sources.load',{id:'performance-vod'});
    const item=(await api.query('catalog.items',{kind:'movie',categoryId:'movies',page:1})).items[0];
    await api.query('media.details',{item});
    return item;
  },origin);
  const detailsBefore=requests.filter(value=>value==='get_vod_info').length;
  const metadata=await page.evaluate(async item=>{
    const api=window.TVBroSamsungPlatform;
    const start=performance.now();
    for(let i=0;i<30;i++) await api.query('media.details',{item});
    await Promise.all(Array.from({length:30},()=>api.query('media.details',{item})));
    return {warm60Ms:performance.now()-start};
  },movie);
  const detailsAfter=requests.filter(value=>value==='get_vod_info').length;
  if(detailsAfter!==detailsBefore) throw Error('Warm details repeated provider requests: '+JSON.stringify({detailsBefore,detailsAfter,requests}));
  const metrics=await page.evaluate(()=>{
    window.__perf.running=false;window.__perf.observer.disconnect();
    const frames=window.__perf.frames.sort((a,b)=>a-b);
    return {frameGapP95Ms:frames[Math.floor(frames.length*.95)],maxFrameGapMs:frames[frames.length-1],longTasks:window.__perf.longTasks};
  });
  await page.evaluate(()=>window.TVBroSamsungPlatform.query('sources.cancel'));
  if(errors.length) throw Error(errors.join('; '));
  return {status:'passed',channels:10000,sourceLoadMs,...catalog,...metadata,...metrics,
    playlistDownloads:requests.filter(value=>value==='playlist').length,
    movieDetailsDownloads:detailsAfter,warmMovieDetailsDownloads:detailsAfter-detailsBefore,browserErrors:errors,
    scope:'Host Chrome with actual Samsung source Worker and synthetic SDK/HTTP; not physical TV performance.'};
}
