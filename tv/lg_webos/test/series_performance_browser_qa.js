// playwright-cli run-code --filename against the shared local fixture server.
// A fresh LG browser context is required. ?baseline=1 records the old DOM cost.
async (page) => {
  const baseline = new URL(page.url()).searchParams.has('baseline');
  const origin = new URL(page.url()).origin;
  if (new URL(origin).hostname !== '127.0.0.1') throw Error('Loopback QA required');
  const errors = [], sample = [], count = 2000;
  let phase = 'setup';
  page.on('pageerror', error => errors.push(error.message));
  const series = Array.from({length:count}, (_, index) => ({
    series_id:900 + index, name:'Series QA ' + String(index).padStart(4,'0'), category_id:'series',
    // Include rows with and without metadata: their original flex heights differ.
    year:index % 18 < 6 ? undefined : '2023', rating:index % 18 < 6 ? undefined : '8.1',
    cover:origin + '/fixture/art/series-poster.svg'
  }));
  await page.route('**/*', route => {
    const url = new URL(route.request().url());
    if (url.origin !== origin) return route.abort();
    if (url.pathname === '/player_api.php') {
      const action = url.searchParams.get('action');
      if (action === 'get_series_categories') return route.fulfill({json:[{category_id:'series',category_name:'QA series'}]});
      if (action === 'get_series') return route.fulfill({json:series});
    }
    return route.continue();
  });
  const activate = async target => (typeof target === 'string' ? page.locator(target) : target).press('Enter');
  async function edit(selector, value) { await activate(selector); await page.locator(selector).fill(value); await page.locator(selector).press('Escape'); }
  const panel = page.locator('#media-view .media-panel');
  const cards = page.locator('#media-items .media-card');
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Emulation.setCPUThrottlingRate',{rate:6});
  try {
    await page.setViewportSize({width:1280,height:720});
    await page.goto(origin);
    await page.locator('#language-view').waitFor({state:'visible'});
    await activate(page.locator('#language-list').getByRole('button',{name:'English',exact:true}));
    await activate('#add-profile');
    const input = page.locator('.dialog:not([hidden]) input').first();
    await activate(input); await input.fill('Series performance'); await input.press('Escape');
    await activate(page.locator('.dialog:not([hidden])').getByRole('button',{name:'Save',exact:true}));
    await activate('#setup-source'); await activate('#kind-xtream');
    await edit('#source-label','Series performance'); await edit('#source-field-host',origin);
    await edit('#source-field-username','fixture-user'); await edit('#source-field-password','fixture-pass');
    await activate('#connect-source'); await page.locator('#home-view').waitFor({state:'visible'});
    await activate('#home-series'); await cards.first().waitFor();
    // Use normal provider paging: the existing global search intentionally
    // limits its results and must not be changed for a performance test.
    await page.evaluate(() => {
      const grid = document.querySelector('#media-items');
      window.__seriesPerf = {maximum:0,longTasks:[]};
      const observe = () => { window.__seriesPerf.maximum = Math.max(window.__seriesPerf.maximum,grid.querySelectorAll('.media-card').length); };
      observe(); window.__seriesPerf.dom = new MutationObserver(observe);
      window.__seriesPerf.dom.observe(grid,{childList:true});
      window.__seriesPerf.tasks = new PerformanceObserver(list => list.getEntries().forEach(entry => window.__seriesPerf.longTasks.push(entry.duration)));
      window.__seriesPerf.tasks.observe({entryTypes:['longtask']});
    });
    const started = Date.now();
    phase = 'deep scroll';
    for (let step=0;step<160;step++) {
      const state = await page.evaluate(() => {
        const grid = document.querySelector('#media-items'), nodes = grid.querySelectorAll('.media-card');
        return {mounted:nodes.length,revealed:Number(grid.getAttribute('data-series-count')) ||
          Math.max.apply(Math,Array.from(nodes,node => Number(node.getAttribute('data-series-index'))))+1};
      });
      sample.push(state);
      if (state.revealed >= count) break;
      await panel.evaluate(node => { node.scrollTop=node.scrollHeight; node.dispatchEvent(new Event('scroll')); });
      await page.waitForFunction(previous => {
        const grid = document.querySelector('#media-items'), nodes = grid.querySelectorAll('.media-card');
        const current = Number(grid.getAttribute('data-series-count')) ||
          Math.max.apply(Math,Array.from(nodes,node => Number(node.getAttribute('data-series-index'))))+1;
        return current > previous;
      },state.revealed);
    }
    if (sample[sample.length-1].revealed !== count) throw Error('Not all series were reachable: '+JSON.stringify(sample));
    phase = 'last item';
    await panel.evaluate(node => { node.scrollTop=node.scrollHeight; node.dispatchEvent(new Event('scroll')); });
    const last = page.locator('#media-items .media-card[data-series-index="1999"]');
    await last.waitFor(); await last.focus();
    const before = await panel.evaluate(node => node.scrollTop);
    phase = 'details';
    await activate(last); const close = page.locator('.dialog.media-details:not([hidden]) .details-close');
    await close.waitFor(); await activate(close);
    if (await page.locator(':focus').getAttribute('data-series-index') !== '1999') throw Error('Details Back lost the series focus');
    if (Math.abs(await panel.evaluate(node => node.scrollTop)-before)>2) throw Error('Details Back moved the scroll position');
    // Moving back over evicted windows must preserve logical keyboard order.
    phase = 'reverse navigation';
    const columns = await page.evaluate(() => {
      const rows = {};
      document.querySelectorAll('#media-items .media-card').forEach(node => { rows[node.offsetTop]=(rows[node.offsetTop] || 0)+1; });
      return Math.max.apply(Math,Object.values(rows));
    });
    for(let step=0;step<40;step++) await page.keyboard.press('ArrowUp');
    if (Number(await page.locator(':focus').getAttribute('data-series-index')) !== 1999-40*columns) throw Error('Up navigation skipped a virtualized row');
    phase = 'return top';
    await panel.evaluate(node => { node.scrollTop=0; node.dispatchEvent(new Event('scroll')); });
    const first = page.locator('#media-items .media-card[data-series-index="0"]');
    await first.waitFor(); await first.focus();
    await page.keyboard.press('ArrowRight');
    if (await page.locator(':focus').getAttribute('data-series-index') !== '1') throw Error('Top navigation did not recover');
    const metrics = await page.evaluate(() => {
      const data = window.__seriesPerf; data.dom.disconnect(); data.tasks.disconnect();
      return {maxMounted:data.maximum,longTasks:data.longTasks,remainingMounted:document.querySelectorAll('#media-items .media-card').length};
    });
    if (!baseline && metrics.maxMounted > 80) throw Error('Series DOM exceeded its bounded window: '+JSON.stringify(metrics));
    if (errors.length) throw Error(errors.join('; '));
    await page.evaluate(() => window.TVBroSamsungPlatform.query('sources.cancel'));
    return {status:'passed',baseline,totalSeries:count,cpuThrottle:6,elapsedMs:Date.now()-started,...metrics,
      deepDetailsBack:true,reverseNavigation:true,topRestored:true,browserErrors:errors,
      scope:'Actual LG payload and canonical source, desktop Chrome 6x CPU; no physical TV qualification.'};
  } catch (error) {
    throw Error(phase + ': ' + error.message + '; samples=' + JSON.stringify(sample.slice(-3)) +
      '; state=' + JSON.stringify(await page.evaluate(() => ({cards:document.querySelectorAll('#media-items .media-card').length,
        revealed:document.querySelector('#media-items').getAttribute('data-series-count'),
        status:document.querySelector('#app-status').textContent,
        search:document.querySelector('#media-search').value}))));
  } finally { await cdp.send('Emulation.setCPUThrottlingRate',{rate:1}); await cdp.detach(); }
}
