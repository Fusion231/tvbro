// Run with playwright-cli run-code --filename after opening the QA server and
// taking a fresh snapshot. Only SDK/HTTP boundaries are synthetic, never query
// actions or the original Dart Source/validation/PIN/business modules.
async (page) => {
  const origin = new URL(page.url()).origin;
  const phases = [];
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  async function check(value, label) { if (!value) throw new Error(label); }
  async function activate(selector) {
    const node = typeof selector === 'string' ? page.locator(selector) : selector;
    await node.press('Enter');
  }
  async function edit(selector, value) {
    const node = typeof selector === 'string' ? page.locator(selector) : selector;
    await node.press('Enter'); await node.fill(value); await node.press('Escape');
  }
  async function shown(selector) { await page.locator(selector).waitFor({state:'visible'}); }
  async function resize(size) {
    await page.setViewportSize(size);
    await page.waitForFunction(() => {
      const viewport = document.querySelector('#ui-viewport'), rect = viewport.getBoundingClientRect();
      const scale = Math.max(1,Math.min(window.innerWidth/1280,window.innerHeight/720));
      return Math.abs(rect.width-window.innerWidth) < 1 && Math.abs(rect.height-window.innerHeight) < 1 &&
        Math.abs(Number(viewport.getAttribute('data-ui-scale'))-scale) < .001;
    });
  }
  async function home() { await activate('#show-home'); await shown('#home-view'); }
  async function section(kind) { await home(); await activate('#home-'+kind); await shown(kind === 'live' ? '#catalog-view' : '#media-view'); }
  async function sectionChrome(screen) {
    await check(await page.locator('#brand-logo').isHidden(),'Global branding must stay on Home, not cover '+screen);
    for (const id of ['show-sources','show-profiles','show-settings']) {
      await check(await page.locator('#'+id).isHidden(),'Global action '+id+' must stay on Home while browsing '+screen);
    }
    await check(await page.locator('#'+screen+'-view .catalog-toolbar #show-home, #'+screen+'-view .guide-toolbar #show-home').isVisible(),'The section Home control must stay in its toolbar');
    await check(await page.locator('#content-tabs').count() === 0,'Section navigation must use Home tiles instead of duplicate content tabs');
  }
  async function designAtTvSizes() {
    for (const size of [{width:1280,height:720},{width:1920,height:1080}]) {
      await resize(size);
      await check(await page.locator('#brand-logo').isVisible(),'Home must retain the global brand at '+size.width);
      const homeSize = await page.evaluate(() => {
        const tiles = document.querySelector('.home-tiles').getBoundingClientRect();
        const tile = document.querySelector('#home-live').getBoundingClientRect();
        const title = document.querySelector('.home-content > h1').getBoundingClientRect();
        return {tileWidth:tiles.width,tileHeight:tile.height,titleHeight:title.height};
      });
      await check(homeSize.tileWidth >= size.width*.8 && homeSize.tileHeight >= size.height*.2 && homeSize.titleHeight >= size.height*.04,'Home controls must scale with the TV screen instead of shrinking into its centre at '+size.width);
      const tiles = await page.locator('.home-tile').evaluateAll(nodes => nodes.filter(node => !node.hidden).map(node => {
        const rect = node.getBoundingClientRect(); return {left:rect.left,right:rect.right,top:rect.top,bottom:rect.bottom};
      }));
      await check(tiles.length === 4 && tiles.every((tile,index) => tile.left >= 0 && tile.right <= size.width && tile.top >= 0 && tile.bottom <= size.height && Math.abs(tile.top-tiles[0].top) <= 1 && (!index || tile.left > tiles[index-1].right)),'Four compact Home tiles must share one visible row at '+size.width);
      await check(await page.locator('#home-live').evaluate(node => node === document.activeElement),'Home must place the remote cursor on its TV tile');
      await page.keyboard.press('ArrowRight');
      await check(await page.locator('#home-movie').evaluate(node => node === document.activeElement),'D-pad Right must reach Movies from the TV tile');
      await page.keyboard.press('ArrowLeft'); await page.keyboard.press('Enter'); await shown('#catalog-view');
      await sectionChrome('catalog');
      await shown('#guide-panel');
      await page.getByRole('button',{name:/Teraz QA/}).waitFor();
      await check(await page.locator('#guide-grid button.guide-channel').first().evaluate(node => node === document.activeElement),'Opening TV by remote must focus the first channel in the embedded guide');
      await check(await page.locator('.guide-programme.is-empty').count() > 0,'Channels without programmes must retain visible guide cells');
      await check(await page.locator('#channel-panel').isHidden(),'The embedded guide must be the default TV view');
      const boxes = await page.evaluate(() => {
        function rect(selector) { const box = document.querySelector(selector).getBoundingClientRect(); return {left:box.left,right:box.right,top:box.top,bottom:box.bottom,width:box.width,height:box.height}; }
        const viewport = document.querySelector('#ui-viewport');
        return {categories:rect('#catalog-view .category-panel'),toolbar:rect('#catalog-view .catalog-toolbar'),preview:rect('#preview-panel'),channels:rect('#guide-panel'),video:rect('#preview-slot'),caption:rect('#preview-panel .preview-caption'),rootScrollTop:viewport.scrollTop,rootScrollLeft:viewport.scrollLeft};
      });
      await check(boxes.categories.right <= boxes.preview.left+1 && boxes.categories.right <= boxes.channels.left+1,'Live categories must stay left of the preview and channels at '+size.width);
      await check(boxes.toolbar.bottom <= boxes.preview.top+1 && boxes.preview.bottom <= boxes.channels.top+1,'Live must stack its toolbar, preview and channel list at '+size.width);
      await check(Math.abs(boxes.preview.left-boxes.channels.left) <= 1 && boxes.video.right <= boxes.caption.left+1,'Preview must share the channel column and show video beside its description at '+size.width);
      await check(boxes.categories.top <= boxes.toolbar.top+1 && boxes.toolbar.top >= 0 && boxes.channels.height > 0 && boxes.channels.bottom <= size.height && boxes.preview.right <= size.width && boxes.rootScrollTop === 0 && boxes.rootScrollLeft === 0,'Live panes must fit the TV viewport without scrolling its presentation root at '+size.width);
      await page.screenshot({path:'D:/tvbro/output/playwright/samsung-full-ui/live-design-'+size.width+'.png'});
      await home();
      await check(await page.locator('#home-live').evaluate(node => node === document.activeElement),'Section Home must restore the remote cursor to the TV tile');
      await page.keyboard.press('Enter'); await shown('#catalog-view'); await page.keyboard.press('Escape'); await shown('#home-view');
      await check(await page.locator('#home-live').evaluate(node => node === document.activeElement),'Remote Back from Live must return to Home tiles');
      await page.screenshot({path:'D:/tvbro/output/playwright/samsung-full-ui/home-design-'+size.width+'.png'});
    }
    phases.push('Android TV Home/Live geometry and directional remote navigation at 1280×720 and 1920×1080');
  }
  function modal() { return page.locator('.dialog:not([hidden])'); }
  async function action(name) { await activate(modal().getByRole('button',{name,exact:true})); }
  async function calls(name) { return page.evaluate(name => window.__samsungFixture.calls.filter(row => row[0] === name).length,name); }
  async function playing() { await page.waitForFunction(() => window.TVBroSamsungPlatform.getState().playing && (document.querySelector('#player-view').hidden || document.querySelector('#player-view').getAttribute('aria-busy') === 'false')); }
  async function readyLiveChannel(name, opens) {
    await page.waitForFunction(expected => {
      const state = window.TVBroSamsungPlatform.getState();
      return document.body.classList.contains('player-open') && document.querySelector('#player-view').getAttribute('aria-busy') === 'false' && state.playing && state.isLive &&
        state.currentItem && state.currentItem.name === expected.name &&
        window.__samsungFixture.calls.filter(row => row[0] === 'open').length >= expected.opens;
    }, {name,opens});
    await check(await calls('open') === opens,'A channel switch must open exactly one native stream for '+name);
    await check(await page.locator('#preview-mask').isHidden(),'Fullscreen playback must hide every preview mask');
  }
  async function zapKey(key, name) {
    const opens = await calls('open');
    if (typeof key === 'number') await page.locator('body').dispatchEvent('keydown',{keyCode:key,which:key});
    else await page.keyboard.press(key);
    await readyLiveChannel(name,opens+1);
  }
  async function hiddenPlayerChrome() {
    if (await page.locator('#player-chrome').isVisible()) await page.keyboard.press('Escape');
    await page.locator('#player-chrome').waitFor({state:'hidden'});
  }
  async function fullscreenChannelKeys() {
    await check(await page.locator('#player-chrome').isVisible(),'Guide fullscreen must start with visible controls');
    await zapKey(427,'Kanał 3');
    await zapKey(428,'Kanał 2');
    await zapKey('PageUp','Kanał 3');
    await zapKey('PageDown','Kanał 2');
    const opens = await calls('open');
    await page.keyboard.press('ArrowUp');
    await check(await calls('open') === opens,'Visible player controls must retain directional navigation');
    await hiddenPlayerChrome(); await zapKey('ArrowUp','Kanał 3');
    await check(await page.locator('#player-chrome').isHidden(),'Arrow zapping must retain hidden controls');
    await zapKey('ArrowUp','Kanał 4');
    await page.evaluate(() => window.__samsungFixture.listener.onbufferingstart());
    await check(await page.locator('#player-chrome').isHidden(),'Live rebuffering must not steal the arrow keys');
    await page.evaluate(() => window.__samsungFixture.listener.onbufferingcomplete());
    await zapKey('ArrowDown','Kanał 3'); await zapKey('ArrowDown','Kanał 2');
    await check(await page.locator('#player-chrome').isHidden(),'Consecutive arrows must keep changing channels');
    await page.keyboard.press('Enter'); await shown('#player-chrome');
    await hiddenPlayerChrome();
    await zapKey(428,'Kanał 1');
    await zapKey(428,'Kanał 161');
    await zapKey(427,'Kanał 1');
    await zapKey(427,'Kanał 2');
    const burstOpens = await calls('open');
    for (let i = 0; i < 3; i++) await page.locator('body').dispatchEvent('keydown',{keyCode:427,which:427});
    await readyLiveChannel('Kanał 5',burstOpens+1);
    await page.locator('body').dispatchEvent('keydown',{keyCode:10190,which:10190});
    await readyLiveChannel('Kanał 2',burstOpens+2);
    await page.keyboard.press('1'); await page.keyboard.press('2'); await page.keyboard.press('Enter');
    await readyLiveChannel('Kanał 12',burstOpens+3);
    await hiddenPlayerChrome(); await page.keyboard.press('ArrowRight');
    await readyLiveChannel('Kanał 2',burstOpens+4);
    await hiddenPlayerChrome(); await page.keyboard.press('ArrowLeft');
    await modal().waitFor({state:'visible'});
    await check(await modal().locator('button').count() <= 24,'Quick channel list must mount a bounded set of rows');
    await page.keyboard.press('Escape');
    await check(await calls('open') === burstOpens+4,'Closing the quick list must preserve the playing stream');
    await page.keyboard.press('Enter');
    await check(await page.locator('#player-clock').textContent(),'Player must show the current clock');
    await check(await page.locator('#seek-forward').isHidden(),'Live must hide unavailable seek controls');
    await page.screenshot({path:'D:/tvbro/output/playwright/samsung-full-ui/player-parity.png'});
    await hiddenPlayerChrome(); await page.keyboard.press('Escape'); await shown('#guide-panel');
    await home();
    const history = page.locator('#home-history-list .media-card').filter({has:page.getByText('Kanał 2',{exact:true})}).first();
    await history.waitFor(); await activate(history);
    await page.waitForFunction(() => document.body.classList.contains('player-open') && window.TVBroSamsungPlatform.getState().playing);
    await zapKey(427,'Kanał 3');
    await zapKey(428,'Kanał 2');
    await hiddenPlayerChrome(); await page.keyboard.press('Escape'); await shown('#catalog-view');
    await shown('#guide-panel');
    await check(await page.locator('#home-view').isHidden(),'Back from a Home history channel must return to TV');
    await check(await page.locator('#catalog-view').evaluate(node => node.contains(document.activeElement)),'Back from history playback must restore TV focus');
    phases.push('fullscreen Channel/Page keys with visible controls, Android directional order, wrapping and persisted-history channel identities');
  }
  async function continuousGuideNavigation() {
    await check(await page.locator('#guide-previous-channels, #guide-next-channels').count() === 0,'The TV guide must not expose channel-page buttons');
    await page.locator('#guide-grid button.guide-channel').first().focus();
    for (let index = 0; index < 13; index++) await page.keyboard.press('ArrowDown');
    await page.waitForFunction(() => {
      const active = document.activeElement;
      return active && Number(active.getAttribute('data-guide-index')) >= 12;
    });
    await check(await page.locator('#guide-grid .guide-row:not(.guide-time-row)').count() <= 48,'The continuous guide must bound rendered channel rows');
    await page.locator('#guide-grid').hover(); await page.mouse.wheel(0,100000);
    await page.locator('#guide-grid button.guide-channel').filter({hasText:'Kanał 161'}).waitFor({state:'visible'});
    await check(await page.locator('#guide-grid .guide-row:not(.guide-time-row)').count() <= 48,'Reaching the last channel must retain a bounded guide DOM');
    await page.mouse.wheel(0,-100000);
    await page.locator('#guide-grid button.guide-channel').filter({hasText:/Kanał 1$/}).waitFor({state:'visible'});
    await page.locator('#guide-grid button.guide-channel').first().focus();
    phases.push('continuous EPG remote navigation beyond twelve channels and scrolling to the final channel without pagination');
  }
  async function previewGeometry() {
    await page.waitForFunction(() => {
      const slot = document.querySelector('#preview-slot').getBoundingClientRect();
      const object = document.querySelector('#native-player').getBoundingClientRect();
      const rect = window.__samsungFixture.calls.filter(row => row[0] === 'rect').slice(-1)[0];
      const values = [Math.round(slot.left),Math.round(slot.top),Math.round(slot.width),Math.round(slot.height)];
      const expected = values.map((value,index) => Math.round(value*(index%2 ? 1080/window.innerHeight : 1920/window.innerWidth)));
      return rect && expected.every((value,index) => Math.abs(value-rect[index+1]) <= 1) &&
        Math.abs(object.left-values[0]) <= 1 && Math.abs(object.top-values[1]) <= 1 &&
        Math.abs(object.width-values[2]) <= 1 && Math.abs(object.height-values[3]) <= 1;
    });
    const masks = await page.evaluate(() => {
      const slot = document.querySelector('#preview-slot').getBoundingClientRect();
      const panes = Array.from(document.querySelectorAll('#preview-mask > div'));
      const centre = {x:slot.left+slot.width/2,y:slot.top+slot.height/2};
      return {
        preview:document.body.classList.contains('preview-open'),
        count:panes.length,
        opaque:panes.every(pane => {
          const style = getComputedStyle(pane), box = pane.getBoundingClientRect();
          return style.display !== 'none' && style.visibility === 'visible' && style.opacity === '1' &&
            style.backgroundColor === 'rgb(11, 13, 18)' && box.width > 0 && box.height > 0;
        }),
        area:panes.reduce((area,pane) => {const box=pane.getBoundingClientRect();return area+box.width*box.height;},0),
        expectedArea:window.innerWidth*window.innerHeight-Math.round(slot.width)*Math.round(slot.height),
        coversCentre:panes.some(pane => {const box=pane.getBoundingClientRect();return centre.x >= box.left && centre.x < box.right && centre.y >= box.top && centre.y < box.bottom;})
      };
    });
    await check(masks.preview && masks.count === 4 && masks.opaque,'Embedded preview must have four visible opaque background panes');
    await check(Math.abs(masks.area-masks.expectedArea) <= 2 && !masks.coversCentre,'Preview masks must cover exactly the screen outside its video slot');
  }
  async function previewIdleBehavior() {
    // The preceding control test leaves the retained preview paused.
    await activate('#channel-row-0'); await shown('#player-view');
    await playing(); await page.waitForFunction(() => document.body.classList.contains('player-open'));
    const openCount = await calls('open');
    await page.keyboard.press('Escape'); await page.keyboard.press('Escape'); await shown('#catalog-view');
    for (const size of [{width:1280,height:720},{width:1920,height:1080}]) {
      await resize(size); await previewGeometry();
    }
    await page.clock.pauseAt(new Date(Date.now()+1000));
    await page.keyboard.press('ArrowDown');
    await check(await page.locator('#channel-row-1').evaluate(node => node === document.activeElement),'Moving the remote cursor must stay in the channel list');
    await check(await calls('open') === openCount,'Moving focus must not switch the preview stream');
    await page.clock.runFor(29000);
    await check(await page.locator('#player-view').isHidden(),'Ready preview must remain embedded before thirty idle seconds');
    await page.keyboard.press('ArrowUp');
    await page.clock.runFor(29000);
    await check(await page.locator('#player-view').isHidden(),'Remote activity must restart the thirty-second preview deadline');
    await page.clock.runFor(1001); await page.clock.resume();
    await shown('#player-view'); await playing();
    await page.waitForFunction(() => document.body.classList.contains('player-open'));
    await check(await calls('open') === openCount,'Idle fullscreen must reuse the already playing native stream');
    await page.keyboard.press('Escape'); await page.keyboard.press('Escape'); await shown('#catalog-view');
    await home();
    await page.clock.pauseAt(new Date(await page.evaluate(() => Date.now()+1000)));
    await page.clock.runFor(31000); await page.clock.resume();
    await check(await page.locator('#home-view').isVisible() && await page.locator('#player-view').isHidden(),'Returning Home must cancel idle fullscreen');
    await check(await calls('open') === openCount,'Cancelled preview must not reopen a stream later');
    await activate('#home-live'); await shown('#catalog-view');
    phases.push('button-free preview keeps channel focus, scales native geometry, reuses its stream after thirty idle seconds, resets on remote activity and cancels on Home');
  }
  async function source(kind, label, fields) {
    await activate('#kind-'+kind); await edit('#source-label',label);
    for (const [key,value] of Object.entries(fields)) await edit('#source-field-'+key,value);
    await activate('#connect-source'); await shown('#home-view');
  }
  await page.clock.install();
  await page.goto(origin);
  await page.waitForFunction(() => !document.querySelector('#language-view').hidden || document.querySelector('#app-status').classList.contains('is-error'));
  await check(await calls('keymanager.save') >= 2,'Fresh boot must exercise both persisted migrations.');
  await check(await calls('keymanager.duplicate') === 0,'Boot attempted to overwrite a create-only KeyManager alias.');
  const registeredKeys = await page.evaluate(() => window.__samsungFixture.calls.filter(row => row[0] === 'registerKey').map(row => row[1]));
  await check(registeredKeys.includes('ChannelUp') && registeredKeys.includes('ChannelDown'),'The Samsung platform must register dedicated channel keys');
  await shown('#language-view'); await activate(page.locator('#language-list').getByRole('button',{name:'Polski',exact:true}));
  await shown('#profiles-view'); await activate('#add-profile'); await edit(modal().locator('input').first(),'Dom QA'); await action('Zapisz');
  await shown('#setup-view'); await activate('#setup-source');
  await shown('#sources-view');
  await check(!await page.locator('#kind-stalker').isVisible(),'Stalker without a privileged transport was advertised');
  await check(!await page.locator('#source-field-userAgent').count(),'Unsupported custom User-Agent field was advertised');
  phases.push('original profile creation + capability-filtered source metadata');

  await source('m3u','M3U QA',{playlistUrl:origin+'/fixture/playlist.m3u',epgUrl:origin+'/fixture/guide.xml'});
  await designAtTvSizes();
  await activate('#home-live'); await shown('#guide-panel'); await continuousGuideNavigation(); await home();
  await activate('#home-live'); await shown('#guide-panel');
  await activate('#show-guide'); await shown('#channel-list');
  await check(await page.locator('#channel-list button').count() === 80,'Channel DOM must remain bounded to 80 rows');
  await activate('#next-page'); await check(await page.locator('#channel-list button').count() === 80,'Second bounded channel page');
  await activate('#next-page'); await check(await page.locator('#channel-list button').count() === 1,'Last channel must remain reachable');
  await edit('#channel-search','Kanał 161'); await shown('#clear-channel-search'); await page.waitForFunction(() => document.querySelectorAll('#channel-list button').length === 1 && document.querySelector('#channel-list').textContent.indexOf('Kanał 161') >= 0);
  await activate('#clear-channel-search'); await check(await page.locator('#channel-list button').count() === 80,'Clear search must restore the complete catalog');
  await page.screenshot({path:'D:/tvbro/output/playwright/samsung-full-ui/live.png'});
  const opensBefore = await calls('open');
  await activate('#channel-row-0'); await playing();
  await check(await page.locator('#preview-fullscreen').count() === 0,'Preview must not expose a separate fullscreen button');
  await check(await page.locator('#channel-row-0').evaluate(node => node === document.activeElement),'First OK must retain the cursor on the channel for the second OK');
  await check(await calls('open') === opensBefore+1,'Preview must open one real native SDK session');
  await previewGeometry();
  await activate('#channel-row-0'); await shown('#player-view'); await playing();
  await check(await calls('open') === opensBefore+1,'Preview/fullscreen handoff must not open a second stream');
  await check(await page.locator('#seek-forward').isDisabled(),'Live HLS must not expose VOD seek');
  await activate('#play-pause'); await page.waitForFunction(() => !window.TVBroSamsungPlatform.getState().playing);
  await page.keyboard.press('ArrowRight'); await check(await page.locator('#stop-player').evaluate(node => node === document.activeElement),'D-pad must skip disabled live seek');
  for (let i = 0; i < 12 && !await page.locator('#player-settings').evaluate(node => node === document.activeElement); i++) await page.keyboard.press('ArrowRight');
  await check(await page.locator('#player-settings').evaluate(node => node === document.activeElement),'D-pad must reach playback settings');
  await page.keyboard.press('ArrowLeft'); await check(await page.locator('#player-subtitles').evaluate(node => node === document.activeElement),'D-pad Left must reach the direct subtitle control');
  await page.keyboard.press('ArrowRight'); await page.keyboard.press('Enter');
  await page.keyboard.press('ArrowDown'); await check((await page.locator(':focus').textContent()) === 'Napisy','D-pad Down must move inside the actual settings dialog');
  await page.keyboard.press('ArrowUp'); await check((await page.locator(':focus').textContent()) === 'Ścieżka dźwiękowa','D-pad Up must retain dialog focus');
  await page.keyboard.press('Escape');
  await page.keyboard.press('Escape'); await page.keyboard.press('Escape'); await shown('#catalog-view');
  await check(await page.locator('#player-view').isHidden(),'Back ladder must return to retained preview');
  await check(await calls('open') === opensBefore+1,'Returning to preview must only transfer geometry');
  phases.push('original M3U/XHR + 161-channel search/paging + single-player geometry + remote Back');
  await previewIdleBehavior();

  await activate('#show-guide'); await shown('#guide-panel');
  await sectionChrome('catalog');
  await check(await page.locator('#catalog-view').isVisible() && await page.locator('#preview-panel').isVisible(),'Guide must stay in the TV section below its preview');
  await page.getByRole('button',{name:/Teraz QA/}).waitFor();
  await check(await page.locator('.guide-row:not(.guide-time-row)').count() <= 48,'Continuous EPG rows must remain bounded');
  const emptyCell = page.locator('#guide-grid .guide-programme.is-empty').first();
  await emptyCell.waitFor();
  const emptyChannel = await emptyCell.getAttribute('data-channel-id'), emptyOpens = await calls('open');
  await activate(emptyCell); await playing();
  await check(await emptyCell.evaluate(node => node === document.activeElement),'First OK on an empty guide cell must retain the remote cursor for the second OK');
  await check(await page.locator('#player-view').isHidden() && await calls('open') === emptyOpens+1,'A channel without EPG must start an embedded preview');
  await check(await page.locator('#guide-grid button.guide-channel[data-channel-id="'+emptyChannel+'"]').count() === 1,'Every empty programme cell must belong to a visible channel');
  await previewGeometry();
  await activate(emptyCell); await shown('#player-view'); await playing();
  await page.waitForFunction(() => document.body.classList.contains('player-open'));
  await check(await calls('open') === emptyOpens+1,'Second OK on an empty guide cell must reuse its preview stream');
  await fullscreenChannelKeys();
  await activate('#guide-earlier'); await page.getByRole('button',{name:/Archiwum QA/}).waitFor();
  await activate(page.getByRole('button',{name:/Archiwum QA/})); await action('Oglądaj z archiwum');
  await page.waitForFunction(() => document.body.classList.contains('player-open') && window.TVBroSamsungPlatform.getState().playing && !window.TVBroSamsungPlatform.getState().isLive);
  await check(await page.evaluate(() => window.TVBroSamsungPlatform.getState().isLive) === false,'Original catch-up resolver must reach finite playback');
  await activate('#seek-forward'); await page.waitForFunction(() => window.__samsungFixture.calls.some(row=>row[0]==='seek'));
  await check(await calls('seek') > 0,'Finite archive must use native absolute seek');
  await activate('#stop-player'); await shown('#catalog-view'); await shown('#guide-panel');
  await page.screenshot({path:'D:/tvbro/output/playwright/samsung-full-ui/guide.png'});
  phases.push('embedded default EPG with empty channel cells, preview/second-OK handoff, original XMLTV and catch-up eligibility/resolve + native seek');

  await home(); await activate('#show-sources'); await source('xtream','Xtream QA',{host:origin+'/',username:'fixture-user',password:'fixture-pass'});
  await activate('#home-movie'); await shown('#media-view'); await page.waitForFunction(() => document.querySelectorAll('#media-items .media-card').length === 14);
  await sectionChrome('media');
  for (const size of [{width:1280,height:720},{width:1920,height:1080}]) {
    await resize(size);
    const boxes = await page.evaluate(() => {
      function rect(selector) { const box = document.querySelector(selector).getBoundingClientRect(); return {left:box.left,right:box.right,top:box.top,bottom:box.bottom,width:box.width,height:box.height}; }
      return {categories:rect('#media-view .category-panel'),toolbar:rect('#media-view .catalog-toolbar'),grid:rect('#media-items'),poster:rect('#media-items .poster-placeholder')};
    });
    await check(boxes.categories.right <= boxes.grid.left+1 && boxes.toolbar.bottom <= boxes.grid.top+1 && boxes.grid.right <= size.width,'Media categories must stay left of the catalogue below its toolbar at '+size.width);
    await check(Math.abs(boxes.poster.width/boxes.poster.height-2/3) < .02,'Media posters must retain Android 2:3 proportions at '+size.width);
    await page.screenshot({path:'D:/tvbro/output/playwright/samsung-full-ui/movies-design-'+size.width+'.png'});
  }
  await activate('#media-next'); await page.waitForFunction(() => document.querySelectorAll('#media-items .media-card').length === 1);
  await check((await page.locator('#media-items').textContent()).indexOf('Film 14') >= 0,'Original VOD second page was lost');
  await activate(page.locator('#media-items .media-card').first()); await action('♡ Ulubione'); await action('Odtwórz'); await playing();
  await check(await page.evaluate(() => window.TVBroSamsungPlatform.getState().isLive) === false,'Original movie resolve must be finite');
  await activate('#player-settings'); await action('Ścieżka dźwiękowa'); await action('Polski');
  await check(await calls('track') > 0,'Audio choice must reach actual AVPlay selectTrack');
  await action('Napisy'); await action('Wyłącz napisy'); await check(await calls('subtitle') > 0,'Subtitle visibility must reach actual AVPlay API');
  await action('Prędkość odtwarzania'); await action('2×'); await check(await calls('speed') > 0,'Playback speed must reach actual AVPlay API');
  await action('Proporcje obrazu'); await action('Wypełnij'); await check(await calls('aspect') > 0,'Aspect ratio must reach actual AVPlay API');
  await page.keyboard.press('Escape'); await page.evaluate(() => window.__samsungFixture.tick(65)); await activate('#stop-player'); await modal().locator('.details-close').waitFor(); await activate(modal().locator('.details-close')); await shown('#media-view');
  await section('favorites'); await page.getByRole('button',{name:/Film 14/}).waitFor();
  await page.screenshot({path:'D:/tvbro/output/playwright/samsung-full-ui/favorites.png'});
  phases.push('original Xtream auth/catalog/paging/details/resolve + stored favorites/history + audio/subtitles/rate/aspect');

  await section('series'); await page.getByRole('button',{name:/Serial QA/}).waitFor();
  await activate(page.getByRole('button',{name:/Serial QA/})); await action('Pokaż odcinki');
  const firstSeason = modal().locator('.season-button').first(); await firstSeason.waitFor();
  await check(await firstSeason.evaluate(node => node === document.activeElement) && await firstSeason.getAttribute('aria-expanded') === 'false','View episodes must focus the first collapsed inline season');
  await activate(firstSeason); await modal().locator('.episode-card').first().waitFor();
  await check(await firstSeason.getAttribute('aria-expanded') === 'true','Selecting a season must expand its inline episode rail');
  await activate(modal().locator('.episode-card').first()); await playing();
  await check(await page.locator('#player-episodes').isVisible(),'Series episode selector must stay available');
  await activate('#player-episodes'); await modal().locator('.dialog-list button').first().waitFor();
  await check(await page.locator('#player-view').isVisible(),'The episode selector must keep the fullscreen player open');
  await action('Wstecz'); await activate('#stop-player');
  await check(await firstSeason.getAttribute('aria-expanded') === 'true','Stopping playback restores its expanded inline season');
  await activate(modal().locator('.details-close')); await shown('#media-view');
  phases.push('original series details -> season -> episode -> native playback + retained episode selector');

  await home(); await activate('#show-settings'); await shown('#settings-view');
  await page.evaluate(() => { window.__uiQaPhase = 'settings.preference'; });
  await activate(page.getByRole('button',{name:/Wybór profilu przy uruchomieniu/})); await action('Zawsze');
  await page.locator('#modal-layer').waitFor({state:'hidden'});
  await check((await page.evaluate(() => window.TVBroSamsungPlatform.query('settings.get'))).settings.profilePickerStartup === 'always','Settings change must be persisted through the actual store');
  const pairingEnabled = await page.evaluate(async () => (await window.TVBroSamsungPlatform.query('bootstrap')).capabilities.pairing);
  await check(await page.locator('#settings-pairing').isVisible() === pairingEnabled,'Cloud UI must match the actual publisher capability');
  if (pairingEnabled) {
    await activate('#settings-pairing'); await shown('#pairing-view'); await shown('#pairing-start');
    await check(!await page.locator('#pairing-pull').isVisible(),'Cloud pull must stay unavailable before a real session/profile');
    await page.keyboard.press('Escape'); await shown('#settings-view');
  }
  await page.evaluate(() => { window.__uiQaPhase = 'parental.enable'; });
  await activate(page.getByRole('button',{name:/Kontrola rodzicielska/})); await edit(modal().locator('input').first(),'4321'); await action('Zapisz PIN i ochronę ustawień');
  await page.locator('#modal-layer').waitFor({state:'hidden'});
  await shown('#settings-view'); await check((await page.evaluate(() => window.TVBroSamsungPlatform.query('parental.get'))).enabled,'Actual canonical parental PIN must be enabled');
  await page.evaluate(() => { window.__uiQaPhase = 'parental.disable'; });
  await activate(page.getByRole('button',{name:/Kontrola rodzicielska/})); await action('Wyłącz ochronę');
  await modal().getByRole('heading',{name:'PIN profilu',exact:true}).waitFor();
  await edit(modal().locator('input').first(),'4321'); await action('Dalej');
  await page.locator('#modal-layer').waitFor({state:'hidden'});
  await page.getByRole('button',{name:'Kontrola rodzicielska Wyłączone',exact:true}).waitFor();
  await page.waitForFunction(async () => !(await window.TVBroSamsungPlatform.query('parental.get')).enabled);
  phases.push('actual settings persistence + publisher capability gate + canonical parental PIN enable/disable');

  await activate('#show-profiles'); await shown('#profiles-view'); await activate('#add-profile');
  await page.evaluate(() => { window.__uiQaPhase = 'profiles.create'; });
  await edit(modal().locator('input').nth(0),'Drugi QA'); await edit(modal().locator('input').nth(1),'1234'); await action('Zapisz'); await shown('#setup-view'); await activate('#setup-source'); await shown('#sources-view');
  await check(await page.locator('#saved-sources .source-row').count() === 0,'Sources leaked into a new profile');
  await activate('#show-profiles'); await activate(page.getByRole('button',{name:/Dom QA/})); await shown('#home-view');
  await page.waitForFunction(() => !document.querySelector('#home-live').disabled);
  await activate('#show-sources'); await shown('#sources-view');
  await check(await page.locator('#saved-sources .source-row').count() === 2,'Original profile sources were not restored');
  await activate('#show-profiles'); await activate(page.getByRole('button',{name:/Drugi QA/}));
  await page.evaluate(() => { window.__uiQaPhase = 'profiles.badPin'; });
  await edit(modal().locator('input').first(),'0000'); await action('Dalej');
  await page.waitForFunction(() => document.querySelector('#app-status').textContent.indexOf('PIN') >= 0);
  await activate(page.getByRole('button',{name:/Drugi QA/})); await edit(modal().locator('input').first(),'1234'); await action('Dalej'); await shown('#setup-view'); await activate('#setup-source'); await shown('#sources-view');
  await check(await page.locator('#saved-sources .source-row').count() === 0,'PIN selection leaked another profile source state');
  await activate('#kind-m3u'); await edit('#source-label','Slow source QA'); await edit('#source-field-playlistUrl',origin+'/fixture/slow.m3u');
  const slowRequest = page.waitForRequest(request => request.url() === origin+'/fixture/slow.m3u');
  await activate('#connect-source'); await slowRequest; await page.keyboard.press('Escape');
  await page.waitForFunction(() => !document.querySelector('#connect-source').disabled);
  await check(await page.locator('#sources-view').isVisible(),'Back during source load must restore source navigation');
  await check(await page.locator('#saved-sources .source-row').count() === 1,'Cancelled load must retain the committed source');
  phases.push('Back cancels an actual pending Source HTTP request and retains its committed configuration');
  await activate('#show-profiles'); await page.screenshot({path:'D:/tvbro/output/playwright/samsung-full-ui/profiles.png'});
  await page.keyboard.press('Escape'); await page.waitForFunction(() => window.__samsungFixture.calls.some(row => row[0] === 'exit')); await check(await calls('exit') === 1,'Root TV Back must delegate native app exit');
  await check(errors.length === 0,'Browser runtime errors: '+errors.join('; '));
  const result = await page.evaluate(() => ({aliases:Object.keys(window.__samsungFixture.data).length,callKinds:window.__samsungFixture.calls.map(row => row[0])}));
  phases.push('canonical profile PIN refusal/acceptance + isolated saved source state + five-key activation/focus');
  return {status:'passed',phases,browserErrors:errors,nativeCalls:result.callKinds,privateSdkAliases:result.aliases,
    scope:'Actual packaged UI/platform/original Dart+panel with synthetic Samsung SDK and provider HTTP only. No physical decoding, TV storage, cloud account or Samsung hardware claim.'};
}
