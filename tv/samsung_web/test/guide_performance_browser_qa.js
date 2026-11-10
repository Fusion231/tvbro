// Run against ui_browser_server.cjs with playwright-cli run-code --filename.
// Add ?baseline=1 to the starting URL to collect the pre-fix operation counts.
async (page) => {
  const baseline = new URL(page.url()).searchParams.has('baseline');
  const origin = new URL(page.url()).origin;
  if (new URL(origin).hostname !== '127.0.0.1') throw Error('Loopback QA required');
  const downloads = {playlist:0,guide:0}, errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const stamp = value => new Date(value).toISOString().replace(/[-:TZ.]/g,'').slice(0,14)+' +0000';
  const now = Date.now();
  const playlist = '#EXTM3U url-tvg="'+origin+'/fixture/performance-guide.xml"\n'+
    Array.from({length:10000},(_,i) => '#EXTINF:-1 tvg-id="perf'+i+'" group-title="Group '+(i%20)+'",Channel '+i+'\n'+origin+'/fixture/live/'+i+'.m3u8\n').join('');
  const guide = '<tv>'+Array.from({length:200},(_,i) => '<channel id="perf'+i+'"><display-name>Channel '+i+'</display-name></channel>'+[-30,0,30].map((offset,j) =>
    '<programme channel="perf'+i+'" start="'+stamp(now+offset*60000)+'" stop="'+stamp(now+(offset+30)*60000)+'"><title>Programme '+i+' / '+j+'</title></programme>').join('')).join('')+'</tv>';
  await page.route('**/*', route => {
    const url = new URL(route.request().url());
    if (url.origin !== origin) return route.abort();
    if (url.pathname === '/fixture/performance.m3u') { downloads.playlist++; return route.fulfill({status:200,contentType:'text/plain',body:playlist}); }
    if (url.pathname === '/fixture/performance-guide.xml') { downloads.guide++; return route.fulfill({status:200,contentType:'text/xml',body:guide}); }
    return route.continue();
  });
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Emulation.setCPUThrottlingRate',{rate:6});
  const activate = async selector => (typeof selector === 'string' ? page.locator(selector) : selector).press('Enter');
  const modal = () => page.locator('.dialog:not([hidden])');
  async function edit(selector,value) { await activate(selector); await page.locator(selector).fill(value); await page.locator(selector).press('Escape'); }
  await page.setViewportSize({width:1920,height:1080});
  await page.goto(origin);
  await page.locator('#language-view').waitFor({state:'visible'});
  await activate(page.locator('#language-list').getByRole('button',{name:'English',exact:true}));
  await activate('#add-profile');
  const input = modal().locator('input').first(); await activate(input); await input.fill('Guide performance'); await input.press('Escape');
  await activate(modal().getByRole('button',{name:'Save',exact:true}));
  await activate('#setup-source');
  await edit('#source-label','10k guide');
  await edit('#source-field-playlistUrl',origin+'/fixture/performance.m3u');
  const start = Date.now();
  await activate('#connect-source'); await page.locator('#home-view').waitFor({state:'visible'});
  const sourceLoadMs = Date.now()-start;
  const openStart = Date.now();
  await activate('#home-live'); await page.locator('#guide-grid .guide-channel').first().waitFor();
  const listReadyMs = Date.now()-openStart;
  await page.waitForFunction(() => document.querySelector('#guide-grid .guide-programme:not(.is-empty)'));
  const guideReadyMs = Date.now()-openStart;
  await page.evaluate(() => {
    const grid = document.querySelector('#guide-grid');
    window.__guidePerf = {addedRows:0,removedRows:0};
    window.__guideObserver = new MutationObserver(records => records.forEach(record => {
      record.addedNodes.forEach(node => { if(node.nodeType===1 && node.classList.contains('guide-row')) window.__guidePerf.addedRows++; });
      record.removedNodes.forEach(node => { if(node.nodeType===1 && node.classList.contains('guide-row')) window.__guidePerf.removedRows++; });
    }));
    window.__guideObserver.observe(grid,{childList:true,subtree:true});
  });
  const scrollStart = Date.now();
  await page.evaluate(async () => {
    const grid = document.querySelector('#guide-grid');
    for(let i=1;i<=24;i++) { grid.scrollTop=i; await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))); }
  });
  const smallScrollMs = Date.now()-scrollStart;
  const churn = await page.evaluate(() => { window.__guideObserver.disconnect(); return window.__guidePerf; });
  await activate(page.locator('#guide-grid .guide-channel').first());
  const navStart = Date.now();
  for(let i=0;i<60;i++) await page.keyboard.press('ArrowDown');
  const navigationMs = Date.now()-navStart;
  const focusedIndex = await page.locator(':focus').getAttribute('data-guide-index');
  const rows = await page.locator('#guide-rows > .guide-row').count();
  await activate('#show-home'); await activate('#home-live');
  await page.locator('#guide-grid .guide-channel').first().waitFor();
  await activate('#show-guide');
  await page.locator('#channel-list button').first().waitFor();
  await edit('#channel-search','Channel 9999');
  await page.waitForFunction(() => document.querySelectorAll('#channel-list button').length===1 && document.querySelector('#channel-list').textContent.includes('Channel 9999'));
  await cdp.send('Emulation.setCPUThrottlingRate',{rate:1}); await cdp.detach();
  if(errors.length) throw Error(errors.join('; '));
  if(downloads.playlist!==1 || downloads.guide!==1) throw Error('Warm navigation downloaded again: '+JSON.stringify(downloads));
  if(rows>40 || Number(focusedIndex)<60) throw Error('Continuous remote navigation failed: '+JSON.stringify({rows,focusedIndex}));
  if(!baseline && churn.removedRows!==0) throw Error('Unchanged guide window rebuilt rows: '+JSON.stringify(churn));
  return {status:'passed',baseline,channels:10000,cpuThrottle:6,sourceLoadMs,listReadyMs,guideReadyMs,smallScrollMs,...churn,navigationMs,focusedIndex,rows,downloads,browserErrors:errors,
    scope:'Actual packaged UI, Worker and Dart core, synthetic HTTP/SDK, desktop Chrome at 6x CPU throttling; not physical Samsung timings.'};
}
