// playwright-cli run-code --filename, against ui_browser_server.cjs serving
// either final Samsung or LG payload. For LG use TVBRO_QA_MEDIA with the local
// 12-second H.264/AAC fixture. Real UI/core/worker/library/protected storage;
// only provider HTTP and Samsung's SDK are synthetic.
async (page) => {
  const origin = new URL(page.url()).origin;
  if (new URL(origin).hostname !== '127.0.0.1') throw Error('Loopback QA required');
  const errors = [], phases = [], providerReads = [];
  page.on('pageerror', error => errors.push(error.message));
  // Capture the actual production store, without replacing its encryption or
  // persistence. Fixture checkpoints use its public string-keyed state API.
  await page.addInitScript(() => {
    for (const name of ['TVBroSamsungSecureStore','TVBroWebOSSecureStore']) {
      let current;
      Object.defineProperty(window, name, {configurable:true,get:() => current,set:value => {
        current = value;
        const create = value.create;
        value.create = function (options) {
          const store = create(options); window.__seriesQaStore = store; return store;
        };
      }});
    }
  });
  await page.route('**/*', route => {
    const url = new URL(route.request().url());
    if (url.origin !== origin) return route.abort();
    if (url.pathname === '/player_api.php') {
      const action = url.searchParams.get('action'); providerReads.push(action);
      if (action === 'get_series_info') return route.fulfill({json:{
        info:{name:'Serial QA',plot:'Series progress fixture.',cover:origin+'/fixture/art/series-poster.svg'},
        seasons:[{season_number:1,name:'Season 1'},{season_number:2,name:'Season 2'}],
        episodes:{'1':[{id:901,title:'Pilot QA',episode_num:1,container_extension:'mp4',info:{duration_secs:600}},
          {id:902,title:'Second episode QA',episode_num:2,container_extension:'mp4',info:{duration_secs:600}}],
        '2':[{id:2001,title:'Season 2 pilot QA',episode_num:1,container_extension:'mp4',info:{duration_secs:600}},
          {id:2002,title:'Season 2 finale QA',episode_num:2,container_extension:'mp4',info:{duration_secs:600}}]}
      }});
    }
    return route.continue();
  });
  const activate = async target => (typeof target === 'string' ? page.locator(target) : target).press('Enter');
  const details = () => page.locator('.dialog.media-details:not([hidden])');
  const modal = () => page.locator('.dialog:not([hidden])');
  function check(value, message) { if (!value) throw Error(message); }
  async function edit(target, value) {
    const input = typeof target === 'string' ? page.locator(target) : target;
    await activate(input); await input.fill(value); await input.press('Escape');
  }
  async function closeDetails() {
    await activate(details().locator('.details-close'));
    await page.locator('.dialog.media-details').waitFor({state:'detached'});
  }
  async function openSeries() {
    if (!await page.locator('#media-view').isVisible()) {
      if (!await page.locator('#home-view').isVisible()) await activate('#show-home');
      await activate('#home-series');
    }
    await page.locator('#media-items .media-card').filter({has:page.getByText('Serial QA',{exact:true})}).waitFor();
    await activate(page.locator('#media-items .media-card').filter({has:page.getByText('Serial QA',{exact:true})}));
    await details().locator('.season-button').nth(1).waitFor();
  }
  async function seed(rows) {
    await page.evaluate(async rows => {
      const store = window.__seriesQaStore, state = store.readUserState();
      const all = JSON.parse(state.samsung_playback_positions_v1 || '{}'), saved = {};
      for (let index = 0; index < rows.length; index++) {
        const row = rows[index], item = window.__seriesQa.episodes[row.index];
        saved[JSON.stringify([window.__seriesQa.sourceId,item.kind,item.id])] = {
          sourceId:window.__seriesQa.sourceId,item,
          position:row.position,duration:row.duration || 600,removed:false,
          updatedAt:new Date(Date.now()+index).toISOString()
        };
      }
      all[window.__seriesQa.profileId] = saved;
      state.samsung_playback_positions_v1 = JSON.stringify(all);
      await store.writeUserState(state);
    }, rows);
  }
  await page.setViewportSize({width:1280,height:720});
  await page.goto(origin);
  await page.locator('#language-view').waitFor({state:'visible'});
  await activate(page.locator('#language-list').getByRole('button',{name:'English',exact:true}));
  await page.locator('#profiles-view').waitFor({state:'visible'});
  await activate('#add-profile'); await edit(modal().locator('input').first(),'Series progress QA');
  await activate(modal().getByRole('button',{name:'Save',exact:true}));
  await page.locator('#setup-view').waitFor({state:'visible'}); await activate('#setup-source');
  await page.locator('#sources-view').waitFor({state:'visible'}); await activate('#kind-xtream');
  await edit('#source-label','Series progress source'); await edit('#source-field-host',origin+'/');
  await edit('#source-field-username','fixture-user'); await edit('#source-field-password','fixture-pass');
  await activate('#connect-source'); await page.locator('#home-view').waitFor({state:'visible'});
  const fixture = await page.evaluate(async () => {
    const api = window.TVBroSamsungPlatform, sources = await api.query('sources.list');
    const sourceId = sources.find(source => source.label === 'Series progress source').id;
    const series = (await api.query('catalog.items',{kind:'series',categoryId:'series',page:1})).items[0];
    const seasons = (await api.query('media.children',{item:series})).items;
    const episodes = [];
    for (const season of seasons) episodes.push(...(await api.query('media.children',{item:season})).items);
    const profileId = (await api.query('profiles.list')).profile.id;
    window.__seriesQa = {sourceId,series,seasons,episodes,profileId};
    const video = document.getElementById('native-player'); if (video && video.tagName === 'VIDEO') video.muted = true;
    return {platform:video && video.tagName === 'VIDEO' ? 'lg' : 'samsung',episodes:episodes.length};
  });
  check(fixture.episodes === 4,'Canonical fixture must contain both seasons');
  await openSeries();
  check(await details().locator('.details-series-progress').isHidden(),'Unstarted series must hide its history');
  check(await details().locator('.details-primary').textContent() === 'View episodes','Unstarted series keeps browse action');
  check(await details().locator('.episode-card').count() === 0,'Summary must not expand seasons');
  await closeDetails(); phases.push('unstarted series and lazy episode UI');

  await seed([{index:0,position:590}]);
  await openSeries(); await details().getByText('Watched episodes: 1',{exact:true}).waitFor();
  check(await details().locator('.details-primary').textContent() === 'Play S1E2','First completion must advance to S1E2');
  check((await details().locator('.details-series-latest').innerText()).includes('S1E1, Pilot QA'),'Latest watched episode must be visible');
  check((await details().locator('.details-series-next').innerText()).includes('S1E2, Second episode QA'),'Next episode title must be visible');
  check(await details().locator('.episode-card').count() === 0,'Started series must remain collapsed');
  for (const width of [1280,1920]) {
    await page.setViewportSize({width,height:width === 1280 ? 720 : 1080});
    await details().locator('.details-primary').focus();
    const bounds = await details().evaluate(node => {
      const box = node.getBoundingClientRect(), close = node.querySelector('.details-close').getBoundingClientRect();
      return {left:box.left,top:box.top,right:box.right,bottom:box.bottom,closeTop:close.top,closeBottom:close.bottom,
        overflow:node.querySelector('.details-scroll').scrollWidth > node.querySelector('.details-scroll').clientWidth+1};
    });
    check(bounds.left >= 0 && bounds.top >= 0 && bounds.right <= width+1 && bounds.bottom <= (width === 1280 ? 720 : 1080)+1 && !bounds.overflow,'Details must fit '+fixture.platform+' '+width);
    await page.screenshot({path:'D:/tvbro/output/playwright/series-progress-'+fixture.platform+'-'+width+'.png'});
  }
  await activate(details().locator('.details-browse-episodes'));
  check(await details().locator('.season-button').first().evaluate(node => node === document.activeElement),'Secondary browse action keeps remote season access');
  await closeDetails(); phases.push('watched count, latest/next, collapsed UI and TV geometry');

  await seed([{index:0,position:590},{index:1,position:90}]);
  await openSeries(); await details().getByRole('button',{name:'Resume S1E2',exact:true}).waitFor();
  await activate(details().locator('.details-primary'));
  await page.waitForFunction(() => document.body.classList.contains('player-open') &&
    window.TVBroSamsungPlatform.getState().playing && document.querySelector('#player-view').getAttribute('aria-busy') === 'false');
  const playing = await page.evaluate(() => window.TVBroSamsungPlatform.getState().currentItem.id);
  check(playing === await page.evaluate(() => window.__seriesQa.episodes[1].id),'Resume action must open the selected episode');
  if (fixture.platform === 'samsung') await page.evaluate(() => window.__samsungFixture.tick(590));
  else await page.evaluate(() => window.TVBroSamsungPlatform.seek(11.6));
  await page.keyboard.press('ArrowUp'); await activate('#stop-player');
  await details().getByRole('button',{name:'Play S2E1',exact:true}).waitFor();
  check(await details().locator('.details-series-watched').textContent() === 'Watched episodes: 2','Stop persists completion before refreshing summary');
  check((await details().locator('.details-series-next').innerText()).includes('S2E1, Season 2 pilot QA'),'Next action must cross the season boundary');
  await closeDetails(); phases.push('actual playback stop checkpoint refresh and next season');

  await seed([0,1,2,3].map(index => ({index,position:590})));
  await openSeries(); await details().getByText('All available episodes watched',{exact:true}).waitFor();
  check(await details().locator('.details-primary').textContent() === 'View episodes','Completed series must keep browsing');
  check(await details().locator('.details-series-watched').textContent() === 'Watched episodes: 4','Completed count covers all episodes');
  check(await details().locator('.details-browse-episodes').isHidden(),'No duplicate browse button after completion');
  await closeDetails(); phases.push('completed series');

  await page.evaluate(() => {
    const api = window.TVBroSamsungPlatform, original = api.query; let held = false;
    window.__seriesQaOriginalQuery = original;
    api.query = function (action,args) {
      if (action === 'media.seriesProgress' && !held) {
        held = true; return new Promise((resolve,reject) => {
          window.__seriesQaRelease = () => original(action,args).then(resolve,reject);
        });
      }
      return original(action,args);
    };
  });
  await openSeries(); await closeDetails();
  await page.evaluate(async () => {
    await window.__seriesQaRelease();
    window.TVBroSamsungPlatform.query = window.__seriesQaOriginalQuery;
  });
  check(await page.locator('.dialog.media-details').count() === 0,'Closed details must ignore delayed summary');
  phases.push('late result after closing details');
  await page.evaluate(() => window.TVBroSamsungPlatform.query('sources.cancel'));
  check(errors.length === 0,errors.join('; '));
  return {status:'passed',platform:fixture.platform,phases,providerSeriesReads:providerReads.filter(action => action === 'get_series_info').length,browserErrors:errors,
    scope:'Actual packaged UI, canonical Dart/core/worker and production protected storage in host Chrome; local provider and Samsung SDK fixture only. No physical TV qualification.'};
}
