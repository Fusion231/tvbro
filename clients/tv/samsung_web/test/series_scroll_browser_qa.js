// playwright-cli run-code --filename against ui_browser_server.cjs.
// The packaged UI, catalogue paging and original Dart Source remain real;
// provider HTTP and the Samsung SDK boundary use loopback fixtures.
async (page) => {
  const origin = new URL(page.url()).origin;
  if (new URL(origin).hostname !== '127.0.0.1') throw Error('Loopback QA server required');
  const errors = [], phases = [], samples = [];
  page.on('pageerror', error => errors.push(error.message));
  const categories = [{category_id:'series',category_name:'Main series'},
    {category_id:'alternate',category_name:'Alternate series'},
    {category_id:'slow',category_name:'Slow series'}];
  const series = category => Array.from({length:category === 'alternate' ? 3 : category === 'slow' ? 2 : 91}, (_, index) => ({
    series_id:(category === 'alternate' ? 2000 : category === 'slow' ? 3000 : 900) + index,
    name:(category === 'alternate' ? 'Alternate QA ' : category === 'slow' ? 'Slow QA ' : 'Serial QA ') + String(index).padStart(3,'0'),
    category_id:category,year:'2023',rating:'8.1'
  }));
  await page.route('**/*', route => {
    const url = new URL(route.request().url());
    if (url.origin !== origin) return route.abort();
    if (url.pathname === '/player_api.php') {
      const action = url.searchParams.get('action');
      if (action === 'get_series_categories') return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(categories)});
      if (action === 'get_series') return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(series(url.searchParams.get('category_id') || 'series'))});
    }
    return route.continue();
  });
  const activate = async target => (typeof target === 'string' ? page.locator(target) : target).press('Enter');
  const shown = selector => page.locator(selector).waitFor({state:'visible'});
  const modal = () => page.locator('.dialog:not([hidden])');
  const cards = () => page.locator('#media-items .media-card');
  const panel = () => page.locator('#media-view .media-panel');
  const category = title => page.locator('#media-categories').getByRole('button',{name:title,exact:true});
  const check = (value,label) => { if (!value) throw Error(label); };
  async function edit(target,value) {
    const input = typeof target === 'string' ? page.locator(target) : target;
    await activate(input); await input.fill(value); await input.press('Escape');
  }
  async function paint() { await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))); }
  async function scrollEnd() { await panel().evaluate(node => { node.scrollTop=node.scrollHeight; node.dispatchEvent(new Event('scroll')); }); }
  async function instrument() {
    await page.evaluate(() => {
      const api = window.TVBroSamsungPlatform, original = api.query;
      const state = window.__seriesScrollQa = {calls:[],active:0,maxActive:0,hold:null,fail:null,waiting:false,release:null};
      api.query = function (action,args) {
        if (action !== 'catalog.items' || args.kind !== 'series') return original.call(api,action,args);
        const call = {args:Object.assign({},args),settled:false}; state.calls.push(call);
        state.active++; state.maxActive=Math.max(state.maxActive,state.active);
        let pending;
        if (state.fail && args.page === state.fail.page && args.categoryId === state.fail.categoryId && !args.query) {
          state.fail=null; pending=Promise.reject(Error('Synthetic catalogue failure'));
        } else pending=original.call(api,action,args);
        if (state.hold && args.page === state.hold.page && args.categoryId === state.hold.categoryId && !args.query) {
          state.hold=null;
          pending=pending.then(data => new Promise(resolve => { state.waiting=true; state.release=() => { state.waiting=false; state.release=null; resolve(data); }; }));
        }
        return pending.then(data => {
          state.active--; call.settled=true; call.count=(data.items || []).length; call.hasMore=!!data.hasMore; return data;
        },error => { state.active--; call.settled=true; call.failed=true; throw error; });
      };
    });
  }
  async function openSeries() {
    await activate('#home-series'); await shown('#media-view'); await cards().first().waitFor();
    await check(await page.locator('#media-next').isHidden() && await page.locator('#media-previous').isHidden(), 'Series must have no visible pagination controls');
  }
  for (const size of [{width:1280,height:720},{width:1920,height:1080}]) {
    await page.setViewportSize(size); await page.goto(origin);
    await shown('#language-view'); await activate(page.locator('#language-list').getByRole('button',{name:'English',exact:true}));
    await shown('#profiles-view'); await activate('#add-profile'); await edit(modal().locator('input').first(),'Series scroll QA');
    await activate(modal().getByRole('button',{name:'Save',exact:true}));
    await shown('#setup-view'); await activate('#setup-source'); await shown('#sources-view'); await activate('#kind-xtream');
    await edit('#source-label','Series scroll source'); await edit('#source-field-host',origin+'/');
    await edit('#source-field-username','fixture-user'); await edit('#source-field-password','fixture-pass');
    await activate('#connect-source'); await shown('#home-view'); await instrument(); await openSeries();

    await cards().first().focus();
    await page.evaluate(() => { window.__seriesScrollQa.first=document.querySelector('#media-items .media-card'); window.__seriesScrollQa.focus=document.activeElement; });
    const initialCount=await page.locator('#media-items').evaluate(node => Number(node.getAttribute('data-series-count')));
    check(initialCount < 96,'The series catalogue must load progressively');
    await scrollEnd();
    await page.waitForFunction(count => Number(document.querySelector('#media-items').getAttribute('data-series-count')) > count,initialCount);
    check(await page.evaluate(() => document.querySelector('#media-items .media-card') === window.__seriesScrollQa.first),'Appending series must retain existing card nodes');
    check(await page.evaluate(() => document.activeElement === window.__seriesScrollQa.focus),'Appending series must not move remote focus');
    await page.waitForFunction(() => window.__seriesScrollQa.active===0);
    const appendedCount=await page.locator('#media-items').evaluate(node => Number(node.getAttribute('data-series-count')));
    await cards().last().focus();
    await page.evaluate(() => { window.__seriesScrollQa.edge=document.activeElement; });
    await page.keyboard.press('ArrowDown');
    await page.waitForFunction(count => Number(document.querySelector('#media-items').getAttribute('data-series-count')) > count &&
      document.activeElement !== window.__seriesScrollQa.edge && document.activeElement.classList.contains('media-card'),appendedCount);
    check(await page.locator(':focus').evaluate(node => Number(node.getAttribute('data-series-index'))) >= appendedCount,
      'A single remote Down at the loaded edge must focus a newly appended row');
    await cards().nth(Math.min(10,appendedCount-1)).focus(); await page.keyboard.press('ArrowDown');
    check(await page.locator(':focus').evaluate(node => node.classList.contains('media-card')),'Remote Down must remain inside the catalogue');
    const beforeDetail=await panel().evaluate(node => node.scrollTop);
    await page.evaluate(() => { window.__seriesScrollQa.opener=document.activeElement; });
    await page.keyboard.press('Enter'); await modal().locator('.details-close').waitFor(); await activate(modal().locator('.details-close'));
    check(await page.evaluate(() => document.activeElement===window.__seriesScrollQa.opener),'Details Back must return to the same series');
    check(Math.abs((await panel().evaluate(node => node.scrollTop))-beforeDetail)<=1,'Details Back must preserve series scroll');
    phases.push('append retains nodes/focus, remote navigation and details Back at '+size.width);

    for(let batch=0;batch<9;batch++) {
      const done=await page.evaluate(() => window.__seriesScrollQa.calls.some(call => call.settled && !call.hasMore));
      if(done) break;
      const count=await page.locator('#media-items').evaluate(node => Number(node.getAttribute('data-series-count'))); await scrollEnd();
      await page.waitForFunction(previous => Number(document.querySelector('#media-items').getAttribute('data-series-count')) > previous ||
        window.__seriesScrollQa.calls.some(call => call.settled && !call.hasMore),count);
    }
    await page.waitForFunction(() => window.__seriesScrollQa.active===0);
    check(await page.locator('#media-items').evaluate(node => Number(node.getAttribute('data-series-count')))===96,'Continuous scrolling must reach every series across provider pages');
    check(await cards().count()<=80,'Continuous scrolling must keep a bounded card window');
    await scrollEnd(); await page.waitForFunction(() => !!document.querySelector('#media-items [data-series-index="95"]'));
    check(await cards().last().isVisible(),'The final series must remain reachable');
    await panel().evaluate(node => { node.scrollTop=0; node.dispatchEvent(new Event('scroll')); });
    await page.waitForFunction(() => !!document.querySelector('#media-items [data-series-index="0"]'));
    check((await cards().first().textContent()).includes('Serial QA 000'),'Scrolling back must restore the first series');
    const stats=await page.evaluate(() => ({count:window.__seriesScrollQa.calls.length,maxActive:window.__seriesScrollQa.maxActive,
      pages:window.__seriesScrollQa.calls.map(call => call.args.page)}));
    check(stats.maxActive===1,'Scrolling must not overlap catalogue reads');
    check(new Set(stats.pages).size===stats.pages.length && stats.pages.length>=3,'Each provider page must load once and in sequence');
    await scrollEnd(); await paint(); await scrollEnd(); await paint();
    check(await page.evaluate(() => window.__seriesScrollQa.calls.length)===stats.count,'Scrolling at EOF must not request another page');
    samples.push({viewport:size.width,loaded:96,mounted:await cards().count(),pages:stats.pages,maxConcurrent:stats.maxActive});
    await page.screenshot({path:'D:/tvbro/output/playwright/samsung-series-scroll/series-'+size.width+'.png'});
    phases.push('continuous provider paging, one read at a time and stable EOF at '+size.width);

    await page.evaluate(() => { window.__seriesScrollQa.hold={categoryId:'series',page:2}; });
    await activate(category('Main series')); await page.waitForFunction(() => document.querySelector('#media-items').textContent.includes('Serial QA 000'));
    await scrollEnd(); await page.waitForFunction(() => window.__seriesScrollQa.waiting);
    check(await page.locator('#media-loading').isVisible(),'Appending a provider page must show the loading status');
    const heldReads=await page.evaluate(() => window.__seriesScrollQa.calls.length);
    await scrollEnd(); await paint();
    check(await page.evaluate(() => window.__seriesScrollQa.active===1 && window.__seriesScrollQa.calls.length)===heldReads,'Scrolling during a held page must retain one in-flight read');
    await activate(category('Alternate series'));
    await page.waitForFunction(() => document.querySelectorAll('#media-items .media-card').length===3 && document.querySelector('#media-items').textContent.includes('Alternate QA 000'));
    check(await panel().evaluate(node => node.scrollTop)===0,'Category changes must reset series scroll');
    await page.evaluate(() => window.__seriesScrollQa.release()); await paint();
    check(await cards().count()===3 && !(await page.locator('#media-items').textContent()).includes('Serial QA'),'A delayed previous-category page must not append to the selected category');
    await activate(category('Main series'));
    await page.waitForFunction(() => document.querySelector('#media-items').textContent.includes('Serial QA 000'));
    await edit('#media-search','Serial QA');
    await page.waitForFunction(() => window.__seriesScrollQa.calls.some(call => call.settled && call.args.query==='Serial QA') && Number(document.querySelector('#media-items').getAttribute('data-series-count'))===80);
    check(await panel().evaluate(node => node.scrollTop)===0,'A new search must reset series scroll');
    const searchReads=await page.evaluate(() => window.__seriesScrollQa.calls.filter(call => call.args.query==='Serial QA').length);
    await scrollEnd(); await page.waitForFunction(() => Number(document.querySelector('#media-items').getAttribute('data-series-count'))===91);
    check(await cards().count()<=80,'Buffered search results must keep a bounded card window');
    check(await page.evaluate(() => window.__seriesScrollQa.calls.filter(call => call.args.query==='Serial QA').length)===searchReads,'Scrolling a buffered search must reveal its remaining rows without repeating the provider search');
    phases.push('category reset rejects stale append; search reveals buffered results on scroll at '+size.width);

    await edit('#media-search','');
    await activate(category('Alternate series'));
    await page.waitForFunction(() => document.querySelectorAll('#media-items .media-card').length===3 && document.querySelector('#media-items').textContent.includes('Alternate QA 000'));
    await page.evaluate(() => { window.__seriesScrollQa.fail={categoryId:'series',page:2}; });
    await activate(category('Main series')); await cards().first().waitFor(); await scrollEnd();
    await page.locator('#media-retry').waitFor({state:'visible'});
    const failedCount=await page.locator('#media-items').evaluate(node => Number(node.getAttribute('data-series-count'))), failedReads=await page.evaluate(() => window.__seriesScrollQa.calls.length);
    check(failedCount>0,'A failed append must retain already loaded series');
    await paint(); await scrollEnd(); await paint();
    check(await page.evaluate(() => window.__seriesScrollQa.calls.length)===failedReads,'A failed append must not retry automatically');
    await activate('#media-retry');
    await page.waitForFunction(count => Number(document.querySelector('#media-items').getAttribute('data-series-count')) > count,failedCount);
    check(await page.locator('#app-status').evaluate(node => !node.classList.contains('is-error') && !node.textContent.trim()),'A successful retry must clear the old error banner');
    check(await page.locator(':focus').evaluate(node => node.classList.contains('media-card')),'A successful retry must return focus to an appended series card');
    phases.push('failed append keeps loaded rows and waits for explicit retry at '+size.width);

    await activate('#show-home'); await shown('#home-view'); await activate('#home-movie'); await shown('#media-view');
    await page.waitForFunction(() => document.querySelectorAll('#media-items .media-card').length===14);
    check(await page.locator('#media-next').isVisible(),'Movie pagination must remain available');
    await activate('#media-next'); await page.waitForFunction(() => document.querySelectorAll('#media-items .media-card').length===1);
    check((await page.locator('#media-items').textContent()).includes('Film 14'),'Movie next-page behavior must remain unchanged');
  }
  await page.unrouteAll({behavior:'wait'});
  if(errors.length) throw Error('Browser runtime errors: '+errors.join('; '));
  return {status:'passed',phases,samples,browserErrors:errors,
    scope:'Actual packaged UI, original Dart catalogue Source and loopback HTTP/SDK boundaries only; not physical Samsung timing or decoding.'};
}
